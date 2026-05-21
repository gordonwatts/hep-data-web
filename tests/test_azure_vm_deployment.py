from pathlib import Path


def test_azure_vm_docs_link_the_two_deployment_paths():
    azure_docs = Path("docs/azure-deployment.md").read_text(encoding="utf-8")
    vm_docs = Path("docs/azure-vm-deployment.md").read_text(encoding="utf-8")

    assert "azure-vm-deployment.md" in azure_docs
    assert "Managed Container Apps" in azure_docs
    assert "VM Compose" in azure_docs
    assert "Caddy" in vm_docs
    assert "Standard_B2s" in vm_docs
    assert "/srv/hep-data-web" in vm_docs
    assert "HTTP-only" in vm_docs or "HTTP only" in vm_docs


def test_azure_vm_compose_file_uses_the_expected_services_and_commands():
    compose = Path("deploy/azure-vm/docker-compose.vm.yml").read_text(encoding="utf-8")

    assert "docker:29-dind" in compose
    assert "postgres:16" in compose
    assert "caddy:2.8" in compose
    assert "AZURE_VM_IMAGE" in compose
    assert "uv run gunicorn hep_data_web.wsgi:application" in compose
    assert "--access-logfile -" in compose
    assert "--error-logfile -" in compose
    assert "collectstatic --noinput" in compose
    assert "uv run python manage.py run_worker" in compose
    assert "80:80" in compose
    assert "443:443" in compose


def test_azure_vm_config_example_includes_the_expected_settings():
    env_example = Path("scripts/azure-vm/deploy.env.example").read_text(encoding="utf-8")

    assert "AZURE_VM_DATA_DISK_NAME" in env_example
    assert "AZURE_VM_TLS_MODE=http" in env_example
    assert "JOB_QUEUE_LIMIT=3" in env_example
    assert "AZURE_BACKUP_CONNECTION_STRING" in env_example


def test_azure_vm_deploy_script_maps_openai_key_to_backend_variable():
    deploy_script = Path("scripts/azure-vm/deploy-compose.ps1").read_text(encoding="utf-8")

    assert "api_openai_com_API_KEY" in deploy_script
    assert "OPENAI_API_KEY = $OpenAiApiKey" in deploy_script


def test_azure_vm_deploy_script_copies_servicex_config_to_home_and_data_mount():
    deploy_script = Path("scripts/azure-vm/deploy-compose.ps1").read_text(encoding="utf-8")

    assert "$remoteBase/servicex.yaml" in deploy_script
    assert "$remoteHome/servicex.yaml" in deploy_script
