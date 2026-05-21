[CmdletBinding()]
param(
  [string]$DefaultsPath = "",
  [string]$ConfigPath = "",
  [string]$ResourceGroup = "",
  [string]$ContainerAppsEnvironmentName = "",
  [string]$WebAppName = "",
  [string]$WorkerAppName = "",
  [string]$PostgresServerName = ""
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
if ([string]::IsNullOrWhiteSpace($ContainerAppsEnvironmentName)) {
  if ($userConfig.ContainsKey("AZURE_CONTAINER_APPS_ENVIRONMENT_NAME")) {
    $ContainerAppsEnvironmentName = $userConfig["AZURE_CONTAINER_APPS_ENVIRONMENT_NAME"]
  }
  elseif ($defaultConfig.ContainsKey("AZURE_CONTAINER_APPS_ENVIRONMENT_NAME")) {
    $ContainerAppsEnvironmentName = $defaultConfig["AZURE_CONTAINER_APPS_ENVIRONMENT_NAME"]
  }
  elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AZURE_CONTAINER_APPS_ENVIRONMENT_NAME"))) {
    $ContainerAppsEnvironmentName = [Environment]::GetEnvironmentVariable("AZURE_CONTAINER_APPS_ENVIRONMENT_NAME")
  }
}
if ([string]::IsNullOrWhiteSpace($WebAppName)) {
  if ($userConfig.ContainsKey("AZURE_WEB_APP_NAME")) {
    $WebAppName = $userConfig["AZURE_WEB_APP_NAME"]
  }
  elseif ($defaultConfig.ContainsKey("AZURE_WEB_APP_NAME")) {
    $WebAppName = $defaultConfig["AZURE_WEB_APP_NAME"]
  }
  elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AZURE_WEB_APP_NAME"))) {
    $WebAppName = [Environment]::GetEnvironmentVariable("AZURE_WEB_APP_NAME")
  }
}
if ([string]::IsNullOrWhiteSpace($WorkerAppName)) {
  if ($userConfig.ContainsKey("AZURE_WORKER_APP_NAME")) {
    $WorkerAppName = $userConfig["AZURE_WORKER_APP_NAME"]
  }
  elseif ($defaultConfig.ContainsKey("AZURE_WORKER_APP_NAME")) {
    $WorkerAppName = $defaultConfig["AZURE_WORKER_APP_NAME"]
  }
  elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AZURE_WORKER_APP_NAME"))) {
    $WorkerAppName = [Environment]::GetEnvironmentVariable("AZURE_WORKER_APP_NAME")
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

if ([string]::IsNullOrWhiteSpace($ResourceGroup) -or [string]::IsNullOrWhiteSpace($ContainerAppsEnvironmentName) -or [string]::IsNullOrWhiteSpace($WebAppName) -or [string]::IsNullOrWhiteSpace($WorkerAppName) -or [string]::IsNullOrWhiteSpace($PostgresServerName)) {
  throw "Missing deployment settings. Provide a config file with -ConfigPath or override AZURE_RESOURCE_GROUP, AZURE_CONTAINER_APPS_ENVIRONMENT_NAME, AZURE_WEB_APP_NAME, AZURE_WORKER_APP_NAME, and AZURE_POSTGRES_SERVER_NAME."
}

Write-Host "Removing ephemeral application resources from resource group '$ResourceGroup'..."

Invoke-Az -Arguments @("containerapp", "delete", "--name", $WorkerAppName, "--resource-group", $ResourceGroup, "--yes", "--output", "none")
Invoke-Az -Arguments @("containerapp", "delete", "--name", $WebAppName, "--resource-group", $ResourceGroup, "--yes", "--output", "none")
Invoke-Az -Arguments @("containerapp", "env", "delete", "--name", $ContainerAppsEnvironmentName, "--resource-group", $ResourceGroup, "--yes", "--output", "none")

$postgresState = (& az postgres flexible-server show --resource-group $ResourceGroup --name $PostgresServerName --query state -o tsv)
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($postgresState) -and $postgresState -ne "Stopped") {
  Invoke-Az -Arguments @("postgres", "flexible-server", "stop", "--resource-group", $ResourceGroup, "--name", $PostgresServerName)
}

Write-Host "Application resources removed. PostgreSQL is stopped; persistent storage resources were not touched."
