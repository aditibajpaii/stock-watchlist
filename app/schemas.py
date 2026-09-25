"""Request and response models for the API.

Validation here gives early, readable 422 errors. It is NOT the data
guarantee: every rule that matters is also enforced by PostgreSQL
(CHECK / UNIQUE / FK constraints, ingest_tick), which protects the data no
matter which client writes it.

Money: NUMERIC columns are Decimal end to end (never float). In JSON,
Decimal values are sent as strings in plain fixed-point form, e.g.
"3000.00000000" or "0.00000001" (never "1E-8"), so no digits are lost;
requests may send numbers or strings.
Time: TIMESTAMPTZ columns are timezone-aware datetimes, ISO 8601 in JSON.
"""

from decimal import Decimal
from typing import Annotated, Literal

from pydantic import (AwareDatetime, BaseModel, ConfigDict, Field, PlainSerializer,
                      StringConstraints, model_validator)

Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=50)]
Code = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=20)]
PositiveId = Annotated[int, Field(gt=0, le=2**63 - 1)]
# NUMERIC -> JSON string in plain fixed-point form ("0.00000001", never "1E-8"),
# keeping every digit PostgreSQL stored
Numeric = Annotated[Decimal, PlainSerializer(lambda d: format(d, "f"), return_type=str,
                                             when_used="json")]


class Strict(BaseModel):
    """Request bodies reject unknown fields (e.g. 'threshold' in a PATCH)."""
    model_config = ConfigDict(extra="forbid")


# ---------------------------------------------------------------------
# responses
# ---------------------------------------------------------------------
class Health(BaseModel):
    status: str
    database: str


class User(BaseModel):
    user_id: int
    username: str
    email: str
    created_at: AwareDatetime


class Instrument(BaseModel):
    instrument_id: int
    exchange: str
    symbol: str
    name: str
    quote_currency: str
    is_active: bool


class Tick(BaseModel):
    tick_id: int
    instrument_id: int
    observed_at: AwareDatetime
    price: Numeric
    volume: Numeric | None
    source: str
    source_event_id: str


class WatchlistItem(BaseModel):
    instrument_id: int
    exchange: str
    symbol: str
    name: str
    added_at: AwareDatetime
    latest_price: Numeric | None          # None = no ticks yet
    latest_observed_at: AwareDatetime | None


class Watchlist(BaseModel):
    watchlist_id: int
    user_id: int
    name: str
    created_at: AwareDatetime
    items: list[WatchlistItem] = []


class AlertRule(BaseModel):
    rule_id: int
    user_id: int
    instrument_id: int
    exchange: str
    symbol: str
    direction: str
    threshold: Numeric
    cooldown_seconds: int
    is_active: bool
    created_at: AwareDatetime


class AlertEvent(BaseModel):
    event_id: int
    rule_id: int
    instrument_id: int
    exchange: str
    symbol: str
    direction: str
    threshold: Numeric
    tick_id: int
    price: Numeric
    observed_at: AwareDatetime
    fired_at: AwareDatetime


class IngestResult(BaseModel):
    status: Literal["INSERTED", "DUPLICATE"]
    tick_id: int | None


# ---------------------------------------------------------------------
# requests
# ---------------------------------------------------------------------
class WatchlistCreate(Strict):
    name: Name


class WatchlistItemCreate(Strict):
    instrument_id: PositiveId


class AlertRuleCreate(Strict):
    instrument_id: PositiveId
    direction: Literal["ABOVE", "BELOW"]
    threshold: Annotated[Decimal, Field(gt=0, allow_inf_nan=False)]
    cooldown_seconds: Annotated[int, Field(ge=0)] = 300


class AlertRulePatch(Strict):
    """Only the MUTABLE settings of a rule. The rule definition (user,
    instrument, direction, threshold) cannot be changed: any other field
    is rejected (extra='forbid')."""
    is_active: bool | None = None
    cooldown_seconds: Annotated[int, Field(ge=0)] | None = None

    @model_validator(mode="after")
    def something_to_change(self):
        if self.is_active is None and self.cooldown_seconds is None:
            raise ValueError("provide is_active and/or cooldown_seconds")
        return self


class TickIngest(Strict):
    exchange: Code
    symbol: Code
    observed_at: AwareDatetime
    price: Annotated[Decimal, Field(gt=0, allow_inf_nan=False)]
    volume: Annotated[Decimal, Field(ge=0, allow_inf_nan=False)] | None = None
    source_event_id: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1,
                                                      max_length=200)]
