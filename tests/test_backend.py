from unittest.mock import patch

import pytest

from portal import backend


def test_available_profile_choices_are_v1_options():
    choices = backend.available_profile_choices()
    assert [choice.value for choice in choices] == [
        backend.BackendProfile.SERVICEX_AWKWARD,
        backend.BackendProfile.RDF,
    ]


def test_validate_backend_profile_accepts_known_value():
    assert backend.validate_backend_profile("rdf") is backend.BackendProfile.RDF


def test_backend_config_name_matches_v1_profile():
    assert (
        backend.backend_config_name_for_profile(backend.BackendProfile.SERVICEX_AWKWARD)
        == "atlas-sx-awk-hist"
    )


def test_validate_backend_profile_rejects_unknown_value():
    with pytest.raises(ValueError, match="Unsupported backend profile"):
        backend.validate_backend_profile("unknown")


def test_prompt_mentions_dataset_detects_explicit_dataset():
    assert backend.prompt_mentions_dataset("Plot from rucio dataset atlas.foo.bar")
    assert backend.prompt_mentions_dataset("Use DAOD_PHYSVAL sample")


def test_prompt_mentions_dataset_ignores_plain_prompt():
    assert backend.prompt_mentions_dataset("Plot the leading jet pT") is False


def test_load_example_questions_reads_yaml_from_package(monkeypatch, tmp_path):
    package_dir = tmp_path / "hep_data_llm"
    package_dir.mkdir()
    (package_dir / "questions.yaml").write_text(
        """
questions:
  - prompt: Plot the ETmiss distribution
    dataset: rucio://atlas-open-data-jz2
    title: ETmiss
  - question: Make a jet multiplicity plot
"""
    )

    monkeypatch.setenv("HEP_DATA_LLM_EXAMPLE_PACKAGE", "hep_data_llm")
    monkeypatch.setattr(backend.resources, "files", lambda package: package_dir)

    questions = backend.load_example_questions()

    assert [question.prompt for question in questions] == [
        "Plot the ETmiss distribution",
        "Make a jet multiplicity plot",
    ]
    assert questions[0].dataset == "rucio://atlas-open-data-jz2"


def test_default_dataset_prefers_explicit_env(monkeypatch):
    monkeypatch.setenv("HEP_DATA_LLM_DEFAULT_DATASET", "explicit-dataset")
    monkeypatch.setattr(backend, "load_example_questions", lambda: [])

    assert backend.default_dataset() == "explicit-dataset"


def test_default_dataset_falls_back_to_first_example_dataset(monkeypatch):
    monkeypatch.delenv("HEP_DATA_LLM_DEFAULT_DATASET", raising=False)
    monkeypatch.setattr(
        backend,
        "load_example_questions",
        lambda: [
            backend.ExampleQuestion(prompt="Plot ETmiss in the rucio dataset dataset-a."),
            backend.ExampleQuestion(prompt="b", dataset="derived-dataset"),
        ],
    )

    assert backend.default_dataset() == "dataset-a"


def test_normalize_question_infers_dataset_from_prompt():
    question = backend._normalize_question(
        "Plot the ETmiss of all events in the rucio dataset user.example.dataset."
    )
    assert question is not None
    assert question.dataset == "user.example.dataset"


def test_render_job_prompt_injects_dataset_once():
    prompt = backend.render_job_prompt("Plot ETmiss", "dataset")
    assert prompt.endswith("If this question does not specify a dataset, use dataset.")
    assert backend.render_job_prompt(prompt, "dataset") == prompt


def test_render_job_prompt_keeps_prompt_dataset_unchanged():
    prompt = "Plot ETmiss from rucio dataset atlas.data.set"
    assert backend.render_job_prompt(prompt, "fallback-dataset") == prompt


def test_backend_defaults_are_configurable():
    with (
        patch.object(backend.settings, "HEP_DATA_LLM_MODEL", "custom-model"),
        patch.object(backend.settings, "HEP_DATA_LLM_REPAIR_CYCLES", 7),
    ):
        assert backend.backend_model_cli_value() == "custom-model"
        assert backend.backend_repair_cycles() == 7


def test_docker_image_for_profile_prefers_profile_specific_override():
    with (
        patch.object(backend.settings, "HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE", "sx/image:tag"),
        patch.object(backend.settings, "HEP_DATA_LLM_RDF_DOCKER_IMAGE", "rdf/image:tag"),
        patch.object(backend.settings, "HEP_DATA_LLM_DOCKER_IMAGE_GLOBAL_FALLBACK", "global/image:tag"),
    ):
        assert (
            backend.docker_image_for_profile(backend.BackendProfile.SERVICEX_AWKWARD)
            == "sx/image:tag"
        )
        assert backend.docker_image_for_profile(backend.BackendProfile.RDF) == "rdf/image:tag"
