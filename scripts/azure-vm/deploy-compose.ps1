[CmdletBinding()]
param(
  [string]$DefaultsPath = "",
  [string]$ConfigPath = "",
  [string]$Subscription = "",
  [string]$ResourceGroup = "",
  [string]$VmName = "",
  [string]$AdminUser = "",
  [string]$VmHost = "",
  [string]$SshPrivateKeyPath = ""
)

. "$PSScriptRoot\_common.ps1"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

if ([string]::IsNullOrWhiteSpace($DefaultsPath)) {
  $DefaultsPath = Join-Path $PSScriptRoot "deploy.env.example"
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot "deploy.env"
}

$DefaultsPath = Resolve-ExistingRelativePath -PathValue $DefaultsPath -SearchDirectories @($PSScriptRoot, $repoRoot)
$ConfigPath = Resolve-ExistingRelativePath -PathValue $ConfigPath -SearchDirectories @((Get-Location).Path, $repoRoot)

$defaultConfig = Read-DotEnvFile -PathValue $DefaultsPath
$userConfig = Read-DotEnvFile -PathValue $ConfigPath

$Subscription = Get-ResolvedValue -ExplicitValue $Subscription -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_SUBSCRIPTION"
$ResourceGroup = Get-ResolvedValue -ExplicitValue $ResourceGroup -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_RESOURCE_GROUP" -DefaultValue "hep-data-web-vm"
$VmName = Get-ResolvedValue -ExplicitValue $VmName -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_NAME" -DefaultValue "hep-data-web-vm"
$AdminUser = Get-ResolvedValue -ExplicitValue $AdminUser -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_ADMIN_USER" -DefaultValue "hepadmin"
$VmHost = Get-ResolvedValue -ExplicitValue $VmHost -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_PUBLIC_HOSTNAME"
$publicKeyPath = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_SSH_PUBLIC_KEY_PATH"
$publicKeyPath = Resolve-ExistingRelativePath -PathValue $publicKeyPath -SearchDirectories @((Split-Path -Parent $ConfigPath), $repoRoot, (Get-Location).Path)
$SshPrivateKeyPath = Get-ResolvedValue -ExplicitValue $SshPrivateKeyPath -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_SSH_PRIVATE_KEY_PATH"
$SshPrivateKeyPath = Get-SshPrivateKeyPath -PublicKeyPath $publicKeyPath -PrivateKeyPath $SshPrivateKeyPath
$VmDataMount = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_DATA_MOUNT" -DefaultValue "/srv/hep-data-web"
$VmImage = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_IMAGE"
$VmTlsEmail = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_TLS_EMAIL"
$VmTlsMode = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_TLS_MODE" -DefaultValue "letsencrypt"
$PostgresPassword = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "POSTGRES_PASSWORD" -DefaultValue "hep_data_web"
$SecretKey = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "SECRET_KEY"
$AllowedHosts = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "ALLOWED_HOSTS"
$CsrfTrustedOrigins = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "CSRF_TRUSTED_ORIGINS"
$DatabaseUrl = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "DATABASE_URL" -DefaultValue "postgresql://hep_data_web:${PostgresPassword}@postgres:5432/hep_data_web"
$GithubClientId = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "GITHUB_CLIENT_ID"
$GithubClientSecret = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "GITHUB_CLIENT_SECRET"
$GithubOrg = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "GITHUB_ORG"
$GithubAdminUsers = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "GITHUB_ADMIN_USERS"
$AdminEmails = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "ADMIN_EMAILS"
$OpenAiApiKey = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "OPENAI_API_KEY"
$ServiceXConfigPath = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "SERVICEX_CONFIG_PATH"
$ServiceXContainerPath = if ([string]::IsNullOrWhiteSpace($ServiceXConfigPath)) { "" } else { "/host-home/servicex.yaml" }
$HePHomeDir = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "HEP_DATA_LLM_HOME_DIR" -DefaultValue "/host-home"
$ServiceXAwkwardImage = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE"
$RdfImage = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "HEP_DATA_LLM_RDF_DOCKER_IMAGE"
$BackendModel = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "HEP_DATA_LLM_MODEL" -DefaultValue "gpt-54-mini"
$BackendRepairCycles = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "HEP_DATA_LLM_REPAIR_CYCLES" -DefaultValue "10"
$JobQueueLimit = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "JOB_QUEUE_LIMIT" -DefaultValue "3"
$JobPollIntervalSeconds = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "JOB_POLL_INTERVAL_SECONDS" -DefaultValue "1"
$JobSoftTimeoutSeconds = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "JOB_SOFT_TIMEOUT_SECONDS" -DefaultValue "1800"
$JobHardTimeoutSeconds = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "JOB_HARD_TIMEOUT_SECONDS" -DefaultValue "2400"

if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
  Invoke-Az -Arguments @("account", "set", "--subscription", $Subscription)
}

$vmInfoJson = & az vm show -d --resource-group $ResourceGroup --name $VmName --query "{publicIp:publicIps,fqdn:fqdns}" -o json
if ($LASTEXITCODE -ne 0) {
  throw "Unable to read VM network details for '$VmName'."
}

$vmInfo = $vmInfoJson | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($vmInfo.publicIp)) {
  throw "Unable to determine the VM public IP."
}
if ([string]::IsNullOrWhiteSpace($VmHost)) {
  $VmHost = if (-not [string]::IsNullOrWhiteSpace($vmInfo.fqdn)) { $vmInfo.fqdn } else { $vmInfo.publicIp }
}
if ($VmTlsMode -eq "letsencrypt" -and [string]::IsNullOrWhiteSpace($VmHost)) {
  throw "AZURE_VM_PUBLIC_HOSTNAME is required when AZURE_VM_TLS_MODE=letsencrypt."
}
if ($VmTlsMode -eq "letsencrypt" -and [string]::IsNullOrWhiteSpace($VmTlsEmail)) {
  throw "AZURE_VM_TLS_EMAIL is required when AZURE_VM_TLS_MODE=letsencrypt."
}
if ($VmTlsMode -eq "letsencrypt" -and $VmHost -match '^\d{1,3}(\.\d{1,3}){3}$') {
  throw "AZURE_VM_PUBLIC_HOSTNAME must be a real hostname when AZURE_VM_TLS_MODE=letsencrypt."
}
if ([string]::IsNullOrWhiteSpace($VmImage)) {
  throw "AZURE_VM_IMAGE is required."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$composeSource = Join-Path $repoRoot "deploy\azure-vm\docker-compose.vm.yml"
$caddySource = Join-Path $repoRoot "deploy\azure-vm\Caddyfile"
if (-not (Test-Path -LiteralPath $composeSource)) {
  throw "Compose file not found: $composeSource"
}
if (-not (Test-Path -LiteralPath $caddySource)) {
  throw "Caddyfile not found: $caddySource"
}

$stagingDir = Join-Path $env:TEMP "hep-data-web-azure-vm"
if (Test-Path -LiteralPath $stagingDir) {
  Remove-Item -LiteralPath $stagingDir -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingDir | Out-Null

$composeTarget = Join-Path $stagingDir "docker-compose.vm.yml"
$caddyTarget = Join-Path $stagingDir "Caddyfile"
Copy-Item -LiteralPath $composeSource -Destination $composeTarget

if ($VmTlsMode -eq "letsencrypt") {
  $caddyContent = @"
{
  email $VmTlsEmail
}

$VmHost {
  encode zstd gzip
  reverse_proxy web:8000
}
"@
}
else {
  $caddyContent = @"
:80 {
  encode zstd gzip
  reverse_proxy web:8000
}
"@
}
Set-Content -LiteralPath $caddyTarget -Value $caddyContent -Encoding utf8

$envTarget = Join-Path $stagingDir ".env"
$allowedHostsValue = if ([string]::IsNullOrWhiteSpace($AllowedHosts)) { "$VmHost,localhost,127.0.0.1" } else { $AllowedHosts }
$csrfOriginsValue = if ($VmTlsMode -eq "letsencrypt" -and -not [string]::IsNullOrWhiteSpace($CsrfTrustedOrigins)) { $CsrfTrustedOrigins } else { "" }

$runtimeEnv = @{
  AZURE_VM_DATA_MOUNT = $VmDataMount
  AZURE_VM_IMAGE = $VmImage
  AZURE_VM_PUBLIC_HOSTNAME = $VmHost
  AZURE_VM_TLS_EMAIL = $VmTlsEmail
  AZURE_VM_TLS_MODE = $VmTlsMode
  PUBLIC_BASE_URL = if ($VmTlsMode -eq "letsencrypt" -and -not [string]::IsNullOrWhiteSpace($VmHost)) { "https://$VmHost" } else { "" }
  DATABASE_URL = $DatabaseUrl
  SECRET_KEY = $SecretKey
  ALLOWED_HOSTS = $allowedHostsValue
  CSRF_TRUSTED_ORIGINS = $csrfOriginsValue
  GITHUB_CLIENT_ID = $GithubClientId
  GITHUB_CLIENT_SECRET = $GithubClientSecret
  GITHUB_ORG = $GithubOrg
  GITHUB_ADMIN_USERS = $GithubAdminUsers
  ADMIN_EMAILS = $AdminEmails
  OPENAI_API_KEY = $OpenAiApiKey
  api_openai_com_API_KEY = $OpenAiApiKey
  SERVICEX_CONFIG_PATH = $ServiceXContainerPath
  HEP_DATA_LLM_HOME_DIR = $HePHomeDir
  HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE = $ServiceXAwkwardImage
  HEP_DATA_LLM_RDF_DOCKER_IMAGE = $RdfImage
  HEP_DATA_LLM_MODEL = $BackendModel
  HEP_DATA_LLM_REPAIR_CYCLES = $BackendRepairCycles
  JOB_QUEUE_LIMIT = $JobQueueLimit
  JOB_POLL_INTERVAL_SECONDS = $JobPollIntervalSeconds
  JOB_SOFT_TIMEOUT_SECONDS = $JobSoftTimeoutSeconds
  JOB_HARD_TIMEOUT_SECONDS = $JobHardTimeoutSeconds
  DEFAULT_FROM_EMAIL = "hep-data-web@example.org"
  EMAIL_BACKEND = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "EMAIL_BACKEND" -DefaultValue "django.core.mail.backends.smtp.EmailBackend"
  EMAIL_HOST = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "EMAIL_HOST"
  EMAIL_PORT = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "EMAIL_PORT" -DefaultValue "587"
  EMAIL_HOST_USER = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "EMAIL_HOST_USER"
  EMAIL_HOST_PASSWORD = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "EMAIL_HOST_PASSWORD"
  EMAIL_USE_TLS = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "EMAIL_USE_TLS" -DefaultValue "true"
  EMAIL_USE_SSL = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "EMAIL_USE_SSL" -DefaultValue "false"
  DJANGO_SETTINGS_MODULE = "hep_data_web.settings.prod"
  POSTGRES_PASSWORD = $PostgresPassword
}
Write-ProductionEnvFile -Path $envTarget -Values $runtimeEnv

$remoteBase = $VmDataMount
$remoteCompose = "$remoteBase/compose"
$remoteEnv = "$remoteBase/env"
$remoteCerts = "$remoteBase/env/certs"
$remoteHome = "$remoteBase/data/home"

Invoke-Ssh -Hostname $VmHost -User $AdminUser -PrivateKeyPath $SshPrivateKeyPath -Command @(
  "mountpoint",
  "-q",
  $remoteBase,
  "||",
  "(",
  "echo",
  "'$remoteBase is not mounted; run create-vm.ps1 and verify the managed data disk before deploying.'",
  ">&2;",
  "exit",
  "1",
  ")"
)
if ($LASTEXITCODE -ne 0) {
  throw "Persistent data mount '$remoteBase' is not active on '$VmHost'."
}

Invoke-Ssh -Hostname $VmHost -User $AdminUser -PrivateKeyPath $SshPrivateKeyPath -Command @(
  "sudo", "install", "-d",
  "-o", $AdminUser,
  "-g", $AdminUser,
  "-m", "755",
  $remoteCompose,
  $remoteEnv,
  $remoteCerts,
  "$remoteBase/data/docker",
  "$remoteBase/data/postgres",
  "$remoteBase/data/media",
  "$remoteBase/data/staticfiles",
  "$remoteBase/data/tmp",
  $remoteHome,
  "$remoteBase/data/caddy",
  "$remoteBase/data/caddy-config",
  "$remoteBase/backups",
  "$remoteBase/logs"
)
if ($LASTEXITCODE -ne 0) {
  throw "Unable to prepare deployment directories on '$VmHost'."
}

Copy-FileToVm -Source $composeTarget -Hostname $VmHost -User $AdminUser -PrivateKeyPath $SshPrivateKeyPath -Destination "$remoteCompose/docker-compose.vm.yml"
Copy-FileToVm -Source $caddyTarget -Hostname $VmHost -User $AdminUser -PrivateKeyPath $SshPrivateKeyPath -Destination "$remoteCompose/Caddyfile"
Copy-FileToVm -Source $envTarget -Hostname $VmHost -User $AdminUser -PrivateKeyPath $SshPrivateKeyPath -Destination "$remoteEnv/.env"

if (-not [string]::IsNullOrWhiteSpace($ServiceXConfigPath)) {
  $resolvedServiceXConfigPath = [System.IO.Path]::GetFullPath($ServiceXConfigPath)
  if (-not (Test-Path -LiteralPath $resolvedServiceXConfigPath)) {
    throw "SERVICEX_CONFIG_PATH was provided but the file was not found: $resolvedServiceXConfigPath"
  }

  Copy-FileToVm -Source $resolvedServiceXConfigPath -Hostname $VmHost -User $AdminUser -PrivateKeyPath $SshPrivateKeyPath -Destination "$remoteHome/servicex.yaml"
  Invoke-Ssh -Hostname $VmHost -User $AdminUser -PrivateKeyPath $SshPrivateKeyPath -Command @(
    "sudo", "install",
    "-o", "root",
    "-g", "root",
    "-m", "0644",
    "$remoteHome/servicex.yaml",
    "$remoteBase/servicex.yaml"
  )
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to install ServiceX config to '$remoteBase/servicex.yaml'."
  }
}

$remotePostCopy = @("chmod", "600", "$remoteEnv/.env", "&&", "cd", $remoteCompose, "&&", "docker", "compose", "--env-file", "$remoteEnv/.env", "-f", "docker-compose.vm.yml", "config")
Invoke-Ssh -Hostname $VmHost -User $AdminUser -PrivateKeyPath $SshPrivateKeyPath -Command $remotePostCopy
if ($LASTEXITCODE -ne 0) {
  throw "docker compose config failed on '$VmHost'."
}

$remoteUp = @("cd", $remoteCompose, "&&", "docker", "compose", "--env-file", "$remoteEnv/.env", "-f", "docker-compose.vm.yml", "pull", "&&", "docker", "compose", "--env-file", "$remoteEnv/.env", "-f", "docker-compose.vm.yml", "up", "-d")
Invoke-Ssh -Hostname $VmHost -User $AdminUser -PrivateKeyPath $SshPrivateKeyPath -Command $remoteUp
if ($LASTEXITCODE -ne 0) {
  throw "docker compose up failed on '$VmHost'."
}

Write-Host "Deployment refreshed on $VmHost."
