# Azure VM Compose Deployment Implementation Plan

## Summary

Replace the current managed Azure Container Apps deployment path with a simpler Azure VM deployment path that mirrors the local `docker compose up` workflow as closely as practical.

The app is expected to be a low-traffic hobby deployment:

- Almost never more than one active user at a time.
- Possibly idle for days.
- Never more than one plot/backend job at a time.
- Small but important persistent state for users, approvals, jobs, database rows, uploaded/generated artifacts, and Docker/cache data.

The current Azure scripts provision a managed PaaS stack:

- Azure Container Apps environment.
- Separate web Container App.
- Separate worker Container App.
- Azure Database for PostgreSQL Flexible Server.
- Azure Storage/Azure Files.
- Azure Container Registry.

That stack is more complex than the expected operating model and does not clearly reproduce the local Docker daemon dependency used by backend execution. The new target is a single small Linux VM running Docker Compose, with persistent data on a managed disk and a simple backup/restore story.

This plan is intentionally docs-first and migration-safe. Keep the existing Azure Container Apps scripts available until the VM path is implemented, verified, and the operator explicitly chooses to retire the old path.

## Chosen Defaults

- **Deployment model:** one Azure Linux VM running Docker Compose.
- **VM size:** start with `Standard_B2s` for 2 vCPU / 4 GiB RAM. Use `Standard_B2ms` only if backend jobs need more memory after real testing.
- **Region:** default to the existing Azure region setting, currently `eastus`, unless the operator chooses otherwise.
- **Operating system:** Ubuntu LTS Azure image.
- **Persistent storage:** one managed data disk mounted at `/srv/hep-data-web`.
- **Disk size:** start with 128 GiB Standard SSD LRS unless the operator explicitly chooses 64 GiB to minimize cost.
- **Database:** keep PostgreSQL in Compose, using a persistent Docker volume stored under `/srv/hep-data-web`.
- **Artifacts/media:** keep filesystem-backed media/artifacts in Compose volumes stored under `/srv/hep-data-web`.
- **Docker daemon:** use the VM's local Docker Engine and preserve the current Docker-in-Docker Compose service if that remains the most compatible backend path.
- **Ingress:** expose only HTTP/HTTPS and SSH at the Azure Network Security Group. Restrict SSH to the operator IP when possible.
- **TLS:** use Caddy with Let's Encrypt automatic certificates and renewal by default. Use the Azure-generated VM DNS label or a custom domain CNAME/A record.
- **Registry:** pull the app image directly from Docker Hub or GitHub Container Registry. Do not require Azure Container Registry for the VM path.
- **Secrets:** keep a production `.env` on the VM outside the repo checkout, with file permissions restricted to the deploy user.
- **Migrations:** preserve the current Compose `migrate` service so database schema setup remains automatic.
- **Backups:** start with simple scheduled backups of PostgreSQL dump plus media/artifact files to Azure Blob Storage, or managed disk snapshots if Blob Storage is not configured yet.
- **Cost target:** keep always-on Azure infrastructure near the cost of one VM plus one managed disk. Avoid always-on managed PostgreSQL, ACR, Log Analytics, and separate app/worker services for the hobby deployment path.

## Public Interfaces / Core Concepts

### Deployment commands

- `scripts/azure-vm/create-vm.ps1`
  - Create or update the resource group, VM, network, public IP, NSG, and managed data disk.
  - Install Docker, Docker Compose plugin, and baseline VM packages through cloud-init or a remote setup script.
  - Do not copy secrets into the repository.
- `scripts/azure-vm/deploy-compose.ps1`
  - Push or refresh the Compose deployment on the VM.
  - Copy deployment templates if needed.
  - Pull the configured app image.
  - Run `docker compose up -d`.
  - Verify the service state.
- `scripts/azure-vm/backup-now.ps1`
  - Trigger a one-off database and artifact backup from the VM.
- `scripts/azure-vm/delete-vm.ps1`
  - Delete only ephemeral compute/network resources by default.
  - Preserve the managed data disk unless the caller explicitly requests data deletion.
- `scripts/azure-vm/delete-persistent-data.ps1`
  - Destructive script requiring explicit confirmation before deleting the data disk and backup storage.

### New documentation

- `docs/azure-vm-deployment.md`
  - Operator-focused instructions for the VM deployment.
  - Cost guidance and SKU selection notes.
  - First-time setup, secrets, DNS, TLS, backup, restore, upgrade, and teardown procedures.
  - Explicit Let's Encrypt certificate setup and renewal verification steps.
- `docs/azure-deployment.md`
  - Update to clearly mark the existing Container Apps path as the managed PaaS path.
  - Link to the VM deployment path as the recommended low-cost hobby deployment.

### VM filesystem layout

- `/srv/hep-data-web/`
  - Root directory for all deployment state.
- `/srv/hep-data-web/compose/`
  - Production Compose file and Caddy config.
- `/srv/hep-data-web/env/`
  - Production `.env` and any external config files.
- `/srv/hep-data-web/env/certs/`
  - Optional manually supplied certificate and key files if not using Let's Encrypt.
- `/srv/hep-data-web/data/`
  - Docker volume storage if using bind-mounted volume paths.
- `/srv/hep-data-web/data/caddy/`
  - Caddy state, including automatically issued Let's Encrypt certificates and renewal metadata.
- `/srv/hep-data-web/backups/`
  - Local staging area for backups before upload.
- `/srv/hep-data-web/logs/`
  - Optional local logs or backup logs.

### Compose files

- Keep `docker-compose.yml` as the local development path.
- Add a production VM Compose file only if local and VM needs diverge.
  - Suggested file: `deploy/azure-vm/docker-compose.vm.yml`.
  - Use image references rather than `build: .`.
  - Keep service names aligned with local Compose: `web`, `worker`, `postgres`, `docker`, `migrate`.
  - Keep named volumes or bind-backed volumes under `/srv/hep-data-web/data`.

### Configuration variables

Document and preserve these existing variables for VM deployment:

- `DJANGO_SETTINGS_MODULE=hep_data_web.settings.prod`
- `SECRET_KEY`
- `ALLOWED_HOSTS`
- `CSRF_TRUSTED_ORIGINS`
- `DATABASE_URL`
- `GITHUB_CLIENT_ID`
- `GITHUB_CLIENT_SECRET`
- `GITHUB_ORG`
- `GITHUB_ADMIN_USERS`
- `ADMIN_EMAILS`
- `OPENAI_API_KEY`
- `SERVICEX_CONFIG_PATH` or the VM equivalent file path
- `HEP_DATA_LLM_HOME_DIR`
- `HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE`
- `HEP_DATA_LLM_RDF_DOCKER_IMAGE`
- `HEP_DATA_LLM_MODEL`
- `HEP_DATA_LLM_REPAIR_CYCLES`
- `JOB_QUEUE_LIMIT`
- `JOB_POLL_INTERVAL_SECONDS`
- `JOB_SOFT_TIMEOUT_SECONDS`
- `JOB_HARD_TIMEOUT_SECONDS`

Add VM-specific variables only when needed:

- `AZURE_VM_NAME`
- `AZURE_VM_SIZE`
- `AZURE_VM_ADMIN_USER`
- `AZURE_VM_SSH_PUBLIC_KEY_PATH`
- `AZURE_VM_DATA_DISK_SIZE_GB`
- `AZURE_VM_DNS_LABEL`
- `AZURE_VM_PUBLIC_HOSTNAME`
- `AZURE_VM_TLS_EMAIL`
- `AZURE_VM_TLS_MODE=letsencrypt`
- `AZURE_VM_TLS_CERT_PATH`
- `AZURE_VM_TLS_KEY_PATH`
- `AZURE_VM_ALLOWED_SSH_CIDR`
- `AZURE_VM_IMAGE`
- `AZURE_VM_DATA_MOUNT=/srv/hep-data-web`
- `AZURE_BACKUP_STORAGE_ACCOUNT`
- `AZURE_BACKUP_CONTAINER`

## Implementation Checklist

### 1. Preserve Current Managed Azure Path

- [ ] Rename or annotate the current Azure Container Apps documentation so it is clearly the managed PaaS deployment path.
  - Keep `docs/azure-deployment.md` intact enough for anyone already using it.
  - Add a short warning that it is operationally heavier and not the recommended hobby deployment.
- [ ] Keep the existing `scripts/azure/` scripts in place during the VM implementation.
  - Do not delete the Container Apps scripts in the first pass.
  - Avoid breaking any existing operator workflow until the VM path is verified.
- [ ] Add a brief comparison table to `docs/azure-deployment.md`.
  - Container Apps path: managed services, more moving parts, higher operational complexity.
  - VM Compose path: closer to local, simpler, likely cheaper, more VM maintenance.

### 2. Add VM Deployment Documentation

- [ ] Create `docs/azure-vm-deployment.md`.
  - Explain that this is the recommended path for the low-traffic hobby deployment.
  - State the expected monthly cost range for `B2s` plus a managed disk.
  - Explain when to choose `B1ms`, `B2s`, or `B2ms`.
- [ ] Document prerequisites.
  - Azure CLI installed.
  - `az login` already completed.
  - SSH key available.
  - Published app image available in Docker Hub or GitHub Container Registry.
  - Production secrets available outside the repo.
- [ ] Document first-time resource creation.
  - Resource group.
  - VM.
  - Network Security Group.
  - Public IP/DNS.
  - Data disk.
  - Optional backup storage account/container.
- [ ] Document first deployment.
  - Create `/srv/hep-data-web`.
  - Mount the data disk.
  - Install Docker.
  - Write production `.env`.
  - Point DNS at the VM public IP before enabling public HTTPS.
  - Configure Caddy for Let's Encrypt using the public hostname and operator email.
  - Start Compose.
  - Create or approve the first admin user.
- [ ] Document HTTPS setup with Let's Encrypt.
  - Explain that ports 80 and 443 must both be reachable for normal automatic issuance and renewal.
  - Explain that Caddy stores ACME account and certificate state under the persistent data disk.
  - Include the expected Caddyfile shape for `https://<hostname>` reverse proxying to `web:8000`.
  - Include a renewal verification command, such as checking `docker compose logs caddy` and the browser certificate issuer.
  - Note that Let's Encrypt renewal is automatic while Caddy is running and storage is persisted.
- [ ] Document a manual certificate fallback.
  - Store certificate and key files under `/srv/hep-data-web/env/certs`.
  - Mount that directory read-only into the reverse proxy.
  - Configure Caddy or nginx to use the mounted cert/key paths.
  - Make manual renewal an explicit operator responsibility for this fallback mode.
- [ ] Document routine operations.
  - Pull a new image and restart.
  - View service status.
  - Read logs.
  - Run Django management commands.
  - Run a smoke job.
  - Restart the worker.
- [ ] Document backup and restore.
  - Database dump command.
  - Media/artifact archive command.
  - Upload to Azure Blob Storage or keep a disk snapshot.
  - Restore to a fresh VM.
- [ ] Document teardown.
  - Stop app.
  - Delete VM while preserving data disk.
  - Delete persistent data only with explicit confirmation.

### 3. Add Production VM Compose File

- [ ] Decide whether to add `deploy/azure-vm/docker-compose.vm.yml` or reuse `docker-compose.yml` with overrides.
  - Prefer a separate VM file if production should use a published image instead of `build: .`.
  - Keep the local development Compose file unchanged unless a shared improvement is needed.
- [ ] Define the `web` service.
  - Use the published app image.
  - Run `uv run gunicorn hep_data_web.wsgi:application --bind 0.0.0.0:8000`.
  - Use `DJANGO_SETTINGS_MODULE=hep_data_web.settings.prod`.
  - Mount persistent media, static, temp, and home/config paths.
  - Depend on `postgres`, `docker`, and `migrate` as appropriate.
- [ ] Define the `worker` service.
  - Use the same app image.
  - Run `uv run python manage.py run_worker`.
  - Mount the same persistent paths needed for artifacts and backend config.
  - Use the same Docker daemon access strategy as local Compose.
  - Keep one worker replica only.
- [ ] Define the `migrate` service.
  - Use the same app image.
  - Run `uv run python manage.py migrate --noinput`.
  - Gate `web` and `worker` startup on successful migration.
- [ ] Define the `postgres` service.
  - Use `postgres:16`.
  - Store data under the persistent data disk.
  - Do not expose PostgreSQL publicly.
- [ ] Define the Docker daemon/backend execution service.
  - Start from the existing local `docker:29-dind` service.
  - Preserve privileged mode only if required by backend execution.
  - Keep the Docker API private to the Compose network.
  - Persist Docker data under the data disk so backend images do not need to be pulled every run.
- [ ] Add Caddy or reverse proxy service if selected.
  - Expose ports 80 and 443.
  - Proxy to `web:8000`.
  - Use Let's Encrypt automatic certificates by default.
  - Set Caddy's ACME contact email from `AZURE_VM_TLS_EMAIL` or the deployment config.
  - Store Caddy data/config under the data disk for certificate persistence and renewal continuity.
  - Mount any manually supplied certificate files only for the explicit manual-cert mode.
- [ ] Add a Caddyfile template.
  - Accept `AZURE_VM_PUBLIC_HOSTNAME` or equivalent as the public site name.
  - Reverse proxy to the internal web service.
  - Preserve the original host and scheme headers needed by Django.
  - Include a local HTTP-only option only for throwaway testing, not production.

### 4. Add VM Resource Creation Script

- [ ] Create `scripts/azure-vm/create-vm.ps1`.
  - Load defaults from `scripts/azure-vm/deploy.env.example`.
  - Overlay a user-provided `-ConfigPath`.
  - Follow the dotenv parser pattern from existing Azure scripts where practical.
- [ ] Create or update the resource group.
- [ ] Create a virtual network, subnet, network security group, public IP, and network interface.
  - Allow inbound 80 and 443 from the internet.
  - Allow inbound 22 only from `AZURE_VM_ALLOWED_SSH_CIDR` when provided.
  - Document that Let's Encrypt HTTP-01 validation requires inbound port 80 unless a different ACME challenge is deliberately implemented.
- [ ] Create the VM.
  - Default size `Standard_B2s`.
  - Ubuntu LTS image.
  - SSH key auth only.
  - Disable password authentication.
- [ ] Create and attach a managed data disk.
  - Default 128 GiB Standard SSD LRS.
  - Use predictable naming from `AZURE_APP_NAME_PREFIX`.
  - Do not overwrite an existing disk.
- [ ] Bootstrap the VM.
  - Install Docker Engine and Compose plugin.
  - Add the deploy user to the Docker group.
  - Format and mount the data disk if it is new.
  - Add `/etc/fstab` entry.
  - Create `/srv/hep-data-web` subdirectories.
- [ ] Print final connection and next-step commands.
  - SSH command.
  - VM public IP/FQDN.
  - Deployment command.

### 5. Add VM Deployment Script

- [ ] Create `scripts/azure-vm/deploy-compose.ps1`.
  - Read the same config file as `create-vm.ps1`.
  - Connect to the VM over SSH/SCP.
  - Create the remote deployment directories.
- [ ] Copy Compose files and reverse proxy config to the VM.
- [ ] Render or copy the Caddyfile.
  - Use the configured public hostname for Let's Encrypt issuance.
  - Use the configured ACME email when available.
  - Refuse production HTTPS deployment if no public hostname is configured.
- [ ] Copy or render a production `.env` template only when explicitly requested.
  - Do not overwrite an existing remote `.env` unless `-ForceEnv` or similar is provided.
  - Never print secret values.
- [ ] Authenticate with the container registry if needed.
  - Support Docker Hub or GHCR token through local environment/config.
  - Prefer `docker login` on the VM only when the image is private.
- [ ] Pull images.
- [ ] Run `docker compose up -d`.
- [ ] Run a post-deploy status check.
  - `docker compose ps`.
  - `docker compose logs --tail`.
  - HTTP health or homepage check if the host is reachable.
  - HTTPS check for the public hostname after DNS is live.
  - Caddy log check showing successful certificate issuance or reuse.
- [ ] Print admin bootstrap commands.
  - `docker compose exec web uv run python manage.py createsuperuser`.
  - Link to the approval admin page.

### 5a. Backend Job Visibility and ServiceX Config Handling

- [x] Copy the configured ServiceX YAML into the VM-visible home directory before launching `hep-data-llm plot`.
  - Keep the host-side `SERVICEX_CONFIG_PATH` as the deploy-machine path.
  - Make the container-side path resolve to `/host-home/servicex.yaml`.
  - Preserve the existing `hep-data-llm` lookup behavior without changing that repo.
- [x] Emit worker-side runtime context for backend jobs.
  - Log the resolved working directory, `HOME`, and `USERPROFILE`.
  - Log the candidate `servicex.yaml` locations and whether they exist.
  - Make the runtime context visible in VM worker logs for troubleshooting.

### 6. Add Backup and Restore Support

- [ ] Create `scripts/azure-vm/backup-now.ps1`.
  - Run `pg_dump` from the `postgres` container.
  - Archive media/artifact directories.
  - Store timestamped files under `/srv/hep-data-web/backups`.
- [ ] Add optional upload to Azure Blob Storage.
  - Create or reuse a storage account/container.
  - Use Azure CLI auth or a scoped SAS token.
  - Do not require Blob Storage for the minimal VM deployment.
- [ ] Add a cron/systemd timer setup step.
  - Daily database backup is enough for the expected usage.
  - Keep local retention small, for example 7 daily backups.
  - Keep remote retention documented.
- [ ] Document restore.
  - Stop web/worker.
  - Restore database dump into Postgres.
  - Restore media/artifact archive.
  - Start services.
  - Verify login and job history.

### 7. Add VM Teardown Scripts

- [ ] Create `scripts/azure-vm/delete-vm.ps1`.
  - Delete the VM and ephemeral network resources.
  - Preserve the managed data disk by default.
  - Preserve backup storage by default.
  - Print the preserved resource names.
- [ ] Create `scripts/azure-vm/delete-persistent-data.ps1`.
  - Require typing `DELETE`.
  - Delete the managed data disk.
  - Optionally delete backup storage only when explicitly requested.
- [ ] Add dry-run or `-WhatIf` support where practical.
- [ ] Document the difference between app teardown and persistent data deletion.

### 8. Update Runtime Defaults for Single-User Operation

- [ ] Set the recommended VM deployment `JOB_QUEUE_LIMIT` to a small value.
  - Suggested default for VM docs: `JOB_QUEUE_LIMIT=3`.
  - This allows one running job and a tiny queue without pretending to support many users.
- [ ] Keep exactly one worker process.
  - Do not add multiple worker replicas.
  - Do not add distributed scheduler infrastructure.
- [ ] Confirm worker restart behavior.
  - Restarting the worker should mark stale running jobs failed using existing recovery behavior.
  - Document this as acceptable for the hobby deployment.
- [ ] Keep polling conservative.
  - Preserve `JOB_POLL_INTERVAL_SECONDS=1` or increase it if desired.
  - Do not introduce high-frequency status infrastructure.

### 9. Security Hardening for a Small VM

- [ ] Restrict SSH in the NSG.
  - Prefer the operator's current public IP `/32`.
  - Document how to update the rule when the operator IP changes.
- [ ] Require SSH key authentication.
- [ ] Do not expose Docker API outside the Compose network.
- [ ] Do not expose Postgres outside the Compose network.
- [ ] Keep the reverse proxy as the only public web entry point.
  - Public ports should be 80 and 443 only.
  - The Django `web` container port should not be exposed directly to the internet.
- [ ] Store production `.env` outside git.
  - Suggested path: `/srv/hep-data-web/env/.env`.
  - File mode should be readable only by the deploy user/root where practical.
- [ ] Document OS patching.
  - Enable unattended security upgrades or document a monthly patch command.
- [ ] Add a simple firewall note.
  - NSG is required.
  - `ufw` is optional if NSG rules are clear and minimal.

### 10. Verification and Acceptance

- [ ] Verify the VM can be created from scratch with `scripts/azure-vm/create-vm.ps1`.
- [ ] Verify Docker and Compose are installed on the VM.
- [ ] Verify the data disk is mounted at `/srv/hep-data-web`.
- [ ] Verify Compose starts all services.
- [ ] Verify migrations run automatically before web/worker.
- [ ] Verify the homepage loads through the public HTTPS URL.
- [ ] Verify the HTTPS certificate is issued by Let's Encrypt in the default path.
- [ ] Verify Caddy certificate state persists under `/srv/hep-data-web/data/caddy`.
- [ ] Verify a Compose restart does not request a fresh certificate unnecessarily.
- [ ] Verify the plan documents manual cert/key installation for non-Let's Encrypt deployments.
- [ ] Verify admin bootstrap works.
- [ ] Verify a user can submit one job and the worker processes it.
- [ ] Verify backend execution can access a Docker daemon on the VM.
- [ ] Verify generated artifacts persist after `docker compose down` and `docker compose up -d`.
- [ ] Verify database state persists after VM reboot.
- [ ] Verify backup script creates a database dump and artifact archive.
- [ ] Verify app-resource teardown preserves the data disk.
- [ ] Verify a new VM can be attached to the preserved data disk and recover the app state.

## Test Plan

### Static validation

- Run PowerShell parser checks for new scripts.
  - `pwsh -NoProfile -File scripts/azure-vm/create-vm.ps1 -WhatIf` if implemented.
  - Use `-WhatIf` or dry-run paths where available.
- Run shellcheck-equivalent review manually for generated cloud-init or bash snippets if no linter is available.
- Run `docker compose config` for the VM Compose file.
  - Confirm service graph.
  - Confirm volumes point to the intended persistent paths.
  - Confirm secrets are not embedded in the committed Compose file.

### Local repository validation

- `uv run pytest`
- `uv run ruff check .`
- `uv run ruff format --check .`

Only run full Python validation if implementation changes Python code. For docs/script-only changes, at minimum validate script parsing and Compose config.

### Manual Azure validation

- Create a fresh VM deployment in a test resource group.
- Deploy the app image.
- Complete admin bootstrap.
- Submit a small smoke job.
- Confirm result artifacts are visible in the UI.
- Reboot the VM and confirm:
  - services restart or can be restarted cleanly,
  - database state remains,
  - artifacts remain,
  - stale running jobs are handled as expected.
- Delete only the VM and recreate it against the preserved disk.
- Confirm app state survives the recreate.
- Run destructive persistent-data deletion only in a throwaway test deployment.

## Suggested Implementation Order

1. Add `docs/azure-vm-deployment.md` and update `docs/azure-deployment.md` with the deployment-choice comparison.
2. Add the VM Compose file and validate it locally with `docker compose config`.
3. Add `scripts/azure-vm/deploy.env.example`.
4. Add `scripts/azure-vm/create-vm.ps1` with VM, disk, network, and bootstrap support.
5. Add `scripts/azure-vm/deploy-compose.ps1`.
6. Test a fresh VM deployment manually.
7. Add backup and restore scripts.
8. Add teardown scripts that preserve data by default.
9. Complete the manual recovery test from preserved data disk.
10. Decide whether to keep, de-emphasize, or remove the managed Container Apps scripts in a later cleanup.

## Assumptions

- The operator is comfortable with a small amount of VM maintenance in exchange for lower cost and simpler deployment semantics.
- Running Docker-based backend execution inside a VM is acceptable and closer to the proven local Compose path than Azure Container Apps.
- The app does not require horizontal scaling, high availability, managed database failover, or zero-downtime deploys for V1.
- The VM can be temporarily unavailable during OS updates, deploys, or restarts.
- A one-worker deployment is the correct production behavior for this usage profile.
- Managed disk persistence plus backups is sufficient for the small amount of important data.
- Azure Blob Storage for backups is useful but should not be mandatory for the first minimal deployment.
- The existing Container Apps scripts should remain available until the VM deployment has been tested end to end.
