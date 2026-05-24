terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.73.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "resource_group_name" {
  type    = string
  default = "rg-sensor-platform"
}

variable "location" {
  type    = string
  default = "West Europe"
}

variable "storage_account_name" {
  type = string
}

variable "databricks_workspace_name" {
  type    = string
  default = "dbw-sensor-platform"
}

variable "managed_resource_group_name" {
  type    = string
  default = "rg-sensor-platform-dbw-managed"
}

resource "azurerm_resource_group" "sensor_platform" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_storage_account" "datalake" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.sensor_platform.name
  location                 = azurerm_resource_group.sensor_platform.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  is_hns_enabled           = true
}

resource "azurerm_databricks_workspace" "workspace" {
  name                        = var.databricks_workspace_name
  resource_group_name         = azurerm_resource_group.sensor_platform.name
  location                    = azurerm_resource_group.sensor_platform.location
  sku                         = "premium"
  managed_resource_group_name = var.managed_resource_group_name
}

resource "azurerm_data_factory" "adf" {
  name                = "adf-sensor-platform"
  location            = azurerm_resource_group.sensor_platform.location
  resource_group_name = azurerm_resource_group.sensor_platform.name

  identity {
    type = "SystemAssigned"
  }
}

# Grant the ADF managed identity access to the storage account (Blob Data Contributor)
resource "azurerm_role_assignment" "adf_storage_blob_contributor" {
  scope                = azurerm_storage_account.datalake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

# Grant the ADF managed identity permission on the Databricks workspace so it can call the Jobs API
resource "azurerm_role_assignment" "adf_databricks_contributor" {
  scope                = azurerm_databricks_workspace.workspace.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

resource "azurerm_storage_container" "layers" {
  for_each             = toset(["raw-data", "bronze", "silver", "gold"])
  name                 = each.value
  storage_account_id   = azurerm_storage_account.datalake.id
}

output "resource_group_name" {
  value = azurerm_resource_group.sensor_platform.name
}

output "storage_account_name" {
  value = azurerm_storage_account.datalake.name
}

output "databricks_workspace_url" {
  value = azurerm_databricks_workspace.workspace.workspace_url
}

output "data_factory_name" {
  value = azurerm_data_factory.adf.name
}

output "data_factory_principal_id" {
  value = azurerm_data_factory.adf.identity[0].principal_id
}

# ADF Linked Service for ADLS Gen2
resource "azurerm_data_factory_linked_service_data_lake_storage_gen2" "adls_linked_service" {
  name                 = "ls-adls-gen2"
  data_factory_id      = azurerm_data_factory.adf.id
  url                  = "https://${azurerm_storage_account.datalake.name}.dfs.core.windows.net"
  use_managed_identity = true
}

# Legacy ADF Linked Service for Databricks (kept temporarily so Terraform does not try to delete the
# live object before the pipeline has fully migrated to MSI)
resource "azurerm_data_factory_linked_service_web" "databricks_linked_service_legacy" {
  name                = "ls-databricks"
  data_factory_id     = azurerm_data_factory.adf.id
  url                 = "https://${azurerm_databricks_workspace.workspace.workspace_url}"
  authentication_type = "Anonymous"
}

# ADF Linked Service for Databricks
resource "azurerm_data_factory_linked_service_azure_databricks" "databricks_linked_service" {
  name            = "ls-databricks-msi"
  data_factory_id = azurerm_data_factory.adf.id
  adb_domain      = "https://${azurerm_databricks_workspace.workspace.workspace_url}"
  msi_workspace_id = azurerm_databricks_workspace.workspace.id

  new_cluster_config {
    node_type             = "Standard_D2ads_v6"
    cluster_version       = "14.3.x-scala2.12"
    min_number_of_workers = 1
    max_number_of_workers = 1
  }
}

# ADF Pipeline with three chained Databricks Notebook activities
resource "azurerm_data_factory_pipeline" "sensor_pipeline" {
  name            = "pipeline-sensor-medallion"
  data_factory_id = azurerm_data_factory.adf.id
  
  activities_json = jsonencode([
    {
      name = "bronze-ingest"
      type = "DatabricksNotebook"
      typeProperties = {
        notebookPath = "/Shared/sensor-pipeline/01_bronze_ingest"
        baseParameters = {
          storage_account = var.storage_account_name
          storage_key     = azurerm_storage_account.datalake.primary_access_key
        }
      }
      linkedServiceName = {
        referenceName = azurerm_data_factory_linked_service_azure_databricks.databricks_linked_service.name
        type          = "LinkedServiceReference"
      }
      dependsOn = []
    },
    {
      name = "silver-transform"
      type = "DatabricksNotebook"
      typeProperties = {
        notebookPath = "/Shared/sensor-pipeline/02_silver_transform"
        baseParameters = {
          storage_account = var.storage_account_name
          storage_key     = azurerm_storage_account.datalake.primary_access_key
        }
      }
      linkedServiceName = {
        referenceName = azurerm_data_factory_linked_service_azure_databricks.databricks_linked_service.name
        type          = "LinkedServiceReference"
      }
      dependsOn = [
        {
          activity = "bronze-ingest"
          dependencyConditions = ["Succeeded"]
        }
      ]
    },
    {
      name = "gold-aggregate"
      type = "DatabricksNotebook"
      typeProperties = {
        notebookPath = "/Shared/sensor-pipeline/03_gold_aggregate"
        baseParameters = {
          storage_account = var.storage_account_name
          storage_key     = azurerm_storage_account.datalake.primary_access_key
        }
      }
      linkedServiceName = {
        referenceName = azurerm_data_factory_linked_service_azure_databricks.databricks_linked_service.name
        type          = "LinkedServiceReference"
      }
      dependsOn = [
        {
          activity = "silver-transform"
          dependencyConditions = ["Succeeded"]
        }
      ]
    }
  ])
}

output "adf_pipeline_name" {
  value = azurerm_data_factory_pipeline.sensor_pipeline.name
}