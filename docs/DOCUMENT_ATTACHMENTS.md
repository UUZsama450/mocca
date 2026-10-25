# 文档附件 / Document attachments

Mocca 1.0.7（5253）在发送前按需读取附件。点开附件的“文档读取”可修改 PDF 页码范围和仅文字模式；保存设置后使用现有发送或重新生成入口。

| 内容 | 读取方式 |
| --- | --- |
| PDF 文字 | 按选定页提取文字层 |
| PDF 扫描页、图片、矢量图表 | 按需渲染整页，通过 OCR 或视觉模型读取 |
| DOCX | 正文、基础表格、内嵌位图；保留图片在正文中的位置 |
| TXT、Markdown 等现有文本附件 | 沿用完整文本读取，不受新增文档字符限额影响 |

开启并配置 OCR 后，页面和图片交给所选 OCR 服务识别，聊天模型收到文字。关闭 OCR 时，支持图片的聊天模型收到文字及图片；纯文本模型收到可提取的文字，并标明视觉内容未读。没有文字层的扫描件会要求开启 OCR 或选择视觉模型，不会只发送文件名并当作读取成功。

历史文档图片与普通图片共享历史图片发送开关、折叠状态和数量限制。最新一次批量发送中的图片及文档均属于当前回合。识别部分失败时不继续请求聊天模型；重试可复用内存中成功的识别结果。切换 OCR 配置或修改文件后重新识别。

## 范围与性能

- PDF/DOCX 单文件上限 20 MiB；选中 PDF 文字最多 100 页；文档视觉及 OCR 图片每次请求共 20 页/张。
- 文档页面长边最多 2048 像素；文档/OCR 附加文字共 60,000 字符；直发文档图片 Base64 共 24 MiB。字符数不等同于服务商 token 预算。
- DOCX 单条目解压最多 16 MiB，所需条目合计最多 64 MiB。
- 文档解析缓存最多 4 份；OCR 缓存最多 48 项且总量不超过 2 MiB。仅保留最近一个渲染 PDF，不缓存所有页面位图。缓存只在进程内存在。
- 没有相关附件时不会启动文档解析、渲染或 OCR，也没有定时轮询。仍在聊天上下文中的历史文档可能在后续发送时被读取。

读取在后台执行；渲染和 OCR 逐项进行并支持取消。超限提示缩小范围，不静默截断文档。服务商处理速度、收费与准确率取决于用户选择的服务。

DOCX 页眉页脚、脚注、外部图片、SmartArt 和复杂嵌入对象不保证读取，会给出遗漏提示。本版不支持旧版 DOC/XLS/PPT、Excel 工作簿或 PPTX。OCR 无法保证完整理解布局与图表。

## English

PDF text and selected page visuals, and DOCX paragraphs, basic tables and embedded raster images are supported. Existing plain-text attachments retain their full content. Document settings are available from the attachment; saving settings does not send automatically.

With OCR enabled, visuals go to the configured OCR service and the chat model receives recognized text. Without OCR, vision models receive text and images; text-only models receive extractable text with explicit visual omission notes. Image-only scans require OCR or a vision model. Historical visuals share the existing resend/collapse/count controls, including batch-send semantics.

Processing is on demand, off the UI thread for parsing and file IO, and cancellable between work items. Limits: 20 MiB per PDF/DOCX, 100 selected PDF text pages, 20 document/OCR visuals per request, 2048-pixel page long edge, 60,000 document/OCR characters and 24 MiB document-image Base64. DOCX entries are limited to 16 MiB each and 64 MiB in total. Ordinary text attachments do not inherit these new document limits. Text limits do not guarantee a provider's token budget.

Caches are in memory only: four parsed documents and up to 48 OCR results / 2 MiB. No periodic background processing is added. A historical document still in the request context can be read again. Partial OCR failures stop the chat request; retry reuses successful cached results. Unsupported Word content is reported, not claimed as read. Legacy DOC, Excel and PowerPoint are not supported.
