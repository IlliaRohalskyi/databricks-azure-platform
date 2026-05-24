param(
    [switch]$DryRun,
    [string]$ResourceGroupName = "rg-sensor-platform",
    [string]$Location = "West Europe",
    [string]$StorageAccountName = "",
    [string]$DatabricksWorkspaceName = "dbw-sensor-platform",
    [string]$ManagedResourceGroupName = "rg-sensor-platform-dbw-managed"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$terraformDir = Join-Path $projectRoot "terraform"
$csvPath = Join-Path $projectRoot "sensor_data_raw.csv"
$notebooksDir = Join-Path $projectRoot "notebooks"

function Assert-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
                switch ($Name) {
                        "az" {
                                throw @"
Missing required command: az

Install Azure CLI before running the deploy script.
Windows install:
    winget install -e --id Microsoft.AzureCLI

After installation, open a new terminal and verify:
    az --version
"@
                        }
                        "terraform" {
                                throw @"
Missing required command: terraform

Install Terraform before running the deploy script.
Windows install:
    winget install -e --id HashiCorp.Terraform
"@
                        }
                        "uv" {
                                throw @"
Missing required command: uv

Install uv before running the deploy script.
Windows install:
    winget install -e --id Astral.uv
"@
                        }
                        default {
                                throw "Missing required command: $Name"
                        }
                }
    }
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $prettyCommand = @($FilePath) + $Arguments -join " "
    Write-Host "`n>> $prettyCommand" -ForegroundColor Cyan

    if ($DryRun) {
        return
    }

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $prettyCommand"
    }
}

function Ensure-AzLogin {
    if ($DryRun) {
        Write-Host "Skipping Azure login check in dry-run mode." -ForegroundColor DarkGray
        return
    }

    try {
        Invoke-External -FilePath "az" -Arguments @("account", "show", "--query", "id", "-o", "tsv")
        return
    }
    catch {
        Write-Host "Azure CLI is not logged in. Starting device-code login..." -ForegroundColor Yellow
        Invoke-External -FilePath "az" -Arguments @("login", "--use-device-code")
        Invoke-External -FilePath "az" -Arguments @("account", "show", "--query", "id", "-o", "tsv")
    }
}

function New-StorageAccountName {
    $suffix = Get-Random -Minimum 100000 -Maximum 999999
    return "spdl$suffix"
}

function Get-TerraformOutputRaw {
    param([string]$Name)

    Push-Location $terraformDir
    try {
        $value = terraform output -raw $Name 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }

        return $null
    }
    finally {
        Pop-Location
    }
}

function Test-TerraformStateHasResources {
    Push-Location $terraformDir
    try {
        $stateList = terraform state list 2>$null
        return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($stateList))
    }
    finally {
        Pop-Location
    }
}

function Ensure-TerraformStateMoved {
    param(
        [string]$Source,
        [string]$Destination
    )

    Push-Location $terraformDir
    try {
        $stateList = terraform state list 2>$null
        if ($LASTEXITCODE -ne 0) {
            return
        }

        $sourceExists = $stateList -match [regex]::Escape($Source)
        $destinationExists = $stateList -match [regex]::Escape($Destination)

        if ($sourceExists -and -not $destinationExists) {
            Write-Host "Migrating Terraform state: $Source -> $Destination" -ForegroundColor Yellow
            Invoke-External -FilePath "terraform" -Arguments @("state", "mv", $Source, $Destination)
        }
    }
    finally {
        Pop-Location
    }
}

function Get-DatabricksAadToken {
    $token = & az account get-access-token --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Failed to acquire Azure AD token for Databricks API. Ensure az login succeeded."
    }

    return $token.Trim()
}

function Import-DatabricksNotebook {
    param(
        [string]$WorkspaceUrl,
        [string]$AadToken,
        [string]$LocalFilePath,
        [string]$RemoteNotebookPath
    )

    if (-not (Test-Path $LocalFilePath)) {
        throw "Notebook file not found: $LocalFilePath"
    }

    $workspaceHost = $WorkspaceUrl
    if (-not $workspaceHost.StartsWith("https://")) {
        $workspaceHost = "https://$workspaceHost"
    }

    $fileContent = Get-Content -Path $LocalFilePath -Raw -Encoding UTF8
    $base64Content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($fileContent))

    $payload = @{
        path      = $RemoteNotebookPath
        format    = "SOURCE"
        language  = "PYTHON"
        overwrite = $true
        content   = $base64Content
    } | ConvertTo-Json -Depth 5

    $headers = @{
        Authorization = "Bearer $AadToken"
    }

    Write-Host "Uploading notebook: $RemoteNotebookPath" -ForegroundColor DarkGray
    Invoke-RestMethod -Method Post -Uri "$workspaceHost/api/2.0/workspace/import" -Headers $headers -ContentType "application/json" -Body $payload | Out-Null
}

function Import-DatabricksNotebooks {
    param([string]$WorkspaceUrl)

    $aadToken = Get-DatabricksAadToken

    $workspaceHost = $WorkspaceUrl
    if (-not $workspaceHost.StartsWith("https://")) {
        $workspaceHost = "https://$workspaceHost"
    }

    $headers = @{
        Authorization = "Bearer $aadToken"
    }

    # Use Shared folder to avoid relying on a specific user home path.
    $mkdirPayload = @{ path = "/Shared/sensor-pipeline" } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$workspaceHost/api/2.0/workspace/mkdirs" -Headers $headers -ContentType "application/json" -Body $mkdirPayload | Out-Null

    Import-DatabricksNotebook -WorkspaceUrl $WorkspaceUrl -AadToken $aadToken -LocalFilePath (Join-Path $notebooksDir "01_bronze_ingest.py") -RemoteNotebookPath "/Shared/sensor-pipeline/01_bronze_ingest"
    Import-DatabricksNotebook -WorkspaceUrl $WorkspaceUrl -AadToken $aadToken -LocalFilePath (Join-Path $notebooksDir "02_silver_transform.py") -RemoteNotebookPath "/Shared/sensor-pipeline/02_silver_transform"
    Import-DatabricksNotebook -WorkspaceUrl $WorkspaceUrl -AadToken $aadToken -LocalFilePath (Join-Path $notebooksDir "03_gold_aggregate.py") -RemoteNotebookPath "/Shared/sensor-pipeline/03_gold_aggregate"
}

if (-not $DryRun) {
    Assert-Command -Name "uv"
    Assert-Command -Name "terraform"
    Assert-Command -Name "az"
}

if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
    if (Test-TerraformStateHasResources) {
        $existingStorageAccountName = Get-TerraformOutputRaw -Name "storage_account_name"
        if (-not [string]::IsNullOrWhiteSpace($existingStorageAccountName)) {
            $StorageAccountName = $existingStorageAccountName
            Write-Host "Reusing existing storage account from Terraform state: $StorageAccountName" -ForegroundColor DarkGray
        }
        else {
            $StorageAccountName = New-StorageAccountName
        }
    }
    else {
        $StorageAccountName = New-StorageAccountName
    }
}

if ($StorageAccountName.Length -lt 3 -or $StorageAccountName.Length -gt 24 -or $StorageAccountName -notmatch '^[a-z0-9]+$') {
    throw "Storage account name must be 3-24 lowercase alphanumeric characters. Got: $StorageAccountName"
}

Ensure-AzLogin

Invoke-External -FilePath "terraform" -Arguments @(
    "-chdir=$terraformDir",
    "init"
)

if (-not $DryRun) {
    Ensure-TerraformStateMoved -Source "azurerm_data_factory_linked_service_web.databricks_linked_service" -Destination "azurerm_data_factory_linked_service_web.databricks_linked_service_legacy"
}

Invoke-External -FilePath "terraform" -Arguments @(
    "-chdir=$terraformDir",
    "apply",
    "-auto-approve",
    "-var",
    "resource_group_name=$ResourceGroupName",
    "-var",
    "location=$Location",
    "-var",
    "storage_account_name=$StorageAccountName",
    "-var",
    "databricks_workspace_name=$DatabricksWorkspaceName",
    "-var",
    "managed_resource_group_name=$ManagedResourceGroupName"
)

Invoke-External -FilePath "uv" -Arguments @("run", "python", "generate_data.py")

if (-not $DryRun) {
    $accountKey = & az storage account keys list --resource-group $ResourceGroupName --account-name $StorageAccountName --query "[0].value" -o tsv
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read the storage account key for $StorageAccountName"
    }

    Invoke-External -FilePath "az" -Arguments @(
        "storage",
        "blob",
        "upload",
        "--account-name",
        $StorageAccountName,
        "--account-key",
        $accountKey,
        "--container-name",
        "raw-data",
        "--name",
        "sensor_data_raw.csv",
        "--file",
        $csvPath,
        "--overwrite",
        "true"
    )
}

Write-Host "`nDeployment complete." -ForegroundColor Green
Write-Host "Storage account: $StorageAccountName"
Write-Host "Databricks workspace name: $DatabricksWorkspaceName"
Write-Host "Raw CSV: $csvPath"

$workspaceUrl = ""
$adfName = "adf-sensor-platform"
$adfPipelineName = "pipeline-sensor-medallion"
$adfPrincipal = ""

if (-not $DryRun) {
    Push-Location $terraformDir
    try {
        $workspaceUrl = terraform output -raw databricks_workspace_url 2>$null
        if ($LASTEXITCODE -eq 0 -and $workspaceUrl) {
            Write-Host "Databricks workspace URL: $workspaceUrl"
        }
        
        $adfName = terraform output -raw data_factory_name 2>$null
        $adfPrincipal = terraform output -raw data_factory_principal_id 2>$null
        $adfPipelineName = terraform output -raw adf_pipeline_name 2>$null
        if ($LASTEXITCODE -eq 0 -and $adfName) {
            Write-Host "Data Factory deployed: $adfName"
            Write-Host "ADF Pipeline created: $adfPipelineName"
            Write-Host "ADF managed identity principal id: $adfPrincipal"
        }
    }
    finally {
        Pop-Location
    }

    if ($workspaceUrl) {
        Import-DatabricksNotebooks -WorkspaceUrl $workspaceUrl
        Write-Host "Databricks notebooks uploaded successfully." -ForegroundColor Green
    }
}

Write-Host "`n=== NEXT STEPS ===" -ForegroundColor Cyan
Write-Host "`n1. Create and start a Databricks cluster (in Databricks workspace UI)" -ForegroundColor Yellow
Write-Host "`n2. Trigger the ADF pipeline:" -ForegroundColor Yellow
Write-Host "   Azure Portal > Data Factories > $adfName > Author > Pipelines > $adfPipelineName"
Write-Host "   Click: Trigger > Trigger Now"
Write-Host "`n3. Monitor pipeline execution:" -ForegroundColor Yellow
Write-Host "   Azure Portal > Data Factories > $adfName > Monitor > Pipeline Runs"
Write-Host "   Or open Databricks to see job executions"