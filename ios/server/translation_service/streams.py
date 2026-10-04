"""Application-owned upstream work; HTTP subscribers never own model-task cancellation."""
import asyncio
from contextlib import suppress
import json

from starlette.concurrency import run_in_threadpool

from .billing import TokenUsage
from .ledger import ServiceError
from .provider import AmbiguousProviderFailure, DefiniteProviderFailure


def sse_event(data):
    return "data:" + json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n\n"


class TranslationStreamJob:
    QUEUE_SIZE = 64
    MAX_OUTPUT_LENGTH = 60000

    def __init__(self, ledger, model, owner, request_id, messages, *, max_tokens=None):
        self.ledger = ledger
        self.model = model
        self.owner = owner
        self.request_id = request_id
        self.messages = messages
        self.max_tokens = max_tokens
        self.queue = asyncio.Queue(maxsize=self.QUEUE_SIZE)
        # Use result values rather than Future exceptions: a disconnected requester may never await it.
        self.ready = asyncio.get_running_loop().create_future()
        self.subscribed = True
        self.detached = asyncio.Event()

    def detach(self):
        """Discard subscriber buffers, while leaving the independent upstream task running."""
        self.subscribed = False
        self.detached.set()
        while not self.queue.empty():
            self.queue.get_nowait()

    def publish(self, data):
        if not self.subscribed:
            return
        try:
            self.queue.put_nowait(data)
        except asyncio.QueueFull:
            # A slow/unconsumed HTTP stream must neither buffer indefinitely nor stall paid work.
            while not self.queue.empty():
                self.queue.get_nowait()
            self.queue.put_nowait({"error": "实时读取暂时跟不上，翻译继续在后台完成。请稍后使用原 requestID 恢复，无需再次扣点。", "status": 409, "retryAfter": 1})
            self.queue.put_nowait(None)
            self.subscribed = False
            self.detached.set()

    def first_result(self, error=None):
        if not self.ready.done():
            self.ready.set_result(error)

    def report_error(self, error):
        self.first_result(error)
        self.publish({"error": error.detail, "status": error.status, "retryAfter": error.retry_after})

    async def shutdown_unstarted(self):
        # Handles a task cancelled before Python ever enters run(), or before dispatch commits.
        state = await run_in_threadpool(self.ledger.request_status, self.owner, self.request_id)
        if state["status"] == "reserved":
            await run_in_threadpool(self.ledger.refund, self.owner, self.request_id)
        else:
            await run_in_threadpool(self.ledger.uncertain, self.owner, self.request_id)
        self.report_error(ServiceError(503, "服务正在重启，请使用原 requestID 查询状态后恢复。", 5))
        self.publish(None)

    async def run(self):
        upstream = None
        fragments = []
        total_length = 0
        usage = None
        try:
            await run_in_threadpool(self.ledger.dispatch, self.owner, self.request_id)
            upstream = self.model.stream(self.messages, max_tokens=self.max_tokens)
            async for fragment in upstream:
                if isinstance(fragment, TokenUsage):
                    if usage is not None and usage != fragment:
                        raise DefiniteProviderFailure(502, "模型用量记录不一致，本次点数已退回。")
                    usage = fragment
                    continue
                if usage is not None:
                    raise DefiniteProviderFailure(502, "模型在结算记录后仍返回文本，本次点数已退回。")
                if not isinstance(fragment, str):
                    raise DefiniteProviderFailure(502, "流式模型输出格式无效，本次点数已退回。")
                total_length += len(fragment)
                if total_length > self.MAX_OUTPUT_LENGTH:
                    raise DefiniteProviderFailure(502, "流式模型输出超过限制，本次点数已退回。")
                if fragment:
                    fragments.append(fragment)
                    self.publish({"delta": fragment})
                    self.first_result()
                    # Let the live subscriber consume real tokens, even if upstream I/O is already buffered.
                    await asyncio.sleep(0)
            text = "".join(fragments)
            if not text.strip() or usage is None:
                raise DefiniteProviderFailure(502, "流式模型没有返回完整文本，本次点数已退回。")
            # DeepSeek.stream only exits successfully after finish_reason=stop.
            await run_in_threadpool(self.ledger.complete, self.owner, self.request_id, {"text": text}, usage)
            self.publish({"done": True})
        except DefiniteProviderFailure as error:
            await run_in_threadpool(self.ledger.refund, self.owner, self.request_id)
            self.report_error(error)
        except AmbiguousProviderFailure as error:
            await run_in_threadpool(self.ledger.uncertain, self.owner, self.request_id)
            self.report_error(error)
        except asyncio.CancelledError:
            # This job belongs to the app. Only shutdown explicitly cancels it.
            await asyncio.shield(self.shutdown_unstarted())
        except Exception:
            await asyncio.shield(run_in_threadpool(self.ledger.uncertain, self.owner, self.request_id))
            self.report_error(ServiceError(503, "模型请求结果暂不确定，请保留原 requestID 联系支持核对。", 5))
        finally:
            if upstream is not None:
                with suppress(Exception):
                    await upstream.aclose()
            self.first_result(ServiceError(503, "模型服务暂不可用，请保留原 requestID。", 5))
            self.publish(None)

    async def events(self):
        try:
            while True:
                data = await self.queue.get()
                if data is None:
                    return
                yield sse_event(data)
        finally:
            self.detach()
