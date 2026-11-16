---
status: active
kind: project-specification
updated_at: 2026-11-16
modules: [自动更新, GitHub Release, Gitee 镜像]
---

# 正式版更新与国内镜像

用户要求：

> 然后得加一下自动更新功能，拉取github release进行比较（只比较正式版版号 beta alpha rc等不管）
> 保留 GitHub 构建，增加国内镜像（推荐）
> https://gitee.com/adoin/Hongguo-video-pack 导入好了 我还需要给提供什么吗
> 建了 叫GITEE_ACCESS
> action里面代码自动同步gitee release自动同步gitee，能做到吗

- 启动自动检查，“关于”提供手动检查。版本来自已安装包的 PackageInfo，不使用容易遗漏的手写版本常量。
- 启动并行检查 GitHub 与 Gitee；两者均失败时显示非阻断警告及手动检查入口，单源失败不阻止使用另一源。自动选择最新就绪正式版，同版本优先 Gitee；自动模式下国内下载失败可回退 GitHub 的相同或更新版本，不降级。手动入口可选自动 / Gitee / GitHub，明确选择单源时不暗中切换。无登录、无内置私人令牌，不使用第三方公共代理。
- 只识别可选 v/V 前缀的三段正式版本号；跳过 draft / prerelease 标记及 beta、alpha、rc、构建元数据等后缀。按整数比较而非字符串，不降级。
- Windows 选 Setup.exe，Android 选 arm64 APK。下载中可取消；网络失败、尺寸异常、SHA256 不匹配都不执行；安装前再次校验。
- 安装需用户点击和系统安装向导确认。拼接任务或素材加载未完成时不安装。Windows 保存状态后启动安装器退出；Android 只共享应用 `data/updates/` 内 APK，包名须相同，未知来源授权交给系统。
- `.github/workflows/sync-gitee.yml` 在 main / v* Tag 更新后同步 main 与标签，不 force push；Gitee 分叉需显式处理。
- GitHub Release 成功后调用 `mirror-gitee.yml`，支持手动补同步旧正式版。GITEE_ACCESS 只在 Actions Secret 使用。镜像上传 Setup、APK、源码及 SHA256SUMS；便携 ZIP 留在 GitHub。
- 镜像先标记 prerelease，全部附件上传成功后转正式版。用户 2026-10-21 明确调整：LA 上传 Gitee 后不再下载附件验证；每个文件最多 3 次上传尝试（含首次），成功即删除本地文件，最终失败也由任务 always 清理剩余下载包。响应丢失只查询附件元数据，已存在则不重复上传。GitHub → LA 的来源 SHA256 校验与客户端安装前校验保留。
- 用户验收前保持 active；构建、模拟更新、真实镜像同步和手机系统安装应分别报告。
- 2026-11-16 用户批准 Gitee 仅保留当前及前一正式版。上传前按三段数字版本排序，删除更旧 Gitee 发行版及其附件以腾出仓库附件配额，保留 Git 标签、GitHub 与夸克历史；旧版手动补同步不得复活两版窗口外的发行版。非正式版本号及未来预览不纳入自动删除。镜像任务跨版本串行，避免清理与上传相互干扰。

## LA 镜像发布节点

- 用户已批准常驻 LA 节点，以及安装 `libicu78`。仓库专用 Runner 名称 / 标签为 `hongputao-gitee-publisher`，以独立普通账号运行，不开放入站发布端口。
- 节点只负责下载 GitHub 已构建的发布包、校验并上传 Gitee，不承担 Windows / Android 构建。其他仓库接入需要分别注册 Runner 和配置发布权限。
- Ubuntu 26.04 上启用 `RestrictSUIDSGID` 时，Runner 解压 checkout Action 报 `Function not implemented`；用户批准后仅关闭此项，同一任务解压及检出成功。保留 NoNewPrivileges、空 capabilities、ProtectSystem 和专用目录写入限制。
- Runner 会重建工具 PATH；工作流通过 GITHUB_PATH 加入专用工具目录。Python 优先使用节点现有 python3，不要求全局 python 别名。
- 2026-10-21 v0.3.0 镜像任务 39577820232 已完整成功，Windows Setup、APK、源码及校验文件就绪，预览标记已取消，临时包清理成功。仓库变量 GITEE_MIRROR_RUNNER 已设为 publisher，后续 Tag 发版自动经 LA 上传。
- 首次验收曾遇到 Gitee 接口无响应、上传响应丢失、PATCH 缺少必填元数据及下载不完整；已补齐 PATCH 元数据。验收时 Windows Setup 经独立下载确认 83,402,753 字节、SHA256 与 GitHub 一致；后续遵循最新要求，不重复下载校验镜像。
- 源码同步仅由 sync-gitee 工作流执行，附件镜像不再重复推 main，避免下载期间 main 已更新造成非快进冲突。

## 夸克发布包备份

- 用户明确备份对象为发布包。GitHub 正式版发布后可独立备份到用户指定夸克文件夹下的项目 / 版本目录，包含 Windows 安装包、便携 ZIP、APK、源码和校验文件。
- 用户已确认目标父目录为夸克根目录下的 `releases`；最终路径为 `releases/Hongguo-video-pack/v版本号/`，授权后定位其真实 FID，不将网盘根目录 FID 当作 releases 的 FID。
- 备份与 Gitee 镜像独立；失败单独报告，不撤销 GitHub 已发布版本。首次必须完成私下授权及目标文件夹确认，未就绪前保持关闭。
- 实施入口、变量与验收边界见 `docs/quark-release-backup.md`。LA 官方 CLI 已安装并授权，QUARK_BACKUP_ENABLED 已启用，正式版发布后独立备份。
- 2026-10-21 首次 v0.3.0 备份 Actions 39576112923 成功，五文件上传步骤约 38 秒，云端目录数量确认完成；任务清理及 SSH 复查确认无发布包留存。仍未进行云端全量下载 SHA256 及授权续期验收。
