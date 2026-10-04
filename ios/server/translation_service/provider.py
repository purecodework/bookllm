import json
import re
import httpx
from pydantic import TypeAdapter, ValidationError

from .billing import TokenUsage, UsageText, UsageTerms
from .config import Settings
from .ledger import ServiceError
from .models import Term


class DefiniteProviderFailure(ServiceError):
    """A definitive failure: no usable result delivered, release the user's reservation."""


class AmbiguousProviderFailure(ServiceError):
    """The upstream may have accepted or processed the request; never retry it blindly."""


class DeepSeek:
    def __init__(self, settings: Settings, client: httpx.AsyncClient):
        self.settings = settings
        self.client = client

    async def complete(self, messages, *, max_tokens=None):
        try:
            response = await self.client.post(
                self.settings.deepseek_base_url.rstrip("/") + "/chat/completions",
                headers={"Authorization": f"Bearer {self.settings.deepseek_api_key}"},
                json={"model": self.settings.deepseek_model, "messages": messages, "temperature": 0.25, "max_tokens": max_tokens or self.settings.max_output_tokens, "stream": False},
                timeout=httpx.Timeout(self.settings.request_timeout_seconds, connect=10, pool=10),
            )
        except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout):
            raise DefiniteProviderFailure(503, "模型服务尚未连接，本次点数已退回。", 3) from None
        except httpx.RequestError:
            raise AmbiguousProviderFailure(503, "模型请求结果暂不确定，点数保留待核对。请使用原 requestID 查询状态或联系支持，勿更换 ID 重复提交。", 5) from None
        if response.status_code == 429:
            try:
                retry = max(1, min(60, int(response.headers.get("Retry-After", "3"))))
            except ValueError:
                retry = 3
            raise DefiniteProviderFailure(429, "模型服务请求较多，本次点数已退回。", retry)
        if response.status_code in (408, 500, 502, 503, 504) or response.status_code >= 500:
            raise AmbiguousProviderFailure(503, "模型服务返回了不确定的处理结果；本次请求待核对。请保留原 requestID。", 5)
        if not 200 <= response.status_code < 300:
            # Do not expose upstream keys, request bodies or diagnostic text.
            raise DefiniteProviderFailure(502, "模型服务拒绝请求，本次点数已退回。请稍后重试或联系支持。")
        try:
            data = response.json()
            choice = data["choices"][0]
            text = choice["message"]["content"]
            if choice.get("finish_reason") != "stop" or not isinstance(text, str) or not text.strip():
                raise ValueError("Incomplete output")
            if len(text) > 60000:
                raise ValueError("Output exceeds limit")
            usage = TokenUsage.from_provider(data.get("usage"))
            return UsageText(text, usage)
        except (ValueError, KeyError, IndexError, TypeError):
            raise DefiniteProviderFailure(502, "模型输出未完整结束、格式或用量记录无效，本次点数已退回。请重试。") from None

    async def terms(self, messages, *, max_tokens=None):
        raw = await self.complete(messages, max_tokens=max_tokens)
        match = re.fullmatch(r"\s*```(?:json)?\s*([\s\S]*?)\s*```\s*", raw)
        cleaned = match.group(1) if match else raw.strip()
        try:
            data = json.loads(cleaned)
            if not isinstance(data, list) or len(data) > 60:
                raise ValueError("Too many terms")
            terms = TypeAdapter(list[Term]).validate_python(data)
            if len({term.source.casefold() for term in terms}) != len(terms):
                raise ValueError("Duplicate glossary term")
            return UsageTerms([term.model_dump() for term in terms], raw.usage)
        except (ValueError, TypeError, ValidationError):
            raise DefiniteProviderFailure(502, "术语提取格式无效，本次点数已退回。请重试。") from None

    async def stream(self, messages, *, max_tokens=None):
        """Pass through actual DeepSeek delta events; never synthesize a token stream."""
        total_length = 0
        nonblank = False
        stopped = False
        usage = None
        try:
            async with self.client.stream(
                "POST", self.settings.deepseek_base_url.rstrip("/") + "/chat/completions",
                headers={"Authorization": f"Bearer {self.settings.deepseek_api_key}"},
                json={"model": self.settings.deepseek_model, "messages": messages, "temperature": 0.25, "max_tokens": max_tokens or self.settings.max_output_tokens, "stream": True, "stream_options": {"include_usage": True}},
                timeout=httpx.Timeout(self.settings.request_timeout_seconds, connect=10, pool=10),
            ) as response:
                if response.status_code == 429:
                    try:
                        retry = max(1, min(60, int(response.headers.get("Retry-After", "3"))))
                    except ValueError:
                        retry = 3
                    raise DefiniteProviderFailure(429, "模型服务请求较多，本次点数已退回。", retry)
                if response.status_code == 408 or response.status_code >= 500:
                    raise AmbiguousProviderFailure(503, "流式模型请求结果待核对，请保留原 requestID。", 5)
                if not 200 <= response.status_code < 300:
                    raise DefiniteProviderFailure(502, "模型服务拒绝请求，本次点数已退回。")
                async for line in response.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    raw = line[5:].strip()
                    if raw == "[DONE]":
                        if not stopped or not nonblank or usage is None:
                            raise DefiniteProviderFailure(502, "流式模型输出或用量记录未完整结束，本次点数已退回。")
                        yield usage
                        return
                    if not raw:
                        continue
                    try:
                        chunk = json.loads(raw)
                        if "error" in chunk:
                            raise ValueError("Provider reported an error")
                        if chunk.get("usage") is not None:
                            incoming_usage = TokenUsage.from_provider(chunk["usage"])
                            if usage is not None and usage != incoming_usage:
                                raise ValueError("Inconsistent stream usage")
                            usage = incoming_usage
                        choices = chunk.get("choices", [])
                        if not choices:
                            continue
                        choice = choices[0]
                        was_stopped = stopped
                        reason = choice.get("finish_reason")
                        if reason is not None:
                            if reason != "stop":
                                raise ValueError("Incomplete finish reason")
                            stopped = True
                        delta = choice.get("delta", {}).get("content")
                        if delta is not None:
                            if not isinstance(delta, str) or was_stopped and delta:
                                raise ValueError("Malformed stream delta")
                            total_length += len(delta)
                            if total_length > 60000:
                                raise ValueError("Output exceeds limit")
                            if delta:
                                nonblank |= bool(delta.strip())
                                yield delta
                    except (ValueError, KeyError, IndexError, TypeError):
                        raise DefiniteProviderFailure(502, "流式模型输出无效或不完整，本次点数已退回。请减小分块后重试。") from None
                if not stopped or not nonblank or usage is None:
                    raise DefiniteProviderFailure(502, "流式模型输出或用量记录提前结束，本次点数已退回。")
                yield usage
        except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout):
            raise DefiniteProviderFailure(503, "模型服务尚未连接，本次点数已退回。", 3) from None
        except httpx.RequestError:
            raise AmbiguousProviderFailure(503, "流式模型请求已发出但结果不确定，点数保留待核对。请保留原 requestID。", 5) from None
