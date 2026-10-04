# 译间 · BookLLM for iOS

原生 SwiftUI 小说与文档翻译应用，参考现有 BookLLM 的书库、阅读器、术语提取及多阶段翻译。此目录独立于原有 `frontend/`、`backend/` 与 OCR 服务；原 Web 应用仍可按仓库原有说明运行。

## 体验与实现

- 新手介绍选择「按量付费」或「买断自带 API」；买断界面隐藏翻译点数与点数包，只显示自己的 API。原语言自动检测，支持中文、英语、日语、韩语、法语、德语、西班牙语、俄语互译，目标默认中文。
- 书库导入 TXT、Markdown、可提取文字的 PDF、EPUB 和 DOCX；粘贴文本也可建立翻译任务。
- 小说使用单独的按章审校流程：初译、校对、语言专家、主编逐轮处理；相邻原文与上一轮译稿用于统一人物口吻、视角、时态与衔接，上一章已完成译稿的结尾用于章间接续参考，不新增模型调用。中文章回、数字/罗马数字章号及英文 one–ninety-nine 章号使用一致的识别规则。
- 三档质量：**快速**（译者）、**精译**（译者 → 校对）、**出版**（译者 → 校对 → 语言专家 → 主编）。精译也可另开语言专家。界面展示实际阶段进度。
- 八种预设文风与可编辑的自定义风格：忠实清晰、文学雅译、现代叙事、古典韵味、专业文档、徐志摩·诗意、相声·抖包袱、水浒·江湖叙事。预设改变语言气质，不拼接现成作品段落。
- 术语库支持系统整理、先由用户校对后开始翻译，或使用自己的术语库；全书采用同一份术语约束。
- 混合外语可一并翻译、保留原文，或显示原文加译文；可开关词语解释与文化背景编者注，并控制注释密度。语言专家检查外语、语域、习语和注释。
- 翻译点数使用 StoreKit 2 购买；自带 API 使用非消耗型买断商品解锁。默认 DeepSeek `deepseek-chat`；自带 API 可改为兼容 OpenAI 的 HTTPS 服务。
- 快速档使用真实 SSE 边翻译边阅读；精译/出版档按章节完成全部审校后开放阅读。已完成章节及完整译文支持系统分享、TXT、Markdown、分页 PDF、EPUB 3、DOCX 导出，EPUB/DOCX/PDF 保留可提取的原始封面。
- 自动识别小说、诗集、剧本、论文、技术文档：分别处理章节/自然段、诗篇/诗节、对白/场幕、引用/标题、代码/表格。普通文稿不显示「通用」标签；可在菜单中纠正类型。可选择保留内容结构或阅读排版。

`TranslationCore` 默认使用小说 1,800、通用文档 1,400、技术文档 1,100、诗集 900、剧本 1,300、论文 1,400 估算 token 的分块预算，保留前文上下文。章节标题不会在代码块内被误识别，适合预算的代码块和表格尽量整块处理；超长内容会进行保留原文的安全拆分。从 2 个并发请求起步，成功后逐步提高到快速/精译最多 4 个、出版最多 3 个；限流时降低并发并退避重试。全文术语也使用 2–4 路自适应并发提取，每个批次独立保存；晚完成的批次不会覆盖前面的固定译名。每段各阶段的结果保存到本地，暂停后继续复用已有结果。点数模式使用稳定请求 ID 在服务端防止重试重复扣点。流式订阅断开后，云端已开始的段落会继续完成并缓存；恢复时等待原请求结果，不会重新付点。速度仍受模型服务和文档长度影响；出版档有更多审校请求。

## 点数、完整性与译作分享

按模型返回的实际输入 + 输出 token 用量结算，默认每 1000 token 1 点，每次模型处理向上取整，服务端可配置。发起时预留足够完成一个分块的预算，结束后结算并退回差额；预估用量不足导致超出预留时，超额由服务端吸收并记账，不使用户因正常翻译产生负余额。点数估算只供参考，包含上下文、草稿及术语成本，真实用量以模型 usage 为准。术语整理、各审校轮和用户选择的补全分别计费。

点数可能不足时可以选择充值，或先使用现有术语库翻译部分；人工术语确认门禁仍生效。余额不足以完整处理下一段时停在检查点，充值后继续，不能保证刚好耗尽最后一点。后台或暂停断开客户端后，云端已开始的普通/流式请求仍会完成并缓存；稳定请求 ID 防止重复扣点。

每轮 prompt 注入所选风格，校对、语言专家和主编保留风格与人物口吻，同时核对事实与覆盖率。最终结果检查代码块、表格行列、标题、诗行/诗节、对白和明显段落遗漏。完整性规则只能发现明确结构问题，不能证明语义上完全正确。检查失败时保存已付费待校稿与诊断，用户核对后可选择「补全并继续」；补全是新的计费调用，暂停/余额不足则继续同一轮请求。未通过检查的段落不作为已完成章节开放。

已完成且未从其他作者处购买的译作可设定 1–100000 点发布；用户先确认翻译和分享权利，提交译本与封面，不上传原文或密钥。发布以原任务 ID 幂等，价格确定后需用原价格恢复未收到响应的发布。链接为配置云服务的 `/w/<UUID>`，网页只展示名称、语言、价格，点击 `bookllm://work/<UUID>` 打开 App；也可复制 UUID 在书架打开。当前采用 URL scheme，不依赖尚未配置的 Universal Links。

购买在同一数据库事务中扣买家点数、给作者记入点数并创建购买记录；并发和重复购买只扣一次。作者已有 Apple 退款债务时收益先抵扣债务。译本内容仅作者和已购买账户可获取，下载保留封面，可离线阅读与导出。作者收入是应用内点数，没有提现流程。云服务未部署时这些交易入口显示配置/登录状态，不伪造实际交易。

## 在 Mac 上运行

需要 **Xcode 16 或更新版本、iOS 17 或更新版本**。工程使用 Swift 6、Observation；支持 iPhone 和 iPad。

1. 打开 `ios/BookLLM.xcodeproj`，选择 **BookLLM** scheme。Swift Package Manager 会解析本地 `TranslationCore` 与 `ZIPFoundation`（从 0.9.19 起）。
2. 选择 iPhone 模拟器后运行。界面和本地书库不需要填写 API 密钥。
3. 真机运行时，在 Signing & Capabilities 选择自己的 Apple Developer Team；将 `app.bookllm.ios` 改为自己的 Bundle ID，并启用 Sign in with Apple。
4. 默认 `CLOUD_BASE_URL` 为空。点数翻译需在 target 的 Build Settings 设置 **CLOUD_BASE_URL** 为部署好的服务 HTTPS 地址（含 `/v1`，例如 `https://your-service.example/v1`）。`Info.plist` 的 `CloudBaseURL` 自动读取该值。不要把 DeepSeek 服务商密钥写入该地址或客户端。
5. 使用自带 API 时，在设置页保存自己的密钥、HTTPS API 地址和模型名；密钥及登录会话保存在 Keychain。正式版本需购买或恢复买断权益。

开发调试可在 scheme 的 Arguments Passed On Launch 加入 `--byok-testing`，仅 Debug 构建可绕过买断校验，方便使用自己的真实 API 进行端到端验证。模型调用仍由服务商计费；Release 构建不提供该入口。

命令行构建与引擎测试：

```bash
cd ios
xcodebuild -resolvePackageDependencies -project BookLLM.xcodeproj -scheme BookLLM
xcodebuild -project BookLLM.xcodeproj -scheme BookLLM \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
cd Packages/TranslationCore
swift test
```

要在命令行指定服务地址，可在 `xcodebuild` 后追加 `CLOUD_BASE_URL=https://your-service.example/v1`。客户端只接受 HTTPS；工程没有放开 App Transport Security。

提交的 `.xcodeproj` 使用 Xcode 16 的文件夹同步，新增 `App/*.swift` 自动成为源文件。`project.yml` 是可再生成工程的 XcodeGen 配置；需要时执行 `brew install xcodegen`，然后在 `ios/` 执行 `xcodegen generate`。

## StoreKit 与真实商店

BookLLM scheme 已关联 `StoreKit/BookLLM.storekit`。该文件是 **Xcode 本地测试配置**，其中价格仅为暂定测试值，不代表正式售价：

| 商品 ID | 类型 | 本地测试价格 |
| --- | --- | --- |
| `app.bookllm.credits.100` | 消耗型 · 100 点 | ¥6 |
| `app.bookllm.credits.1000` | 消耗型 · 1,000 点 | ¥40 |
| `app.bookllm.byok.lifetime` | 非消耗型 · 自带 API 永久解锁 | ¥98 |

正式价格从 `Product.displayPrice` 显示。点数与买断权益分别管理：买断允许使用自己的模型服务商账号，模型费用由该服务商收取。

本地 StoreKit 适合测试商品加载、购买状态和买断恢复。云端点数账本只接受 Apple **Sandbox / Production** 的有效签名交易，不接受 Xcode 本地交易生成的凭据，因此本地测试购买不会伪造到账。验证真实点数购买时，在 Edit Scheme → Run → Options 将 StoreKit Configuration 设为 **None**，使用 App Store Connect 配置的商品与 Apple Sandbox 测试账户，并将服务设为 Sandbox 验证环境。点数购买先登录，交易绑定 `appAccountToken`；服务确认入账后客户端才结束交易。

## 云端服务与上线配置

`server/` 为 iOS 的账户、交易验证、点数账本与 DeepSeek 转发服务；详见该目录说明。原 NestJS Web 后端未替换。接入现有基础设施时，应保留同样的服务协议和服务端校验，不能让客户端自行声明购买有效或点数余额。

发布前需要完成的外部配置：

- Apple Developer Team、唯一 Bundle ID、Sign in with Apple capability 与 App Store Connect 应用。
- App Store Connect 中创建上述商品 ID，确认消耗型/非消耗型类型、实际价格、购买说明及审核材料；若更改商品 ID，需同步客户端、StoreKit 测试文件与服务端商品表。
- 部署 `server/` 并配置 Apple Bundle ID、数值 App ID、Apple 根证书、Sandbox/Production 环境、随机会话签名密钥和服务商密钥；部署到 HTTPS，持久化并备份点数数据库。
- 在真实 Sandbox 和真机上验证登录、点数到账、重复交易、暂停续译、恢复买断、文档分享和长文导出，再运行 Release archive 和 App Store 验证。
- 提供可访问的隐私政策、使用条款、服务计费说明与账号删除功能；根据实际数据收集情况填写 App Store 隐私标签。`Resources/PrivacyInfo.xcprivacy` 已声明仅访问本应用 UserDefaults 的必需理由 `CA92.1`；发布时仍需复核新增代码和依赖的声明。用户文档会发送给所选模型服务商，需在正式产品隐私说明中告知。

App 在前台执行翻译；进入后台时 iOS 可能挂起任务。重新打开后可继续已有检查点。导入会尽量保留标题、段落、列表、强调及代码等文本结构。保留排版是结构与语义保留，PDF 复杂页布局、图片定位、复杂表格和原书脚注不保证完整保真；扫描 PDF 需先 OCR。导出生成新的 TXT/Markdown/PDF/EPUB/DOCX 译文文件；并非原始文件的精确版式回写。EPUB 从明确的封面声明或封面页解析图片，PDF 使用首页缩略图；DOCX 根据第一页图片和分页标记提取封面，缺少精确 Word 分页时采用启发式。纯 SVG 封面由可用的系统渲染支持决定，不能提取时仍可导入正文。

## 验证范围

本工作区为 Linux，**没有 Xcode 或 iOS Simulator**。Linux 的 Swift 编译器可执行独立翻译引擎测试与原生 Swift 文件的语法解析；不能在本机完成 SwiftUI/UIKit/StoreKit 的 iOS SDK 类型检查、运行或真机验证。`.github/workflows/ios.yml` 在 macOS 上运行 `swift test` 和关闭签名的模拟器构建；macOS CI 已通过 Xcode 16 的 iOS Simulator 构建，每次变更以对应提交的 CI 结果为准。Web 预览仅用于交互和视觉检查，不代替原生 iOS 运行。
