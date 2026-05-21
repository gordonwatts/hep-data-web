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
  [string]$ServiceXToken = "",
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
    [string]$GithubClientSecret = "",
    [string]$CertificatePassword = "",
    [string]$AllowedHosts = "*",
    [string]$CsrfTrustedOrigins = "",
    [string]$GithubClientId = "",
    [string]$GithubOrg = "",
    [string]$GithubAdminUsers = "",
    [string]$AdminEmails = "",
    [string]$ServiceXToken = "",
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
  $yaml += "        identity: system"
  $yaml += "    secrets:"
  $yaml += "      - name: django-secret-key"
  $yaml += "        value: $(Escape-YamlScalar $SecretKey)"
  $yaml += "      - name: database-url"
  $yaml += "        value: $(Escape-YamlScalar $DatabaseUrl)"
  if (-not [string]::IsNullOrWhiteSpace($GithubClientSecret)) {
    $yaml += "      - name: github-client-secret"
    $yaml += "        value: $(Escape-YamlScalar $GithubClientSecret)"
  }
  if (-not [string]::IsNullOrWhiteSpace($ServiceXToken)) {
    $yaml += "      - name: servicex-token"
    $yaml += "        value: $(Escape-YamlScalar $ServiceXToken)"
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
  if (-not [string]::IsNullOrWhiteSpace($ServiceXToken)) {
    $yaml += "          - name: SERVICEX_TOKEN"
    $yaml += "            secretRef: servicex-token"
  }
  if (-not [string]::IsNullOrWhiteSpace($OpenAiApiKey)) {
    $yaml += "          - name: OPENAI_API_KEY"
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
$ServiceXToken = Get-ConfigValue -ExplicitValue $ServiceXToken -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "SERVICEX_TOKEN"
$OpenAiApiKey = Get-ConfigValue -ExplicitValue $OpenAiApiKey -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "OPENAI_API_KEY"
$ServiceXAwkwardDockerImage = Get-ConfigValue -ExplicitValue $ServiceXAwkwardDockerImage -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE"
$RdfDockerImage = Get-ConfigValue -ExplicitValue $RdfDockerImage -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "HEP_DATA_LLM_RDF_DOCKER_IMAGE"
$DockerImageGlobalFallback = Get-ConfigValue -ExplicitValue $DockerImageGlobalFallback -ConfigValues $userConfig -DefaultValues $defaultConfig -EnvironmentVariable "HEP_DATA_LLM_DOCKER_IMAGE_GLOBAL_FALLBACK"
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

$postgresAdminPassword = Get-SecretText -EnvironmentVariable "AZURE_POSTGRES_ADMIN_PASSWORD" -Prompt "Azure PostgreSQL admin password" -ConfigValues $userConfig -DefaultValues $defaultConfig
$djangoSecretKey = Get-SecretText -EnvironmentVariable "AZURE_DJANGO_SECRET_KEY" -Prompt "Django SECRET_KEY" -ConfigValues $userConfig -DefaultValues $defaultConfig
$githubClientSecret = Get-SecretText -EnvironmentVariable "AZURE_GITHUB_CLIENT_SECRET" -Prompt "GitHub OAuth client secret" -ConfigValues $userConfig -DefaultValues $defaultConfig
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
Invoke-Az -Arguments @("group", "create", "--name", $ResourceGroup, "--location", $Location, "--output", "none")

$acrLoginServer = $null
Invoke-Az -Arguments @(
  "acr", "create",
  "--resource-group", $ResourceGroup,
  "--name", $ContainerRegistryName,
  "--sku", "Standard",
  "--location", $Location,
  "--admin-enabled", "false",
  "--output", "none"
)
$acrImportArgs = @(
  "acr", "import",
  "--name", $ContainerRegistryName,
  "--source", $dockerHubSourceImage,
  "--image", "$ImageName`:$ImageTag",
  "--force",
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
  "--output", "none"
)

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
  "--output", "none"
)

Invoke-Az -Arguments @(
  "postgres", "flexible-server", "db", "create",
  "--resource-group", $ResourceGroup,
  "--server-name", $PostgresServerName,
  "--database-name", $PostgresDatabaseName,
  "--output", "none"
)

Invoke-Az -Arguments @(
  "containerapp", "env", "create",
  "--name", $ContainerAppsEnvironmentName,
  "--resource-group", $ResourceGroup,
  "--location", $Location,
  "--output", "none"
)

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
$databaseUrl = "postgresql://$($PostgresAdminUser):$postgresAdminPassword@$postgresHost:5432/$PostgresDatabaseName?sslmode=require"
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
  -ServiceXToken $ServiceXToken `
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
  -IncludeIngress

$workerYaml = New-ContainerAppYaml `
  -Name $WorkerAppName `
  -ImageRef $imageRef `
  -EnvironmentId $environmentId `
  -RegistryServer $acrLoginServer `
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
  -ServiceXToken $ServiceXToken `
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
  Invoke-Az -Arguments @("containerapp", "create", "--resource-group", $ResourceGroup, "--yaml", $webYamlPath, "--output", "none")
  Invoke-Az -Arguments @("containerapp", "create", "--resource-group", $ResourceGroup, "--yaml", $workerYamlPath, "--output", "none")

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

Write-Host "Deployment resources created."
Write-Host "Web app FQDN: $webFqdn"
Write-Host "Registry: $acrLoginServer"
Write-Host "PostgreSQL server: $PostgresServerName"
Write-Host "Storage account: $StorageAccountName"
Write-Host "Next step: bind the uploaded certificate and create or approve an admin account."
