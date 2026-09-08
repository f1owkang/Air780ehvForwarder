# AGENTS.md

## 项目概述

基于 LuatOS 的短信转发器固件（纯 Lua，无构建系统、无自动化测试，验证只能真机烧录看串口日志）。接收短信后按 `config.lua` 中 `FORWARD_RULES` 的规则匹配（关键词或 Lua pattern），转发到企业微信/飞书/钉钉/自定义 webhook/邮件/QQ 等渠道。**全部源码位于 `script/` 目录**（Luatools 烧录时直接选择该文件夹）；文档统一在 `docs/`（CHANGELOG、硬件手册、设计文档），根目录仅保留 README / AGENTS / LICENSE。

## Git 与签名

- 仓库托管于 [f1owkang/Air780ehvForwarder](https://github.com/f1owkang/Air780ehvForwarder)（main 分支）；push 等对外发布操作需用户明确指示后执行。
- 提交必须 GPG 签名：优先直接 `git commit -S` 使用现有配置，仅当签名失败时才排查，不要预先改动密钥配置。
- 签名证书存于智能卡（不可导出），无需也无法读出私钥。

## 安全红线

- 禁止读取、打印或复制任何真实凭据：`config.lua` 等文件中的 webhook key / secret / SMTP 密码 / `QQBOT_SECRET`（示例占位符除外），以及 GPG/SSH 私钥等本机凭据。
- 对外发送与发布操作（git push、上传文件、向真实 webhook 地址发调试请求）必须先获得用户明确指示，不得自行执行。

**目标硬件：Air780EHV**（用户确认，使用 LuatOS-SoC_V2050 的 101 号 64 位固件）。本项目改编自 Air780E/EP 的上游工程，`PROJECT` 已更正为 `air780ehv_forwarder`。硬件问题先查 `docs/Air780EHV硬件手册V1.1.pdf`。

## 运行与验证方式

- 代码只能在 LuatOS 固件环境（设备上）运行，无法在 PC 本地跑：依赖 `sys`/`sysplus`/`log`/`mobile`/`sms`/`socket`/`fskv`/`crypto`/`json`/`http`/`uart`/`libnet` 等全局 API。
- 烧录用 LuatOS 官方 Luatools 工具，脚本直接选择 `script` 文件夹；日志通过串口/USB 查看（`log.setLevel("DEBUG")`）。
- 验证改动只能靠烧录后看串口日志，没有自动化验证手段。

## 文件结构与职责

源码全部位于 `script/` 目录：

- `main.lua` — 入口。看门狗（9 秒超时、3 秒喂狗）、DNS、短信回调、电源键事件、来电通知（CC_IND）、定时任务（SNTP/飞行模式/重启）、SLAVE 模式串口转发。
- `config.lua` — **唯一配置文件**，五节：系统与网络（超时、定时任务、FLYMODE、`POWERKEY_PIN`）/ Qbot（`QQBOT_*`）/ 短信控制安全（`SMS_ADMIN_NUMBERS`）/ 转发规则（`FORWARD_RULES`）/ 备用通知（`FEISHU_WEBHOOK` 等）。**可能含真实 webhook/secret/SMTP 密码，属敏感信息，不要外传或写入公开文档。**
- `util_forward.lua` — 转发引擎：`matchRule()`（keyword 不区分大小写部分匹配 / regular 为区分大小写的 Lua pattern，二选一；`"all"` 匹配全部）、`sendByChannel()` 及 wecom/feishu/dingding/custom_post 的实现函数都在本文件内；email 渠道委托给 `util_smtp.send(rule, msg)`。
- `util_notify.lua` + `util_channel.lua` — 备用通知队列（转发失败、来电等走这里）。队列轮询 + 重试，`#SMS`/`#CALL` 消息失败后会写入 fskv 断电恢复。渠道实现按 key 索引，配置键在 `config.lua` 第 5 节（默认留空 = 未启用，默认渠道为 feishu）。
- `util_smtp.lua` — SMTP 邮件（AUTH LOGIN，SSL 465 / 明文 25，正文 base64）。
- `util_http.lua` — 对 `http.request` 的统一封装 `fetch(timeout, method, url, headers, body)`，所有 HTTP 必须走它（会联动网络 LED 和 GC）。
- `util_mobile.lua` — 本机号码/IMEI/IMSI/ICCID/运营商/信号（RSRP+CSQ）/流量查询短信/PIN 验证/`appendDeviceInfo()`。
- `util_qqbot.lua` — Qbot 通道（设备直连，API v2 wss 网关协议：token 鉴权、IDENTIFY/RESUME、心跳、指数退避重连、openid 白名单、指令路由、被动回复）。交互走被动回复；短信通知可经转发规则 `qq` 渠道主动推送（`pushToUser`/`pushToGroup`，仅需 token，不依赖 wss 连接，频控每好友/群 1000 条/天）。配置在 `config.lua` 的 `QQBOT_*` 键。REST 请求强制域名白名单 + URL 校验（http/https、拒绝 IP 字面量/userinfo/显式端口），新增外发请求必须走同样的校验。
- `util_sms_store.lua` — fskv 持久化的最近短信环形缓存（20 条），main.lua 短信回调写入，Qbot `短信` 指令读取。
- `util_location.lua` — 基站定位；`util_netled.lua` — 网络状态 LED；`util_task.lua` — 命名任务管理（pcall 包裹、`createLoop`、重启前 `cleanupAllTasks()` 会用到）。
- README.md 是面向用户的配置说明，`docs/CHANGELOG.md` 记录版本。
- `.mimosa/` 是扫描工具生成的目录，非项目代码。

## 两条消息通路（重要边界）

1. **规则转发**：`config.FORWARD_RULES` 规则 → `util_forward.forwardSms()/forwardMessage()` → `sendByChannel()`（实现在 util_forward.lua）。渠道名：`wecom`、`feishu`、`dingding`、`custom_post`、`email`、`qq`（qq 渠道由 `util_qqbot.pushToUser/pushToGroup` 实现，util_forward 通过全局变量调用以避免循环 require）。
2. **备用通知**：`util_notify.add(msg, channels)` → `util_channel.lua`。渠道 key：`custom_post`、`dingtalk`、`feishu`、`wecom`、`serial`，配置在 `config.lua`。

⚠️ 命名陷阱：规则转发用 `dingding`，备用通知用 `dingtalk`。添加新渠道时两套体系要分别接入：规则转发改 `util_forward.lua`，备用通知改 `util_channel.lua`。

## LuatOS 协程规范（改代码必守）

- 所有阻塞/异步操作（HTTP、sys.wait、SMTP）必须在 `sys.taskInit()` 或任务协程内执行；**严禁在回调（GPIO 中断、sms 回调、uart 回调）里直接 `sys.wait()`**。
- 消息转发靠 `sys.taskInit` 包裹的协程异步执行，多渠道间 `sys.wait(1000)` 限速。
- 内存敏感：`util_http.fetch` 前后都会 `collectgarbage("collect")`，另有每小时全局 GC——写新网络代码时保持该习惯。

## 代码约定

- 文件命名规范（2026-09 统一）：入口 `main.lua`；**所有配置集中在单一 `config.lua`**（含 `FORWARD_RULES` 转发规则段）；功能模块一律 `util_<名称>.lua`（如 `util_task.lua`、`util_channel.lua`）。新增文件必须遵循。
- 模块在 `main.lua` 中以全局变量加载（`config = require "config"`、`util_forward = require "util_forward"` 等），各模块直接引用全局 `config` 和 `log`——新增模块必须同步在 `main.lua` 按依赖顺序 require。
- 注释、日志、文档全部使用中文；日志用 `log.info/warn/error(模块名, ...)` 风格。
- 长任务用 `TaskManager.create/createLoop`（带 pcall 错误捕获），不要裸起协程。

## 硬件相关注意（Air780EHV）

- 用户固件：**LuatOS-SoC_V2050_Air780EHV_101.soc**（101 号 64 位），位于项目外 `..\..\resource\LuatOS_Air780EHV\LuatOS-SoC_V2050_Air780EHV\`。websocket 核心库在 Air780EHV"所有固件全部支持"列表中，101 号可用。
- `main.lua` 的 `pin_table` 目前只有 EC618/EC718P/AIR780E/AIR780EP/AIR780E4G 的电源键引脚，**没有 AIR780EHV 条目**——若 `rtos.bsp()` 返回值不匹配，电源键功能会被跳过（日志"未找到支持的平台电源键引脚配置"）。适配 EHV 时需实测 `rtos.bsp()` 返回值并补表，引脚定义查硬件手册 PDF。
- SLAVE 角色走 UART1@115200；短信控制指令格式 `SMS,接收号码,内容`，仅 `config.SMS_ADMIN_NUMBERS` 白名单号码可触发（空表全部拒绝），触发后转发消息尾加 `#CTRL` 标记。
