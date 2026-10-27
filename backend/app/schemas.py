import uuid
from datetime import UTC, date, datetime
from typing import Annotated

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    StringConstraints,
    field_serializer,
    model_validator,
)

NonEmptyStr = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1)]


def _require_tz(value: datetime) -> datetime:
    if value.tzinfo is None:
        raise ValueError("datetime must include a time-zone offset")
    return value.astimezone(UTC)


AwareDatetime = Annotated[datetime, AfterValidator(_require_tz)]


class UserRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    name: str


class ParticipantCreate(BaseModel):
    name: Annotated[NonEmptyStr, StringConstraints(max_length=100)]
    email: Annotated[EmailStr, StringConstraints(max_length=255)]


class ParticipantRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    email: str


class MeetingCreate(BaseModel):
    title: Annotated[NonEmptyStr, StringConstraints(max_length=200)]
    description: str = ""
    starts_at: AwareDatetime
    ends_at: AwareDatetime
    place: Annotated[NonEmptyStr, StringConstraints(max_length=200)]
    participant_ids: list[uuid.UUID] = []

    @model_validator(mode="after")
    def check_times(self) -> MeetingCreate:
        if self.ends_at <= self.starts_at:
            raise ValueError("ends_at must be after starts_at")
        # de-duplicate while keeping order
        self.participant_ids = list(dict.fromkeys(self.participant_ids))
        return self


class AgendaItem(BaseModel):
    topic: Annotated[NonEmptyStr, StringConstraints(max_length=300)]
    owner: Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)] | None = None
    minutes: int | None = Field(default=None, ge=1, le=480)


class ActionItem(BaseModel):
    task: Annotated[NonEmptyStr, StringConstraints(max_length=300)]
    owner: Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)] | None = None
    due: date | None = None


class Agenda(BaseModel):
    items: list[AgendaItem] = Field(default=[], max_length=50)
    action_items: list[ActionItem] = Field(default=[], max_length=50)


class AiSuggestion(BaseModel):
    """What the agenda parser returned, kept as it was: it is compared, never trusted."""

    agenda: dict
    model: Annotated[str, StringConstraints(max_length=100)]
    prompt_version: Annotated[str, StringConstraints(max_length=50)]


class AgendaSave(Agenda):
    ai_suggestion: AiSuggestion | None = None


class MeetingRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    title: str
    description: str
    starts_at: datetime
    ends_at: datetime
    place: str
    participants: list[ParticipantRead]
    agenda: Agenda | None = None
    created_at: datetime

    @field_serializer("starts_at", "ends_at", "created_at")
    def to_utc(self, value: datetime) -> str:
        return value.astimezone(UTC).isoformat().replace("+00:00", "Z")
