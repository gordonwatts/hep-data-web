# Azure Deployment

This repository is designed to be deployed by an operator who is already signed in to Azure with `az login`.

## Prerequisites

- Azure CLI installed and working locally.
- The `containerapp` and `postgres flexible-server` Azure CLI command groups available.
- The `Microsoft.DBforPostgreSQL`, `Microsoft.App`, and `Microsoft.OperationalInsights`
  resource providers registered on the target subscription.
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

If the PostgreSQL step fails with `MissingSubscriptionRegistration`, register the
provider once for that subscription and rerun the script:

```powershell
az provider register --namespace Microsoft.DBforPostgreSQL --wait
```

If the Container Apps environment step fails with a similar provider error,
register the Container Apps providers too:

```powershell
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait
```

The deployment defaults to `AZURE_CONTAINER_APPS_LOGS_DESTINATION=none`, which
keeps the Container Apps environment cheap and avoids Log Analytics setup.
If you want environment logs, set
`AZURE_CONTAINER_APPS_LOGS_DESTINATION=log-analytics` and provide the workspace
ID and key in the deploy config.
If your local `containerapp` extension still auto-generates a workspace in the
`none` path, the create script deletes that workspace right after the
environment is created.

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
  - Uses Azure Container Registry admin credentials for the initial web and worker image pull so the first revision can start immediately.
  - Ensures the PostgreSQL server is on the cheapest Burstable `Standard_B1ms` compute shape before continuing.
  - Mounts Azure Files for persistent media and artifact storage.
- `scripts/azure/delete-app-resources.ps1`
  - Deletes only the ephemeral application resources.
  - Stops the PostgreSQL server and leaves only storage in place.
- `scripts/azure/delete-persistent-data.ps1`
  - Deletes the persistent database and storage resources.
  - This script is intentionally destructive and asks for confirmation.

## First-time setup

1. Log in to Azure with `az login`.
2. Create a deployment config file anywhere you like, using
   `scripts/azure/deploy.env.example` as the baseline.
3. Fill in the subscription, registry, Docker Hub image, and secret values.
   You can leave the GitHub OAuth fields blank on the first pass if you want to
   create the OAuth app only after you know the Azure callback URL.
4. Run the create script with `-ConfigPath` pointing at your file:

   ```powershell
   .\scripts\azure\create-resources.ps1 -ConfigPath "C:\configs\hep-data-web-prod.env"
   ```

5. Upload and bind your certificate if you are using a custom hostname.
6. Create a Django superuser or approve the first admin profile after the app comes up.

If you want to override a value temporarily, you can still pass a parameter or
set an environment variable before running the script, but that is optional.
If you tear down only the app layer and rerun the create script later, the
script will start an existing stopped PostgreSQL server before it recreates the
app resources.

## Secrets and configuration

The scripts never commit secrets to the repository. They read sensitive values
from the config file passed with `-ConfigPath`, fall back to the example
defaults, and prompt securely when needed.

If you are bootstrapping GitHub OAuth, you can leave `GITHUB_CLIENT_ID` and
`AZURE_GITHUB_CLIENT_SECRET` blank for the first deployment. The create script
prints the deployed web app FQDN and the callback URL after it finishes, so you
can copy that exact URL into the GitHub OAuth app settings before rerunning the
script with OAuth enabled.

Recommended environment variables:

- `AZURE_POSTGRES_ADMIN_PASSWORD`
- `AZURE_DJANGO_SECRET_KEY`
- `AZURE_GITHUB_CLIENT_SECRET`
- `AZURE_CERTIFICATE_PASSWORD`
- `SERVICEX_CONFIG_PATH`
- `OPENAI_API_KEY`
- `DOCKER_HUB_USERNAME`
- `DOCKER_HUB_PASSWORD`

Non-secret values can also come from environment variables if you prefer not to pass them on the command line.

For ServiceX, provide the path to your local `servicex.yaml` file. The script
reads that file and mounts it into the Azure containers as a secret volume at
runtime, so it never gets baked into the image.
If the path is relative, the script resolves it relative to the deploy config
file you passed with `-ConfigPath`.

For OpenAI, keep using `OPENAI_API_KEY` in the deploy config. The Azure script
maps that value into the container runtime variable
`api_openai_com_API_KEY`, which is the name the backend subprocess actually
sees.

## Certificate handling

There are two hostname choices:

- Use the Azure-generated Container Apps hostname that the create script prints
  as `Web app FQDN: ...`.
- Use a custom domain such as `app.example.com`.

If you use the Azure-generated hostname, you do not need to upload a
certificate yourself.

If you use a custom domain, complete these steps after the first deployment:

1. Decide the exact hostname you want to use, for example `app.example.com`.
2. Point DNS at the Container Apps app:
   - For a subdomain, create a `CNAME` record from `app.example.com` to the
     printed Container Apps hostname.
   - For an apex domain, create the `A` and `TXT` records that Azure requires.
3. Upload and bind the certificate to the app and hostname.

If you are bringing your own certificate, use the PFX file on disk and run:

```powershell
az containerapp ssl upload `
  --resource-group "hep-data-web-prod" `
  --environment "hep-data-web-env" `
  --name "hep-data-web-web" `
  --hostname "app.example.com" `
  --certificate-file "C:\certs\hep-data-web.pfx" `
  --password "<pfx-password>"
```

That command uploads the certificate to the Container Apps environment, adds
the hostname to the app, and binds the certificate.

If you want to inspect the hostname later, use:

```powershell
az containerapp hostname list `
  --resource-group "hep-data-web-prod" `
  --name "hep-data-web-web"
```

If you do not have the final hostname yet, finish deployment first, copy the
printed FQDN from the script output, and then create the DNS record and upload
the certificate once DNS is ready.

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

If you have not finished GitHub OAuth yet, create the first superuser now.

1. Open a shell in the running web container:

   ```powershell
   az containerapp exec `
     --resource-group "hep-data-web-prod" `
     --name "hep-data-web-web" `
     --container "web" `
     --command bash
   ```

   If `bash` is not available, use `/bin/sh` instead.

2. Run the Django management command inside that shell:

   ```powershell
   uv run python manage.py createsuperuser
   ```

3. Follow the prompts for username, email, and password.

If you are using GitHub OAuth instead of a local superuser, sign in through the
site after OAuth is configured, then approve the first profile in the admin UI.
The `az containerapp exec` command above is only for getting a shell inside the
running container.

## Teardown

Use the normal teardown script to remove only the application resources when you want to recycle the app layer.
That script stops PostgreSQL so only storage charges remain.

Use the destructive persistent-data script only when you explicitly want to remove the database and storage contents.
That script removes the remaining billable state as well.

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
