[CmdletBinding()]
param(
  [string]$DefaultsPath = "",
  [string]$ConfigPath = "",
  [string]$Subscription = "",
  [string]$ResourceGroup = "",
  [string]$Location = "",
  [string]$VmName = "",
  [string]$VmSize = "",
  [string]$AdminUser = "",
  [string]$SshPublicKeyPath = "",
  [string]$DataDiskName = "",
  [string]$DataDiskSizeGb = "",
  [string]$DnsLabel = "",
  [string]$AllowedSshCidr = ""
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
$Location = Get-ResolvedValue -ExplicitValue $Location -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_LOCATION" -DefaultValue "eastus"
$VmName = Get-ResolvedValue -ExplicitValue $VmName -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_NAME" -DefaultValue "hep-data-web-vm"
$VmSize = Get-ResolvedValue -ExplicitValue $VmSize -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_SIZE" -DefaultValue "Standard_B2s"
$AdminUser = Get-ResolvedValue -ExplicitValue $AdminUser -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_ADMIN_USER" -DefaultValue "hepadmin"
$SshPublicKeyPath = Get-ResolvedValue -ExplicitValue $SshPublicKeyPath -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_SSH_PUBLIC_KEY_PATH"
$DataDiskName = Get-ResolvedValue -ExplicitValue $DataDiskName -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_DATA_DISK_NAME" -DefaultValue "$VmName-data"
$DataDiskSizeGb = Get-ResolvedValue -ExplicitValue $DataDiskSizeGb -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_DATA_DISK_SIZE_GB" -DefaultValue "128"
$DnsLabel = Get-ResolvedValue -ExplicitValue $DnsLabel -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_DNS_LABEL" -DefaultValue "hep-data-llm"
$AllowedSshCidr = Get-ResolvedValue -ExplicitValue $AllowedSshCidr -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_ALLOWED_SSH_CIDR"
$VmDataMount = Get-ResolvedValue -ConfigValues $userConfig -DefaultValues $defaultConfig -Name "AZURE_VM_DATA_MOUNT" -DefaultValue "/srv/hep-data-web"
if ([string]::IsNullOrWhiteSpace($DnsLabel)) {
  $DnsLabel = "hep-data-llm"
}

if ([string]::IsNullOrWhiteSpace($SshPublicKeyPath)) {
  throw "AZURE_VM_SSH_PUBLIC_KEY_PATH is required."
}

$resolvedSshKeyPath = Resolve-ExistingRelativePath -PathValue $SshPublicKeyPath -SearchDirectories @((Split-Path -Parent $ConfigPath), $repoRoot, (Get-Location).Path)
if (-not (Test-Path -LiteralPath $resolvedSshKeyPath)) {
  throw "SSH public key file not found: $resolvedSshKeyPath"
}

if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
  Invoke-Az -Arguments @("account", "set", "--subscription", $Subscription)
}

Write-Host "Ensuring resource group '$ResourceGroup' exists in '$Location'..."
Invoke-Az -Arguments @(
  "group", "create",
  "--name", $ResourceGroup,
  "--location", $Location,
  "--only-show-errors",
  "--output", "none"
)

$vmExists = $false
try {
  $null = & az vm show --resource-group $ResourceGroup --name $VmName --output none
  if ($LASTEXITCODE -eq 0) {
    $vmExists = $true
  }
}
catch {
  $vmExists = $false
}

if (-not $vmExists) {
  $createArgs = @(
    "vm", "create",
    "--resource-group", $ResourceGroup,
    "--name", $VmName,
    "--image", "Ubuntu2204",
    "--size", $VmSize,
    "--admin-username", $AdminUser,
    "--ssh-key-values", $resolvedSshKeyPath,
    "--public-ip-sku", "Standard",
    "--nsg-rule", "SSH",
    "--only-show-errors",
    "--output", "none"
  )
  if (-not [string]::IsNullOrWhiteSpace($DnsLabel)) {
    $createArgs += @("--public-ip-address-dns-name", $DnsLabel)
  }

  Write-Host "Creating VM '$VmName'..."
  Invoke-Az -Arguments $createArgs
}
else {
  Write-Host "VM '$VmName' already exists; reusing it."
}

if (-not [string]::IsNullOrWhiteSpace($DnsLabel)) {
  $publicIpName = "${VmName}PublicIP"
  Write-Host "Ensuring DNS label '$DnsLabel' on public IP '$publicIpName'..."
  Invoke-Az -Arguments @(
    "network", "public-ip", "update",
    "--resource-group", $ResourceGroup,
    "--name", $publicIpName,
    "--dns-name", $DnsLabel,
    "--only-show-errors",
    "--output", "none"
  )
}

$diskExists = $false
try {
  $null = & az disk show --resource-group $ResourceGroup --name $DataDiskName --output none
  if ($LASTEXITCODE -eq 0) {
    $diskExists = $true
  }
}
catch {
  $diskExists = $false
}

if (-not $diskExists) {
  Write-Host "Creating data disk '$DataDiskName'..."
  Invoke-Az -Arguments @(
    "disk", "create",
    "--resource-group", $ResourceGroup,
    "--name", $DataDiskName,
    "--size-gb", $DataDiskSizeGb,
    "--sku", "StandardSSD_LRS",
    "--only-show-errors",
    "--output", "none"
  )
}
else {
  Write-Host "Data disk '$DataDiskName' already exists; reusing it."
}

$attachedDiskIds = & az vm show --resource-group $ResourceGroup --name $VmName --query "storageProfile.dataDisks[].name" -o tsv
if ($LASTEXITCODE -ne 0) {
  throw "Unable to inspect attached data disks."
}
$attachedDiskNames = @($attachedDiskIds)
if (-not ($attachedDiskNames -contains $DataDiskName)) {
  Write-Host "Attaching data disk '$DataDiskName'..."
  Invoke-Az -Arguments @(
    "vm", "disk", "attach",
    "--resource-group", $ResourceGroup,
    "--vm-name", $VmName,
    "--name", $DataDiskName,
    "--only-show-errors",
    "--output", "none"
  )
}

Write-Host "Opening HTTP and HTTPS ports..."
Invoke-Az -Arguments @("vm", "open-port", "--resource-group", $ResourceGroup, "--name", $VmName, "--port", "80", "--priority", "900", "--only-show-errors", "--output", "none")
Invoke-Az -Arguments @("vm", "open-port", "--resource-group", $ResourceGroup, "--name", $VmName, "--port", "443", "--priority", "901", "--only-show-errors", "--output", "none")

if (-not [string]::IsNullOrWhiteSpace($AllowedSshCidr)) {
  $nsgName = "${VmName}NSG"
  $sshRuleName = & az network nsg rule list --resource-group $ResourceGroup --nsg-name $nsgName --query "[?destinationPortRange=='22' || destinationPortRanges[0]=='22'].name | [0]" -o tsv
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sshRuleName)) {
    Write-Host "Restricting SSH on NSG '$nsgName' to '$AllowedSshCidr'..."
    Invoke-Az -Arguments @(
      "network", "nsg", "rule", "update",
      "--resource-group", $ResourceGroup,
      "--nsg-name", $nsgName,
      "--name", $sshRuleName,
      "--source-address-prefixes", $AllowedSshCidr,
      "--only-show-errors",
      "--output", "none"
    )
  }
  else {
    Write-Warning "Could not locate the SSH NSG rule for '$VmName'. Review the NSG manually if you need SSH restriction."
  }
}

$bootstrapScript = @(
  'set -eux',
  'export DEBIAN_FRONTEND=noninteractive',
  'apt-get update',
  'apt-get install -y ca-certificates curl',
  'curl -fsSL https://get.docker.com | sh',
  'systemctl enable --now docker',
  "usermod -aG docker $AdminUser || true",
  "install -d -m 755 $VmDataMount",
  'data_device=/dev/disk/azure/scsi1/lun0',
  'if [ ! -b "$data_device" ]; then echo "Managed data disk not found at $data_device" >&2; exit 1; fi',
  'if ! blkid "$data_device" >/dev/null 2>&1; then mkfs.ext4 -F "$data_device"; fi',
  'disk_uuid=$(blkid -s UUID -o value "$data_device")',
  "fstab_entry=`"UUID=`$disk_uuid $VmDataMount ext4 defaults,nofail 0 2`"",
  "grep -v `"[[:space:]]$VmDataMount[[:space:]]`" /etc/fstab > /tmp/hep-data-web-fstab",
  'printf "%s\n" "$fstab_entry" >> /tmp/hep-data-web-fstab',
  'cat /tmp/hep-data-web-fstab > /etc/fstab',
  "if ! mountpoint -q $VmDataMount; then",
  "  if [ -n `"`$(find $VmDataMount -mindepth 1 -maxdepth 1 -print -quit)`" ]; then",
  "    echo `"$VmDataMount contains files but is not mounted; refusing to hide OS-disk data. Move or back it up, then rerun.`" >&2",
  '    exit 1',
  '  fi',
  "  mount $VmDataMount",
  'fi',
  "if ! mountpoint -q $VmDataMount; then echo `"$VmDataMount is not mounted`" >&2; exit 1; fi",
  "mkdir -p $VmDataMount/compose $VmDataMount/env $VmDataMount/env/certs $VmDataMount/data/docker $VmDataMount/data/postgres $VmDataMount/data/media $VmDataMount/data/staticfiles $VmDataMount/data/tmp $VmDataMount/data/home $VmDataMount/data/caddy $VmDataMount/data/caddy-config $VmDataMount/backups $VmDataMount/logs",
  "chown -R ${AdminUser}:${AdminUser} $VmDataMount"
)

Write-Host "Bootstrapping Docker and the persistent mount on the VM..."
$bootstrapArgs = @(
  "vm", "run-command", "invoke",
  "--resource-group", $ResourceGroup,
  "--name", $VmName,
  "--command-id", "RunShellScript",
  "--scripts"
) + $bootstrapScript
Invoke-Az -Arguments $bootstrapArgs

$vmInfoJson = & az vm show -d --resource-group $ResourceGroup --name $VmName --query "{publicIp:publicIps,fqdn:fqdns}" -o json
if ($LASTEXITCODE -ne 0) {
  throw "Unable to read VM network details."
}

$vmInfo = $vmInfoJson | ConvertFrom-Json
$publicHost = if (-not [string]::IsNullOrWhiteSpace($vmInfo.fqdn)) { $vmInfo.fqdn } else { $vmInfo.publicIp }

Write-Host ""
Write-Host "VM ready."
Write-Host "Public host: $publicHost"
Write-Host "Mount point: $VmDataMount"
