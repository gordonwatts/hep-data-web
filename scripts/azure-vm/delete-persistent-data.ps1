[CmdletBinding()]
param(
  [string]$DefaultsPath = "",
  [string]$ConfigPath = "",
  [string]$Subscription = "",
  [string]$ResourceGroup = "",
  [string]$VmName = "",
  [string]$DataDiskName = "",
  [switch]$Force
)

. "$PSScriptRoot\_common.ps1"

if ([string]::IsNullOrWhiteSpace($DefaultsPath)) {
  $DefaultsPath = Join-Path $PSScriptRoot "deploy.env.example"
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot "deploy.env"
}

$defaultConfig = Read-DotEnvFile -PathValue $DefaultsPath
$userConfig = Read-DotEnvFile -PathValue $ConfigPath

$Subscription = Get-ResolvedValue -ExplicitValue $Subscription -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_SUBSCRIPTION"
$ResourceGroup = Get-ResolvedValue -ExplicitValue $ResourceGroup -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_RESOURCE_GROUP" -DefaultValue "hep-data-web-vm"
$VmName = Get-ResolvedValue -ExplicitValue $VmName -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_NAME" -DefaultValue "hep-data-web-vm"
$DataDiskName = Get-ResolvedValue -ExplicitValue $DataDiskName -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_DATA_DISK_NAME" -DefaultValue "$VmName-data"
$BackupConnectionString = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_BACKUP_CONNECTION_STRING"
$BackupStorageAccount = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_BACKUP_STORAGE_ACCOUNT"
$BackupContainer = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_BACKUP_CONTAINER"

if (-not $Force) {
  $confirmation = Read-Host "Type DELETE to remove data disk '$DataDiskName' and any configured backup container"
  if ($confirmation -ne "DELETE") {
    throw "Confirmation not provided."
  }
}

if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
  Invoke-Az -Arguments @("account", "set", "--subscription", $Subscription)
}

Write-Host "Deleting managed disk '$DataDiskName'..."
Invoke-Az -Arguments @(
  "disk", "delete",
  "--resource-group", $ResourceGroup,
  "--name", $DataDiskName,
  "--yes",
  "--only-show-errors",
  "--output", "none"
)

if (-not [string]::IsNullOrWhiteSpace($BackupStorageAccount) -and -not [string]::IsNullOrWhiteSpace($BackupContainer)) {
  $backupDeleteConfirmation = if ($Force) { "DELETE" } else { Read-Host "Type DELETE again to remove backup container '$BackupContainer'" }
  if ($backupDeleteConfirmation -ne "DELETE") {
    throw "Backup container confirmation not provided."
  }

  if (-not [string]::IsNullOrWhiteSpace($BackupConnectionString)) {
    Write-Host "Deleting backup container '$BackupContainer'..."
    Invoke-Az -Arguments @(
      "storage", "container", "delete",
      "--connection-string", $BackupConnectionString,
      "--name", $BackupContainer,
      "--yes",
      "--only-show-errors",
      "--output", "none"
    )
  }
  else {
    Write-Host "Backup storage account '$BackupStorageAccount' is configured, but no connection string was supplied, so the backup container was not deleted."
  }
}

Write-Host "Persistent data removed."
