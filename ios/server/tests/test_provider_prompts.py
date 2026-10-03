import httpx
import pytest

from translation_service.models import TranslationRequest
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
        return httpx.Response(200, json={"choices": [{"message": {"content": "译文"}, "finish_reason": "stop"}]})
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
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, json={"choices": [{"message": {"content": '[{"source":"Alice","target":"爱丽丝"},{"source":"alice","target":"其他"}]'}, "finish_reason": "stop"}]}))) as client:
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
        with pytest.raises(StopAsyncIteration):
            await anext(generator)
        assert chunks.read_count == 3


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
