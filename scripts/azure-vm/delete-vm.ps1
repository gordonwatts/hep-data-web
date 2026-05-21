[CmdletBinding()]
param(
  [string]$DefaultsPath = "",
  [string]$ConfigPath = "",
  [string]$Subscription = "",
  [string]$ResourceGroup = "",
  [string]$VmName = ""
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

if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
  Invoke-Az -Arguments @("account", "set", "--subscription", $Subscription)
}

$nicId = & az vm show --resource-group $ResourceGroup --name $VmName --query "networkProfile.networkInterfaces[0].id" -o tsv
if ($LASTEXITCODE -ne 0) {
  throw "Unable to inspect VM '$VmName'."
}

$publicIpId = $null
if (-not [string]::IsNullOrWhiteSpace($nicId)) {
  $publicIpId = & az network nic show --ids $nicId --query "ipConfigurations[0].publicIpAddress.id" -o tsv
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect the public IP for VM '$VmName'."
  }
}

Write-Host "Removing VM '$VmName' while leaving the managed data disk in place..."
Invoke-Az -Arguments @("vm", "delete", "--resource-group", $ResourceGroup, "--name", $VmName, "--yes", "--only-show-errors", "--output", "none")

if (-not [string]::IsNullOrWhiteSpace($nicId)) {
  $nicName = ($nicId -split "/")[-1]
  $nicExists = $false
  try {
    $null = & az resource show --ids $nicId --output none
    if ($LASTEXITCODE -eq 0) {
      $nicExists = $true
    }
  }
  catch {
    $nicExists = $false
  }
  if ($nicExists) {
    Write-Host "Deleting NIC '$nicName'..."
    & az network nic delete --ids $nicId
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to delete the VM network interface."
    }
  }
}

if (-not [string]::IsNullOrWhiteSpace($publicIpId)) {
  $publicIpExists = $false
  try {
    $null = & az resource show --ids $publicIpId --output none
    if ($LASTEXITCODE -eq 0) {
      $publicIpExists = $true
    }
  }
  catch {
    $publicIpExists = $false
  }
  if ($publicIpExists) {
    Write-Host "Deleting public IP resource..."
    & az network public-ip delete --ids $publicIpId
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to delete the VM public IP."
    }
  }
}

Write-Host "VM removed. The managed data disk is still present."
