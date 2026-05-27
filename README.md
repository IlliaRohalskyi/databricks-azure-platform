# Azure Databricks Sensor Platform

An Azure + Databricks medallion demo that shows end-to-end data engineering work:

- Terraform provisions Azure infrastructure.
- Azure Data Factory orchestrates Databricks notebook execution.
- Databricks notebooks build bronze, silver, and gold Delta layers.
- A small synthetic sensor dataset is generated locally and uploaded to ADLS.
- The repository uses a repeatable deploy script.

## What This Project Demonstrates

- Infrastructure as code with Terraform.
- Azure Data Factory orchestration with a managed identity.
- Azure Databricks notebook execution from ADF.
- ADLS Gen2 storage for raw and curated data.
- A medallion architecture: raw -> bronze -> silver -> gold.
- Automated notebook upload and pipeline deployment from a single PowerShell script.

## Architecture

- **Raw**: synthetic CSV in ADLS `raw-data` container.
- **Bronze**: Databricks ingests the CSV and appends ingest metadata.
- **Silver**: Databricks cleans types, removes duplicates, and filters bad rows.
- **Gold**: Databricks aggregates by machine and hour for reporting.

Azure Data Factory triggers the notebooks in order:

1. `01_bronze_ingest`
2. `02_silver_transform`
3. `03_gold_aggregate`

The Databricks notebooks live in the shared workspace folder:

```text
/Shared/sensor-pipeline
```

## Repository Layout

- `generate_data.py` - creates the synthetic CSV used by the pipeline.
- `notebooks/` - Databricks notebooks for bronze, silver, and gold processing.
- `terraform/main.tf` - Azure resource definitions and the ADF pipeline.
- `scripts/deploy.ps1` - one-command deploy, data upload, and notebook import.

## Prerequisites

Install the following before running the project:

- Python 3.13+
- `uv`
- Azure CLI (`az`)
- Terraform
- PowerShell 7 or Windows PowerShell with execution policy allowed for the session

You also need an Azure subscription with permissions to create:

- Resource groups
- Storage accounts
- Azure Data Factory
- Azure Databricks workspaces
- Role assignments

## Quick Start

### 1. Install Python dependencies

```powershell
uv sync
```

### 2. Sign in to Azure

```powershell
az login
```

### 3. Deploy everything

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
```

The deploy script will:

- initialize and apply Terraform,
- generate `sensor_data_raw.csv`,
- upload the CSV to ADLS,
- upload the Databricks notebooks to `/Shared/sensor-pipeline`,
- and print the Azure resources and next steps.

### 4. Trigger the pipeline

In the Azure Portal:

1. Open **Data Factories**.
2. Select **adf-sensor-platform**.
3. Go to **Author** -> **Pipelines** -> **pipeline-sensor-medallion**.
4. Click **Trigger** -> **Trigger now**.

### 5. Monitor the run

Check the run in either place:

- Azure Portal -> **Data Factory** -> **Monitor**
- Databricks workspace -> job run details

## Verify the Data at Each Layer

Replace the storage account name with the one printed by deploy. The current environment uses `spdl213435`.

### Raw

```powershell
az storage blob list --account-name spdl213435 --container-name raw-data --auth-mode login -o table
```

### Bronze / Silver / Gold

Run these in a Databricks notebook or the notebook UI:

```python
spark.read.format("delta").load("abfss://bronze@spdl213435.dfs.core.windows.net/sensors/").count()
spark.read.format("delta").load("abfss://silver@spdl213435.dfs.core.windows.net/sensors/").count()
spark.read.format("delta").load("abfss://gold@spdl213435.dfs.core.windows.net/machine_hourly_metrics/").count()
```

## Local Development

Validate syntax locally:

```powershell
uv run python -m compileall generate_data.py notebooks src scripts
```

Generate data without deploying:

```powershell
uv run python generate_data.py
```

## Clean Up

To remove the Azure resources:

```powershell
terraform -chdir=terraform destroy
```

## Notes

- Generated run outputs and the local CSV are intentionally ignored by Git.
- Notebooks are imported into the shared workspace folder, not a user home folder.
- The deploy script reuses the existing storage account when state already exists.
