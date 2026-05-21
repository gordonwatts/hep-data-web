[CmdletBinding()]
param(
  [string]$DefaultsPath = "",
  [string]$ConfigPath = "",
  [string]$Subscription = "",
  [string]$ResourceGroup = "",
  [string]$Location = "",
  [string]$AppNamePrefix = "",
  [string]$ContainerRegistryName = "",
  [string]$ImageName = "",
  [string]$ImageTag = "",
  [string]$ContainerAppsEnvironmentName,
  [string]$ContainerAppsLogsDestination = "",
  [string]$ContainerAppsLogsWorkspaceId = "",
  [string]$ContainerAppsLogsWorkspaceKey = "",
  [string]$WebAppName,
  [string]$WorkerAppName,
  [string]$StorageAccountName,
  [string]$StorageShareName = "",
  [string]$PostgresServerName,
  [string]$PostgresDatabaseName = "",
  [string]$PostgresAdminUser = "",
  [string]$SecretsSource = "",
  [string]$DockerHubSourceImage = "",
  [string]$DockerHubUsername = "",
  [string]$DockerHubPassword = "",
  [string]$CertificatePath = "",
  [string]$CertificatePassword = "",
  [string]$AllowedHosts = "",
  [string]$CsrfTrustedOrigins = "",
  [string]$GithubClientId = "",
  [string]$GithubOrg = "",
  [string]$GithubAdminUsers = "",
  [string]$AdminEmails = "",
  [string]$ServiceXConfigPath = "",
  [string]$OpenAiApiKey = "",
  [string]$ServiceXAwkwardDockerImage = "",
  [string]$RdfDockerImage = "",
  [string]$DockerImageGlobalFallback = "",
  [string]$JobQueueLimit = "",
  [string]$JobPollIntervalSeconds = "",
  [string]$JobSoftTimeoutSeconds = "",
  [string]$JobHardTimeoutSeconds = "",
  [string]$BackendModel = "",
  [string]$BackendRepairCycles = ""
)

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
    throw "Azure CLI command failed."
  }
}

function Ensure-ResourceProviderRegistered {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Namespace
  )

  $registrationState = (& az provider show --namespace $Namespace --query registrationState -o tsv)
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to check Azure resource provider registration for '$Namespace'."
  }

  if ($registrationState -eq "Registered") {
    return
  }

  Write-Host "Registering Azure resource provider '$Namespace' for this subscription..."
  Invoke-Az -Arguments @("provider", "register", "--namespace", $Namespace, "--wait", "--only-show-errors", "--output", "none")
}

function Ensure-PostgresServerReady {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,
    [Parameter(Mandatory = $true)]
    [string]$ServerName
  )

  $serverState = (& az postgres flexible-server show --resource-group $ResourceGroup --name $ServerName --query state -o tsv)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serverState)) {
    return $false
  }

  if ($serverState -eq "Stopped") {
    Write-Host "Starting existing PostgreSQL server '$ServerName'..."
    Invoke-Az -Arguments @("postgres", "flexible-server", "start", "--resource-group", $ResourceGroup, "--name", $ServerName)
  }
  return $true
}

function Ensure-PostgresDatabase {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,
    [Parameter(Mandatory = $true)]
    [string]$ServerName,
    [Parameter(Mandatory = $true)]
    [string]$DatabaseName
  )

  $existingDatabases = (& az postgres flexible-server db list --resource-group $ResourceGroup --server-name $ServerName --query "[].name" -o tsv)
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to list PostgreSQL databases for server '$ServerName'."
  }

  foreach ($existingDatabase in @($existingDatabases)) {
    if ($existingDatabase -eq $DatabaseName) {
      return
    }
  }

  Invoke-Az -Arguments @(
    "postgres", "flexible-server", "db", "create",
    "--resource-group", $ResourceGroup,
    "--server-name", $ServerName,
    "--name", $DatabaseName,
    "--only-show-errors",
    "--output", "none"
  )
}

function Ensure-PostgresComputeSku {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,
    [Parameter(Mandatory = $true)]
    [string]$ServerName,
    [Parameter(Mandatory = $true)]
    [string]$SkuName,
    [Parameter(Mandatory = $true)]
    [string]$Tier
  )

  $serverInfoJson = (& az postgres flexible-server show --resource-group $ResourceGroup --name $ServerName --query "{sku:sku.name,tier:sku.tier}" -o json)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serverInfoJson)) {
    throw "Unable to inspect PostgreSQL server '$ServerName'."
  }

  $serverInfo = $serverInfoJson | ConvertFrom-Json
  if ($serverInfo.sku -eq $SkuName -and $serverInfo.tier -eq $Tier) {
    return
  }

  Write-Host "Updating PostgreSQL server '$ServerName' to compute SKU '$SkuName' in tier '$Tier'..."
  Invoke-Az -Arguments @(
    "postgres", "flexible-server", "update",
    "--resource-group", $ResourceGroup,
    "--name", $ServerName,
    "--sku-name", $SkuName,
    "--tier", $Tier,
    "--only-show-errors",
    "--output", "none"
  )
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

function Get-ConfigValue {
  param(
    [string]$ExplicitValue,
    [hashtable]$ConfigValues,
    [hashtable]$DefaultValues,
    [string]$EnvironmentVariable,
    [string]$DefaultValue = ""
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitValue)) {
    return $ExplicitValue
  }

  if ($null -ne $ConfigValues -and $ConfigValues.ContainsKey($EnvironmentVariable)) {
    $value = [string]$ConfigValues[$EnvironmentVariable]
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }

  if ($null -ne $DefaultValues -and $DefaultValues.ContainsKey($EnvironmentVariable)) {
    $value = [string]$DefaultValues[$EnvironmentVariable]
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }

  $value = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
  if (-not [string]::IsNullOrWhiteSpace($value)) {
    return $value
  }

  return $DefaultValue
}

function Require-ConfigValue {
  param(
    [string]$Value,
    [string]$Label
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "Missing required deployment setting: $Label"
  }

  return $Value
}

function Resolve-RelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PathValue,
    [Parameter(Mandatory = $true)]
    [string]$BaseDirectory
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $PathValue
  }

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return $PathValue
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $PathValue))
}

function Get-SecretText {
  param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentVariable,
    [Parameter(Mandatory = $true)]
    [string]$Prompt,
    [hashtable]$ConfigValues,
    [hashtable]$DefaultValues
  )

  $value = Get-ConfigValue -ExplicitValue "" -ConfigValues $ConfigValues -DefaultValues $DefaultValues -EnvironmentVariable $EnvironmentVariable
  if (-not [string]::IsNullOrWhiteSpace($value)) {
    return $value
  }

  if ($SecretsSource -eq "Environment" -or $SecretsSource -eq "Prompt") {
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    return [System.Net.NetworkCredential]::new("", $secure).Password
  }

  throw "Unsupported SecretsSource '$SecretsSource'. Use Environment or Prompt."
}

if ([string]::IsNullOrWhiteSpace($DefaultsPath)) {
  $DefaultsPath = Join-Path $PSScriptRoot "deploy.env.example"
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot "deploy.env"
}

$defaultConfig = Read-DotEnvFile -PathValue $DefaultsPath
$userConfig = Read-DotEnvFile -PathValue $ConfigPath

function Escape-YamlScalar {
  param([string]$Value)
  if ($null -eq $Value) {
    $escaped = ""
  } else {
    $escaped = $Value
  }
  $escaped = $escaped -replace "'", "''"
  return "'$escaped'"
}

function New-ContainerAppYaml {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$ImageRef,
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,
    [Parameter(Mandatory = $true)]
    [string]$RegistryServer,
    [Parameter(Mandatory = $true)]
    [string]$DatabaseUrl,
    [Parameter(Mandatory = $true)]
    [string]$SecretKey,
    [Parameter(Mandatory = $true)]
    [string]$ContainerName,
    [Parameter(Mandatory = $true)]
    [string[]]$Command,
    [string]$RegistryUsername = "",
    [string]$RegistryPassword = "",
    [string]$GithubClientSecret = "",
    [string]$CertificatePassword = "",
    [string]$AllowedHosts = "*",
    [string]$CsrfTrustedOrigins = "",
    [string]$GithubClientId = "",
    [string]$GithubOrg = "",
    [string]$GithubAdminUsers = "",
    [string]$AdminEmails = "",
    [string]$ServiceXConfigText = "",
    [string]$ServiceXHomeDir = "",
    [string]$OpenAiApiKey = "",
    [string]$ServiceXAwkwardDockerImage = "",
    [string]$RdfDockerImage = "",
    [string]$DockerImageGlobalFallback = "",
    [string]$JobQueueLimit = "20",
    [string]$JobPollIntervalSeconds = "1",
    [string]$JobSoftTimeoutSeconds = "1800",
    [string]$JobHardTimeoutSeconds = "2400",
    [string]$BackendModel = "gpt-54-mini",
    [string]$BackendRepairCycles = "10",
    [switch]$IncludeIngress
  )

  $yaml = @()
  $yaml += "name: $Name"
  $yaml += "type: Microsoft.App/containerApps"
  $yaml += "identity:"
  $yaml += "  type: SystemAssigned"
  $yaml += "properties:"
  $yaml += "  managedEnvironmentId: $EnvironmentId"
  $yaml += "  configuration:"
  if ($IncludeIngress) {
    $yaml += "    ingress:"
    $yaml += "      external: true"
    $yaml += "      targetPort: 8000"
    $yaml += "      allowInsecure: false"
  }
  $yaml += "    registries:"
  $yaml += "      - server: $RegistryServer"
  if (-not [string]::IsNullOrWhiteSpace($RegistryUsername) -and -not [string]::IsNullOrWhiteSpace($RegistryPassword)) {
    $yaml += "        username: $RegistryUsername"
    $yaml += "        passwordSecretRef: acr-password"
  } else {
    $yaml += "        identity: system"
  }
  $yaml += "    secrets:"
  $yaml += "      - name: django-secret-key"
  $yaml += "        value: $(Escape-YamlScalar $SecretKey)"
  $yaml += "      - name: database-url"
  $yaml += "        value: $(Escape-YamlScalar $DatabaseUrl)"
  if (-not [string]::IsNullOrWhiteSpace($RegistryUsername) -and -not [string]::IsNullOrWhiteSpace($RegistryPassword)) {
    $yaml += "      - name: acr-password"
    $yaml += "        value: $(Escape-YamlScalar $RegistryPassword)"
  }
  if (-not [string]::IsNullOrWhiteSpace($GithubClientSecret)) {
    $yaml += "      - name: github-client-secret"
    $yaml += "        value: $(Escape-YamlScalar $GithubClientSecret)"
  }
  if (-not [string]::IsNullOrWhiteSpace($ServiceXConfigText)) {
    $yaml += "      - name: servicex-config-yaml"
    $yaml += "        value: |"
    foreach ($line in ($ServiceXConfigText -replace "`r`n", "`n" -replace "`r", "`n").Split("`n")) {
      $yaml += "          $line"
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($OpenAiApiKey)) {
    $yaml += "      - name: openai-api-key"
    $yaml += "        value: $(Escape-YamlScalar $OpenAiApiKey)"
  }
  $yaml += "  template:"
  $yaml += "    scale:"
  $yaml += "      minReplicas: 1"
  if ($IncludeIngress) {
    $yaml += "      maxReplicas: 3"
  } else {
    $yaml += "      maxReplicas: 1"
  }
  $yaml += "    volumes:"
  $yaml += "      - name: media"
  $yaml += "        storageType: AzureFile"
  $yaml += "        storageName: mediafiles"
  if (-not [string]::IsNullOrWhiteSpace($ServiceXConfigText)) {
    $yaml += "      - name: servicex-config"
    $yaml += "        storageType: Secret"
    $yaml += "        secrets:"
    $yaml += "          - secretRef: servicex-config-yaml"
    $yaml += "            path: servicex.yaml"
  }
  $yaml += "    containers:"
  $yaml += "      - name: $ContainerName"
  $yaml += "        image: $ImageRef"
  if ($Command.Count -gt 0) {
    $yaml += "        command:"
    foreach ($part in $Command) {
      $yaml += "          - $part"
    }
  }
  $yaml += "        env:"
  $yaml += "          - name: DJANGO_SETTINGS_MODULE"
  $yaml += "            value: hep_data_web.settings.prod"
  if (-not [string]::IsNullOrWhiteSpace($ServiceXConfigText)) {
    $yaml += "          - name: HEP_DATA_LLM_HOME_DIR"
    $yaml += "            value: $(Escape-YamlScalar $ServiceXHomeDir)"
  }
  $yaml += "          - name: SECRET_KEY"
  $yaml += "            secretRef: django-secret-key"
  $yaml += "          - name: DATABASE_URL"
  $yaml += "            secretRef: database-url"
  $yaml += "          - name: ALLOWED_HOSTS"
  $yaml += "            value: $(Escape-YamlScalar $AllowedHosts)"
  if (-not [string]::IsNullOrWhiteSpace($CsrfTrustedOrigins)) {
    $yaml += "          - name: CSRF_TRUSTED_ORIGINS"
    $yaml += "            value: $(Escape-YamlScalar $CsrfTrustedOrigins)"
  }
  if (-not [string]::IsNullOrWhiteSpace($GithubClientId)) {
    $yaml += "          - name: GITHUB_CLIENT_ID"
    $yaml += "            value: $(Escape-YamlScalar $GithubClientId)"
  }
  if (-not [string]::IsNullOrWhiteSpace($GithubClientSecret)) {
    $yaml += "          - name: GITHUB_CLIENT_SECRET"
    $yaml += "            secretRef: github-client-secret"
  }
  if (-not [string]::IsNullOrWhiteSpace($OpenAiApiKey)) {
    $yaml += "          - name: api_openai_com_API_KEY"
    $yaml += "            secretRef: openai-api-key"
  }
  if (-not [string]::IsNullOrWhiteSpace($GithubOrg)) {
    $yaml += "          - name: GITHUB_ORG"
    $yaml += "            value: $(Escape-YamlScalar $GithubOrg)"
  }
  if (-not [string]::IsNullOrWhiteSpace($GithubAdminUsers)) {
    $yaml += "          - name: GITHUB_ADMIN_USERS"
    $yaml += "            value: $(Escape-YamlScalar $GithubAdminUsers)"
  }
  if (-not [string]::IsNullOrWhiteSpace($AdminEmails)) {
    $yaml += "          - name: ADMIN_EMAILS"
    $yaml += "            value: $(Escape-YamlScalar $AdminEmails)"
  }
  $yaml += "          - name: STATIC_ROOT"
  $yaml += "            value: /app/staticfiles"
  $yaml += "          - name: MEDIA_ROOT"
  $yaml += "            value: /app/media"
  $yaml += "          - name: ARTIFACT_ROOT"
  $yaml += "            value: /app/media/artifacts"
  $yaml += "          - name: HEP_DATA_LLM_MODEL"
  $yaml += "            value: $(Escape-YamlScalar $BackendModel)"
  $yaml += "          - name: HEP_DATA_LLM_REPAIR_CYCLES"
  $yaml += "            value: $(Escape-YamlScalar $BackendRepairCycles)"
  if (-not [string]::IsNullOrWhiteSpace($ServiceXAwkwardDockerImage)) {
    $yaml += "          - name: HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE"
    $yaml += "            value: $(Escape-YamlScalar $ServiceXAwkwardDockerImage)"
  }
  if (-not [string]::IsNullOrWhiteSpace($RdfDockerImage)) {
    $yaml += "          - name: HEP_DATA_LLM_RDF_DOCKER_IMAGE"
    $yaml += "            value: $(Escape-YamlScalar $RdfDockerImage)"
  }
  if (-not [string]::IsNullOrWhiteSpace($DockerImageGlobalFallback)) {
    $yaml += "          - name: HEP_DATA_LLM_DOCKER_IMAGE_GLOBAL_FALLBACK"
    $yaml += "            value: $(Escape-YamlScalar $DockerImageGlobalFallback)"
  }
  $yaml += "          - name: JOB_QUEUE_LIMIT"
  $yaml += "            value: $(Escape-YamlScalar $JobQueueLimit)"
  $yaml += "          - name: JOB_POLL_INTERVAL_SECONDS"
  $yaml += "            value: $(Escape-YamlScalar $JobPollIntervalSeconds)"
  $yaml += "          - name: JOB_SOFT_TIMEOUT_SECONDS"
  $yaml += "            value: $(Escape-YamlScalar $JobSoftTimeoutSeconds)"
  $yaml += "          - name: JOB_HARD_TIMEOUT_SECONDS"
  $yaml += "            value: $(Escape-YamlScalar $JobHardTimeoutSeconds)"
  $yaml += "        volumeMounts:"
  $yaml += "          - volumeName: media"
  $yaml += "            mountPath: /app/media"
  if (-not [string]::IsNullOrWhiteSpace($ServiceXConfigText)) {
    $yaml += "          - volumeName: servicex-config"
    $yaml += "            mountPath: $(Escape-YamlScalar $ServiceXHomeDir)"
  }
  return $yaml -join [Environment]::NewLine
}

$Subscription = Get-ConfigValue -ExplicitValue $Subscription -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_SUBSCRIPTION"
$ResourceGroup = Require-ConfigValue (Get-ConfigValue -ExplicitValue $ResourceGroup -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_RESOURCE_GROUP") "AZURE_RESOURCE_GROUP"
$Location = Require-ConfigValue (Get-ConfigValue -ExplicitValue $Location -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_LOCATION") "AZURE_LOCATION"
$AppNamePrefix = Require-ConfigValue (Get-ConfigValue -ExplicitValue $AppNamePrefix -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_APP_NAME_PREFIX") "AZURE_APP_NAME_PREFIX"
$ContainerRegistryName = Require-ConfigValue (Get-ConfigValue -ExplicitValue $ContainerRegistryName -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_CONTAINER_REGISTRY_NAME") "AZURE_CONTAINER_REGISTRY_NAME"
$ImageName = Require-ConfigValue (Get-ConfigValue -ExplicitValue $ImageName -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_IMAGE_NAME") "AZURE_IMAGE_NAME"
$ImageTag = Get-ConfigValue -ExplicitValue $ImageTag -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_IMAGE_TAG" -DefaultValue "latest"
$ContainerAppsEnvironmentName = Get-ConfigValue -ExplicitValue $ContainerAppsEnvironmentName -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_CONTAINER_APPS_ENVIRONMENT_NAME"
$ContainerAppsLogsDestination = Get-ConfigValue -ExplicitValue $ContainerAppsLogsDestination -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_CONTAINER_APPS_LOGS_DESTINATION" -DefaultValue "none"
$ContainerAppsLogsWorkspaceId = Get-ConfigValue -ExplicitValue $ContainerAppsLogsWorkspaceId -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_CONTAINER_APPS_LOGS_WORKSPACE_ID"
$ContainerAppsLogsWorkspaceKey = Get-ConfigValue -ExplicitValue $ContainerAppsLogsWorkspaceKey -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_CONTAINER_APPS_LOGS_WORKSPACE_KEY"
$WebAppName = Get-ConfigValue -ExplicitValue $WebAppName -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_WEB_APP_NAME"
$WorkerAppName = Get-ConfigValue -ExplicitValue $WorkerAppName -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_WORKER_APP_NAME"
$StorageAccountName = Get-ConfigValue -ExplicitValue $StorageAccountName -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_STORAGE_ACCOUNT_NAME"
$StorageShareName = Get-ConfigValue -ExplicitValue $StorageShareName -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_STORAGE_SHARE_NAME" -DefaultValue "media"
$PostgresServerName = Get-ConfigValue -ExplicitValue $PostgresServerName -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_POSTGRES_SERVER_NAME"
$PostgresDatabaseName = Get-ConfigValue -ExplicitValue $PostgresDatabaseName -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_POSTGRES_DATABASE_NAME" -DefaultValue "hep_data_web"
$PostgresAdminUser = Get-ConfigValue -ExplicitValue $PostgresAdminUser -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_POSTGRES_ADMIN_USER" -DefaultValue "hepadmin"
$SecretsSource = Get-ConfigValue -ExplicitValue $SecretsSource -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_SECRETS_SOURCE" -DefaultValue "Environment"
$DockerHubSourceImage = Require-ConfigValue (Get-ConfigValue -ExplicitValue $DockerHubSourceImage -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "DOCKER_HUB_SOURCE_IMAGE") "DOCKER_HUB_SOURCE_IMAGE"
$DockerHubUsername = Get-ConfigValue -ExplicitValue $DockerHubUsername -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "DOCKER_HUB_USERNAME"
$DockerHubPassword = Get-ConfigValue -ExplicitValue $DockerHubPassword -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "DOCKER_HUB_PASSWORD"
$CertificatePath = Get-ConfigValue -ExplicitValue $CertificatePath -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_CERTIFICATE_PATH"
$CertificatePassword = Get-ConfigValue -ExplicitValue $CertificatePassword -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_CERTIFICATE_PASSWORD"
$AllowedHosts = Get-ConfigValue -ExplicitValue $AllowedHosts -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_ALLOWED_HOSTS" -DefaultValue "*"
$CsrfTrustedOrigins = Get-ConfigValue -ExplicitValue $CsrfTrustedOrigins -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_CSRF_TRUSTED_ORIGINS"
$GithubClientId = Get-ConfigValue -ExplicitValue $GithubClientId -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "GITHUB_CLIENT_ID"
$GithubOrg = Get-ConfigValue -ExplicitValue $GithubOrg -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "GITHUB_ORG"
$GithubAdminUsers = Get-ConfigValue -ExplicitValue $GithubAdminUsers -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "GITHUB_ADMIN_USERS"
$AdminEmails = Get-ConfigValue -ExplicitValue $AdminEmails -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "ADMIN_EMAILS"
$ServiceXConfigPath = Get-ConfigValue -ExplicitValue $ServiceXConfigPath -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "SERVICEX_CONFIG_PATH"
$OpenAiApiKey = Get-ConfigValue -ExplicitValue $OpenAiApiKey -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "OPENAI_API_KEY"
$ServiceXAwkwardDockerImage = Get-ConfigValue -ExplicitValue $ServiceXAwkwardDockerImage -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE"
$RdfDockerImage = Get-ConfigValue -ExplicitValue $RdfDockerImage -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "HEP_DATA_LLM_RDF_DOCKER_IMAGE"
$DockerImageGlobalFallback = Get-ConfigValue -ExplicitValue $DockerImageGlobalFallback -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "HEP_DATA_LLM_DOCKER_IMAGE_GLOBAL_FALLBACK"
$ServiceXHomeDir = Get-ConfigValue -ExplicitValue "" -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "HEP_DATA_LLM_HOME_DIR" -DefaultValue "/home/site"
$JobQueueLimit = Get-ConfigValue -ExplicitValue $JobQueueLimit -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "JOB_QUEUE_LIMIT" -DefaultValue "20"
$JobPollIntervalSeconds = Get-ConfigValue -ExplicitValue $JobPollIntervalSeconds -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "JOB_POLL_INTERVAL_SECONDS" -DefaultValue "1"
$JobSoftTimeoutSeconds = Get-ConfigValue -ExplicitValue $JobSoftTimeoutSeconds -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "JOB_SOFT_TIMEOUT_SECONDS" -DefaultValue "1800"
$JobHardTimeoutSeconds = Get-ConfigValue -ExplicitValue $JobHardTimeoutSeconds -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "JOB_HARD_TIMEOUT_SECONDS" -DefaultValue "2400"
$BackendModel = Get-ConfigValue -ExplicitValue $BackendModel -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "HEP_DATA_LLM_MODEL" -DefaultValue "gpt-54-mini"
$BackendRepairCycles = Get-ConfigValue -ExplicitValue $BackendRepairCycles -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "HEP_DATA_LLM_REPAIR_CYCLES" -DefaultValue "10"

if ([string]::IsNullOrWhiteSpace($ContainerAppsEnvironmentName)) {
  $ContainerAppsEnvironmentName = Get-SanitizedName -Value "$AppNamePrefix-env" -MaxLength 40 -AllowHyphen
}
if ([string]::IsNullOrWhiteSpace($WebAppName)) {
  $WebAppName = Get-SanitizedName -Value "$AppNamePrefix-web" -MaxLength 40 -AllowHyphen
}
if ([string]::IsNullOrWhiteSpace($WorkerAppName)) {
  $WorkerAppName = Get-SanitizedName -Value "$AppNamePrefix-worker" -MaxLength 40 -AllowHyphen
}
if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
  $StorageAccountName = Get-SanitizedName -Value "$AppNamePrefixstorage" -MaxLength 24
}
if ([string]::IsNullOrWhiteSpace($PostgresServerName)) {
  $PostgresServerName = Get-SanitizedName -Value "$AppNamePrefix-pg" -MaxLength 63 -AllowHyphen
}

$ServiceXConfigText = ""
if (-not [string]::IsNullOrWhiteSpace($ServiceXConfigPath)) {
  $ServiceXConfigPath = Resolve-RelativePath -PathValue $ServiceXConfigPath -BaseDirectory (Split-Path -Parent ([System.IO.Path]::GetFullPath($ConfigPath)))
  if (-not (Test-Path -LiteralPath $ServiceXConfigPath)) {
    throw "ServiceX config file not found: $ServiceXConfigPath"
  }
  $ServiceXConfigText = Get-Content -LiteralPath $ServiceXConfigPath -Raw -Encoding utf8
}

$postgresAdminPassword = Get-SecretText -EnvironmentVariable "AZURE_POSTGRES_ADMIN_PASSWORD" -Prompt "Azure PostgreSQL admin password" -ConfigValues $userConfig -DefaultValues $defaultConfig
$djangoSecretKey = Get-SecretText -EnvironmentVariable "AZURE_DJANGO_SECRET_KEY" -Prompt "Django SECRET_KEY" -ConfigValues $userConfig -DefaultValues $defaultConfig
$githubClientSecret = ""
$githubClientSecretCandidate = Get-ConfigValue -ExplicitValue "" -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "AZURE_GITHUB_CLIENT_SECRET"
if (-not [string]::IsNullOrWhiteSpace($GithubClientId) -or -not [string]::IsNullOrWhiteSpace($githubClientSecretCandidate)) {
  $githubClientSecret = Get-SecretText -EnvironmentVariable "AZURE_GITHUB_CLIENT_SECRET" -Prompt "GitHub OAuth client secret" -ConfigValues $userConfig -DefaultValues $defaultConfig
}
$certificatePasswordValue = $CertificatePassword
if (-not [string]::IsNullOrWhiteSpace($CertificatePath)) {
  if (-not (Test-Path -LiteralPath $CertificatePath)) {
    throw "Certificate file not found: $CertificatePath"
  }
  if ([string]::IsNullOrWhiteSpace($certificatePasswordValue)) {
    $certificatePasswordValue = Get-SecretText -EnvironmentVariable "AZURE_CERTIFICATE_PASSWORD" -Prompt "Certificate password" -ConfigValues $userConfig -DefaultValues $defaultConfig
  }
}

Write-Host "Creating or updating Azure resources in resource group '$ResourceGroup'..."
if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
  Invoke-Az -Arguments @("account", "set", "--subscription", $Subscription, "--output", "none")
}
Invoke-Az -Arguments @("group", "create", "--name", $ResourceGroup, "--location", $Location, "--only-show-errors", "--output", "none")
Ensure-ResourceProviderRegistered -Namespace "Microsoft.DBforPostgreSQL"
Ensure-ResourceProviderRegistered -Namespace "Microsoft.App"
Ensure-ResourceProviderRegistered -Namespace "Microsoft.OperationalInsights"

$acrLoginServer = $null
Invoke-Az -Arguments @(
  "acr", "create",
  "--resource-group", $ResourceGroup,
  "--name", $ContainerRegistryName,
  "--sku", "Standard",
  "--location", $Location,
  "--admin-enabled", "true",
  "--only-show-errors",
  "--output", "none"
)
Invoke-Az -Arguments @(
  "acr", "update",
  "--resource-group", $ResourceGroup,
  "--name", $ContainerRegistryName,
  "--admin-enabled", "true",
  "--only-show-errors",
  "--output", "none"
)
$acrAdminCredentials = (& az acr credential show --resource-group $ResourceGroup --name $ContainerRegistryName --query "{username:username,password:passwords[0].value}" -o json)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acrAdminCredentials)) {
  throw "Unable to determine Azure Container Registry admin credentials."
}
$acrAdminCredentialsObject = $acrAdminCredentials | ConvertFrom-Json
$acrImportArgs = @(
  "acr", "import",
  "--name", $ContainerRegistryName,
  "--source", $dockerHubSourceImage,
  "--image", "$ImageName`:$ImageTag",
  "--force",
  "--only-show-errors",
  "--output", "none"
)
if (-not [string]::IsNullOrWhiteSpace($dockerHubUsername) -and -not [string]::IsNullOrWhiteSpace($dockerHubPassword)) {
  $acrImportArgs += @("--username", $dockerHubUsername, "--password", $dockerHubPassword)
}
Invoke-Az -Arguments $acrImportArgs
$acrLoginServer = (& az acr show --resource-group $ResourceGroup --name $ContainerRegistryName --query loginServer -o tsv)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acrLoginServer)) {
  throw "Unable to determine the Azure Container Registry login server."
}

Invoke-Az -Arguments @(
  "storage", "account", "create",
  "--resource-group", $ResourceGroup,
  "--name", $StorageAccountName,
  "--location", $Location,
  "--sku", "Standard_LRS",
  "--kind", "StorageV2",
  "--allow-blob-public-access", "false",
  "--only-show-errors",
  "--output", "none"
)

$storageAccountKey = (& az storage account keys list --resource-group $ResourceGroup --account-name $StorageAccountName --query "[0].value" -o tsv)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($storageAccountKey)) {
  throw "Unable to determine the storage account key."
}

Invoke-Az -Arguments @(
  "storage", "share", "create",
  "--name", $StorageShareName,
  "--account-name", $StorageAccountName,
  "--account-key", $storageAccountKey,
  "--only-show-errors",
  "--output", "none"
)

$postgresServerExists = Ensure-PostgresServerReady -ResourceGroup $ResourceGroup -ServerName $PostgresServerName
if (-not $postgresServerExists) {
  Invoke-Az -Arguments @(
    "postgres", "flexible-server", "create",
    "--resource-group", $ResourceGroup,
    "--name", $PostgresServerName,
    "--location", $Location,
    "--admin-user", $PostgresAdminUser,
    "--admin-password", $postgresAdminPassword,
    "--version", "16",
    "--tier", "Burstable",
    "--sku-name", "Standard_B1ms",
    "--storage-size", "32",
    "--public-access", "0.0.0.0",
    "--only-show-errors",
    "--output", "none"
  )
}

Ensure-PostgresComputeSku -ResourceGroup $ResourceGroup -ServerName $PostgresServerName -SkuName "Standard_B1ms" -Tier "Burstable"

Ensure-PostgresDatabase -ResourceGroup $ResourceGroup -ServerName $PostgresServerName -DatabaseName $PostgresDatabaseName

 $containerAppEnvCreateOutput = & az containerapp env create `
  --name $ContainerAppsEnvironmentName `
  --resource-group $ResourceGroup `
  --location $Location `
  --logs-destination $ContainerAppsLogsDestination `
  --only-show-errors `
  --output none 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Azure CLI command failed."
}
if ($ContainerAppsLogsDestination -eq "none") {
  $containerAppEnvCreateText = $containerAppEnvCreateOutput -join [Environment]::NewLine
  if ($containerAppEnvCreateText -match 'Generating a Log Analytics workspace with name "([^"]+)"') {
    $generatedWorkspaceName = $Matches[1]
    Write-Host "Removing auto-generated Log Analytics workspace '$generatedWorkspaceName'..."
    Invoke-Az -Arguments @(
      "monitor", "log-analytics", "workspace", "delete",
      "--resource-group", $ResourceGroup,
      "--workspace-name", $generatedWorkspaceName,
      "--force",
      "--yes",
      "--only-show-errors",
      "--output", "none"
    )
  }
}
if (-not [string]::IsNullOrWhiteSpace($ContainerAppsLogsWorkspaceId) -and -not [string]::IsNullOrWhiteSpace($ContainerAppsLogsWorkspaceKey)) {
  Invoke-Az -Arguments @(
    "containerapp", "env", "update",
    "--name", $ContainerAppsEnvironmentName,
    "--resource-group", $ResourceGroup,
    "--logs-destination", "log-analytics",
    "--logs-workspace-id", $ContainerAppsLogsWorkspaceId,
    "--logs-workspace-key", $ContainerAppsLogsWorkspaceKey,
    "--output", "none"
  )
}

Invoke-Az -Arguments @(
  "containerapp", "env", "storage", "set",
  "--name", $ContainerAppsEnvironmentName,
  "--resource-group", $ResourceGroup,
  "--storage-name", "mediafiles",
  "--storage-type", "AzureFile",
  "--azure-file-account-name", $StorageAccountName,
  "--azure-file-account-key", $storageAccountKey,
  "--azure-file-share-name", $StorageShareName,
  "--access-mode", "ReadWrite",
  "--output", "none"
)

$postgresHost = "$PostgresServerName.postgres.database.azure.com"
$databaseUrl = "postgresql://$($PostgresAdminUser):$postgresAdminPassword@$postgresHost:5432/${PostgresDatabaseName}?sslmode=require"
$environmentId = (& az containerapp env show --name $ContainerAppsEnvironmentName --resource-group $ResourceGroup --query id -o tsv)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($environmentId)) {
  throw "Unable to determine the Container Apps environment ID."
}

$imageRef = "$acrLoginServer/$ImageName`:$ImageTag"
$webYaml = New-ContainerAppYaml `
  -Name $WebAppName `
  -ImageRef $imageRef `
  -EnvironmentId $environmentId `
  -RegistryServer $acrLoginServer `
  -RegistryUsername $acrAdminCredentialsObject.username `
  -RegistryPassword $acrAdminCredentialsObject.password `
  -DatabaseUrl $databaseUrl `
  -SecretKey $djangoSecretKey `
  -ContainerName "web" `
  -GithubClientSecret $githubClientSecret `
  -AllowedHosts $AllowedHosts `
  -CsrfTrustedOrigins $CsrfTrustedOrigins `
  -GithubClientId $GithubClientId `
  -GithubOrg $GithubOrg `
  -GithubAdminUsers $GithubAdminUsers `
  -AdminEmails $AdminEmails `
  -ServiceXConfigText $ServiceXConfigText `
  -ServiceXHomeDir $ServiceXHomeDir `
  -OpenAiApiKey $OpenAiApiKey `
  -ServiceXAwkwardDockerImage $ServiceXAwkwardDockerImage `
  -RdfDockerImage $RdfDockerImage `
  -DockerImageGlobalFallback $DockerImageGlobalFallback `
  -JobQueueLimit $JobQueueLimit `
  -JobPollIntervalSeconds $JobPollIntervalSeconds `
  -JobSoftTimeoutSeconds $JobSoftTimeoutSeconds `
  -JobHardTimeoutSeconds $JobHardTimeoutSeconds `
  -BackendModel $BackendModel `
  -BackendRepairCycles $BackendRepairCycles `
  -Command @("uv", "run", "gunicorn", "hep_data_web.wsgi:application", "--bind", "0.0.0.0:8000") `
  -IncludeIngress

$workerYaml = New-ContainerAppYaml `
  -Name $WorkerAppName `
  -ImageRef $imageRef `
  -EnvironmentId $environmentId `
  -RegistryServer $acrLoginServer `
  -RegistryUsername $acrAdminCredentialsObject.username `
  -RegistryPassword $acrAdminCredentialsObject.password `
  -DatabaseUrl $databaseUrl `
  -SecretKey $djangoSecretKey `
  -ContainerName "worker" `
  -GithubClientSecret $githubClientSecret `
  -AllowedHosts $AllowedHosts `
  -CsrfTrustedOrigins $CsrfTrustedOrigins `
  -GithubClientId $GithubClientId `
  -GithubOrg $GithubOrg `
  -GithubAdminUsers $GithubAdminUsers `
  -AdminEmails $AdminEmails `
  -ServiceXConfigText $ServiceXConfigText `
  -ServiceXHomeDir $ServiceXHomeDir `
  -OpenAiApiKey $OpenAiApiKey `
  -ServiceXAwkwardDockerImage $ServiceXAwkwardDockerImage `
  -RdfDockerImage $RdfDockerImage `
  -DockerImageGlobalFallback $DockerImageGlobalFallback `
  -JobQueueLimit $JobQueueLimit `
  -JobPollIntervalSeconds $JobPollIntervalSeconds `
  -JobSoftTimeoutSeconds $JobSoftTimeoutSeconds `
  -JobHardTimeoutSeconds $JobHardTimeoutSeconds `
  -BackendModel $BackendModel `
  -BackendRepairCycles $BackendRepairCycles `
  -Command @("uv", "run", "python", "manage.py", "run_worker")

$tempRoot = Join-Path $env:TEMP "hep-data-web-azure"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$webYamlPath = Join-Path $tempRoot "$WebAppName.yaml"
$workerYamlPath = Join-Path $tempRoot "$WorkerAppName.yaml"
Set-Content -LiteralPath $webYamlPath -Value $webYaml -Encoding utf8
Set-Content -LiteralPath $workerYamlPath -Value $workerYaml -Encoding utf8

try {
  Invoke-Az -Arguments @("containerapp", "create", "--name", $WebAppName, "--resource-group", $ResourceGroup, "--yaml", $webYamlPath, "--output", "none")
  Invoke-Az -Arguments @("containerapp", "create", "--name", $WorkerAppName, "--resource-group", $ResourceGroup, "--yaml", $workerYamlPath, "--output", "none")

  $webPrincipalId = (& az containerapp show --name $WebAppName --resource-group $ResourceGroup --query identity.principalId -o tsv)
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($webPrincipalId)) {
    Invoke-Az -Arguments @(
      "role", "assignment", "create",
      "--assignee", $webPrincipalId,
      "--role", "AcrPull",
      "--scope", (& az acr show --name $ContainerRegistryName --resource-group $ResourceGroup --query id -o tsv),
      "--output", "none"
    )
  }

  $workerPrincipalId = (& az containerapp show --name $WorkerAppName --resource-group $ResourceGroup --query identity.principalId -o tsv)
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($workerPrincipalId)) {
    Invoke-Az -Arguments @(
      "role", "assignment", "create",
      "--assignee", $workerPrincipalId,
      "--role", "AcrPull",
      "--scope", (& az acr show --name $ContainerRegistryName --resource-group $ResourceGroup --query id -o tsv),
      "--output", "none"
    )
  }

  if (-not [string]::IsNullOrWhiteSpace($CertificatePath)) {
    Invoke-Az -Arguments @(
      "containerapp", "env", "certificate", "upload",
      "--name", $ContainerAppsEnvironmentName,
      "--resource-group", $ResourceGroup,
      "--certificate-file", $CertificatePath,
      "--password", $certificatePasswordValue,
      "--output", "none"
    )
  }
}
finally {
  Remove-Item -LiteralPath $webYamlPath, $workerYamlPath -ErrorAction SilentlyContinue
}

$webFqdn = (& az containerapp show --name $WebAppName --resource-group $ResourceGroup --query properties.configuration.ingress.fqdn -o tsv)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($webFqdn)) {
  throw "Unable to determine the web app FQDN."
}
$githubCallbackUrl = ""
if (-not [string]::IsNullOrWhiteSpace($webFqdn)) {
  $githubCallbackUrl = "https://$webFqdn/accounts/github/callback/"
}

Write-Host "Deployment resources created."
Write-Host "Web app FQDN: $webFqdn"
if (-not [string]::IsNullOrWhiteSpace($githubCallbackUrl)) {
  Write-Host "GitHub OAuth callback URL: $githubCallbackUrl"
}
Write-Host "Registry: $acrLoginServer"
Write-Host "PostgreSQL server: $PostgresServerName"
Write-Host "Storage account: $StorageAccountName"
Write-Host "Next step: bind the uploaded certificate and create or approve an admin account."
