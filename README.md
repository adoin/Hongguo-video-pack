# 红葡萄 Hongputao

[LINUX DO 社区](https://linux.do/) · [GitHub 下载](https://github.com/adoin/Hongguo-video-pack/releases) · [Gitee 镜像](https://gitee.com/adoin/Hongguo-video-pack/releases) · [问题反馈](https://github.com/adoin/Hongguo-video-pack/issues)

基于 Flutter 的 Windows / Android 选剧、播放与合集制作工具。支持搜索分页、榜单、内置播放、观看记录与断点续播、下一集预加载、范围选集、下载与本地视频拼接。各安装包包含的功能以对应 Release 说明为准。

支持启动时检查正式版更新和手动选择更新来源，国内 Gitee 镜像优先、GitHub 备用；下载后校验再交给系统安装，忽略 beta / alpha / rc 等预发布版本。观看记录保存在本地，启动页显示最近三条，在线剧集和合成视频均可继续观看。

## 项目缘起与社区

最初我使用的是 LINUX DO 站内分享的 [MiniReel](https://linux.do/t/topic/3028726)。在当时的使用过程中，我遇到过搜索结果翻页和播放失败的问题，也希望将分集整理、观看记录与合集拼接放在同一个工具里，因此开始自己观测、采集红果官网和 App 的接口，编写适配，逐步做成了红葡萄。

这些是我当时的个人使用经历，不代表 MiniReel 当前版本仍存在同样的问题。感谢 MiniReel 作者和 [LINUX DO](https://linux.do/) 社区带来的启发与交流，也感谢协议适配和媒体组件的开源作者。项目实际复用的开源代码、修改与许可证列在 [第三方声明](THIRD_PARTY_NOTICES.md)；MiniReel 的客户端程序、私有源码、账号及设备身份不随本项目分发。

## 使用

- **Windows 10/11 x64**：从 Release 下载对应版本的 `Hongputao-Windows-<版本号>-Setup.exe` 安装，可选择目录与桌面快捷方式，开始菜单提供启动和卸载入口。默认安装目录和应用标识保留升级兼容，无需管理员权限或另装 Flutter、Node、FFmpeg、Java。升级前请结束任务并退出旧版；安装程序不会强制关闭任务。卸载保留用户设置和导出视频。便携包仅作为备用交付。
- **Android 8.0+ ARM64**：安装交付的 APK。下载和拼接使用前台服务，通知显示受系统设置影响；成品先写入应用内目录，完成后点击“保存到手机”，通过系统文件选择器另存。卸载前请另存需要保留的视频。
- 输入红果播放页链接或剧集 ID，点击“读取剧集”。默认选中前两集，可点选、全选或按范围选择。
- 清晰度列表只显示来源实际返回且可处理的档位；当前示例能返回原始 1080P。当前源码会为每台安装独立注册并保存访客身份，不需要从其他播放器导入账号或设备配置；不要求登录红果账号。播放初始化修复与验证范围见 [App 接口文档](.agents/api/app-core.md#6-首次访客注册)。
- 点击“下载并拼接”。同规格素材直接保留码流；开启“自动兼容素材”时，纯尺寸差异优先取最常见规格，仅对差异集数等比缩放、补黑，保留其他集数原流；混合拼接必须通过完整解码校验。不满足兼容条件或校验失败时才回退为最常见尺寸、30fps、H.264/AAC 全量统一。解码和编码最多 2 线程，滤镜 1 线程；这是线程预算，不是固定 CPU 百分比上限。
- 可另行导入已有本地视频，按列表顺序调整后拼接。
- 失败或取消后，已完成分集留在导出目录的 `.hongguo-cache`，重新执行会校验并复用。未完成的一集重新下载；不声称支持字节级断点续传。
- “最近导出”保留最近 20 条记录。清理缓存不会删除导出的 MP4。

默认 Windows 导出目录为系统文档目录下的 `Hongguo Studio/exports`，可以自行选择其他可写目录。工作区设置保存在应用支持目录，不在安装目录写入个人配置。

## 剧库与搜索

- 点击卡片或“播放”进入内置播放页；“拼接”进入工作台选择下载与拼接范围，长按卡片可看简介。
- 播放页的“播放选集”用于切集，“选择拼接”用于勾选任务分集；“拼接所选”直接启动任务。已有任务进行时可继续播放，但不新建或覆盖正在进行的拼接任务。
- 播放页右上角“任务管理”可看进度、取消任务和查看导出记录；离开播放页停止播放器，已开始的拼接任务继续运行。
- 更名后，Windows 首次运行只复制旧应用支持目录中已知的设置、访客初始化和分类缓存；不覆盖新设置，不移动旧导出文件。

- 发现页支持总热播榜、真人剧榜、漫剧榜和 AI 剧榜；榜单和漫剧分类可以继续加载后页。
- 默认调用红果官网 `/api/search/result` 实时搜索并按来源分页，单次请求返回即显示，保持来源顺序；不在搜索前扫描全片库。每次主动搜索都重新联网，失败时清空旧结果；热度缺失时后台补充，不阻塞展示。
- 兼容已有本机访客配置的 App 搜索与真实游标分页，不需要账号登录、Cookie 或常驻模拟器。已在程序内实测两页不同剧集、热度和返回上页缓存；不伪造未知总页数。
- 0.2.3 修复 App 搜索封面显示：对 HEIC/HEIF 或缺失封面，按剧集 ID 在后台读取详情页的兼容封面；最多 3 个并发、逐张显示、复用详情缓存，不阻塞搜索首批、不修改签名图片 URL 后缀。
- 旧 App 搜索配置来自支持目录的 `search-visitor.json`，不内置、不随安装包分发；没有此文件也可使用默认官网搜索及分页。播放使用独立的 `data/visitor-v1.json`，播放初始化不会自动切换搜索来源。
- 用户主动点击“补充检索分类片库（较慢）”才建立真人剧、漫剧、AI 剧本地索引，补充结果每页 20 部，支持上下页、30 分钟缓存。范围不是全站完整剧库，不在后台自动扫描。
- 搜索结果显示详情页实际返回的热度，存在明确播放次数字段才显示播放量；缺失时省略。不把评分、收藏数当播放量。
- 工作台的“查看关联作品 / 其他季”按去除季数后的同名标题检索；不声称是官方关联关系。
- 随机推荐从真人剧、漫剧或 AI 剧分类随机选页抽取，尽量避开本次会话已展示的结果，不代表官方个性化推荐。
- 剧库卡片只作选剧入口，进入工作台后重新读取完整分集，不能使用分类页预览片段代替全剧。

## 设置、同步与开发者日志

- 桌面侧栏底部、移动端顶部的齿轮进入“设置”。在线观看记录条数可设置为 1–10000；超过限制时优先清理已看过的，再按最早观看时间清理，有合成文件的记录另行保留。
- 填写 WebDAV 目录地址、用户名及密码或应用密码，测试连接后保存并启用。程序在该目录下使用 `Hongputao/watch-history-v1.json`，不覆盖目录里的其他文件。自动同步覆盖启动、返回应用和记录变更，连续播放时按 30 秒合并变更；也可“立即同步”。
- 同步剧集、集号、播放点位、已看过标记、记录条数和删除标记。并发更新使用服务端 ETag 检测冲突并重新合并，最多尝试三次；服务器不支持安全版本检测时会报错，保留本地记录。
- 合成视频同步标题和播放点位，不上传视频文件或本地绝对路径；其他设备打开这类记录时可选择并关联本地视频。WebDAV 凭据保存在系统安全存储中，不进入工作区 JSON、日志或同步文件。
- “设置 → 开发者日志”默认记录错误和警告，可以按级别筛选、展开详情、单条复制，或一键复制全部错误与警告。手动开启“全量日志”后额外记录应用事件和请求状态；最多保留 1000 条，并限制日志体积。密码、Cookie、设备身份、临时链接及媒体密钥会被隐藏，日志只保存在本地。

## 验证与范围

最新播放初始化修复、独立注册与安卓模拟器实际播放验证见 [播放接口与验证记录](.agents/api/playback.md)。历史播放与更名验证见 [docs/acceptance-0.3.0.md](docs/acceptance-0.3.0.md)，封面修复见 [docs/acceptance-0.2.3.md](docs/acceptance-0.2.3.md)，历史验证见 [docs/acceptance.md](docs/acceptance.md)。Android 模拟器出帧不等于所有真实手机、系统保存和后台任务均已验收，这些需在对应设备上确认。

## 开发与构建

使用 Flutter 3.47.7 / Dart 3.13.5、Node.js 24、Java 21、Android SDK/NDK、Windows Visual Studio C++ 和 Inno Setup 6.5+ 构建工具。依赖由 `pubspec.lock` 固定。Windows 构建时将发现的 Node 可执行文件一并打包，目标电脑不依赖 PATH。

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
pwsh.exe -NoLogo -NoProfile -File scripts/prepare-signing.ps1
flutter build apk --release --target-platform android-arm64
pwsh.exe -NoLogo -NoProfile -File scripts/package.ps1
```

`prepare-signing.ps1` 仅在首次构建生成本地发布密钥，不覆盖现有密钥。**私下备份 `.local/signing/` 和 `android/key.properties`，不要提交或随安装包分发。** 后续 Android 升级需使用同一密钥。

联网协议检查（会实际请求示例剧集）：

```powershell
$env:HONGGUO_LIVE_TEST='1'
flutter test test/live_protocol_test.dart
./android/gradlew.bat -p android :app:testDebugUnitTest
```

Windows Release 整体检查：在项目根目录运行 `build/windows/x64/runner/Release/hongguo_studio.exe --acceptance`。结果写入 `.local/acceptance/result.json`，只记录画质、轨道、时长和任务事件，不记录媒体密钥或临时地址。

`--smoke` 用于验证打包的原生 FFmpeg 引擎。可选外部 FFmpeg 测试需要 PATH 中的 ffmpeg/ffprobe，或设置 `HONGGUO_FFMPEG` / `HONGGUO_FFPROBE`；普通应用使用内置引擎。

`--search-acceptance` 使用本机初始化信息验证成品运行时的两页搜索、去重与返回缓存，结果写入 `.local/search-acceptance/result.json`，不输出身份或签名值。来源 API 参考见 [.agents/api/README.md](.agents/api/README.md)。

`--playback-acceptance` 在真实 Flutter 原生窗口中播放来源视频，验证解密出帧、拖动和下一集，并在播放期间运行内置拼接引擎检查。脱敏报告及画面样本保存在 `.local/playback-acceptance/`。内置 libmpv 运行库随安装包分发，不依赖用户安装播放器。

GitHub Actions 自动构建/Release 流程及首次签名 Secrets 配置见 [docs/releasing.md](docs/releasing.md)；透明图标母版及导出说明见 [docs/branding.md](docs/branding.md)。

桌面发布必须提供安装程序：Windows 为 Setup.exe；Linux / macOS 后续接入时也应提供对应系统安装格式。目前尚未交付 Linux / macOS 构建，不能把 Windows 包当作这些系统的安装包。

## 结构与许可

- `lib/`：共享界面、单剧数据、任务编排、缓存、媒体校验与导出。
- `assets/protocol/`：Windows 签名适配；`android/.../protocol/`：Android 原生签名适配。
- `android/.../MainActivity.kt`：签名桥接、系统文件导入/保存及文件预览。
- `scripts/`：本地签名准备、可重复打包、Inno Setup 安装包构建与安装 / 卸载验证。
- `installer/`：Windows 安装器与简体中文翻译（来自 jrsoftware/issrc 官方仓库，保留原文件声明）。

软件源码按 [GPL-3.0-only](LICENSE) 发布；使用、修改和再分发软件须遵守该许可证，商业使用也适用同一许可。软件许可证不授予任何视频内容的使用或传播权；请仅处理你有权使用的内容，未经授权不得下载、传播或商业利用视频内容。

协议适配包含 GPL-3.0-only 来源代码，媒体引擎包含 GPL 组件；本交付随附完整应用源码、许可证和来源声明。见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 及 `licenses/`。本程序不是红果官方客户端。使用的是来源接口实际返回的访问能力，未接入第三方收费解析服务。

## 社区交流

欢迎通过 [GitHub Issues](https://github.com/adoin/Hongguo-video-pack/issues) 反馈问题，提供工具版本、系统平台、复现步骤与脱敏错误信息；不要提交账号、Cookie、设备身份、签名或媒体密钥。

感谢并链接认可 [LINUX DO](https://linux.do/) 社区。本项目是本地客户端，日常使用无需 LINUX DO 账号，也未接入 Connect 登录。社区分享请按 [开源推广规则](https://linux.do/t/topic/1776670) 和 [发帖模板](https://linux.do/t/topic/1776558) 如实填写声明；AI 参与撰写或润色的帖子介绍应按模板以截图展示。README 中的社区链接不代表项目已获社区审核或背书。
