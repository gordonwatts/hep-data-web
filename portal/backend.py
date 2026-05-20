"""Backend integration boundary for hep-data-llm."""

from __future__ import annotations

import importlib
import re
from dataclasses import dataclass
from enum import StrEnum
from importlib import resources
from pathlib import Path
from typing import Any

from django.conf import settings

import yaml

from hep_data_web.settings.base import env

EXAMPLE_PACKAGE_CANDIDATES = (
    "hep_data_llm",
    "hep_data_llm.data",
    "hep_data_llm.examples",
)

EXAMPLE_FILE_CANDIDATES = ("questions.yaml", "question.yaml")
EXAMPLE_FILE_PATHS = (
    ("config", "questions.yaml"),
    ("config", "question.yaml"),
)


class BackendProfile(StrEnum):
    SERVICEX_AWKWARD = "servicex_awkward"
    RDF = "rdf"


@dataclass(frozen=True)
class BackendProfileChoice:
    value: BackendProfile
    label: str


@dataclass(frozen=True)
class ExampleQuestion:
    prompt: str
    dataset: str | None = None
    title: str | None = None
    source: str = "hep-data-llm"


def available_profile_choices() -> list[BackendProfileChoice]:
    return [
        BackendProfileChoice(BackendProfile.SERVICEX_AWKWARD, "ServiceX + Awkward"),
        BackendProfileChoice(BackendProfile.RDF, "RDF"),
    ]


def backend_config_name_for_profile(value: str | BackendProfile) -> str:
    profile = validate_backend_profile(value)
    if profile is BackendProfile.SERVICEX_AWKWARD:
        return "atlas-sx-awk-hist"
    if profile is BackendProfile.RDF:
        return "atlas-sx-rdf"
    raise ValueError(f"Unsupported backend profile: {value!r}")


def validate_backend_profile(value: str | BackendProfile) -> BackendProfile:
    if isinstance(value, BackendProfile):
        return value
    try:
        return BackendProfile(value)
    except ValueError as exc:
        valid = ", ".join(choice.value for choice in available_profile_choices())
        raise ValueError(
            f"Unsupported backend profile: {value!r}. Expected one of: {valid}"
        ) from exc


def _yaml_documents(package: str, filename: str) -> Any:
    try:
        resource = resources.files(package).joinpath(filename)
        if resource.is_file():
            return yaml.safe_load(resource.read_text(encoding="utf-8"))
    except (ModuleNotFoundError, TypeError):
        pass

    module = importlib.import_module(package)
    module_path = Path(module.__file__).resolve().parent / filename
    if not module_path.is_file():
        raise FileNotFoundError(filename)
    return yaml.safe_load(module_path.read_text(encoding="utf-8"))


def _normalize_question(raw: Any) -> ExampleQuestion | None:
    if isinstance(raw, str):
        prompt = raw.strip()
        if prompt:
            return ExampleQuestion(prompt=prompt, dataset=_dataset_from_prompt(prompt))
        return None

    if isinstance(raw, dict):
        prompt = (
            raw.get("prompt") or raw.get("question") or raw.get("text") or raw.get("title") or ""
        )
        prompt = str(prompt).strip()
        if not prompt:
            return None
        dataset = raw.get("dataset") or raw.get("data_set") or raw.get("rucio_dataset")
        if not dataset:
            dataset = _dataset_from_prompt(prompt)
        title = raw.get("title") or raw.get("name")
        source = str(raw.get("source") or "hep-data-llm")
        return ExampleQuestion(
            prompt=prompt,
            dataset=str(dataset).strip() if dataset else None,
            title=str(title).strip() if title else None,
            source=source,
        )

    return None


def _dataset_from_prompt(prompt: str) -> str | None:
    match = re.search(r"rucio dataset\s+(.+)$", prompt, re.IGNORECASE)
    if not match:
        return None

    dataset = match.group(1).strip().rstrip(" .")
    dataset = dataset.strip("\"'`")
    return dataset or None


def prompt_mentions_dataset(prompt: str) -> bool:
    if _dataset_from_prompt(prompt):
        return True

    if re.search(r"\brucio\s+dataset\b", prompt, re.IGNORECASE):
        return True

    if re.search(r"\bdaod[\w.-]*\b", prompt, re.IGNORECASE):
        return True

    if re.search(r"\bdataset\s*[:=]\s*[A-Za-z0-9][\w./:-]*", prompt, re.IGNORECASE):
        return True

    return False


def load_example_questions() -> list[ExampleQuestion]:
    package_override = env("HEP_DATA_LLM_EXAMPLE_PACKAGE")
    packages = (package_override,) if package_override else EXAMPLE_PACKAGE_CANDIDATES

    for package in packages:
        if not package:
            continue
        for filename in EXAMPLE_FILE_CANDIDATES:
            try:
                raw_questions = _yaml_documents(package, filename)
            except (FileNotFoundError, ModuleNotFoundError, yaml.YAMLError):
                raw_questions = None

            if not raw_questions:
                for path_parts in EXAMPLE_FILE_PATHS:
                    try:
                        resource = resources.files(package)
                        for part in path_parts:
                            resource = resource.joinpath(part)
                        if resource.is_file():
                            raw_questions = yaml.safe_load(resource.read_text(encoding="utf-8"))
                            break
                    except (ModuleNotFoundError, TypeError, yaml.YAMLError):
                        continue

            if not raw_questions:
                continue

            if isinstance(raw_questions, dict):
                raw_questions = raw_questions.get("questions") or raw_questions.get("items") or []

            if not isinstance(raw_questions, list):
                raw_questions = [raw_questions]

            questions = [
                question
                for raw in raw_questions
                if (question := _normalize_question(raw)) is not None
            ]
            if questions:
                return questions

    return []


def default_dataset() -> str | None:
    explicit_dataset = env("HEP_DATA_LLM_DEFAULT_DATASET")
    if explicit_dataset:
        return explicit_dataset

    for question in load_example_questions():
        if question.dataset:
            return question.dataset
        inferred_dataset = _dataset_from_prompt(question.prompt)
        if inferred_dataset:
            return inferred_dataset

    return None


def render_job_prompt(prompt: str, dataset: str | None) -> str:
    if not dataset:
        return prompt
    if prompt_mentions_dataset(prompt):
        return prompt
    return f"{prompt}\n\nIf this question does not specify a dataset, use {dataset}."


def backend_model_cli_value() -> str:
    value = str(getattr(settings, "HEP_DATA_LLM_MODEL", "")).strip()
    if not value:
        raise ValueError("HEP_DATA_LLM_MODEL must not be empty")
    return value


def backend_repair_cycles() -> int:
    raw_value = getattr(settings, "HEP_DATA_LLM_REPAIR_CYCLES", 0)
    try:
        cycles = int(raw_value)
    except (TypeError, ValueError) as exc:
        raise ValueError("HEP_DATA_LLM_REPAIR_CYCLES must be a positive integer") from exc
    if cycles <= 0:
        raise ValueError("HEP_DATA_LLM_REPAIR_CYCLES must be a positive integer")
    return cycles


def docker_image_for_profile(value: str | BackendProfile) -> str | None:
    profile = validate_backend_profile(value)
    if profile is BackendProfile.SERVICEX_AWKWARD:
        image = getattr(settings, "HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE", "")
    else:
        image = getattr(settings, "HEP_DATA_LLM_RDF_DOCKER_IMAGE", "")

    if not image:
        image = getattr(settings, "HEP_DATA_LLM_DOCKER_IMAGE_GLOBAL_FALLBACK", "")
    if not image:
        image = getattr(settings, "HEP_DATA_LLM_DOCKER_IMAGE", "")

    image = str(image).strip()
    return image or None
