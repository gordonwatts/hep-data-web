# Azure Deployment

This repository is designed to be deployed by an operator who is already signed in to Azure with `az login`.

## Prerequisites

- Azure CLI installed and working locally.
- The `containerapp` and `postgres flexible-server` Azure CLI command groups available.
- A private container registry image for the web front end.
- A PostgreSQL admin password, Django `SECRET_KEY`, and any GitHub OAuth values you want to enable.
- A PFX certificate file if you plan to bind a custom domain.

If you do not already have the `containerapp` extension installed, install it before running the scripts:

```powershell
az extension add -n containerapp
```

If you manage more than one subscription, pick the one you want before you deploy:

```powershell
az login
az account show --output table
az account list --query "[?isDefault]" --output table
az account set --subscription "<subscription-id-or-name>"
```

The Azure scripts read a deployment config file automatically. Start from
[scripts/azure/deploy.env.example](../scripts/azure/deploy.env.example) and
create a user-specific file anywhere you like. Pass that path with
`-ConfigPath`, and the scripts will load the example defaults first and then
overlay your file on top.

Example:

```powershell
.\scripts\azure\create-resources.ps1 -ConfigPath "C:\configs\hep-data-web-prod.env"
```

The config file can hold the subscription name, resource group, registry,
Docker Hub source image, secrets, and any environment-specific overrides for a
given deployment. Comment lines beginning with `#` are ignored, and trailing
comments after unquoted values are also accepted.

## Deployment model

The deployment scripts create a small Azure stack:

- Azure Container Apps for the web app and the worker
- Azure Database for PostgreSQL flexible server for persistent relational data
- Azure Storage for persistent media and artifact files
- Azure Container Registry for the application image

The worker and web app use the same application image, but the worker runs `run_worker` instead of the web server command.
The backend job execution still pulls `hep-data-llm` analysis images at runtime, so the scripts also configure the profile-specific image settings used by the app.

## Script overview

- `scripts/azure/create-resources.ps1`
  - Creates the resource group, registry, PostgreSQL server, storage account, Container Apps environment, and the web and worker apps.
  - Configures environment variables for database access, Django secrets, and backend image selection.
  - Mounts Azure Files for persistent media and artifact storage.
- `scripts/azure/delete-app-resources.ps1`
  - Deletes only the ephemeral application resources.
  - Leaves the database, storage account, and registry in place.
- `scripts/azure/delete-persistent-data.ps1`
  - Deletes the persistent database and storage resources.
  - This script is intentionally destructive and asks for confirmation.

## First-time setup

1. Log in to Azure with `az login`.
2. Create a deployment config file anywhere you like, using
   `scripts/azure/deploy.env.example` as the baseline.
3. Fill in the subscription, registry, Docker Hub image, and secret values.
4. Run the create script with `-ConfigPath` pointing at your file.
5. Upload and bind your certificate if you are using a custom hostname.
6. Create a Django superuser or approve the first admin profile after the app comes up.

Example deployment command:

```powershell
.\scripts\azure\create-resources.ps1 -ConfigPath "C:\configs\hep-data-web-prod.env"
```

If you want to override a value temporarily, you can still pass a parameter or
set an environment variable before running the script, but that is optional.

## Secrets and configuration

The scripts never commit secrets to the repository. They read sensitive values
from the config file passed with `-ConfigPath`, fall back to the example
defaults, and prompt securely when needed.

Recommended environment variables:

- `AZURE_POSTGRES_ADMIN_PASSWORD`
- `AZURE_DJANGO_SECRET_KEY`
- `AZURE_GITHUB_CLIENT_SECRET`
- `AZURE_CERTIFICATE_PASSWORD`
- `SERVICEX_TOKEN`
- `OPENAI_API_KEY`
- `DOCKER_HUB_USERNAME`
- `DOCKER_HUB_PASSWORD`

Non-secret values can also come from environment variables if you prefer not to pass them on the command line.

## Certificate handling

Use a local PFX file for the certificate. The create script accepts a certificate path and optional password.

For Container Apps, the certificate is uploaded to the Container Apps environment with `az containerapp env certificate upload`.
After upload, bind the certificate to your custom hostname in the same environment.

If you do not have the final hostname yet, complete the deployment first and then bind the certificate once DNS is ready.

The default public hostname is the web app's Container Apps ingress FQDN. The
create script prints it at the end of deployment as `Web app FQDN: ...`. If you
are using that Azure-provided hostname, you do not need to request your own
certificate. If you want a custom domain, the certificate should match the
exact hostname you plan to bind, such as `app.example.com`.

Example certificate upload:

```powershell
az containerapp env certificate upload `
  -g "hep-data-web-prod" `
  --name "hep-data-web-env" `
  --certificate-file "C:\certs\hep-data-web.pfx" `
  --password "<pfx-password>"
```

## Docker image pulls

The create script imports the application image from Docker Hub into Azure
Container Registry with `az acr import`, then the web and worker apps pull from
ACR.

If the source image is private, provide a Docker Hub username and token or password. The script passes those credentials to the Azure import command so Azure, not your local Docker daemon, performs the pull.

Example registry inspection commands:

```powershell
az acr show -g "hep-data-web-prod" -n "hepdatawebacr" --query loginServer -o tsv
az acr repository show-tags -n "hepdatawebacr" --repository "hep-data-web" -o table
```

Example import flow for the source image:

```powershell
az acr import `
  --name "hepdatawebacr" `
  --source "docker.io/<namespace>/<image>:<tag>" `
  --image "hep-data-web:latest" `
  --username "<docker-hub-username>" `
  --password "<docker-hub-token-or-password>" `
  --force
```

## Admin bootstrap

The app still needs a first privileged account after a fresh deploy.

Use one of these approaches:

- Create a Django superuser through the web container.
- Approve the first GitHub profile through the built-in admin flow.

The choice depends on whether you are using local login testing or GitHub OAuth in Azure.

Example superuser bootstrap inside the web container:

```powershell
az containerapp exec `
  --name "hep-data-web-web" `
  --resource-group "hep-data-web-prod" `
  --container "web"
```

Then run this inside the container shell:

```powershell
uv run python manage.py createsuperuser
```

If you already have a GitHub OAuth login configured, sign in through the app, then approve the first profile in the admin UI.
The `az containerapp exec` command above is only for getting a shell inside the running container.

## Teardown

Use the normal teardown script to remove only the application resources when you want to recycle the app layer.

Use the destructive persistent-data script only when you explicitly want to remove the database and storage contents.

Example teardown commands:

```powershell
.\scripts\azure\delete-app-resources.ps1 -ConfigPath "C:\configs\hep-data-web-prod.env"
```

```powershell
.\scripts\azure\delete-persistent-data.ps1 -ConfigPath "C:\configs\hep-data-web-prod.env"
```

## Manual verification checklist

- Create the Azure resources from scratch.
- Deploy the web app and worker.
- Confirm login, approval, and job metadata survive an app-resource teardown and recreate.
- Confirm the persistent-data deletion script is a separate explicit action.
- Confirm the certificate uploads and binds from the documented local PFX file.
- Confirm the registry pull path works with the configured auth method.
