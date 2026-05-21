[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
  [string]$DefaultsPath = "",
  [string]$ConfigPath = "",
  [string]$ResourceGroup = "",
  [string]$StorageAccountName = "",
  [string]$PostgresServerName = "",
  [string]$PostgresDatabaseName = "hep_data_web",
  [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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

if ([string]::IsNullOrWhiteSpace($DefaultsPath)) {
  $DefaultsPath = Join-Path $PSScriptRoot "deploy.env.example"
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot "deploy.env"
}

$defaultConfig = Read-DotEnvFile -PathValue $DefaultsPath
$userConfig = Read-DotEnvFile -PathValue $ConfigPath

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
  if ($userConfig.ContainsKey("AZURE_RESOURCE_GROUP")) {
    $ResourceGroup = $userConfig["AZURE_RESOURCE_GROUP"]
  }
  elseif ($defaultConfig.ContainsKey("AZURE_RESOURCE_GROUP")) {
    $ResourceGroup = $defaultConfig["AZURE_RESOURCE_GROUP"]
  }
  elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AZURE_RESOURCE_GROUP"))) {
    $ResourceGroup = [Environment]::GetEnvironmentVariable("AZURE_RESOURCE_GROUP")
  }
}
if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
  if ($userConfig.ContainsKey("AZURE_STORAGE_ACCOUNT_NAME")) {
    $StorageAccountName = $userConfig["AZURE_STORAGE_ACCOUNT_NAME"]
  }
  elseif ($defaultConfig.ContainsKey("AZURE_STORAGE_ACCOUNT_NAME")) {
    $StorageAccountName = $defaultConfig["AZURE_STORAGE_ACCOUNT_NAME"]
  }
  elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AZURE_STORAGE_ACCOUNT_NAME"))) {
    $StorageAccountName = [Environment]::GetEnvironmentVariable("AZURE_STORAGE_ACCOUNT_NAME")
  }
}
if ([string]::IsNullOrWhiteSpace($PostgresServerName)) {
  if ($userConfig.ContainsKey("AZURE_POSTGRES_SERVER_NAME")) {
    $PostgresServerName = $userConfig["AZURE_POSTGRES_SERVER_NAME"]
  }
  elseif ($defaultConfig.ContainsKey("AZURE_POSTGRES_SERVER_NAME")) {
    $PostgresServerName = $defaultConfig["AZURE_POSTGRES_SERVER_NAME"]
  }
  elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AZURE_POSTGRES_SERVER_NAME"))) {
    $PostgresServerName = [Environment]::GetEnvironmentVariable("AZURE_POSTGRES_SERVER_NAME")
  }
}
if ([string]::IsNullOrWhiteSpace($PostgresDatabaseName)) {
  if ($userConfig.ContainsKey("AZURE_POSTGRES_DATABASE_NAME")) {
    $PostgresDatabaseName = $userConfig["AZURE_POSTGRES_DATABASE_NAME"]
  }
  elseif ($defaultConfig.ContainsKey("AZURE_POSTGRES_DATABASE_NAME")) {
    $PostgresDatabaseName = $defaultConfig["AZURE_POSTGRES_DATABASE_NAME"]
  }
  elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AZURE_POSTGRES_DATABASE_NAME"))) {
    $PostgresDatabaseName = [Environment]::GetEnvironmentVariable("AZURE_POSTGRES_DATABASE_NAME")
  }
}

if ([string]::IsNullOrWhiteSpace($ResourceGroup) -or [string]::IsNullOrWhiteSpace($StorageAccountName) -or [string]::IsNullOrWhiteSpace($PostgresServerName)) {
  throw "Missing deployment settings. Provide a config file with -ConfigPath or override AZURE_RESOURCE_GROUP, AZURE_STORAGE_ACCOUNT_NAME, and AZURE_POSTGRES_SERVER_NAME."
}

if (-not $Force) {
  $confirmation = Read-Host -Prompt "Type DELETE to remove the persistent database and storage resources"
  if ($confirmation -ne "DELETE") {
    Write-Host "Aborted."
    return
  }
}

if ($PSCmdlet.ShouldProcess($ResourceGroup, "Delete persistent database and storage resources")) {
  Invoke-Az -Arguments @(
    "postgres", "flexible-server", "delete",
    "--resource-group", $ResourceGroup,
    "--name", $PostgresServerName,
    "--yes",
    "--output", "none"
  )

  Invoke-Az -Arguments @(
    "storage", "account", "delete",
    "--resource-group", $ResourceGroup,
    "--name", $StorageAccountName,
    "--yes",
    "--output", "none"
  )
}

Write-Host "Persistent data resources removed."
