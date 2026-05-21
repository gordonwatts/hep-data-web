# Azure VM Compose Deployment

This is the recommended Azure path for the low-traffic hobby deployment.
It keeps the runtime close to local `docker compose up` by running the app on a
single Linux VM with Docker Compose and a persistent managed disk.

## Cost and sizing

- Start with `Standard_B2s` for the VM.
- Move to `Standard_B2ms` only if real backend jobs need more memory.
- Use `Standard_B1ms` only for very small or mostly idle deployments where the
  backend workload is known to fit.
- Plan for the VM plus one managed disk as the steady-state cost.

## Prerequisites

- Azure CLI installed.
- `az login` already completed.
- An SSH public key available on the machine that will create the VM.
- A published application image in Docker Hub or GitHub Container Registry.
- Production secrets kept outside the repository checkout.
- A hostname only if you plan to switch on HTTPS later.

## Filesystem layout

The deployment scripts use this layout on the VM:

- `/srv/hep-data-web/compose/` for Compose files and reverse-proxy config.
- `/srv/hep-data-web/env/` for the production `.env` file.
- `/srv/hep-data-web/env/certs/` for manual certificate files, if used.
- `/srv/hep-data-web/data/` for persistent Docker, database, Caddy, and media data.
- `/srv/hep-data-web/backups/` for local backup staging.
- `/srv/hep-data-web/logs/` for operator logs if desired.

## First-time setup

1. Create a deployment config file from
   [scripts/azure-vm/deploy.env.example](../scripts/azure-vm/deploy.env.example).
2. Fill in the Azure subscription, resource group, VM name, SSH key path,
   image, and secrets. Leave the hostname blank for the initial HTTP-only run.
3. Run the VM creation script:

   ```powershell
   .\scripts\azure-vm\create-vm.ps1 -ConfigPath "C:\configs\hep-data-web-vm.env"
   ```

4. If you are using a hostname later, point DNS at the VM public IP or Azure DNS label.
5. Copy the Compose files and production environment to the VM:

   ```powershell
   .\scripts\azure-vm\deploy-compose.ps1 -ConfigPath "C:\configs\hep-data-web-vm.env"
   ```

6. Open the site at the VM public IP over HTTP and create or approve the first admin user.
7. If you later want HTTPS, add a hostname, switch `AZURE_VM_TLS_MODE` to `letsencrypt`, and redeploy.

If you use ServiceX, point `SERVICEX_CONFIG_PATH` at your local `servicex.yaml`
before deployment. The deploy script copies it to
`/srv/hep-data-web/data/home/servicex.yaml` on the VM, which the backend sees
as `~/servicex.yaml`.

For GitHub OAuth, register this callback URL in the GitHub app:

`https://hep-data-llm.eastus.cloudapp.azure.com/accounts/github/callback/`

## HTTPS and Let's Encrypt

The default first-pass deployment uses plain HTTP on the VM public IP.
If you later add a hostname, Caddy and Let's Encrypt handle HTTPS.

- Allow inbound TCP ports 80 and 443.
- Keep SSH restricted to the operator IP when possible.
- Caddy stores its ACME account and certificate state under
  `/srv/hep-data-web/data/caddy`.
- Renewal is automatic while Caddy is running and the data disk remains mounted.
- For the initial HTTP-only mode, Caddy listens on port 80 and does not request
  a certificate.

Expected Caddyfile shape:

```caddyfile
{
  email {$AZURE_VM_TLS_EMAIL}
}

{$AZURE_VM_PUBLIC_HOSTNAME} {
  encode zstd gzip
  reverse_proxy web:8000
}
```

To verify renewal, check the proxy logs and browser certificate issuer:

```powershell
docker compose logs caddy --tail 100
```

Manual cert mode is supported as a fallback:

- Put the certificate and key under `/srv/hep-data-web/env/certs`.
- Mount that directory read-only into the reverse proxy.
- Configure Caddy or nginx to read the mounted files.
- Track renewal manually in that mode.

## Routine operations

Common day-to-day commands on the VM:

```powershell
cd /srv/hep-data-web/compose
docker compose ps
docker compose logs --tail 100 web
docker compose pull
docker compose up -d
docker compose exec web uv run python manage.py createsuperuser
docker compose exec web uv run python manage.py run_smoke_job
docker compose restart worker
```

## Backup and restore

Back up the database and artifacts from the VM, then copy the result to Azure
Blob Storage or keep a disk snapshot.

Example database dump:

```powershell
docker compose exec -T postgres pg_dump -U hep_data_web hep_data_web > backups\hep_data_web.sql
```

Example archive of the persistent files:

```powershell
tar -czf backups\hep_data_web-data.tgz -C /srv/hep-data-web data
```

To restore to a fresh VM:

1. Provision the new VM and attach the preserved data disk if you have one.
2. Restore the database dump into the PostgreSQL container.
3. Restore the `data/` archive if you are not reusing the same disk.
4. Start Compose again.

## Teardown

To remove only the compute layer:

```powershell
.\scripts\azure-vm\delete-vm.ps1 -ConfigPath "C:\configs\hep-data-web-vm.env"
```

To delete the persistent data only when you are sure you want to lose it:

```powershell
.\scripts\azure-vm\delete-persistent-data.ps1 -ConfigPath "C:\configs\hep-data-web-vm.env"
```

The persistent-data script requires explicit confirmation before deleting the
disk and any configured backup storage.
