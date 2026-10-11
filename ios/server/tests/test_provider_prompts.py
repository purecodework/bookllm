import httpx
import pytest

from translation_service.models import TranslationRequest
from translation_service.billing import TokenUsage
from translation_service.prompts import translation_messages
from translation_service.provider import AmbiguousProviderFailure, DeepSeek, DefiniteProviderFailure
from test_api import body


def test_language_expert_and_editor_respect_preferences():
    payload = body()
    payload.update(stage="linguist", draft="Draft")
    request = TranslationRequest.model_validate(payload)
    prompt = translation_messages(request)[0]["content"]
    assert "language expert" in prompt
    assert "preserve that passage" in prompt
    assert "at most 1" in prompt and "cultural" in prompt
    assert "omit any explanation" in prompt
    payload["options"]["quality"] = "publication"
    payload["options"]["preferences"].update(foreignText="preserve", annotations="none")
    payload["stage"] = "editor"
    prompt = translation_messages(TranslationRequest.model_validate(payload))[0]["content"]
    assert "chief editor" in prompt
    assert "verbatim" in prompt
    assert "Do not add translator or editor notes" in prompt


@pytest.mark.asyncio
async def test_provider_sends_only_server_key_and_validates_stop(settings):
    def respond(request):
        assert request.headers["Authorization"] == "Bearer unit-test-not-a-real-secret"
        return httpx.Response(200, json={"choices": [{"message": {"content": "译文"}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30}})
    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
        assert await DeepSeek(settings, client).complete([]) == "译文"


@pytest.mark.asyncio
@pytest.mark.parametrize("reason", ["length", "content_filter", None])
async def test_truncated_or_filtered_output_is_not_success(settings, reason):
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, json={"choices": [{"message": {"content": "partial"}, "finish_reason": reason}]}))) as client:
        with pytest.raises(DefiniteProviderFailure):
            await DeepSeek(settings, client).complete([])


@pytest.mark.asyncio
async def test_connection_failure_and_read_timeout_have_different_refund_semantics(settings):
    for exception, expected in ((httpx.ConnectError("offline"), DefiniteProviderFailure), (httpx.ReadTimeout("timeout after dispatch"), AmbiguousProviderFailure)):
        def fail(request):
            raise exception
        async with httpx.AsyncClient(transport=httpx.MockTransport(fail)) as client:
            with pytest.raises(expected):
                await DeepSeek(settings, client).complete([])


@pytest.mark.asyncio
async def test_429_refundable_and_500_ambiguous(settings):
    for code, expected in ((429, DefiniteProviderFailure), (500, AmbiguousProviderFailure)):
        async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(code, headers={"Retry-After": "4"}))) as client:
            with pytest.raises(expected) as error:
                await DeepSeek(settings, client).complete([])
            assert error.value.retry_after == (4 if code == 429 else 5)


@pytest.mark.asyncio
async def test_invalid_glossary_never_returns_partial_terms(settings):
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, json={"choices": [{"message": {"content": '[{"source":"Alice","target":"爱丽丝"},{"source":"alice","target":"其他"}]'}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30}}))) as client:
        with pytest.raises(DefiniteProviderFailure):
            await DeepSeek(settings, client).terms([])


class TokenStream(httpx.AsyncByteStream):
    def __init__(self, frames):
        self.frames = frames
        self.read_count = 0

    async def __aiter__(self):
        for frame in self.frames:
            self.read_count += 1
            yield frame.encode()


@pytest.mark.asyncio
async def test_deepseek_real_stream_yields_before_final_frame(settings):
    frames = [
        'data: {"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"content":"世界"},"finish_reason":"stop"}]}\n\n',
        'data: {"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":10,"total_tokens":30}}\n\n',
        'data: [DONE]\n\n',
    ]
    chunks = TokenStream(frames)
    def response(request):
        assert b'"stream":true' in request.content
        return httpx.Response(200, stream=chunks)
    async with httpx.AsyncClient(transport=httpx.MockTransport(response)) as client:
        generator = DeepSeek(settings, client).stream([])
        assert await anext(generator) == "你好"
        assert chunks.read_count == 1  # No buffering/synthetic splitting of a completed output.
        assert await anext(generator) == "世界"
        assert chunks.read_count == 2
        assert await anext(generator) == TokenUsage(20, 10)
        with pytest.raises(StopAsyncIteration):
            await anext(generator)
        assert chunks.read_count == 4


@pytest.mark.asyncio
async def test_stream_without_stop_is_incomplete_and_refundable(settings):
    chunks = TokenStream(['data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}\n\n', 'data: [DONE]\n\n'])
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, stream=chunks))) as client:
        generator = DeepSeek(settings, client).stream([])
        assert await anext(generator) == "partial"
        with pytest.raises(DefiniteProviderFailure):
            await anext(generator)


def test_document_kind_and_layout_options():
    payload = body()
    payload["options"].update(documentKind="technical", layout="preserve")
    prompt = translation_messages(TranslationRequest.model_validate(payload))[0]["content"]
    assert "technical accuracy" in prompt and "Markdown code fences and tables" in prompt
    payload["options"]["layout"] = "reading"
    assert "tidy spacing" in translation_messages(TranslationRequest.model_validate(payload))[0]["content"]


@pytest.mark.parametrize("genre,required", [
    ("poetry", ("verse, stanza and line boundaries", "source imagery", "deliberate repetition", "without adding imagery")),
    ("script", ("speaker names", "scene and act markers", "stage directions", "Do not invent dialogue")),
    ("academic", ("citation and reference numbers", "quotations", "equations", "source precision", "objective academic register", "fabricate references")),
])
@pytest.mark.parametrize("stage", ["translate", "proofread", "linguist", "editor"])
def test_new_genres_preserve_source_structure_across_entire_pipeline(genre, required, stage):
    payload = body()
    payload.update(stage=stage, draft="" if stage == "translate" else "Reviewed draft")
    payload["options"].update(quality="publication", documentKind=genre, layout="reading")
    request = TranslationRequest.model_validate(payload)
    prompt = translation_messages(request)[0]["content"]
    for phrase in required:
        assert phrase in prompt
    assert "Genre-specific structural rules take precedence" in prompt
    assert "alter facts" in prompt
    # The source remains data, independent of genre and selected pipeline role.
    import json
    assert json.loads(translation_messages(request)[1]["content"])["source"] == payload["source"]


def test_unknown_genre_rejected_and_original_document_kinds_remain_valid():
    from pydantic import ValidationError
    for genre in ("fiction", "general", "technical", "poetry", "script", "academic"):
        payload = body()
        payload["options"]["documentKind"] = genre
        assert TranslationRequest.model_validate(payload).options.documentKind == genre
    payload["options"]["documentKind"] = "unsupported-genre"
    with pytest.raises(ValidationError, match="Unknown document kind"):
        TranslationRequest.model_validate(payload)


@pytest.mark.parametrize("style", [
    {"id": "xu-zhimo", "name": "徐志摩诗意", "subtitle": "轻盈", "instruction": "Express a lyrical poetic cadence with imagery from the source."},
    {"id": "xiangsheng", "name": "相声幽默", "subtitle": "机趣", "instruction": "Use lively conversational rhythm and comic timing already present in the source."},
    {"id": "water-margin", "name": "水浒说书", "subtitle": "说书", "instruction": "Use restrained storyteller cadence while preserving every source event."},
])
def test_new_style_instructions_remain_bounded_by_source_fidelity(style):
    payload = body()
    payload["options"].update(style=style, documentKind="poetry")
    prompt = translation_messages(TranslationRequest.model_validate(payload))[0]["content"]
    assert style["instruction"] in prompt
    assert "Do not add imagery, jokes, events or dialogue absent from the source" in prompt
    assert "source imagery and deliberate repetition" in prompt


def test_fiction_neighbors_are_continuity_references_without_importing_events():
    payload = body()
    payload["options"]["documentKind"] = "fiction"
    payload["context"] = "Opening tone: a quiet narrator. Previous source: a character arrives. Previous-stage neighbor: 他抵达了。"
    prompt = translation_messages(TranslationRequest.model_validate(payload))[0]["content"]
    for phrase in ("plot chronology and causality", "character aliases", "narrative perspective and tense", "distinct character dialogue", "deliberate ambiguity", "foreshadowing", "intentional register shifts", "continuity references only", "never import their events or text"):
        assert phrase in prompt


@pytest.mark.parametrize("stage", ["translate", "proofread", "linguist", "editor"])
def test_ocr_guidance_reaches_all_style_aware_stages(stage):
    payload = body()
    payload.update(stage=stage, draft="" if stage == "translate" else "Reviewed draft")
    payload["options"].update(sourceWasOCR=True, quality="publication")
    prompt = translation_messages(TranslationRequest.model_validate(payload))[0]["content"]
    assert "OCR source" in prompt
    assert "Never invent missing text" in prompt
    assert "uncertain name, number, equation or citation" in prompt
    assert "not speculative OCR repairs" in prompt
    assert payload["options"]["style"]["instruction"] in prompt
    payload["options"].pop("sourceWasOCR")
    assert "OCR source" not in translation_messages(TranslationRequest.model_validate(payload))[0]["content"]


@pytest.mark.parametrize("quality,stages", [
    ("fast", ["translate"]),
    ("refined", ["translate", "proofread"]),
    ("deep", ["translate", "proofread", "linguist"]),
    ("publication", ["translate", "proofread", "linguist", "editor"]),
    ("definitive", ["translate", "proofread", "linguist", "editor", "verify"]),
])
def test_strength_contract_enables_exact_pipeline_and_rejects_extra_passes(quality, stages):
    from pydantic import ValidationError
    from translation_service.models import Stage
    payload = body()
    payload["options"].update(quality=quality, sourceWasOCR=True)
    payload["options"]["preferences"]["extraLanguageReview"] = False
    for stage in Stage:
        payload.update(stage=stage.value, draft="" if stage == Stage.translate else "Complete draft")
        if stage.value not in stages:
            with pytest.raises(ValidationError, match="Stage is not enabled"):
                TranslationRequest.model_validate(payload)
        else:
            request = TranslationRequest.model_validate(payload)
            assert [s.value for s in request.options.allowed_stages()] == stages
            prompt = translation_messages(request)[0]["content"]
            assert "OCR source" in prompt
            assert request.options.style.instruction in prompt
            if stage == Stage.verify:
                assert "Correct only demonstrable problems" in prompt
                assert "including unchanged text" in prompt
                assert "first-occurrence" in prompt
