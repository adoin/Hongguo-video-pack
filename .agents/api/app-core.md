# App 核心 API

核对日期：2026-11-02。App 包名 `com.phoenix.read`，当前抓包版本 `7.3.9.32 / 73932`，App 标识 `aid=8662`、`app_name=novelread`。历史取流使用的版本参数与签名环境不同，不能统一替换后声称仍可用。

## 网关与鉴权边界

### 2026-11-13 当前取流适配

- 已复现 0.3.4：首次注册返回非零身份，但旧 `POST /novel/player/multi_video_model/v1/` 以及此前观测的 player/preload 路径配旧签名均 HTTP 200 空正文；重建身份后不恢复，不能再次归因为仅本机身份过期。
- 本次独立请求已验证 `GET https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/`，查询包含 `video_id`、`video_id_type=0`、`device_level=1`、`need_all_video_definition=1`、`video_platform=1024` 等。使用当前安装自己注册的身份，不导入固定设备配置。
- 播放专用完整 Argus/Ladon 签名绑定最终查询，取代旧播放请求的时间戳占位头；不修改现有 App 搜索签名。响应业务码 0，模型位于 `data.video_model_data[episodeId].video_model`，后续动态媒体信息链路仍可用。
- 新适配已通过独立注册、两集取流、第二集 1080P 实际缓存 8,069,633 字节与 2 秒解密解码验证，缓存随后清理；不能把该有限验证泛化为全部剧集或全设备验收。
- Windows：`player_signer.cjs` 随 worker 与其他协议资产一同打包；Android：同源 Kotlin `PlayerSigner.kt`。两端使用独立公开算法向量测试，测试数据不来自用户抓包。更新来源及 GPL 声明见 THIRD_PARTY_NOTICES.md。以下旧入口成功记录仅代表对应日期。

| 用途 | 已观测/使用的网关 | 边界 |
|---|---|---|
| 实测搜索 | `api5-normal-sinfonlinec.fqnovel.com` | 已取得有效搜索及后页；程序新签名可用 |
| 当前详情/取流 | `api5-normal-sinfonlineb.fqnovel.com` | 当前适配主路径 |
| 旧搜索实验 | `api5-normal-sinfonlinea.fqnovel.com` 及 b 网关 | 曾 HTTP 200 空正文，不代表搜索本身不支持分页 |

所有请求使用 HTTPS。设备/安装身份是访客身份，不等于账号登录。实测搜索移除 Cookie、登录授权及捕获 SDK 临时字段后仍可成功，但随机替换 `device_id` 或 `iid` 会返回空正文；省略或置零曾返回业务码 `100103`。因此不能把取流中可用的随机身份策略视为搜索身份初始化方案。

签名头的**名称**：`x-khronos`、`x-ladon`、`x-argus`、`x-gorgon`、`x-helios`、`x-medusa`。附带 `x-ss-req-ticket`、SDK/版本相关头；POST 请求可使用 `x-ss-stub` 表示正文摘要。每次请求按实际 query、正文、时间重新生成；签名值不写入文档。

## 1. 搜索与真实分页

`GET /reading/bookapi/search/tab/v`

无尾斜杠是本次成功观测的形式；历史带尾斜杠实验的空响应不能证明两者永远等价或永远不同。

| 字段 | 位置/类型 | 用途与实测值 |
|---|---|---|
| `query` | query/string | 搜索词，UTF-8 百分号编码 |
| `tab_type` | query/int 字符串 | 本次综合页为 `11`；不能靠数字猜标签名 |
| `count` | query/int 字符串 | 本次官方请求为 `0`，不是“结果条数应为零” |
| `offset` | query/int 字符串 | 首批 0，后续取上一响应 `next_offset` |
| `search_id` | query/string | 后页沿用服务端搜索会话 |
| `passback` | query/string | 后页原样传回服务端游标，不在客户端自行递增 |
| `bookshelf_search_plan` | query/string | 观测为 `4` |
| `user_is_login` | query/string | 本次免登录为 `0` |
| `search_source` | query/string | 观测为 `1` |
| `device_id`、`iid` | query/string | 有效访客设备/安装身份；本机保存，不提供共享常量 |
| App/系统信息 | query/string | `aid`、`app_name`、版本、平台、语言、分辨率等，需与签名环境相容 |
| 时效字段 | query/string | `_rticket`、签名时钟等，按请求生成 |

官方请求还含推荐/上次消费上下文、`use_lynx`、分类标签、设备运行状态等。没有证据说明所有字段都必需；不要直接把整份抓包 query 固化进产品。

成功响应的结构示例（全部身份与会话值为占位符）：

```json
{
  "code": 0,
  "message": "SUCCESS",
  "selected_tab_idx": 0,
  "search_tabs": [{
    "tab_type": 11,
    "title": "综合",
    "query": "示例剧名",
    "data": [{
      "show_type": 369,
      "video_data": [{
        "vid": "<preview-id>",
        "series_id": "<series-id>",
        "title": "示例剧名",
        "episode_cnt": 80,
        "show_rec_text": true,
        "rec_text": "123万热度",
        "show_play_cnt": true,
        "play_cnt": 12345,
        "video_detail": {
          "series_id_str": "<series-id>",
          "series_title": "示例剧名",
          "episode_cnt": 80,
          "series_cover": "<cover-url>",
          "series_intro": "示例简介"
        }
      }]
    }],
    "has_more": true,
    "next_offset": 6,
    "passback": "<cursor>",
    "search_id": "<search-session>"
  }]
}
```

根字段还观测到 `server_ab_params`、`log_id`。每个 tab 可含 `plan_id`、`search_target_channel`、`search_scene`、`client_template`、`selector`，不是统一的数据数组。

### 混合卡片解析

- `show_type=369` 的样本包含正式 `series_id` 与 `video_detail`；以剧集 ID 去重，不能以预览 `vid` 作剧集 ID。
- `show_type=532` 的样本为 UGC 合集，只有 `album_info.album_id`；当前正式剧集解析器跳过。
- `show_type=611` 的样本含字符串 `lynx_data` 和排名容器；当前解析器不把容器当一个剧集。
- `video_detail.series_id_str` 优先于数值字段，避免把大整数经不支持的数值类型转换后丢精度。
- `rec_text` 只有明确含“热度”才归热度，`play_cnt` 与展示开关共同处理；评分、点赞、收藏不得混用。
- 搜索 `series_cover` 可能是签名 HEIC 图片，HTTP 200 不代表 Flutter Windows 可解码；改变后缀为 JPEG/WebP 已实测返回 403。当前按同一 `series_id` 异步查询官网 `/detail` 的 `seriesDetail.series_cover`，已取得 JPEG，保留原签名 URL，不自行拼接或改写格式参数。

### 已验证的分页链路

2026-10-19 13:04:53 的首批与 13:23:36 的后页使用同一搜索会话。后页请求 `offset=6`、`passback=5`，返回 9 个正式剧集，与首批无重复；后页 `next_offset=16`。这是本次会话的实测值，不是固定分页步长。

自研 Dart 模块加自研新签名已连续取得 5 条、9 条正式剧集，ID 无重合，返回上页使用缓存。测试使用本机已注册访客身份，不证明自动注册已完成。应用可从自己的支持目录读取 `search-visitor.json`（version 1，仅设备/安装标识）；配置存在且有效时启用 App 搜索，没有本机配置时仍走明确标注的网页首批。初始化文件不随安装包分发，不是共享内置身份。

异常：HTTP 非 200、200 空正文、非零业务码、标签/关键词不匹配、会话变化、游标不前进、重复结果均须明确失败，不能消费游标或伪造后页。`has_more` 不等于已知总页数。

代码：`lib/data/app_search_client.dart`、`signed_app_search.dart`、`request_signer.dart`、`assets/protocol/worker.cjs`、`signer.cjs` 及 Android `protocol/Signer.kt`。

## 2. 详情与完整分集

`POST /novel/player/video_detail/v1/`

```json
{"series_id":"<series-id>"}
```

当前程序读取 `data.video_data`，核对 `series_id_str / series_id` 与请求一致。分集在 `video_list`，读取 `vid`、`vid_index`，核对分集所属剧集并按序排序。详情失败可回退官网 `/player/{series_id}` 读取完整分集。不能以列表搜索里的预览条目替代完整列表。

代码：`HongguoClient.fetchDrama`、`parseAppDrama`、`parseWebDrama`。已接入当前程序；具体来源当时是否成功须看对应请求，回退成功不证明 App 详情请求也成功。

## 3. 批量取流与清晰度

`POST /novel/player/multi_video_model/v1/`

```json
{
  "biz_param": {
    "detail_page_version": 0,
    "device_level": 3,
    "disable_digg_stat": false,
    "need_all_video_definition": true,
    "need_mp4_align": false,
    "use_os_player": false,
    "use_server_dns": false,
    "video_platform": 1024
  },
  "mixed_video_id_map": {"1004":["<episode-id>"]}
}
```

已通过完整签名实测，业务 Code 0；独立随机访客身份对该取流链路曾有效，不可推导到搜索。`data[episodeId].video_model` 可能是 JSON 字符串或对象；从中读取 `fallback_api`，该字段也可能嵌套为对象、JSON 字符串或数组。

当前代码会校验媒体信息 URL 为 HTTPS 且位于已允许的来源域名。不要拼造固定媒体网关，不把失效临时 URL 当永久资源。

## 4. 动态媒体信息与实际媒体

### 2026-11-02 播放故障复核

- 用户 Android 0.3.2 显示“播放准备失败”，搜索正常；USB 连接已确认安装版本为 0.3.2（11）。
- 自研 `test/live_protocol_test.dart` 连续两次联网复测：完整分集读取成功，随后 `multi_video_model/v1/` 返回 HTTP 200 空正文，失败发生在 `decodeApiResponse`，未进入动态媒体信息读取和播放器解码。
- 有限诊断中，现有签名的 7.1.3.32 / 7.3.5.32 / 7.3.9.32 请求，以及已知 a / c 网关请求均为空。仅切版本或网关未恢复；这些实验没有进入正式适配。
- 后续已通过雷电中官方 7.3.9.32 的 PCAPdroid HTTPS 明文观察到成功取流：`POST api5-normal-sinfonlinec.fqnovel.com/novel/player/multi_video_model/player/v1`，正文增加 `dr_scene: "player"`、`biz_param.disable_video_relate_book: false`；预加载为 `/novel/player/multi_video_model/preload/v1`，`dr_scene: "preload"`。响应业务码 0，`data[episodeId].video_model` 有效。
- 当前安装 APK 的 `classes14.dex` 已内置 `/novel/player/multi_video_model/:dr_scene/v1/` 和 `/novel/player/multi_video_model/v1/` 字符串。因此无需更新 App 就能构造带播放场景的路径；尚未证明远程配置参与了本次路由选择，不能称为今日新增地址。
- 受控诊断使用自研签名重新生成请求，不依赖重放原签名：本机已注册访客配置取得有效模型；去掉 `klink_egdi`、`cdid` 等新增字段，甚至仅保留注册 ID 与基础版本/设备参数，仍成功；保持其余条件、改用随机身份则 HTTP 200 空正文。原始捕获请求直接重放未成功，未将其当作可复用签名。
- 旧 b 网关 `/novel/player/multi_video_model/v1/` 使用有效本机注册配置，配新正文和旧正文分别成功。故端点变更不是本次失败的必要条件，当前随机访客身份被拒绝是已复现的兼容问题；无法据此确定服务端何时开始收紧，首次注册流程仍未完成。
- 以上捕获的注册配置仅用于用户授权的本机诊断，不进入产品、源码、测试夹具或交付；不以内置共享身份或第三方解析服务掩盖初始化缺失。
- 后续独立首次注册与 Dart 联网验证已成功：全新随机安装标识取得服务端非零身份，取得第二集 1080P 媒体、预加载 8,069,633 字节并用该集密钥实际解码 2 秒音视频，随后删除临时缓存。Android 安装后的验证状态须单独记录，不能以此替代。
- 此条覆盖“当前仍可取流”的时效性判断；上文历史成功只代表对应验证时间。

`GET <video_model 返回的 fallback_api>`，完整路径由来源动态给出。

读取 `video_info.data.video_list`、`key_seed`、`video_duration`；`video_list` 可能为映射或列表，包含 `definition`、`vwidth`、`vheight`、`codec_type`、`main_url`、`spade_a` 等字段。

- 媒体地址按 `key_seed` 处理；`spade_a` 用于内容密钥派生，密钥与原始地址不写进文档。
- 已观测 360/480/576/720/1080 档位；低档出现 bytevc2，不代表已被引擎支持。当前过滤 bytevc2/bvc2。
- bytevc1 对应本次媒体中的 HEVC；清晰度优先依据实际宽高较小边，不能只信 UI 标签。
- Windows 已对前两集 1080P 下载、拼接、完整音视频解码验收；不能据此宣称所有剧集或自研 Android 全设备流程都已验收。

## 5. 已失败的旧取流入口

`POST /novel/player/video_model/v1/`：在 guoguo-juku 的 native media 实现中存在，本项目早期简化签名请求曾返回空正文。只更换成批量路径或只更换设备 ID 也曾失败；成功来自完整请求链路，不能恢复旧方案后宣称等价。

## 6. 首次访客注册

2026-11-02 已实测入口：`POST https://log5-applog.fqnovel.com/service/2/device_register/?tt_data=a&okhttp_version=4.2.243.31-douyin&use_store_region_cookie=1`

历史入口 `log.snssdk.com` 的旧实验、仅 gzip 的 `tt_data=b` 均未取得有效身份，不是当前实现。独立雷电空白实例中已取得官方首次注册请求与非零响应，并成功解码其 TTEncrypt 正文。

正文为 TTEncrypt(gzip(JSON))；JSON 含 `magic_tag=ss_app_log`、`header`、`_gen_time`。header 包括 App、协议设备参数、语言、时区及全新随机 `cdid / openudid / clientudid / req_id`。观察到 SDK `3.7.0-rc.34-fanqie-xiaoshuo`，`custom` 包括 `account_region_src / host_bit / account_region / dragon_device_type`；简化体省略 custom 的实验未成功，不把未知字段随意裁掉。

请求使用 `Content-Type: application/octet-stream;tt-data=a`、`log-encode-type: gzip`、编码后正文的 `x-ss-stub`、`x-ss-req-ticket` 与 SDK/UA 头。独立请求不需要复制官方 `x-neptune`，也不携带账号 Cookie。响应核对 `device_id_str / install_id_str` 非零、长度与格式合法；仅 HTTP 200 不算初始化成功。

实现为跨端 Dart `lib/data/visitor_identity.dart`，使用现有 SHA-512 / AES 库封装协议，不要求 Python、Java 或 Node 注册服务。每次安装的身份写入应用支持目录 `data/visitor-v1.json`，并发共享初始化，重启复用；失败不覆盖已有文件。注册最多尝试两次，403/429 不自动重试；取流 HTTP 200 空正文最多重建一次身份后重试一次，仍失败则报错。Android 播放签名桥接显式保留注册身份，禁止再随机覆盖 Dart 传入的 ID。旧 search-visitor.json 不作为发布版身份来源。

注册返回 ID 为 0 时禁止生成假身份替代，禁止内置抓包中单台设备的身份。访客注册与账号登录是两件事，当前修复不要求用户登录账号。
