from enum import StrEnum
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=False)


class Quality(StrEnum):
    fast = "fast"
    refined = "refined"
    deep = "deep"
    publication = "publication"
    definitive = "definitive"


class Stage(StrEnum):
    translate = "translate"
    proofread = "proofread"
    linguist = "linguist"
    editor = "editor"
    verify = "verify"


class TermCategory(StrEnum):
    person = "person"
    place = "place"
    organization = "organization"
    title = "title"
    specialist = "specialist"
    name = "name"


class Term(StrictModel):
    source: str = Field(min_length=1, max_length=200)
    target: str = Field(min_length=1, max_length=400)
    category: TermCategory | None = None
    entityID: str | None = Field(default=None, max_length=240, pattern=r"^[^\x00-\x1f]+$")
    aliases: list[str] | None = Field(default=None, max_length=8)
    evidence: str | None = Field(default=None, min_length=1, max_length=300)
    ambiguous: bool | None = None
    firstChunk: int | None = Field(default=None, ge=0)

    @field_validator("aliases")
    @classmethod
    def alias_lengths(cls, values):
        if values is not None and any(not value.strip() or len(value) > 200 for value in values):
            raise ValueError("Invalid alias spelling")
        return values

    @model_validator(mode="after")
    def ambiguity_scope(self):
        if self.ambiguous and not self.evidence:
            raise ValueError("Ambiguous terms require an evidence scope")
        return self

    def relevant_to(self, source):
        if self.category is None and self.ambiguous is None and self.entityID is None and self.aliases is None:
            return self.source.casefold() in source.casefold()
        import re
        pattern = re.escape(self.source)
        if self.category == TermCategory.specialist and re.fullmatch(r"[A-Za-z][A-Za-z0-9 _’'-]*[A-Za-z]", self.source):
            variants = [pattern + r"(?:s|es|['’]s)?"]
            if self.source.endswith("y"):
                variants.append(re.escape(self.source[:-1]) + "ies")
            pattern = "(?:" + "|".join(variants) + ")"
        if re.search(r"[A-Za-z]", self.source):
            pattern = r"(?<!\w)" + pattern + r"(?!\w)"
        return bool(re.search(pattern, source, re.I)) and (not self.ambiguous or self.evidence in source)


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
    pipelineVersion: int | None = Field(default=None, ge=2, le=2)
    targetLanguage: str = Field(min_length=1, max_length=80)
    sourceWasOCR: bool | None = None
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
        if self.quality == Quality.deep:
            return [Stage.translate, Stage.proofread, Stage.linguist]
        if self.quality == Quality.publication:
            return [Stage.translate, Stage.proofread, Stage.linguist, Stage.editor]
        return [Stage.translate, Stage.proofread, Stage.linguist, Stage.editor] if self.pipelineVersion == 2 else list(Stage)


class ReviewFinding(StrictModel):
    paragraphID: str = Field(pattern=r"^p[1-9][0-9]*$", max_length=16)
    kind: str = Field(pattern=r"^(omission|mistranslation|fact|term|language|voice|annotation|structure)$")
    severity: str = Field(pattern=r"^(critical|major|minor)$")
    sourceQuote: str = Field(min_length=1, max_length=600)
    explanation: str = Field(min_length=1, max_length=600)
    suggestedTranslation: str = Field(max_length=1200)


class ReviewReport(StrictModel):
    findings: list[ReviewFinding] = Field(max_length=6)


class ReviewerFeedback(StrictModel):
    role: Stage
    report: ReviewReport


def source_units(source):
    import re
    parts = [p.strip() for p in re.split(r"\n[ \t]*\n+", source.replace("\r\n", "\n")) if p.strip()]
    return [{"id": f"p{i + 1}", "text": text} for i, text in enumerate(parts)]


class TranslationRequest(StrictModel):
    requestID: str = Field(min_length=1, max_length=160, pattern=r"^[A-Za-z0-9:._-]+$")
    source: str = Field(min_length=1, max_length=12000)
    context: str = Field(default="", max_length=4000)
    draft: str = Field(default="", max_length=40000)
    reviewNotes: str | None = Field(default=None, max_length=2000)
    reviewMode: bool | None = None
    reviews: list[ReviewerFeedback] | None = Field(default=None, min_length=2, max_length=2)
    chapterContext: str | None = Field(default=None, max_length=32000)
    chunkIndex: int | None = Field(default=None, ge=0)
    glossaryCapture: bool | None = None
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
        if self.glossaryCapture and (self.stage != Stage.translate or self.options.pipelineVersion != 2 or "<bookllm-glossary-v1>" in self.source or "</bookllm-glossary-v1>" in self.source):
            raise ValueError("Private glossary capture is restricted to new initial translations without literal markers")
        modern_editor = self.options.pipelineVersion == 2 and self.options.quality in (Quality.publication, Quality.definitive)
        if self.reviewMode and not (modern_editor and self.stage in (Stage.proofread, Stage.linguist)):
            raise ValueError("Report mode requires a modern collaborative review stage")
        if self.reviews is not None:
            if not modern_editor or self.stage != Stage.editor or {r.role for r in self.reviews} != {Stage.proofread, Stage.linguist}:
                raise ValueError("Chief editor requires exactly one report from each reviewer")
            units = {u["id"]: u["text"] for u in source_units(self.source)}
            for feedback in self.reviews:
                for finding in feedback.report.findings:
                    if finding.paragraphID not in units or finding.sourceQuote not in units[finding.paragraphID]:
                        raise ValueError("Review finding must quote its actual source paragraph")
        if modern_editor and self.stage == Stage.editor and self.reviews is None:
            raise ValueError("Collaborative chief editor requires reviewer feedback")
        if self.chapterContext is not None and not modern_editor:
            raise ValueError("Chapter editorial context requires the collaborative pipeline")
        return self


class GlossaryRequest(StrictModel):
    requestID: str = Field(min_length=1, max_length=160, pattern=r"^[A-Za-z0-9:._-]+$")
    source: str = Field(min_length=1, max_length=12000)
    target: str = Field(min_length=1, max_length=80)
    mode: str | None = Field(default=None, pattern=r"^entities-v1$")
    candidates: list[str] | None = Field(default=None, min_length=1, max_length=24)
    known: list[Term] | None = Field(default=None, max_length=16)

    @model_validator(mode="after")
    def compact_query(self):
        if (self.candidates is not None or self.known is not None) and self.mode != "entities-v1":
            raise ValueError("Entity context requires entities-v1")
        if self.candidates is not None:
            if any(not name.strip() or len(name) > 100 or name.casefold() not in self.source.casefold() for name in self.candidates):
                raise ValueError("Candidates must occur in the supplied compact context")
            if len({name.casefold() for name in self.candidates}) != len(self.candidates):
                raise ValueError("Duplicate candidate")
        return self


class SessionRequest(StrictModel):
    identityToken: str = Field(min_length=32, max_length=16384)
    nonce: str = Field(min_length=16, max_length=256)


class PurchaseRequest(StrictModel):
    signedTransaction: str = Field(min_length=32, max_length=32768)


class NotificationRequest(StrictModel):
    signedPayload: str = Field(min_length=32, max_length=65536)
