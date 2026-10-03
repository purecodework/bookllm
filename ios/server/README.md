# BookLLM iOS 云端

FastAPI 云端负责 Apple 登录、点数购买兑换、默认 DeepSeek 翻译、真实流式翻译和术语提取。自带 API 模式仍由 iOS 使用用户 Key 直接连接供应商；该 Key 不会发送给此服务。

## 运行

需要 Python 3.12+。此目录与 iOS 客户端接口配套。

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
```

填写 `.env` 中的必填配置。`SESSION_SECRET` 用密码学安全方式生成至少 32 字节随机值，例如 `python -c 'import secrets; print(secrets.token_hex(32))'`。将 App Store Connect 中的数值 App ID 放入 `APPLE_APP_ID`，Bundle ID 与签名的 iOS Target 保持一致。

从 [Apple PKI](https://www.apple.com/certificateauthority/) 获取 Apple 根证书的 DER 文件，通过 `APPLE_ROOT_CERTIFICATES` 配置受信文件路径。应用官方 `app-store-server-library`，启用线上证书撤销检查。生产服务只接受 `Production` 交易；沙盒使用另一服务和另一数据库。不会接受 Xcode / LocalTesting / 无签名收据。没有开发登录、测试兑换接口或绕过校验的环境开关。

将 `.env` 配置载入进程环境后启动：

```bash
uvicorn main:app --host 127.0.0.1 --port 8080 --workers 2
```

`main.py` 不自动读取 `.env`；通过进程管理器注入环境，或安装 `python-dotenv` 后使用 `uvicorn main:app --env-file .env`。缺少 Key、签名秘密或根证书时停止启动。配置 HTTPS 反向代理，原生 `CloudBaseURL` 填 `https://your-domain.example/v1`。

## 接口与账单

| 接口 | 请求 / 返回 |
| --- | --- |
| `POST /v1/session` | `{identityToken, nonce}`，其中 nonce 为原始随机串；返回 `{accountID, points, ownAPIUnlocked, creditDebt, token}` |
| `GET /v1/account` | Bearer 会话，返回账户余额和解锁状态 |
| `POST /v1/purchases` | `{signedTransaction}`；验证后原子兑换并返回账户 |
| `POST /v1/translate` | 原生 `TranslationRequest` 驼峰字段；返回 `{text}` |
| `POST /v1/translate/stream` | 同样请求，仅 fast / translate；真实 DeepSeek SSE 返回增量 |
| `POST /v1/glossary` | `{requestID, source, target}`；返回 `[{source,target}]` |
| `GET /v1/requests/{requestID}` | 账户自己的请求状态；完成状态含 `result` |
| `POST /v1/app-store/notifications` | Apple V2 `{signedPayload}`；验证外层和内层签名后处理退款、撤销与退款撤回 |
| `GET /health` | 不含秘密的运行状态 |

登录验证 Apple RS256 签名、发行方、Bundle ID、有效期、最近 10 分钟内的签发时间，以及 `SHA256(raw nonce)`。同一身份凭据或 nonce 不能重复创建会话。`accountID` 是从 Apple subject 与 Bundle ID 派生的稳定 UUID，也就是 StoreKit `appAccountToken`。所有私人接口校验有有效期的 HS256 会话。

商品固定匹配 iOS：`app.bookllm.credits.100`、`app.bookllm.credits.1000` 为 Consumable；`app.bookllm.byok.lifetime` 为 Non-Consumable。交易必须包含匹配当前账户的 appAccountToken、正确商品类型和数量 1。相同交易只能入账一次，不能跨账户兑换。自带 API 可在未登录时通过客户端本地 StoreKit 验证解锁；无账户 token 的购买不能给任意云端账户发点。

每次实际执行的翻译、校对、语言专家、主编阶段，以及术语提取，分别消耗 `ceil(源文本 Unicode scalar 数 / 1000)` 点，包含空白。上下文、草稿、输出长度不重复收费。例如 2,500 个字符：快速档 3 点；精译档 6 点；启用额外语言专家的精译档 9 点；出版档 12 点，术语提取另计。单次源文上限 12,000，客户端负责分块；词表最多 1,000 项，整体 HTTP 请求上限 256 KiB。

质量和偏好校验与原生模型一致：fast 为译者；refined 为译者和校对，可增加语言专家；publication 为四阶段。所有阶段都应用自定义风格、强制术语、夹杂外语的保留 / 双语 / 翻译偏好，以及不加说明 / 词语解释 / 文化解释。语言专家检查外语、习语、语体和注释真实性；主编统一文风并保留事实。注释标识为 `[编者注：…]`，按 sparseNotes 限制每块最多 1 或 3 条，要求省略不确定解释。`documentKind` 支持 fiction / general / technical / poetry / script / academic，分别对应小说、通用文本、技术文档、诗歌、剧本和学术文本。小说规则保留时间顺序、因果、角色别名、叙述视角与时态、角色对白差异、刻意含糊、伏笔和语体转变；开篇语气与邻段原文/前阶段译稿只用于连续性参照，禁止把邻段事件或文字移入当前原文。iOS 可自动识别候选类型并允许用户修改，云端按最终选择应用规则。诗歌保留诗行、节与意象及有意重复；剧本保留人物名、场幕标记和舞台指示；学术文本保留引用编号、引文、公式与客观精确的语体。`layout` 支持 preserve / reading（默认 fiction / preserve），文体结构规则始终优先于间距整理和风格。徐志摩诗意、相声幽默、水浒说书等原生风格以 style.instruction 传入；只调整原文表达，不编造意象、笑话、事件或台词。

## 流式协议

首个输出来自实际上游 SSE 增量，而非完成文本的模拟拆分。只有 upstream `finish_reason=stop` 和非空完整输出才能提交账本并发送 `done`。上游工作由应用持有的独立任务执行；客户端暂停、切到后台或断开仅停止推送，后台任务继续完成并缓存原 requestID 的完整结果。恢复时，仍在处理的请求返回 409 + Retry-After: 1，完成后同 ID 回放，不再扣点。订阅者队列最多 64 条增量，断开立即丢弃队列；读取过慢超过队列上限时发送可恢复的 409 错误并停止推送，后台继续完成，避免无限缓存或阻塞上游。进程关闭时默认等待 STREAM_SHUTDOWN_GRACE_SECONDS=10 秒收尾，仅仍未完成的任务被取消并保留 uncertain 待核对。未发出的预留请求在关闭时退点。真正的上游超时或网络中断仍按不确定失败处理，半段文字不会记为完成。

```text
data:{"delta":"你好"}

data:{"delta":"，世界。"}

data:{"done":true}

```

首个增量前的错误使用 HTTP 状态；已经开始流式响应后的错误使用 `data:{"error":"说明","status":503,"retryAfter":5}`，随后结束，且不会发送 done。客户端必须检测 error 和缺少 done 的异常结束。已完成请求的幂等重放可一次发送缓存全文 delta + done，且不会再次调用上游或扣点。反向代理必须关闭 SSE 缓冲，例如 Nginx `proxy_buffering off`；服务发送 `X-Accel-Buffering: no`。

## 幂等、并发与失败

SQLite `BEGIN IMMEDIATE` 事务保证购买、扣点、退款、状态变更和账本事件原子性；WAL + FULL 同步用于持久化。每个账户的 requestID 与请求内容哈希绑定；重复已完成请求返回缓存，重复进行中请求返回 409 + Retry-After: 1，同一个 ID 改变内容也返回 409。流式客户端的暂停或断开不会取消独立上游任务，恢复可等待原任务完成；实际上游结果不确定的请求则需要人工核对，其重复请求返回 409 且没有 Retry-After，以区别仍在后台运行的任务。

执行前先保留点数，再记录 dispatched，随后请求上游。连接未建立、429、明确拒绝、错误输出格式或被截断输出会退点，且原 requestID 可重试。Read/Write 超时、连接在发送后中断、上游 5xx 或进程在 dispatch 后崩溃可能已产生上游成本，因此保留点数并标记 uncertain / dispatched，禁止自动重复提交。同 ID 重试不会重复扣点。用户可查询状态，运营需核对上游后恢复结果或退款。客户端不应在此情况自动更换 requestID。

并发限制通过数据库记录跨 worker 生效，默认每账户 4、全局 32。超过限制返回 429 + Retry-After，不保留点数。uncertain 不占用并发槽，但其费用仍保留。

将 App Store Connect 的 V2 Server Notifications URL 指向 `/v1/app-store/notifications`，分别配置生产和沙盒。退款通知可先于兑换到达并留下撤销记录，防止旧 JWS 兑换。已消费的退款点数形成 creditDebt，余额不会成为负数；后续充值先补差额。通知按签名时间排序，重放不重复撤销；REFUND_REVERSED 恢复一次。此机制依赖 Apple 通知送达；部署方应监控通知失败并使用 Apple Notification History 补发遗漏通知。CONSUMPTION_REQUEST 等不改变账本；若要提交退款消费信息，需另接 App Store Server API。

## 核对与验证

```bash
python -m pip install -r requirements-dev.txt
python -m pytest -q
python -m translation_service.manage --database ./data/bookllm.sqlite3 audit
python -m translation_service.manage --database ./data/bookllm.sqlite3 pending
```

`audit` 比较余额、欠额和事件流水；`pending` 仅输出运行元数据。人工核对前停止相关 worker，避免与仍在运行的模型请求竞态。确认上游未完成 / 商户承担成本后，可用明确参数退款；需离最近活动至少 360 秒：

```bash
python -m translation_service.manage --database ./data/bookllm.sqlite3 refund --account ACCOUNT_UUID --request REQUEST_ID --reason '已核对上游未完成' --confirm-provider-failed
python -m translation_service.manage --database ./data/bookllm.sqlite3 complete --account ACCOUNT_UUID --request REQUEST_ID --result-json /secure/recovered-result.json
```

恢复结果文件应为 `{text: ...}` JSON 对象，术语提取则为 Term 数组。工具没有公网退款接口。

测试使用独立临时 SQLite、生成的 RSA 测试签名与 mock 上游，覆盖流式订阅者中途断开、首 token 前取消、慢读取的有界队列、后台完成后恢复与不重复扣点、服务关闭收尾，以及并发余额争用、同一购买重放、账户隔离、绑定校验、签名和 nonce 边界、伪收据拒绝、流水一致性、退款及逆序通知、质量偏好提示词、真实 SSE 增量与未完成输出。无需访问真实 Apple / DeepSeek。仍需要用真实沙盒购买、OCSP、Apple 登录和 DeepSeek 翻译完成联调后发布。

生产基础设施应使用 HTTPS、私有文件权限、备份且加密的本地持久磁盘，并在代理限制请求体 256 KiB、登录与收据验证的速率；不记录 Authorization、JWS、源文或模型 Key。SQLite 适合同一台机器多个 worker；不要跨主机共用 NFS 数据库。多副本部署需迁移为共享 PostgreSQL 事务账本。翻译缓存包含用户译文，需制定保留期限与账户删除流程。此目录实现可运行服务，未部署到外部，也没有配置真实购买或模型密钥。
