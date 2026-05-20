from pathlib import Path


def test_release_workflow_tags_images_with_release_version():
    workflow = Path(".github/workflows/release.yml").read_text(encoding="utf-8")

    assert "release:" in workflow
    assert "types:" in workflow
    assert "published" in workflow
    assert "release_tag" in workflow
    assert "${{ github.event.release.tag_name || github.event.inputs.release_tag }}" in workflow
    assert "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ env.RELEASE_TAG }}" in workflow
    assert "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest" in workflow
    assert "${{ github.sha }}" not in workflow
