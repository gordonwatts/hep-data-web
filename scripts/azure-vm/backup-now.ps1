[CmdletBinding()]
param(
  [string]$DefaultsPath = "",
  [string]$ConfigPath = "",
  [string]$Subscription = "",
  [string]$ResourceGroup = "",
  [string]$VmName = "",
  [string]$AdminUser = ""
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
$AdminUser = Get-ResolvedValue -ExplicitValue $AdminUser -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_ADMIN_USER" -DefaultValue "hepadmin"
$VmHost = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_PUBLIC_HOSTNAME"
$publicKeyPath = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_SSH_PUBLIC_KEY_PATH"
$privateKeyPath = Get-SshPrivateKeyPath -PublicKeyPath $publicKeyPath -PrivateKeyPath (Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_SSH_PRIVATE_KEY_PATH")
$VmDataMount = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_DATA_MOUNT" -DefaultValue "/srv/hep-data-web"
$BackupStorageConnectionString = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_BACKUP_CONNECTION_STRING"
$BackupStorageAccount = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_BACKUP_STORAGE_ACCOUNT"
$BackupContainer = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_BACKUP_CONTAINER"

if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
  Invoke-Az -Arguments @("account", "set", "--subscription", $Subscription)
}

$vmInfoJson = & az vm show -d --resource-group $ResourceGroup --name $VmName --query "{publicIp:publicIps,fqdn:fqdns}" -o json
if ($LASTEXITCODE -ne 0) {
  throw "Unable to read VM network details for '$VmName'."
}
$vmInfo = $vmInfoJson | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($VmHost)) {
  $VmHost = if (-not [string]::IsNullOrWhiteSpace($vmInfo.fqdn)) { $vmInfo.fqdn } else { $vmInfo.publicIp }
}
if ([string]::IsNullOrWhiteSpace($VmHost)) {
  throw "AZURE_VM_PUBLIC_HOSTNAME is required for backup operations."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$remoteBackupDir = "$VmDataMount/backups/$timestamp"
$remoteCommand = "bash -lc 'set -euo pipefail; mkdir -p $remoteBackupDir; cd $VmDataMount/compose; docker compose --env-file $VmDataMount/env/.env -f docker-compose.vm.yml exec -T postgres pg_dump -U hep_data_web hep_data_web > $remoteBackupDir/hep_data_web.sql; tar -czf $remoteBackupDir/artifacts.tgz -C $VmDataMount data/media data/staticfiles data/caddy data/caddy-config'"
if ([string]::IsNullOrWhiteSpace($privateKeyPath)) {
  & ssh -o StrictHostKeyChecking=accept-new "$AdminUser@$VmHost" $remoteCommand
}
else {
  & ssh -o StrictHostKeyChecking=accept-new -i $privateKeyPath "$AdminUser@$VmHost" $remoteCommand
}
if ($LASTEXITCODE -ne 0) {
  throw "Backup command failed on '$VmHost'."
}

Write-Host "Backup staged on $VmHost at $remoteBackupDir"

if (-not [string]::IsNullOrWhiteSpace($BackupStorageConnectionString) -and -not [string]::IsNullOrWhiteSpace($BackupContainer)) {
  $localStaging = Join-Path $env:TEMP "hep-data-web-backup-$timestamp"
  if (Test-Path -LiteralPath $localStaging) {
    Remove-Item -LiteralPath $localStaging -Recurse -Force
  }
  New-Item -ItemType Directory -Path $localStaging | Out-Null

  Write-Host "Copying the staged backup back to the local machine for upload..."
  if ([string]::IsNullOrWhiteSpace($privateKeyPath)) {
    & scp -o StrictHostKeyChecking=accept-new -r "$AdminUser@$VmHost`:$remoteBackupDir" $localStaging
  }
  else {
    & scp -o StrictHostKeyChecking=accept-new -i $privateKeyPath -r "$AdminUser@$VmHost`:$remoteBackupDir" $localStaging
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to copy the backup from '$VmHost'."
  }

  $archiveName = "hep-data-web-$timestamp"
  $uploadCommand = @(
    "storage", "blob", "upload-batch",
    "--connection-string", $BackupStorageConnectionString,
    "--destination", $BackupContainer,
    "--source", (Join-Path $localStaging (Split-Path -Leaf $remoteBackupDir)),
    "--pattern", "*",
    "--destination-path", $archiveName,
    "--only-show-errors",
    "--output", "none"
  )
  Write-Host "Uploading backup to Azure Blob Storage container '$BackupContainer'..."
  Invoke-Az -Arguments $uploadCommand
}
elseif (-not [string]::IsNullOrWhiteSpace($BackupStorageAccount)) {
  Write-Host "Backup storage account '$BackupStorageAccount' is configured but no connection string was supplied, so the backup remains on the VM."
}
