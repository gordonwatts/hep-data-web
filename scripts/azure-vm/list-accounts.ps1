[CmdletBinding()]
param(
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

if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
  Invoke-Az -Arguments @("account", "set", "--subscription", $Subscription)
}

$runCommandArgs = @(
  "vm", "run-command", "invoke",
  "--resource-group", $ResourceGroup,
  "--name", $VmName,
  "--command-id", "RunShellScript",
  "--scripts",
  "cd /srv/hep-data-web/compose",
  "cat <<'SQL' | docker compose --env-file /srv/hep-data-web/env/.env -f docker-compose.vm.yml exec -T postgres psql -U hep_data_web -d hep_data_web -P pager=off -At -F '|'",
  "select u.id as user_id, u.username, u.is_staff, u.is_superuser, coalesce(u.email, '') as email, p.id as profile_id, coalesce(p.github_id, '') as github_id, coalesce(p.github_login, '') as github_login, p.role, p.approval_state, coalesce(to_char(p.approved_at, 'YYYY-MM-DD HH24:MI:SSOF'), '') as approved_at, coalesce(to_char(p.decided_at, 'YYYY-MM-DD HH24:MI:SSOF'), '') as decided_at, coalesce(to_char(p.pending_notified_at, 'YYYY-MM-DD HH24:MI:SSOF'), '') as pending_notified_at from auth_user u join portal_userprofile p on p.user_id = u.id order by p.approval_state, p.role, coalesce(p.github_login, ''), u.username;",
  "SQL"
)

$resultJson = & az @runCommandArgs -o json
if ($LASTEXITCODE -ne 0) {
  throw "Unable to list account rows."
}

$result = $resultJson | ConvertFrom-Json
$message = [string]$result.value[0].message
$stdoutMatch = [regex]::Match($message, "(?s)\[stdout\]\s*(.*?)\s*\[stderr\]")
$stdout = $stdoutMatch.Groups[1].Value.Trim()
if ([string]::IsNullOrWhiteSpace($stdout)) {
  Write-Host "No account rows were returned."
  return
}

$rows = foreach ($line in $stdout -split "`r?`n") {
  if ([string]::IsNullOrWhiteSpace($line)) {
    continue
  }

  $parts = $line -split '\|', 13
  if ($parts.Count -ne 13) {
    continue
  }

  [pscustomobject]@{
    Username = $parts[1]
    GitHubLogin = $parts[7]
    Role = $parts[8]
    ApprovalState = $parts[9]
    Staff = $parts[2]
    Superuser = $parts[3]
    Email = $parts[4]
    UserId = $parts[0]
    ProfileId = $parts[5]
  }
}

$rows |
  Sort-Object ApprovalState, Role, GitHubLogin, Username |
  Format-Table -AutoSize Username, GitHubLogin, Role, ApprovalState, Staff, Superuser, Email, UserId, ProfileId |
  Out-String -Width 240 |
  Write-Host
