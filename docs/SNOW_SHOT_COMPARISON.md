# Snow Shot 与 Flameshoter 功能对照

2026-11-27，对照 Snow Shot 完整版源码 `ea4f4868` 与 Flameshoter `c518271c` 及本地录屏导出、文字识别改动。下表核对的是用户能从界面或命令行完成的操作。Snow Shot 一侧依据上游文档与源码，未在两款应用之间做识别准确率、录屏画质或耗时跑分。[Snow Shot 项目说明](https://github.com/mg-chao/snow-shot/blob/ea4f48680b6613b40ef8ec7dff22313f326b8159/README.md) · [Flameshoter 基线](https://github.com/Word2VecT/flameshoter/tree/c518271c06b46423d3c7b02bf072d50e2c678b5b)

## 两边都能完成的任务

| 任务 | Snow Shot | Flameshoter |
| --- | --- | --- |
| 截取窗口、显示器或长页面 | 区域、焦点窗口、当前显示器、延时和滚动截图。 | 从菜单栏截取指定屏幕，在选区捕捉窗口或辅助功能元素。长截图支持横向和纵向、自动滚动、预览及裁剪。可按 F5 刷新画面并保留标注。 |
| 标注后分享 | 箭头、形状、文字、序号、高亮、模糊，也可打开已有图片进行编辑。 | 支持画笔、箭头、形状、序号、聚光灯、放大镜和水印。已有图片可经「置顶剪贴板 → 空格」进入标注。自动打码可逐处撤销，随后可用系统分享。 |
| 置顶参考图、恢复历史 | 图片和剪贴板内容可置顶，历史可恢复，还可切换贴图分组。 | 图片、文字、颜色和文件可置顶，GIF 和 WebP 动图可播放。支持重新标注、锁定、旋转静态图，以及重启后恢复贴图。 |
| 从图片提取文字与代码 | 普通 OCR 与二维码识别在设备上运行。 | 截图和贴图使用 PP-OCRv6 Small 离线提取文字，原图支持系统划词。Vision 读取二维码及系统支持的条码。 |
| 翻译、提取表格与文档 | 可配置在线翻译和高级识别服务，支持表格、公式、AI 格式转换。 | 翻译使用 macOS 语言包，可生成译图。表格在本机识别、校对、排序并导出 CSV 或保留合并单元格的 XLSX。文档导出可编辑段落，Markdown 导出保留文本。 |
| 录制并导出操作演示 | 支持录屏、系统声音、麦克风和动图导出，可保留带有事件信息的可编辑录屏源文件。 | 可录选区、暂停、预览和修剪，按需叠加点击、快捷键及摄像头。原有输出为 MP4、GIF、WebP，本次增加 APNG。点击和快捷键叠加在录制时合成。 |
| 调整习惯与导出 | 自定义快捷键、工具栏、主题和导出选项。 | 可配置快捷键、工具、外观和导出质量。保存时可比较原图和编码结果，查看像素尺寸与实际文件大小。 |

上游对设备端与在线处理有单独说明。Flameshoter 的文字、翻译及表格处理可分别追溯到三个本地入口。[Snow Shot 数据处理说明](https://github.com/mg-chao/snow-shot/blob/ea4f48680b6613b40ef8ec7dff22313f326b8159/docs/snow-shot-privacy-policy.zh-CN.md) · [文字与条码](../Sources/Flameshoter/ImageRecognition.swift) · [翻译](../Sources/Flameshoter/ImageTranslation.swift) · [表格](../Sources/Flameshoter/TableRecognition.swift)

## Snow Shot 提供、Flameshoter 仍缺少的能力

| 能力 | 在 Flameshoter 中最接近的操作 | 用户仍缺少什么 |
| --- | --- | --- |
| 多图拼版、切片、全屏画布 | 长截图拼接连续滚动帧，截图选区和静态贴图可以标注。 | 打开多张无重叠的现有图片、调整排布并导出合图，将一张图切成多份，以及在独立的全屏画布上讲解。[拼版编辑器](https://github.com/mg-chao/snow-shot/tree/ea4f48680b6613b40ef8ec7dff22313f326b8159/snow_shot/src/presentation/collage) · [切图](https://github.com/mg-chao/snow-shot/tree/ea4f48680b6613b40ef8ec7dff22313f326b8159/snow_shot/src/presentation/imagesplit) · [全屏画布](https://github.com/mg-chao/snow-shot/tree/ea4f48680b6613b40ef8ec7dff22313f326b8159/snow_shot/src/presentation/globalcanvas) |
| 成组管理贴图、按容量或时间清理历史 | 恢复打开的贴图或最近关闭的一张，设置保留条数或手动清除。 | 按项目创建和切换贴图组，对本地历史同时设置天数和磁盘空间上限。[贴图组实现](https://github.com/mg-chao/snow-shot/blob/ea4f48680b6613b40ef8ec7dff22313f326b8159/snow_shot/src/presentation/services/pinnedwindowgroupmanager.cpp) · [本项目历史设置](../Sources/FlameshoterCore/Settings.swift) |
| 录完再改鼠标效果 | 录屏前选好点击和键盘叠加，录完可修剪起止点。 | 重新打开带事件轨迹的录屏工程，在导出时调整效果。[上游录屏数据说明](https://github.com/mg-chao/snow-shot/blob/ea4f48680b6613b40ef8ec7dff22313f326b8159/docs/snow-shot-privacy-policy.zh-CN.md) · [本项目录屏](../Sources/Flameshoter/ScreenRecordingSession.swift) |
| 公式识别和结构化 AI 转换 | 可导出已识别的文本文档和表格。 | 从公式图片生成 LaTeX，将页面转换成结构化 Markdown 或 HTML。现有 Markdown 导出只写入校对后的文本。[上游识别服务说明](https://github.com/mg-chao/snow-shot/blob/ea4f48680b6613b40ef8ec7dff22313f326b8159/docs/snow-shot-privacy-policy.zh-CN.md) · [本项目文档导出](../Sources/Flameshoter/DocumentRecognition.swift) |
| MCP、对象存储上传 | CLI 可启动截图、指定显示器、复制或输出原始 PNG，系统分享面板可交给其他应用。 | 供 AI 客户端调用的 MCP 服务，以及应用内配置 S3 兼容存储和直接上传。[MCP 能力清单](https://github.com/mg-chao/snow-shot/blob/ea4f48680b6613b40ef8ec7dff22313f326b8159/snow_shot/mcp-capabilities.source.json) · [本项目 CLI](../Sources/Flameshoter/Command.swift) |
| 更多平台和界面语言 | Apple Silicon、macOS 26+，简体中文和英文界面。 | Snow Shot 也面向 Windows、macOS 15+ 和部分 Intel Mac 构建，并提供繁体中文与俄文界面。可用架构依发行包而定。[上游安装说明](https://github.com/mg-chao/snow-shot/blob/ea4f48680b6613b40ef8ec7dff22313f326b8159/README.md) · [上游翻译资源](https://github.com/mg-chao/snow-shot/tree/ea4f48680b6613b40ef8ec7dff22313f326b8159/snow_shot/i18n) |

## 哪些改进值得借鉴

**录屏导出已加入 APNG。** 想把一小段软件操作嵌入文档时，在录屏预览中选择 APNG 即可保存循环播放的 `.png`。它沿用现有修剪区间、帧率和取消导出流程，使用系统 ImageIO 逐帧编码。按累计时间计算帧延迟，避免 24 fps 等帧率在导出时逐帧累积误差。动图进度最多通知界面 20 次，编码完成后才显示 100%。回读测试检查了文件类型、循环标志、画面切换、总时长和短于一个采样间隔的录屏片段。[上游录屏导出](https://github.com/mg-chao/snow-shot/tree/ea4f48680b6613b40ef8ec7dff22313f326b8159/snow-crates/crates/snow-recording-export) · [本项目实现](../Sources/Flameshoter/RecordingExport.swift) · [导出测试](../tests/FlameshoterCoreTests/RecordingTests.swift)

**长截图可先验证采样间隔。** Flameshoter 每次完成截取与匹配后固定等待 400 毫秒。Snow Shot 会测量截取、拼接耗时与队列压力来调整采样频率。可先用同一组竖向网页、横向表格和快速滚动轨迹，对比匹配失败次数、空闲 CPU 与输出像素。若能减少快速滚动时的断接，再把采样调整接入现有流程。[上游采样策略](https://github.com/mg-chao/snow-shot/blob/ea4f48680b6613b40ef8ec7dff22313f326b8159/snow_shot/src/presentation/capture/adaptivescrollingcapturecadence.h) · [本项目采样循环](../Sources/Flameshoter/LongCaptureSession.swift)

**日常使用优先考虑贴图分组和历史空间上限。** 已有贴图存档和恢复入口，分组可复用相同的图片文件。磁盘限额对长截图和高分辨率贴图尤其有用。实现时应验证旧存档迁移、重启后恢复当前组，以及清理历史时仍打开的贴图可以继续使用。[贴图存档](../Sources/Flameshoter/PinArchive.swift) · [截图内容历史](../Sources/Flameshoter/CaptureHistory.swift)

**多图拼版是独立的编辑任务。** 如果优先满足“把几张截图排成操作步骤图”，可先支持拖入图片、手动排序和横排或竖排导出。它可以复用现有图片导出和预览。云端识别、上传和 MCP 则会引入新的外部服务或调用方，需单独决定产品范围。[本项目导出预览](../Sources/Flameshoter/ImageExportPreview.swift)

## README 借鉴

Snow Shot 把下载入口、界面示意和首次操作放在项目首页。Flameshoter 的中英文首页沿用这一阅读顺序，展示本项目实际的明暗两种截图界面，并说明下载版与当前源码的差别。常用键位按「全局、截图、贴图」区分，完整标注快捷键可展开查看。[中文版](../README.md) · [English](../README.en.md)
