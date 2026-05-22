[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$AccountName,
  [string]$DefaultsPath = "",
  [string]$ConfigPath = "",
  [string]$Subscription = "",
  [string]$ResourceGroup = "",
  [string]$VmName = ""
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

if ([string]::IsNullOrWhiteSpace($AccountName)) {
  throw "AccountName is required."
}
if ($AccountName -notmatch '^[A-Za-z0-9_.@-]+$') {
  throw "AccountName contains unsupported characters."
}

if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
  Invoke-Az -Arguments @("account", "set", "--subscription", $Subscription)
}

$remoteScript = @(
  "cd /srv/hep-data-web/compose"
  "cat <<'SQL' | docker compose --env-file /srv/hep-data-web/env/.env -f docker-compose.vm.yml exec -T postgres psql -U hep_data_web -d hep_data_web -v ON_ERROR_STOP=1"
  "update auth_user set is_staff = true, is_superuser = true where username = '$AccountName' or email = '$AccountName';"
  "update portal_userprofile set role = 'admin', approval_state = 'approved', approved_at = CURRENT_TIMESTAMP, decided_at = CURRENT_TIMESTAMP from auth_user where portal_userprofile.user_id = auth_user.id and (auth_user.username = '$AccountName' or auth_user.email = '$AccountName' or portal_userprofile.github_login = '$AccountName' or portal_userprofile.github_id = '$AccountName');"
  "select 'auth_user' as table_name, u.id, u.username, u.is_staff, u.is_superuser, coalesce(u.email, '') as email from auth_user u where u.username = '$AccountName' or u.email = '$AccountName' or u.id in (select p.user_id from portal_userprofile p where p.github_login = '$AccountName' or p.github_id = '$AccountName');"
  "select 'portal_userprofile' as table_name, p.id, p.user_id, coalesce(p.github_id, '') as github_id, coalesce(p.github_login, '') as github_login, p.role, p.approval_state, coalesce(to_char(p.approved_at, 'YYYY-MM-DD HH24:MI:SSOF'), '') as approved_at, coalesce(to_char(p.decided_at, 'YYYY-MM-DD HH24:MI:SSOF'), '') as decided_at from portal_userprofile p where p.user_id in (select u.id from auth_user u where u.username = '$AccountName' or u.email = '$AccountName' or u.id in (select p2.user_id from portal_userprofile p2 where p2.github_login = '$AccountName' or p2.github_id = '$AccountName'));"
  "SQL"
)

$runCommandArgs = @(
  "vm", "run-command", "invoke",
  "--resource-group", $ResourceGroup,
  "--name", $VmName,
  "--command-id", "RunShellScript",
  "--scripts"
)
Invoke-Az -Arguments ($runCommandArgs + $remoteScript)
