<div align="center">

# 📨 Air780EHV 短信转发器

**基于 LuatOS 的 Air780EHV 智能短信转发器 —— 短信一到，送达你的每个聊天软件**

![version](https://img.shields.io/badge/version-1.3.0-blue)
![chip](https://img.shields.io/badge/芯片-Air780EHV-green)
![platform](https://img.shields.io/badge/平台-LuatOS%20·%20Lua-orange)
![channel](https://img.shields.io/badge/转发渠道-6%20种-purple)
![license](https://img.shields.io/badge/license-Apache%202.0-green)

[功能特性](#功能特性) · [硬件要求](#硬件要求) · [快速开始](#快速开始) · [转发渠道](#转发渠道) · [Qbot-交互](#qbot-交互) · [已知问题](#已知问题) · [开源协议](#开源协议)

</div>

> [!WARNING]
> 请确保在合法合规的前提下使用本设备（如转发本人短信、服务器告警通知等），遵守相关法律法规。QQ 推送受官方频控：每好友/每群 20 条/分钟、1000 条/天。

## 模块简介

验证码、银行动账、服务器告警……插在抽屉旧手机里的 SIM 卡，短信总是错过。本项目把 SIM 卡装进 Air780EHV 4G 模组，运行 LuatOS 固件：**收到短信后按关键词或 Lua 正则匹配规则，异步转发**到企业微信、飞书、钉钉、自定义 webhook、邮件、QQ 等渠道；还可以在 QQ 里直接和设备对话——查状态、查最近短信、远程发短信。

转发失败进入备用通知队列自动重试并写入 fskv（断电可恢复）；网络异常自动开关飞行模式自救；看门狗、定时内存回收、可配置定时重启，专为长期无人值守设计。

## 功能特性

| 特性 | 说明 |
| --- | --- |
| 🎯 智能匹配 | `keyword` 关键词（不区分大小写）或 `regular` Lua 正则，二选一；一条短信可命中多条规则同时转发 |
| 📤 多渠道转发 | 企业微信 / 飞书 / 钉钉（支持加签）/ 自定义 POST / SMTP 邮件 / QQ 主动推送 |
| 💬 Qbot 交互 | 设备直连（无需服务器），QQ 单聊或群 @ 下发指令，被动回复不受频控限制 |
| 📊 设备信息附加 | 信号强度（RSRP/CSQ）、运营商、基站定位链接、开机时长自动附加到通知内容 |
| 🛡️ 容错机制 | 转发失败备用通知队列 + fskv 断电恢复；连续失败自动开关飞行模式恢复网络 |
| ⚡ 无人值守 | 硬看门狗（9s 超时）、定时内存回收、定时重启（默认 72h，重启前检查活跃任务） |
| 📟 多种控制入口 | 短信控制指令、QQ 指令、电源键短按/双击/长按快捷操作 |

## 硬件要求

- **模组**：Air780EHV（本项目目标芯片，实测 101 号固件）；同平台 Air780E / Air780EP 亦可
- **固件**：需包含 websocket 核心库（Air780EHV 各编号固件均自带）；本项目实测 **LuatOS-SoC_V2050_Air780EHV_101.soc**（101 号 64 位固件）
- **网络**：4G SIM 卡（注意确认流量卡是否支持收发短信）
- **供电**：3.3V–4.2V
- **工具**：[Luatools 烧录工具](https://luatos.com/luatools/download/last)

[推荐淘宝购买链接](https://item.taobao.com/item.htm?id=989345949846)

## 快速开始

1. **硬件连接**：SIM 卡插入卡槽，接好 4G 天线，USB 连接电脑；
2. **配置**：所有需要修改的配置**全部集中**在 [`script/config.lua`](script/config.lua) 一个文件，分五节——第 1~3 节（系统与网络 / Qbot / 短信控制安全）按需调整，第 4 节**转发规则 `FORWARD_RULES`** 至少配置一条渠道规则，第 5 节备用通知可选：

```lua
FORWARD_RULES = {
    -- 所有短信转发到企业微信
    {
        channel = "wecom",
        keyword = "all",
        webhook = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=your-key"
    },
}
```

3. **烧录**：Luatools 直接选择 `script` 文件夹导入全部脚本，固件选择 `LuatOS-SoC_V2050_Air780EHV_101.soc` 下载；
4. **验证**：向设备发送一条短信，目标渠道应收到消息；串口日志出现 `匹配到规则` 与 `转发成功` 即成功。

## 转发渠道

每条规则 = `channel` + 匹配字段（`keyword` / `regular` 二选一）+ 渠道专属字段，写在 [`script/config.lua`](script/config.lua) 第 4 节 `FORWARD_RULES`：

| 渠道 | channel 值 | 专属字段 |
| --- | --- | --- |
| 企业微信 | `wecom` | `webhook` |
| 飞书 | `feishu` | `webhook`，可选 `secret` 签名 |
| 钉钉 | `dingding` | `webhook`，可选 `secret` 加签 |
| 自定义 POST | `custom_post` | `webhook`、`content_type`、`post_body`（`{msg}` 占位符会被替换为消息内容） |
| 邮件 | `email` | `smtp_server`、`smtp_port`、`smtp_ssl`、`smtp_username`、`smtp_password`、`email_from`、`email_to` |
| QQ 推送 | `qq` | `openid`（单聊）或 `group_openid`（群），需在 `config.lua` 配置 `QQBOT_APPID/SECRET` |

<details>
<summary>各渠道配置示例（点击展开）</summary>

```lua
-- 企业微信
{
    channel = "wecom",
    keyword = "all",
    webhook = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=your-webhook-key"
}

-- 飞书
{
    channel = "feishu",
    keyword = "验证码",
    webhook = "https://open.feishu.cn/open-apis/bot/v2/hook/your-webhook-id"
}

-- 钉钉（secret 可选，配置后走加签模式）
{
    channel = "dingding",
    keyword = "all",
    webhook = "https://oapi.dingtalk.com/robot/send?access_token=your-token",
    secret = "your-secret"
}

-- 自定义 POST
{
    channel = "custom_post",
    keyword = "百度",
    webhook = "https://your-api-endpoint.com/webhook",
    content_type = "application/json",
    post_body = {
        title = "通知标题",
        desp = "通知内容: {msg}"
    }
}

-- 邮件（SSL，适用于 QQ 邮箱/163/Gmail 等主流邮箱）
{
    channel = "email",
    keyword = "all",
    smtp_server = "smtp.qq.com",
    smtp_port = 465,
    smtp_ssl = true,
    smtp_username = "user@qq.com",
    smtp_password = "授权码",       -- QQ 邮箱需使用授权码而非登录密码
    email_from = "user@qq.com",
    email_to = "recipient@example.com"
}

-- QQ 单聊推送（openid 从设备串口日志"收到单聊消息"处获取）
{
    channel = "qq",
    keyword = "all",
    openid = "your-openid"
}

-- QQ 群推送（group_openid 从串口日志"收到群@消息"处获取）
{
    channel = "qq",
    keyword = "all",
    group_openid = "your-group-openid"
}
```
</details>

<details>
<summary>常用邮箱 SMTP 参数（点击展开）</summary>

| 邮箱 | SMTP 服务器 | 端口 | 说明 |
|------|-----------|------|------|
| QQ 邮箱 | smtp.qq.com | 465 | 需开启 SMTP 服务并获取授权码 |
| 163 邮箱 | smtp.163.com | 465 | 需开启 SMTP 服务并设置授权密码 |
| Gmail | smtp.gmail.com | 465 | 需启用应用专用密码 |
| Outlook | smtp.office365.com | 587 | 支持明文/STARTTLS 场景可设 `smtp_ssl = false` |
</details>

<details>
<summary>匹配规则与 Lua pattern 语法（点击展开）</summary>

- `keyword`：部分匹配、不区分大小写，消息中包含关键词即命中；`"all"` 匹配所有消息；
- `regular`：Lua pattern 正则，**区分大小写**，适合精确场景；与 `keyword` 二选一；
- 注意：Lua pattern **不支持 `|` 或语法**，匹配多个不同关键词请分别建规则。

```lua
-- 匹配以"验证码"开头的消息
{ channel = "feishu", regular = "^验证码", webhook = "https://..." }

-- 匹配 4-6 位连续数字（如验证码）
{ channel = "dingding", regular = "%d%d%d%d%d?%d?", webhook = "https://..." }
```

| 语法 | 说明 | 语法 | 说明 |
|------|------|------|------|
| `%d` | 数字 | `%a` | 字母 |
| `%w` | 字母+数字 | `%s` | 空白字符 |
| `.` | 任意字符 | `%l` / `%u` | 小写 / 大写字母 |
| `*` | 0 次或多次 | `+` | 1 次或多次 |
| `?` | 0 次或 1 次 | `^` / `$` | 开头 / 结尾 |
| `[set]` | 字符集 | `%` | 转义特殊字符 |
</details>

## Qbot 交互

设备直连 Qbot，无需任何服务器。在 QQ 里私聊或在群里 @它 即可下发指令；回复均为被动消息，不受主动消息频控限制。长连接心跳流量约 30–50MB/月。

**开启步骤：**

1. 在 [q.qq.com](https://q.qq.com/) 创建 Qbot，获取 **AppID** 和 **AppSecret**；
2. 修改 `config.lua`：

```lua
QQBOT_ENABLED = true,
QQBOT_APPID = "你的AppID",
QQBOT_SECRET = "你的AppSecret",
QQBOT_ALLOW = {},  -- 先留空
```

3. 烧录后在 QQ 给机器人发一条消息，从串口日志 `收到单聊消息 openid XXXXX` 中复制你的 openid；
4. 填入白名单并重新烧录：

```lua
QQBOT_ALLOW = { "你的openid" },
```

**指令一览：**

| 指令 | 说明 |
|------|------|
| `帮助` / `help` | 指令列表 |
| `状态` / `status` | 信号、运营商、内存、转发规则数、短信缓存数 |
| `短信 [N]` / `sms [N]` | 最近收到的 N 条短信（默认 5，上限 20，fskv 持久化） |
| `重载规则` / `reload` | 重新加载转发规则 |
| `测试` / `test` | 触发一次测试转发 |
| `发短信 号码 内容` | 通过设备 SIM 卡发送短信 |

群聊使用需把机器人拉入群并 @它；白名单对单聊用户与群成员统一生效（群成员 openid 同样在串口日志中打印）。

## 已知问题

- `main.lua` 的电源键引脚表（`pin_table`）尚未收录 AIR780EHV 条目——若 `rtos.bsp()` 返回值不匹配，在 `config.lua` 的 `POWERKEY_PIN` 手动填写引脚即可（查硬件手册），无需改代码，也不影响转发主流程；
- 备用通知为兜底通道（转发规则失败/来电时启用），需在 `config.lua` 第 5 节填入 `FEISHU_WEBHOOK` 等地址后才会生效，默认留空不启用；
- Qbot 的事件权限与个人开发者沙箱限制需以你的机器人实际权限为准，鉴权失败会在串口日志体现（连续断开重连）。

## 进阶用法

<details>
<summary>如何添加新的转发渠道？</summary>

1. 在 `util_forward.lua` 中实现渠道发送函数；
2. 在 `sendByChannel()` 中添加 `channel` 判断分支；
3. 在 `config.lua` 的 `FORWARD_RULES` 段补充配置示例。
</details>

<details>
<summary>如何使用短信控制与电源键操作？</summary>

**短信控制**：向设备发送 `SMS,接收号码,短信内容` 格式的短信（支持国际号码），仅 **`config.lua` 第 3 节 `SMS_ADMIN_NUMBERS` 白名单中的管理员号码**可触发（空表全部拒绝，首次触发时串口日志会打印发件号码）；触发后设备代发，并在转发内容尾部附加 `#CTRL` 标记：

```
SMS,13800138000,这是一条测试短信
```

**电源键操作**（需 `pin_table` 已支持当前平台）：

| 操作 | 动作 |
|------|------|
| 短按 | 发送测试消息 `#ALIVE` |
| 双击 | 发送开机测试消息 `#BOOT_TEST_xxx` |
| 长按 | 查询流量（向运营商发送查询短信） |
</details>

<details>
<summary>如何监控状态与排障？</summary>

**信号强度判读**（通知中自动附加）：

| RSRP (dBm) | 状态 |
|------------|------|
| -50 ~ -80 | 信号优秀 |
| -80 ~ -90 | 信号良好 |
| -90 ~ -100 | 信号一般 |
| < -100 | 信号较差 |

**常见问题：**

1. *无法接收短信*：检查 SIM 卡是否插好、信号强度、是否已注册网络；
2. *转发失败*：检查 webhook URL、网络连接、目标渠道服务状态；
3. *设备频繁重启*：检查供电稳定性、看门狗配置、内存状况。

**调试命令**（串口 REPL 或临时脚本）：

```lua
-- 查看网络与信号
log.info("signal", mobile.rsrp(), mobile.csq())

-- 发送测试消息（经转发规则）
util_forward.forwardMessage("#TEST_MESSAGE", "TEST")

-- 查看设备标识
log.info("device", util_mobile.getDeviceIdentityText())
```
</details>

<details>
<summary>主从机串口转发（ROLE = SLAVE）</summary>

`config.lua` 中 `ROLE = "SLAVE"` 时，设备配置 UART1@115200，通过串口转发数据（用于主机代为联网的场景）；默认 `MASTER` 独立工作，无需改动。
</details>

## 更新日志

详见 [docs/CHANGELOG.md](docs/CHANGELOG.md)。

## 致谢

- 上游项目 [lostmaniac/air780e_forwarder](https://github.com/lostmaniac/air780e_forwarder)（MIT License, Copyright (c) lostmaniac——本项目衍生部分的原版权声明同样适用）
- [LuatOS](https://luatos.com) 及合宙开源社区

## 开源协议

[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)

---

<div align="center">

Made with ❤ · air780ehv_forwarder

</div>
