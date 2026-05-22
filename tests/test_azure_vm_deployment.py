import os
import subprocess
import tempfile
from pathlib import Path

import pytest


def _ps_quote(value: Path) -> str:
    return str(value).replace("'", "''")


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
    assert "VM disks and persistence" in vm_docs
    assert "hep-data-web-vm-data" in vm_docs
    assert "hep-data-web-vm_disk1_" in vm_docs


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
    assert "$ServiceXContainerPath" in deploy_script
    assert "/host-home/servicex.yaml" in deploy_script
    assert 'sudo", "install", "-d"' in deploy_script
    assert '"sudo", "install",\n    "-o", "root"' in deploy_script


def test_azure_vm_delete_script_removes_the_current_os_disk():
    delete_script = Path("scripts/azure-vm/delete-vm.ps1").read_text(encoding="utf-8")

    assert "storageProfile.osDisk.managedDisk.id" in delete_script
    assert "az disk delete --ids" in delete_script or "az disk delete" in delete_script
    assert "Deleting OS disk" in delete_script


def test_azure_vm_account_admin_scripts_cover_listing_and_promotion():
    list_script = Path("scripts/azure-vm/list-accounts.ps1").read_text(encoding="utf-8")
    promote_script = Path("scripts/azure-vm/promote-account.ps1").read_text(encoding="utf-8")

    assert "Format-Table -AutoSize" in list_script
    assert "Out-String -Width 240" in list_script
    assert "AccountName is required" in promote_script
    assert "is_staff = true" in promote_script
    assert "approval_state = 'approved'" in promote_script
    assert "github_login" in promote_script


@pytest.mark.skipif(
    os.name != "nt",
    reason="PowerShell is only available in the Windows test environment",
)
def test_azure_vm_relative_config_path_resolves_outside_repo_root():
    repo_root = Path(__file__).resolve().parents[1]
    outside_cwd = Path(tempfile.mkdtemp(dir=r"C:\tmp"))

    command = (
        f"Set-Location '{_ps_quote(outside_cwd)}'; "
        f". '{_ps_quote(repo_root / 'scripts/azure-vm/_common.ps1')}'; "
        f"$resolved = Resolve-ExistingRelativePath -PathValue '.\\azure-vm-deploy.env' "
        f"-SearchDirectories @('{_ps_quote(outside_cwd)}', '{_ps_quote(repo_root)}'); "
        "Write-Output $resolved"
    )
    completed = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", command],
        check=True,
        capture_output=True,
        text=True,
    )

    assert Path(completed.stdout.strip()) == repo_root / "azure-vm-deploy.env"
