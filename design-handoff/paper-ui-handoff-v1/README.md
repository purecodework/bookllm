# 纸间 · 最新 UI 设计交接包

**用途：在已有 iOS App 上替换界面与交互表现，不重建产品功能。**

版本：UI handoff v1 · 2026-10-09。本包已合并本次对话最后的简化决定。`纸间` 是设计稿暂名；现有 App 的正式名称、Bundle ID、项目结构、账号体系和商业权益保持不变。

## 先看什么

| 文件 | 用途 |
|---|---|
| `CODEX_START.md` | 给 Codex 的实施任务；先读，避免从零重写 App |
| `docs/01-final-decisions.md` | 最终设计决定、被替换的旧方案、范围边界 |
| `docs/02-ui-spec.md` | 页面、组件、布局、状态与文案要求 |
| `docs/03-motion.md` | 四档人物、面板、阅读及减少动态效果规范 |
| `docs/04-integration.md` | UI 到既有功能的绑定、旧数据兼容、不能做的改动 |
| `docs/05-acceptance.md` | 视觉与业务回归验收清单 |
| `design/`、`assets/` | 颜色/排版/间距 tokens、文案、图像及 UI 类型示意 |
| `gallery.html`、`preview.html`、`references/` | 视觉总览、可点击交互参考、逐屏高清截图 |

## 最新 UI 已统一到这一版

首页是书库，每本书只出现一次，翻译进度直接属于这本书。没有独立任务导航，也没有全局“术语待确认”任务。人物仍为译者、校对、语言专家、主编；使用最后一版适度细节的开放墨线画像，主编叼烟斗。

术语自动维护。用户只有在需要时从本书 `··· → 译名` 修改单个译名；没有三种术语模式选择、人工确认清单、批量校对、确认词表后才开译等必经流程。取消的是用户手动术语确认，不是模型校对、完整性检查或扫描 PDF 的识别核对。

## 如何交给 Codex

将整个文件夹解压到现有仓库的 `design-handoff/paper-ui-handoff-v1/`，把 `CODEX_START.md` 交给 Codex 执行。不要只给截图，也不要只给早期原型 ZIP。先让它读取项目自身的说明与规则，再读取本包。

本包没有读取你的生产仓库，因此没有假设实际 App 是 SwiftUI、UIKit、React Native、Expo 或其他技术栈。`prototype/` 的 HTML/CSS/JavaScript 是界面参考，不是要求使用 WebView 或更换框架。`design/component-contracts.ts` 只表达 UI 所需语义，不是新后端协议，也不是要求迁移数据模型。

## 如何看设计

打开 `gallery.html` 查看所有定稿屏幕；打开 `preview.html` 测试书库、进度、四档角色、阅读和简化译名。两者均不需要 npm 安装。`preview.html` 内嵌所有演示图片，不调用外部字体、模型或后端。

`prototype/` 保留可读源文件；改动后可用 `python3 scripts/build_preview.py` 重建单文件参考。不要将演示 seed、计时器、localStorage、固定百分比或示例文本移植到生产 App。

## 权威顺序与范围

本次用户的明确要求 > `docs/01-final-decisions.md` > 页面/动效/接入规范 > `design/tokens.json` > 截图 > 演示代码。截图用于视觉，真实处理结果以现有业务服务为准。原始第一张阅读图只用于材质和排版气质，不覆盖后来确定的信息架构。

没有高清定稿图的既有页面（例如购买、API、完整导出、OCR）按 `docs/02-ui-spec.md` 的继承规范统一样式，保留现有功能，不应因为原型未实现就删除、置灰或重造。

## 检查状态

`qa/reference-results.json` 记录 38 项 HTML 参考检查通过、14 张手机截图和测试范围；这些不是生产 App 的测试结果。检查包括取消术语门槛、按书暂停/继续、并行角色、返回链路、可选译名编辑和四档切换。

未进行：iOS 原生真机渲染、VoiceOver、原生动态字体、生产 API/支付、数据迁移或你的实际仓库回归。Codex 必须完成这些接入检查后再说明“App 已完成”。
