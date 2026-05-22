[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

function Invoke-Az {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  & az @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI command failed: az $($Arguments -join ' ')"
  }
}

function Read-DotEnvFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PathValue
  )

  $values = @{}
  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $values
  }

  $resolvedPath = [System.IO.Path]::GetFullPath($PathValue)
  if (-not (Test-Path -LiteralPath $resolvedPath)) {
    return $values
  }

  foreach ($rawLine in Get-Content -LiteralPath $resolvedPath) {
    $line = $rawLine.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#") -or -not $line.Contains("=")) {
      continue
    }

    $parts = $line.Split("=", 2)
    $key = $parts[0].Trim()
    if ([string]::IsNullOrWhiteSpace($key)) {
      continue
    }

    $rawValue = $parts[1].Trim()
    if ($rawValue.StartsWith('"') -and $rawValue.EndsWith('"') -and $rawValue.Length -ge 2) {
      $value = $rawValue.Substring(1, $rawValue.Length - 2)
    }
    elseif ($rawValue.StartsWith("'") -and $rawValue.EndsWith("'") -and $rawValue.Length -ge 2) {
      $value = $rawValue.Substring(1, $rawValue.Length - 2)
    }
    else {
      $value = ($rawValue -replace '\s+#.*$', '').Trim()
    }

    $values[$key] = $value
  }

  return $values
}

function Resolve-ExistingRelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PathValue,
    [string[]]$SearchDirectories = @()
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $PathValue
  }

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  foreach ($baseDirectory in $SearchDirectories) {
    if ([string]::IsNullOrWhiteSpace($baseDirectory)) {
      continue
    }

    $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $baseDirectory $PathValue))
    if (Test-Path -LiteralPath $candidatePath) {
      return $candidatePath
    }
  }

  return [System.IO.Path]::GetFullPath($PathValue)
}

function Get-ResolvedValue {
  param(
    [string]$ExplicitValue,
    [hashtable]$ConfigValues,
    [hashtable]$DefaultValues,
    [string]$Name,
    [string]$DefaultValue = ""
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitValue)) {
    return $ExplicitValue
  }

  if ($null -ne $ConfigValues -and $ConfigValues.ContainsKey($Name)) {
    $value = [string]$ConfigValues[$Name]
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }

  if ($null -ne $DefaultValues -and $DefaultValues.ContainsKey($Name)) {
    $value = [string]$DefaultValues[$Name]
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }

  $environmentValue = [Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
    return $environmentValue
  }

  return $DefaultValue
}

function Get-SanitizedName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value,
    [int]$MaxLength = 63,
    [switch]$AllowHyphen
  )

  $pattern = if ($AllowHyphen) { '[^a-zA-Z0-9-]' } else { '[^a-zA-Z0-9]' }
  $sanitized = ($Value -replace $pattern, "").ToLowerInvariant()
  if ($sanitized.Length -gt $MaxLength) {
    $sanitized = $sanitized.Substring(0, $MaxLength)
  }
  if ([string]::IsNullOrWhiteSpace($sanitized)) {
    throw "Unable to derive a valid Azure resource name from '$Value'."
  }
  return $sanitized
}

function Ensure-ParentDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

function Write-ProductionEnvFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [hashtable]$Values
  )

  Ensure-ParentDirectory -Path $Path

  $lines = foreach ($entry in $Values.GetEnumerator() | Sort-Object Key) {
    "$($entry.Key)=$($entry.Value)"
  }

  Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}

function Get-SshPrivateKeyPath {
  param(
    [string]$PublicKeyPath,
    [string]$PrivateKeyPath = ""
  )

  if (-not [string]::IsNullOrWhiteSpace($PrivateKeyPath)) {
    return [System.IO.Path]::GetFullPath($PrivateKeyPath)
  }

  if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) {
    return ""
  }

  $resolvedPublicKeyPath = [System.IO.Path]::GetFullPath($PublicKeyPath)
  if ($resolvedPublicKeyPath.EndsWith(".pub")) {
    return $resolvedPublicKeyPath.Substring(0, $resolvedPublicKeyPath.Length - 4)
  }

  return $resolvedPublicKeyPath
}

function Invoke-Ssh {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Hostname,
    [Parameter(Mandatory = $true)]
    [string]$User,
    [Parameter(Mandatory = $true)]
    [string[]]$Command,
    [string]$PrivateKeyPath = ""
  )

  $commandString = $Command -join " "
  if ([string]::IsNullOrWhiteSpace($PrivateKeyPath)) {
    & ssh -o StrictHostKeyChecking=accept-new "$User@$Hostname" $commandString
  }
  else {
    & ssh -o StrictHostKeyChecking=accept-new -i $PrivateKeyPath "$User@$Hostname" $commandString
  }
  if ($LASTEXITCODE -ne 0) {
    throw "SSH command failed for '$User@$Hostname'."
  }
}

function Copy-FileToVm {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Hostname,
    [Parameter(Mandatory = $true)]
    [string]$User,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [string]$PrivateKeyPath = ""
  )

  if ([string]::IsNullOrWhiteSpace($PrivateKeyPath)) {
    & scp -o StrictHostKeyChecking=accept-new $Source "$User@$Hostname`:$Destination"
  }
  else {
    & scp -o StrictHostKeyChecking=accept-new -i $PrivateKeyPath $Source "$User@$Hostname`:$Destination"
  }
  if ($LASTEXITCODE -ne 0) {
    throw "SCP copy failed for '$Source' to '${User}@${Hostname}:$Destination'."
  }
}
