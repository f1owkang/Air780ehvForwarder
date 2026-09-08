# 更新日志

## v1.3.0 (2026-09-08)

### 新功能

- **Qbot 交互通道**：设备直连 QQ 官方机器人（无需服务器），在 QQ 单聊或群 @机器人 即可下发指令
  - 基于 LuatOS websocket 库实现 API v2 网关协议（Access Token 鉴权、IDENTIFY/RESUME、心跳保活、指数退避重连）
  - 指令：帮助 / 状态 / 短信 [N] / 重载规则 / 测试 / 发短信 号码 内容
  - 指令系统升级为表驱动：新增 信号/设备/定位/流量/时间/规则/飞行模式/重启(二次确认)；帮助菜单按分组自动生成
  - 输入体验：全角自动转半角、/ 前缀容忍、群聊 @前缀剥离、空输入(只@)返回菜单、未知指令前缀建议
  - openid 白名单防未授权操控；非白名单用户自动回复欢迎消息（含其 openid 与配置指引），每 openid 最多 3 次防刷；REST 请求强制域名白名单与 URL 校验
  - 新增 `util_sms_store.lua`：fskv 持久化的最近短信环形缓存（20 条，断电不丢）
  - 配置项：`QQBOT_ENABLED / QQBOT_APPID / QQBOT_SECRET / QQBOT_ALLOW`
  - 短信通知仍走转发规则渠道；如需推送到 QQ，使用下方 qq 转发渠道

- **QQ 推送渠道**：转发规则新增 `channel = "qq"`，短信可主动推送到 QQ 单聊（`openid`）或群（`group_openid`）
  - 仅依赖 Access Token，wss 断连不影响推送，与 webhook 渠道互为备份
  - 官方频控：每好友/每群 20 条/分钟、1000 条/天

### 安全修复

- `SMS,号码,内容` 短信控制指令增加管理员号码白名单 `SMS_ADMIN_NUMBERS`（空表全部拒绝；修复任意发件人均可触发设备发短信、消耗话费的问题）

### 规范化

- 源代码统一移入 `script/` 目录（Luatools 烧录直接选择该文件夹）；文档与硬件手册收拢至 `docs/`，根目录仅保留 README / AGENTS / LICENSE
- 采用 Apache 2.0 协议（与 GitHub 仓库一致）；上游 air780e_forwarder 为 MIT，其版权声明在 README 致谢中保留
- 表述统一：文档/注释/日志中"QQ 机器人"简化为 **Qbot**（代码标识符 `QQBOT_*`、`util_qqbot`、渠道名 `qq` 不变）
- 代码清洁：删除过时的 AGENT.md（以 AGENTS.md 为准）；移除 `util_notify` 无实际功能的 storage 占位任务；备用通知配置键（`FEISHU_WEBHOOK` 等）并入 `config.lua` 第 5 节（默认留空）
- 配置集中化：所有用户配置合并到 `config.lua` 单文件，分五节（系统与网络 / Qbot / 短信控制安全 / 转发规则 `FORWARD_RULES` / 备用通知），移除 `config_forward.lua`
- 新增 `POWERKEY_PIN` 配置项：`pin_table` 未收录的平台（如 Air780EHV）可直接在配置中指定电源键引脚，无需改代码
- 文件更名：`forward_config.lua`→`config_forward.lua`（后并入 config.lua）、`task_manager.lua`→`util_task.lua`、`util_notify_channel.lua`→`util_channel.lua`
- 命名规范统一：入口 `main.lua`，配置 `config.lua`，模块 `util_*.lua`；main.lua 全局 `TaskManager` 更名为 `util_task`
- `PROJECT` 更正为 `air780ehv_forwarder`（与实际芯片一致）

### Bug 修复

- 修复 LuatOS 固件 `tonumber(nil)` 直接抛错导致的问题：未收到短信时 `状态` 指令崩溃；**首条短信会使回调中断、影响转发**——短信缓存读写改为类型检查读取，`save()` 整体 pcall 包裹，缓存故障不再影响转发主流程
- token 有效期解析增加类型防御

### 新功能（v1.3.0 续）

- **Qbot markdown 回复**：新增 `QQBOT_MARKDOWN` 配置（默认关闭），开启后菜单/状态等回复以 markdown 格式发送（标题与分组加粗）；机器人无 markdown 权限时自动回退纯文本并本次会话记住

---

## v1.2.0 (2026-04-09)

### 新功能

- **SMTP邮件转发**：新增邮件转发渠道（`channel = "email"`），支持将短信转发到指定邮箱
  - 支持 SSL/TLS 加密连接（端口 465），适用于QQ邮箱、163邮箱、Gmail等主流邮箱
  - 支持明文连接（端口 25），适用于内网邮件服务器
  - 邮件标题和正文支持 UTF-8 编码
  - SMTP配置写在每条转发规则中，支持不同规则转发到不同邮箱
  - 使用 AUTH LOGIN 认证方式

---

## v1.1.0 (2026-04-09)

### 新功能

- **正则表达式匹配**：转发规则新增 `regular` 字段，支持 Lua 正则模式匹配（区分大小写），与原有 `keyword` 关键词匹配互斥使用
- 双击检测改为延迟机制，避免双击时同时触发单击动作

### Bug 修复

- 修复 `getMccMnc()` 在 IMSI 为空时返回空字符串而非 `-1` 的问题
- 修复 `cache.lbs_data` 初始化为 named keys 导致 `unpack()` 无法正确取值的问题
- 修复备用通知中飞行模式恢复未检查 `FLYMODE_ENABLE` 配置开关的问题
- 修复 `util_notify.send()` 在 channel 为 nil 时崩溃的问题
- 修复 `queryTraffic()` 被误传无用参数的问题
- 移除串口回调中不可达的 MASTER 分支死代码

---

## v1.0.0

- 增加对电源键引脚的支持，优化电源键事件处理及日志记录
- 改进自定义POST请求的日志和状态码处理
- 修正重启间隔配置，确保重启间隔为72小时
- 修改重启配置，默认每隔7天重启一次
- 增加多种转发示例
- 首次上传
