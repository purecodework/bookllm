from enum import StrEnum
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=False)


class Quality(StrEnum):
    fast = "fast"
    refined = "refined"
    publication = "publication"


class Stage(StrEnum):
    translate = "translate"
    proofread = "proofread"
    linguist = "linguist"
    editor = "editor"


class Term(StrictModel):
    source: str = Field(min_length=1, max_length=200)
    target: str = Field(min_length=1, max_length=400)


class Style(StrictModel):
    id: str = Field(min_length=1, max_length=128)
    name: str = Field(min_length=1, max_length=128)
    subtitle: str = Field(max_length=256)
    instruction: str = Field(min_length=1, max_length=4000)


class Preferences(StrictModel):
    foreignText: str = "bilingual"
    annotations: str = "none"
    sparseNotes: bool = True
    extraLanguageReview: bool = False

    @field_validator("foreignText")
    @classmethod
    def foreign_policy(cls, value):
        if value not in ("translate", "bilingual", "preserve"):
            raise ValueError("Unknown foreign text policy")
        return value

    @field_validator("annotations")
    @classmethod
    def annotation_policy(cls, value):
        if value not in ("none", "terms", "cultural"):
            raise ValueError("Unknown annotation policy")
        return value


class Options(StrictModel):
    targetLanguage: str = Field(min_length=1, max_length=80)
    sourceLanguage: str | None = Field(default=None, min_length=2, max_length=32, pattern=r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")
    quality: Quality
    documentKind: str = "fiction"
    layout: str = "preserve"
    style: Style
    glossary: list[Term] = Field(default_factory=list, max_length=1000)
    preferences: Preferences = Field(default_factory=Preferences)

    @field_validator("documentKind")
    @classmethod
    def document_kind(cls, value):
        if value not in ("fiction", "general", "technical", "poetry", "script", "academic"):
            raise ValueError("Unknown document kind")
        return value

    @field_validator("layout")
    @classmethod
    def layout_policy(cls, value):
        if value not in ("preserve", "reading"):
            raise ValueError("Unknown layout policy")
        return value

    def allowed_stages(self):
        if self.quality == Quality.fast:
            return [Stage.translate]
        if self.quality == Quality.refined:
            return [Stage.translate, Stage.proofread] + ([Stage.linguist] if self.preferences.extraLanguageReview else [])
        return list(Stage)


class TranslationRequest(StrictModel):
    requestID: str = Field(min_length=1, max_length=160, pattern=r"^[A-Za-z0-9:._-]+$")
    source: str = Field(min_length=1, max_length=12000)
    context: str = Field(default="", max_length=4000)
    draft: str = Field(default="", max_length=40000)
    reviewNotes: str | None = Field(default=None, max_length=2000)
    stage: Stage
    options: Options

    @model_validator(mode="after")
    def validate_stage(self):
        if self.stage not in self.options.allowed_stages():
            raise ValueError("Stage is not enabled by this quality and preference selection")
        if self.stage != Stage.translate and not self.draft.strip():
            raise ValueError("Review stages require a translated draft")
        if not self.source.strip():
            raise ValueError("Source text cannot be blank")
        return self


class GlossaryRequest(StrictModel):
    requestID: str = Field(min_length=1, max_length=160, pattern=r"^[A-Za-z0-9:._-]+$")
    source: str = Field(min_length=1, max_length=12000)
    target: str = Field(min_length=1, max_length=80)


class SessionRequest(StrictModel):
    identityToken: str = Field(min_length=32, max_length=16384)
    nonce: str = Field(min_length=16, max_length=256)


class PurchaseRequest(StrictModel):
    signedTransaction: str = Field(min_length=32, max_length=32768)


class NotificationRequest(StrictModel):
    signedPayload: str = Field(min_length=32, max_length=65536)
