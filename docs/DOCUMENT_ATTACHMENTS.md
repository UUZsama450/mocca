# 文档附件 / Document attachments

本地候选 Mocca 1.0.7（5254）在发送前按需读取附件。点开附件的“文档读取”可修改 PDF 页码范围和仅文字模式；保存设置后使用现有发送或重新生成入口。

| 内容 | 读取方式 |
| --- | --- |
| PDF 文字 | 按选定页提取文字层 |
| PDF 扫描页、图片、矢量图表 | 按需渲染整页，通过 OCR 或视觉模型读取 |
| DOCX | 正文、基础表格、内嵌位图；保留图片在正文中的位置 |
| TXT、Markdown 等现有文本附件 | 沿用完整文本读取 |

开启并配置 OCR 后，页面和图片交给所选 OCR 服务识别，聊天模型收到文字。关闭 OCR 时，支持图片的聊天模型收到文字及图片；纯文本模型收到可提取的文字，并标明视觉内容未读。没有文字层的扫描件会要求开启 OCR 或选择视觉模型，不会只发送文件名并当作读取成功。

历史文档图片与普通图片共享历史图片发送开关、折叠状态和数量限制。最新一次批量发送中的图片及文档均属于当前回合。识别部分失败时不继续请求聊天模型；重试可复用内存中成功的识别结果。切换 OCR 配置或修改文件后重新识别。

## 范围与性能

- 不再设置客户端文档文件大小、文字量、PDF 页数、图片总数或 DOCX 解压内容总量的硬上限。沿用现有大文件提醒与“不再提醒”偏好；提醒说明内存、处理时间与界面响应风险。
- 默认读取全部页；用户可选择页码或仅文字。现有历史图片开关、折叠状态与历史图片数量偏好仍然适用。
- 页面渲染长边最多 2048 像素；逐页渲染与 OCR，支持取消。此设置控制单页位图的资源占用，不截断页数。
- 文档解析缓存最多 4 份，仅缓存估算内容不超过 2 MiB 的解析结果；大文档仍完整返回，只是不常驻缓存。OCR 缓存最多 48 项且总量不超过 2 MiB。仅保留最近一个渲染 PDF，不缓存所有页面位图。缓存只在进程内存在。
- 没有相关附件时不会启动文档解析、渲染或 OCR，也没有定时轮询。仍在聊天上下文中的历史文档可能在后续发送时被读取。

读取在后台执行；渲染和 OCR 逐项进行并支持取消。客户端不因上述旧限额拒绝或截断内容；过大的请求仍可能超过服务商或设备的实际容量。服务商处理速度、收费与准确率取决于用户选择的服务。

DOCX 页眉页脚、脚注、外部图片、SmartArt 和复杂嵌入对象不保证读取，会给出遗漏提示。本版不支持旧版 DOC/XLS/PPT、Excel 工作簿或 PPTX。OCR 无法保证完整理解布局与图表。

## English

PDF text and selected page visuals, and DOCX paragraphs, basic tables and embedded raster images are supported. Existing plain-text attachments retain their full content. Document settings are available from the attachment; saving settings does not send automatically.

With OCR enabled, visuals go to the configured OCR service and the chat model receives recognized text. Without OCR, vision models receive text and images; text-only models receive extractable text with explicit visual omission notes. Image-only scans require OCR or a vision model. Historical visuals share the existing resend/collapse/count controls, including batch-send semantics.

Processing is on demand, off the UI thread for parsing and file IO, and cancellable between work items. There are no client document-size, text-length, page-count, visual-count or DOCX expanded-content hard caps. The existing large-file confirmation and its opt-out preference remain; its explanation includes memory use, processing time and interface responsiveness. Provider and device capacity can still constrain very large requests. Historical-image settings continue to apply.

Page rendering retains a 2048-pixel long edge to bound individual bitmap allocation, without limiting page count. Large parsed documents are returned in full but not retained in the document cache when their estimated content exceeds 2 MiB.

Caches are in memory only: four parsed documents and up to 48 OCR results / 2 MiB. No periodic background processing is added. A historical document still in the request context can be read again. Partial OCR failures stop the chat request; retry reuses successful cached results. Unsupported Word content is reported, not claimed as read. Legacy DOC, Excel and PowerPoint are not supported.
