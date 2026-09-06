from typing import Annotated, Literal
from pydantic import BaseModel, ConfigDict, Field, field_validator
from pathlib import PurePosixPath

Slug = Annotated[str, Field(pattern=r'^[a-z][a-z0-9-]{0,31}$')]
Commit = Annotated[str, Field(pattern=r'^[0-9a-f]{40}$')]
Repo = Annotated[str, Field(pattern=r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$', max_length=150)]


class Model(BaseModel):
    model_config = ConfigDict(extra='forbid')


class CaseInput(Model):
    id: Slug
    day: int = Field(ge=1, le=7)
    title: str = Field(min_length=1, max_length=200)
    prompt: str = Field(min_length=1, max_length=20_000)
    source_repo: Repo
    base_commit: Commit
    project: str = Field(min_length=1, max_length=300)
    scheme: str = Field(pattern=r'^[A-Za-z0-9][A-Za-z0-9 ._-]{0,99}$')
    runtime_version: str = Field(pattern=r'^\d{1,2}\.\d{1,2}(\.\d{1,2})?$')
    is_open: bool = False

    @field_validator('project')
    @classmethod
    def safe_project(cls, value):
        if (PurePosixPath(value).is_absolute() or '..' in value.split('/')
                or '\\' in value or not value.endswith('.xcodeproj')
                or any(ord(c) < 32 for c in value)):
            raise ValueError('Expected a relative .xcodeproj path')
        return value


class SubmissionInput(Model):
    case_id: Slug
    answer: str = Field(min_length=1, max_length=20_000)

    @field_validator('answer')
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError('Answer must not be blank')
        return value  # Preserve the participant's exact text.


class LeaseInput(Model):
    lease_token: str = Field(min_length=20, max_length=200)


class CompletionInput(LeaseInput):
    outcome: Literal['succeeded', 'failed']
    source_commit: Commit | None = None
    summary: str = Field(min_length=1, max_length=10_000)


class CaseAvailability(Model):
    is_open: bool
