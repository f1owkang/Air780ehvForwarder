-- Qbot 交互通道 (设备直连 QQ 官方机器人, 无需服务器)
-- 流程: AppID+Secret 换 Access Token -> 取 wss 网关 -> IDENTIFY 鉴权 -> 心跳保活 -> 收消息 -> 指令处理 -> 被动回复
-- 协议文档: https://bot.q.qq.com/wiki/develop/api-v2/
-- 说明: 交互指令走被动回复; 短信通知可经转发规则 qq 渠道主动推送

local util_http = require "util_http"
local util_mobile = require "util_mobile"
local util_location = require "util_location"
local util_forward = require "util_forward"
local util_sms_store = require "util_sms_store"
local TaskManager = require "util_task"

local util_qqbot = {}

-- intents: GROUP_AND_C2C_EVENT (1 << 25), 一个位同时订阅单聊 C2C_MESSAGE_CREATE 和群@ GROUP_AT_MESSAGE_CREATE
local INTENTS_GROUP_C2C = 33554432

-- 非白名单用户欢迎消息的每 openid 回复上限 (防刷)
local WELCOME_MAX = 3

-- REST 接口允许访问的域名白名单
local REST_HOSTS = {
    ["api.bot.qq.com"] = true,     -- 换取 access token
    ["api.sgroup.qq.com"] = true,  -- 网关地址与被动回复接口
}

local TASK_MAIN = "qqbot_main"
local TASK_WATCHDOG = "qqbot_watchdog"
local EVT = "QQBOT_INTERNAL_EVENT"

-- ===== 运行状态 =====
local state = "OFFLINE"        -- OFFLINE/CONNECTING/AUTHING/RUNNING
local wsc = nil
local session_id = nil         -- 会话 ID, RESUME 恢复用
local last_seq = nil           -- 服务端最新序号 s
local resume_fail = 0
local identify_fail = 0
local auth_style = 1           -- 1: QQBot <token>; 2: Bot <appid>.<secret> (旧格式回退)
local backoff_ms = 3000
local heartbeat_timer = nil
local heartbeat_interval = nil -- 毫秒
local last_ack_time = 0        -- mcu.ticks(), 心跳 ACK 监控用
local recent_msg_ids = {}      -- msg_id 去重环形缓存
local welcome_count = {}       -- openid -> 已回复欢迎消息次数 (内存计数, 重启清零)
local pending_confirm = {}     -- openid -> { action, expire } 危险指令二次确认 (mcu.ticks 毫秒)

local access_token = nil
local token_expire_at = 0      -- os.time() 秒
local md_available = nil       -- markdown 可用性: nil=未测, true/false 本次会话内有效
local kb_available = nil       -- 按钮键盘可用性: nil=未测, true/false 本次会话内有效

local onDisconnected           -- 前向声明, 见下方实现

-- ===== 工具 =====

--- 按字节截断字符串, 保证不把 UTF-8 多字节字符切成两半
local function utf8Sub(s, max_bytes)
    if type(s) ~= "string" or #s <= max_bytes then
        return s or ""
    end
    local i = max_bytes
    while i > 0 do
        local b = s:byte(i)
        if b and (b < 0x80 or b >= 0xC0) then
            break
        end
        i = i - 1
    end
    return s:sub(1, i) .. "…"
end

--- markdown 样式: 开启 QQBOT_MARKDOWN 时返回粗体, 纯文本模式原样返回
local function mdBold(s)
    return config.QQBOT_MARKDOWN and ("**" .. s .. "**") or s
end

--- markdown 内联代码: 开启 QQBOT_MARKDOWN 时渲染为等宽代码框, 纯文本模式原样返回
local function mdCode(s)
    return config.QQBOT_MARKDOWN and ("`" .. s .. "`") or s
end

--- 去除 markdown 样式符号 (无权限回退纯文本时使用, 避免显示 ** 和 ` 字符)
local function stripMd(s)
    return (tostring(s):gsub("%*%*", ""):gsub("`", ""))
end

--- 校验外发 REST URL: 仅 http/https 且 host 必须在白名单内 (拒绝 localhost/环回/私网/保留地址等一切非白名单目标)
local function checkRestUrl(url)
    if type(url) ~= "string" then
        return false
    end
    local scheme, host = url:match("^(https?)://([^/^?#]+)")
    if not scheme or not host then
        return false
    end
    host = host:lower()
    if host:find("@") or host:find(":") then
        return false    -- 拒绝 userinfo 和显式端口/IPv6 字面量
    end
    return REST_HOSTS[host] == true
end

--- 校验服务端下发的 wss 网关地址: 仅 ws/wss + *.qq.com 域名, 拒绝 IP 字面量(含环回/私网/保留地址)
local function checkGatewayUrl(url)
    if type(url) ~= "string" then
        return false
    end
    local scheme, host = url:match("^(wss?)://([^/^?#]+)")
    if not scheme or not host then
        return false
    end
    host = host:lower()
    if host:find("@") or host:find(":") then
        return false
    end
    if host:match("^%d+%.%d+%.%d+%.%d+$") then
        return false    -- 拒绝 IP 直连
    end
    return host:match("%.qq%.com$") ~= nil
end

-- ===== 鉴权与 REST =====

--- 获取 access token (带缓存, 有效期剩余 120 秒内才重新请求)
local function fetchToken()
    if access_token and os.time() < token_expire_at - 120 then
        return access_token
    end

    local url = "https://api.bot.qq.com/app/getAppAccessToken"
    if not checkRestUrl(url) then
        return nil
    end

    local headers = { ["Content-Type"] = "application/json" }
    local body = json.encode({ appId = config.QQBOT_APPID, clientSecret = config.QQBOT_SECRET })
    local code, _, resp = util_http.fetch(config.NETWORK_TIMEOUT_SHORT, "POST", url, headers, body)

    if code ~= 200 or type(resp) ~= "string" or resp == "" then
        log.error("util_qqbot", "获取 access token 失败", "code", code, "resp", resp)
        return nil
    end

    local ok, data = pcall(json.decode, resp)
    if not ok or type(data) ~= "table" or type(data.access_token) ~= "string" then
        log.error("util_qqbot", "access token 响应异常", resp)
        return nil
    end

    local expires = 7200
    if type(data.expires_in) == "string" or type(data.expires_in) == "number" then
        expires = tonumber(data.expires_in) or 7200
    end
    access_token = data.access_token
    token_expire_at = os.time() + expires
    log.info("util_qqbot", "access token 已更新, 有效期", expires .. "s")
    return access_token
end

--- 调用 api.sgroup.qq.com 接口 (自动携带鉴权, 401 时刷新 token 重试一次)
local function qqApi(method, path, body_table)
    local url = "https://api.sgroup.qq.com" .. path
    if not checkRestUrl(url) then
        log.error("util_qqbot", "URL 校验失败, 拒绝请求", url)
        return nil
    end

    for attempt = 1, 2 do
        local token = fetchToken()
        if not token then
            return nil
        end
        local headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "QQBot " .. token,
        }
        local body = body_table and json.encode(body_table) or nil
        local code, _, resp = util_http.fetch(config.NETWORK_TIMEOUT_SHORT, method, url, headers, body)
        if code == 401 and attempt == 1 then
            log.warn("util_qqbot", "token 失效, 刷新后重试")
            access_token = nil
        else
            return code, resp
        end
    end
end

--- 获取 wss 网关地址 (校验合法后才允许连接)
local function fetchGateway()
    local code, resp = qqApi("GET", "/gateway")
    if code ~= 200 or type(resp) ~= "string" or resp == "" then
        log.error("util_qqbot", "获取网关地址失败", "code", code, "resp", resp)
        return nil
    end
    local ok, data = pcall(json.decode, resp)
    if not ok or type(data) ~= "table" or not checkGatewayUrl(data.url) then
        log.error("util_qqbot", "网关地址校验失败, 拒绝连接", resp)
        return nil
    end
    log.info("util_qqbot", "网关地址", data.url)
    return data.url
end

--- 发送消息 (被动/主动通用): markdown -> 按钮键盘逐级降级 (md+按钮 -> 纯md -> 纯文本), 失败自动记住
local function postMessage(path, content, msg_id, seq, keyboard)
    local function trySend(with_md, with_kb, text)
        text = text or content
        local b = {}
        if with_md then
            b.msg_type = 2
            b.markdown = { content = text }
            if with_kb and keyboard then
                b.keyboard = { content = keyboard }
            end
        else
            b.msg_type = 0
            b.content = text
        end
        if msg_id then
            b.msg_id = msg_id
            b.msg_seq = seq or 1
        end
        local code, resp = qqApi("POST", path, b)
        local ok = type(code) == "number" and code >= 200 and code < 300
        return ok, code, resp
    end

    -- 未开启 markdown: 纯文本直接发送
    if config.QQBOT_MARKDOWN ~= true then
        local _, code, resp = trySend(false, false)
        return code, resp
    end

    -- 1) markdown + 按钮键盘
    if keyboard and config.QQBOT_BUTTONS == true and kb_available ~= false then
        local ok, code, resp = trySend(true, true)
        if ok then
            md_available, kb_available = true, true
            return code, resp
        end
        log.warn("util_qqbot", "markdown+按钮发送失败, 去掉按钮重试", "code", code, "resp", resp)
        kb_available = false
    end

    -- 2) 纯 markdown (本次会话已确认不可用则跳过)
    if md_available ~= false then
        local ok, code, resp = trySend(true, false)
        if ok then
            md_available = true
            return code, resp
        end
        log.warn("util_qqbot", "markdown 发送失败, 回退纯文本", "code", code, "resp", resp)
        md_available = false
    end

    -- 3) 纯文本 (去除 markdown 样式符号)
    local _, code, resp = trySend(false, false, stripMd(content))
    return code, resp
end

-- ===== WebSocket 网关协议 =====

local function wsSendRaw(text)
    if wsc and wsc:ready() then
        return wsc:send(text)
    end
    return false
end

local function buildTokenValue()
    if auth_style == 1 then
        return "QQBot " .. (access_token or "")
    end
    return "Bot " .. config.QQBOT_APPID .. "." .. config.QQBOT_SECRET
end

local function sendIdentify()
    if auth_style == 1 and not access_token then
        return false
    end
    state = "AUTHING"
    local payload = json.encode({
        op = 2,
        d = {
            token = buildTokenValue(),
            intents = INTENTS_GROUP_C2C,
            shard = { 0, 1 },
            properties = {
                ["$os"] = tostring(rtos.bsp()),
                ["$browser"] = "air780ehv_forwarder",
                ["$device"] = tostring(rtos.bsp()),
            },
        },
    })
    log.info("util_qqbot", "发送 IDENTIFY, style =", auth_style)
    return wsSendRaw(payload)
end

local function sendResume()
    if not session_id or not last_seq then
        return sendIdentify()
    end
    state = "AUTHING"
    local payload = json.encode({
        op = 6,
        d = {
            token = buildTokenValue(),
            session_id = session_id,
            seq = last_seq,
        },
    })
    log.info("util_qqbot", "发送 RESUME, seq =", last_seq)
    return wsSendRaw(payload)
end

local function sendHeartbeat()
    if state ~= "AUTHING" and state ~= "RUNNING" then
        return
    end
    if last_seq then
        wsSendRaw(string.format('{"op":1,"d":%d}', last_seq))
    else
        wsSendRaw('{"op":1,"d":null}')
    end
end

local function stopHeartbeat()
    if heartbeat_timer then
        sys.timerStop(heartbeat_timer)
        heartbeat_timer = nil
    end
end

local function startHeartbeat()
    stopHeartbeat()
    if not heartbeat_interval or heartbeat_interval < 5000 then
        heartbeat_interval = 30000
    end
    heartbeat_timer = sys.timerLoopStart(sendHeartbeat, heartbeat_interval)
    log.info("util_qqbot", "心跳已启动, 间隔", heartbeat_interval .. "ms")
end

-- ===== 消息与指令 =====

--- msg_id 去重 (QQ 可能重推同一条消息)
local function isDuplicate(msg_id)
    if not msg_id then
        return false
    end
    for _, v in ipairs(recent_msg_ids) do
        if v == msg_id then
            return true
        end
    end
    table.insert(recent_msg_ids, msg_id)
    if #recent_msg_ids > 16 then
        table.remove(recent_msg_ids, 1)
    end
    return false
end

--- openid 白名单校验
local function isAllowed(openid)
    if type(config.QQBOT_ALLOW) ~= "table" then
        return false
    end
    for _, v in ipairs(config.QQBOT_ALLOW) do
        if v == openid then
            return true
        end
    end
    return false
end

local function buildStatus()
    local lines = { "📊 " .. mdBold("设备状态") }

    local rsrp, csq = mobile.rsrp(), mobile.csq()
    if rsrp and rsrp ~= 0 then
        local sig = "信号: " .. rsrp .. "dBm (RSRP)"
        if csq and csq >= 0 and csq <= 31 then
            sig = sig .. " CSQ:" .. csq
        end
        lines[#lines + 1] = sig
    else
        lines[#lines + 1] = "信号: 获取失败"
    end

    local oper = util_mobile.getOper(true)
    lines[#lines + 1] = "运营商: " .. (oper ~= "" and oper or "未知")
    lines[#lines + 1] = "网络: " .. util_mobile.status()

    local sec = math.floor(mcu.ticks() / 1000)
    lines[#lines + 1] = string.format("开机时长: %02d:%02d:%02d",
        math.floor(sec / 3600), math.floor((sec % 3600) / 60), sec % 60)

    lines[#lines + 1] = "Lua 内存: " .. string.format("%.1f", collectgarbage("count")) .. " KB"
    lines[#lines + 1] = "转发规则: " .. #(util_forward.getRules() or {}) .. " 条"
    lines[#lines + 1] = "短信缓存: " .. util_sms_store.count() .. " 条"
    lines[#lines + 1] = "Qbot 通道: " .. state
    return table.concat(lines, "\n")
end

-- ===== 指令系统 (表驱动, 帮助菜单自动生成) =====

--- 全角转半角 (字母/数字/标点), 全角空格转普通空格
local function toHalfWidth(s)
    local ok, out = pcall(function()
        local t = {}
        for _, cp in utf8.codes(s) do
            if cp >= 0xFF01 and cp <= 0xFF5E then
                cp = cp - 0xFEE0
            elseif cp == 0x3000 then
                cp = 0x20
            end
            t[#t + 1] = utf8.char(cp)
        end
        return table.concat(t)
    end)
    return ok and out or s
end

--- 指令输入归一化: 去 @前缀/斜杠前缀, 全角转半角, 空白合一, 去首尾
local function normalizeInput(raw)
    local s = toHalfWidth(tostring(raw or ""))
    s = s:gsub("^@%S+%s*", "")    -- 群聊 @机器人 前缀残留
    s = s:gsub("^[/\\]+", "")     -- / 前缀容忍
    s = s:gsub("%s+", " ")
    s = s:gsub("^ ", ""):gsub(" $", "")
    return s
end

local function buildSignal()
    local rsrp, csq = mobile.rsrp(), mobile.csq()
    if rsrp and rsrp ~= 0 then
        local s = "📶 RSRP: " .. rsrp .. " dBm"
        if csq and csq >= 0 and csq <= 31 then
            s = s .. "  CSQ: " .. csq
        end
        if rsrp >= -80 then s = s .. "（优）"
        elseif rsrp >= -90 then s = s .. "（良）"
        elseif rsrp >= -100 then s = s .. "（一般）"
        else s = s .. "（差）" end
        return s
    end
    return "❌ 信号获取失败"
end

local function buildDeviceInfo()
    local lines = { "📱 " .. mdBold("设备信息") }
    local id_text = util_mobile.getDeviceIdentityText()
    if id_text ~= "" then
        lines[#lines + 1] = id_text
    end
    local number = util_mobile.getLocalNumber(2, 1000)
    if number then
        lines[#lines + 1] = "本机号码: " .. number .. " (系统获取)"
    elseif config.FALLBACK_LOCAL_NUMBER ~= "" then
        lines[#lines + 1] = "本机号码: " .. config.FALLBACK_LOCAL_NUMBER .. " (备用配置)"
    else
        lines[#lines + 1] = "本机号码: 未知"
    end
    return table.concat(lines, "\n")
end

local function buildTimeInfo()
    local synced = os.time() > 1714500000
    return "🕐 设备时间：" .. os.date("%Y-%m-%d %H:%M:%S") .. (synced and "（已同步）" or "（未同步）")
end

--- 转发规则列表 (目标地址/标识打码)
local function buildRulesList()
    local rules = util_forward.getRules() or {}
    if #rules == 0 then
        return "📭 未配置转发规则（config.lua 第 4 节 FORWARD_RULES）"
    end
    local lines = { "📋 " .. mdBold("转发规则") .. "（" .. #rules .. " 条）" }
    for i, r in ipairs(rules) do
        local match_desc = r.regular and ("正则:" .. r.regular)
            or (r.keyword and ("关键词:" .. r.keyword) or "全部")
        local target = ""
        if type(r.webhook) == "string" then
            target = r.webhook:match("^https?://([^/]+)") or ""
        elseif type(r.openid) == "string" then
            target = "QQ:" .. r.openid:sub(1, 6) .. "***"
        elseif type(r.group_openid) == "string" then
            target = "QQ群:" .. r.group_openid:sub(1, 6) .. "***"
        elseif r.email_to then
            target = "邮件"
        end
        lines[#lines + 1] = string.format("[%d] %s | %s | %s", i, r.channel or "?", match_desc, target)
    end
    return table.concat(lines, "\n")
end

local function cmdRecentSms(arg)
    local n = tonumber(arg) or 5
    return util_sms_store.recentText(n)
end

local function cmdSendSms(arg)
    local num, text = arg:match("^([%+]?%d%d%d%d%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?)%s+(.+)$")
    if not num or not text then
        return "用法：发短信 号码 内容\n示例：发短信 13800138000 你好"
    end
    local ok = sms.send(num, text)
    log.info("util_qqbot", "指令发短信", num, ok)
    return (ok and "✅ 已提交发送：" or "❌ 发送失败：") .. num
end

local function cmdTest()
    util_forward.forwardMessage("#QQBOT_TEST", "QQBOT")
    return "✅ 已触发测试转发（经转发规则发送）"
end

local function cmdReload()
    util_forward.reloadRules()
    return "✅ 已重新加载转发规则，当前 " .. #(util_forward.getRules() or {}) .. " 条"
end

local function cmdTraffic()
    util_mobile.queryTraffic()
    return "📨 已向运营商发送流量查询短信，回复将以短信到达并按规则转发"
end

local function cmdLocation()
    local old_lat = util_location.get()
    util_location.refresh()
    -- 等待定位刷新 (最长 20 秒), 超时回退缓存
    local deadline = mcu.ticks() + 20000
    while mcu.ticks() < deadline do
        sys.wait(2000)
        local lat, _, link = util_location.get()
        if link ~= "" and (lat ~= old_lat or old_lat == 0) then
            return "📍 定位：" .. link
        end
    end
    local _, _, link = util_location.get()
    return link ~= "" and ("📍 定位（缓存）：" .. link) or "❌ 定位失败，稍后再试"
end

local function cmdFlymode()
    log.warn("util_qqbot", "指令触发飞行模式自愈")
    mobile.flymode(0, true)
    sys.wait(3000)
    mobile.flymode(0, false)
    sys.waitUntil("IP_READY", config.NETWORK_TIMEOUT_DEFAULT)
    return "✅ 飞行模式已执行一次，网络状态：" .. util_mobile.status() .. "\nℹ️ Qbot 通道将自动重连"
end

--- 构建按钮键盘: 每行最多 4 个按钮, 点击即发送对应指令 (action type=2, enter=true)
-- permission 限定仅发起人可点击
local function buildKeyboard(openid, labels)
    if not openid then
        return nil
    end
    local rows, row = {}, {}
    for i, label in ipairs(labels) do
        row[#row + 1] = {
            id = tostring(i),
            render_data = { label = label, visited_label = label .. " ✓", style = 1 },
            action = {
                type = 2,
                permission = { type = 0, user_list = { openid } },
                data = label,
                enter = true,
            },
        }
        if #row >= 4 then
            rows[#rows + 1] = { buttons = row }
            row = {}
        end
    end
    if #row > 0 then
        rows[#rows + 1] = { buttons = row }
    end
    return { rows = rows }
end

local function cmdReboot(arg, ctx)
    pending_confirm[ctx.openid] = { action = "reboot", expire = mcu.ticks() + 60000 }
    local text = table.concat({
        "⚠️ " .. mdBold("确认重启设备"),
        "",
        "重启将清理全部任务并断开连接，约 1 分钟后自动恢复。",
        "",
        "请选择：",
        "• " .. mdBold("确认") .. " — 60 秒内重启设备",
        "• " .. mdBold("取消") .. " — 什么都不做",
    }, "\n")
    if config.QQBOT_BUTTONS then
        return { text = text, keyboard = buildKeyboard(ctx.openid, { "确认", "取消" }) }
    end
    return text
end

local function cmdConfirm(arg, ctx)
    local p = pending_confirm[ctx.openid]
    pending_confirm[ctx.openid] = nil
    if not p or mcu.ticks() > p.expire then
        return "ℹ️ 没有待确认的操作"
    end
    if p.action == "reboot" then
        -- 先回复再重启, 让回复来得及发出
        sys.timerStart(function()
            log.warn("util_qqbot", "指令触发重启")
            if cleanupAllTasks then
                cleanupAllTasks()
            end
            sys.wait(1000)
            rtos.restart()
        end, 3000)
        return "✅ 已确认，设备 3 秒后重启…"
    end
    return "ℹ️ 未知操作"
end

local function cmdCancel(arg, ctx)
    local p = pending_confirm[ctx.openid]
    pending_confirm[ctx.openid] = nil
    if p then
        return "✗ 已取消"
    end
    return "ℹ️ 没有待确认的操作"
end

local buildHelp                 -- 前向声明, 由 COMMANDS 自动生成

-- 指令表: keys 为触发词(小写), group 决定帮助菜单分组, hidden 不出现在帮助中
local COMMANDS = {
    { group = "查询", keys = { "帮助", "help", "?" }, desc = "显示本帮助", fn = function(arg, ctx)
        local text = buildHelp()
        if config.QQBOT_BUTTONS then
            return {
                text = text,
                keyboard = buildKeyboard(ctx and ctx.openid,
                    { "状态", "信号", "短信", "设备", "定位", "规则", "测试", "重载规则" }),
            }
        end
        return text
    end },
    { group = "查询", keys = { "状态", "status" }, desc = "设备状态(信号/网络/内存/规则)", fn = function() return buildStatus() end },
    { group = "查询", keys = { "信号", "signal" }, desc = "信号强度", fn = buildSignal },
    { group = "查询", keys = { "设备", "device" }, desc = "IMEI/IMSI/ICCID/本机号码", fn = buildDeviceInfo },
    { group = "查询", keys = { "定位", "位置", "location" }, desc = "基站定位地图链接", fn = cmdLocation },
    { group = "查询", keys = { "流量", "查流量", "traffic" }, desc = "发短信查询流量", fn = cmdTraffic },
    { group = "查询", keys = { "时间", "time" }, desc = "设备时间与同步状态", fn = buildTimeInfo },
    { group = "查询", keys = { "规则", "rules" }, desc = "列出转发规则(目标打码)", fn = buildRulesList },
    { group = "短信", keys = { "短信", "sms" }, desc = "最近短信, 如: 短信 10", fn = cmdRecentSms },
    { group = "短信", keys = { "发短信" }, desc = "设备代发, 如: 发短信 13800138000 内容", fn = cmdSendSms },
    { group = "短信", keys = { "测试", "test" }, desc = "触发一次测试转发", fn = cmdTest },
    { group = "控制", keys = { "重载规则", "reload" }, desc = "重载转发规则", fn = cmdReload },
    { group = "控制", keys = { "飞行模式", "flymode" }, desc = "开关一次飞行模式(网络自愈)", fn = cmdFlymode },
    { group = "控制", keys = { "重启", "reboot" }, desc = "重启设备(需二次确认)", fn = cmdReboot },
    { keys = { "确认", "confirm" }, desc = "", hidden = true, fn = cmdConfirm },
    { keys = { "取消", "cancel" }, desc = "", hidden = true, fn = cmdCancel },
}

-- 触发词 -> 指令项 的索引
local cmd_map = {}
for _, c in ipairs(COMMANDS) do
    for _, k in ipairs(c.keys) do
        cmd_map[k:lower()] = c
    end
end

buildHelp = function()
    local icons = { ["查询"] = "🔍", ["短信"] = "📨", ["控制"] = "⚙️" }
    local lines = { "💬 " .. mdBold("指令菜单") }
    for _, g in ipairs({ "查询", "短信", "控制" }) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = icons[g] .. " " .. mdBold(g)
        for _, c in ipairs(COMMANDS) do
            if c.group == g and not c.hidden then
                lines[#lines + 1] = "• " .. table.concat(c.keys, "/") .. " — " .. c.desc
            end
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "ℹ️ 支持 / 前缀；直接 @机器人 不带内容可打开本菜单"
    lines[#lines + 1] = '⚠️ 危险操作需二次确认，发送 "取消" 可撤销'
    return table.concat(lines, "\n")
end

--- 指令入口: 归一化后查表分发, 返回回复文本 (异常与未知指令均返回提示)
local function handleCommand(raw, ctx)
    local s = normalizeInput(raw)
    if s == "" then
        return buildHelp()
    end

    local cmd, arg = s:match("^(%S+)%s*(.-)$")
    cmd = cmd:lower()

    local entry = cmd_map[cmd]
    if not entry then
        -- 支持指令与参数连写, 如 "短信10" / "sms10"
        local base, num = cmd:match("^(%D+)(%d+)$")
        if base then
            entry = cmd_map[base]
            if entry then
                arg = (arg ~= "" and (num .. " " .. arg)) or num
            end
        end
    end
    if entry then
        local ok, reply = pcall(entry.fn, arg, ctx or {})
        if ok then
            -- 指令可返回字符串, 或 { text, keyboard } 结构 (附按钮)
            if type(reply) == "table" then
                reply.text = utf8Sub(reply.text or "指令执行完毕", 1500)
                return reply
            end
            return utf8Sub(reply or "指令执行完毕", 1500)
        end
        log.error("util_qqbot", "指令执行异常", cmd, reply)
        return "❌ 指令执行出错：" .. tostring(reply)
    end

    -- 未知指令: 基于前缀给出建议 (输入是某触发词的前缀, 或触发词是输入的前缀)
    local suggest = {}
    for k in pairs(cmd_map) do
        if #k > 1 and #cmd > 0 and (k:sub(1, #cmd) == cmd or cmd:sub(1, #k) == k) then
            suggest[#suggest + 1] = k
        end
    end
    local head = "❓ 未知指令：" .. cmd
    if #suggest > 0 then
        table.sort(suggest)
        if #suggest > 4 then
            for i = #suggest, 5, -1 do suggest[i] = nil end
        end
        head = head .. "\n你是想找：" .. table.concat(suggest, " / ") .. " ？"
    end
    return head .. "\n\n" .. buildHelp()
end

--- 被动回复单聊消息 (携带 msg_id, 不受主动消息频控)
local function replyC2C(openid, msg_id, seq, content, keyboard)
    if type(openid) ~= "string" or not openid:match("^[%w%-_]+$") then
        log.error("util_qqbot", "openid 非法, 拒绝回复", openid)
        return false
    end
    local code, resp = postMessage("/v2/users/" .. openid .. "/messages", content, msg_id, seq, keyboard)
    local ok = type(code) == "number" and code >= 200 and code < 300
    if ok then
        log.info("util_qqbot", "单聊回复成功", code)
    else
        log.error("util_qqbot", "单聊回复失败", code, resp)
    end
    return ok
end

--- 被动回复群@消息
local function replyGroup(group_openid, msg_id, seq, content, keyboard)
    if type(group_openid) ~= "string" or not group_openid:match("^[%w%-_]+$") then
        log.error("util_qqbot", "group_openid 非法, 拒绝回复", group_openid)
        return false
    end
    local code, resp = postMessage("/v2/groups/" .. group_openid .. "/messages", content, msg_id, seq, keyboard)
    local ok = type(code) == "number" and code >= 200 and code < 300
    if ok then
        log.info("util_qqbot", "群回复成功", code)
    else
        log.error("util_qqbot", "群回复失败", code, resp)
    end
    return ok
end

--- 非白名单用户回复欢迎引导消息 (含其 openid 与配置方法), 每个 openid 最多 WELCOME_MAX 次防刷
local function replyWelcome(openid, msg_id, is_group, group_openid)
    local count = welcome_count[openid] or 0
    if count >= WELCOME_MAX then
        log.warn("util_qqbot", "欢迎消息次数用尽, 忽略", "openid", openid, "已回复", count)
        return
    end
    welcome_count[openid] = count + 1

    local content = table.concat({
        "👋 " .. mdBold("欢迎使用 Air780EHV 短信转发器"),
        "",
        "你的 openid：" .. mdCode(openid),
        "",
        "配置方法：",
        "• 编辑 script/config.lua 第 2 节 QQBOT_ALLOW",
        "• 填入：" .. mdCode('QQBOT_ALLOW = { "' .. openid .. '" }'),
        "• 重新烧录后发送 \"帮助\" 查看全部指令",
    }, "\n")

    if is_group then
        replyGroup(group_openid, msg_id, 1, content)
    else
        replyC2C(openid, msg_id, 1, content)
    end
end

--- 处理一条聊天消息事件 (在独立协程中执行, 允许阻塞)
local function processMessage(t, d)
    local msg_id = d.id
    if isDuplicate(msg_id) then
        log.debug("util_qqbot", "重复消息, 忽略", msg_id)
        return
    end

    local content = tostring(d.content or "")

    if t == "C2C_MESSAGE_CREATE" then
        local openid = d.author and d.author.user_openid
        log.info("util_qqbot", "收到单聊消息", "openid", openid, "内容", content)
        if type(openid) ~= "string" then
            return
        end
        if not isAllowed(openid) then
            log.warn("util_qqbot", "非白名单用户, 回复欢迎引导", "openid", openid)
            replyWelcome(openid, msg_id, false, nil)
            return
        end
        local reply = handleCommand(content, { openid = openid })
        if type(reply) == "table" then
            replyC2C(openid, msg_id, 1, reply.text, reply.keyboard)
        else
            replyC2C(openid, msg_id, 1, reply)
        end

    elseif t == "GROUP_AT_MESSAGE_CREATE" then
        local openid = d.author and d.author.member_openid
        local group_openid = d.group_openid
        log.info("util_qqbot", "收到群@消息", "群", group_openid, "openid", openid, "内容", content)
        if type(openid) ~= "string" or type(group_openid) ~= "string" then
            return
        end
        if not isAllowed(openid) then
            log.warn("util_qqbot", "非白名单群成员, 回复欢迎引导", "openid", openid)
            replyWelcome(openid, msg_id, true, group_openid)
            return
        end
        local reply = handleCommand(content, { openid = openid })
        if type(reply) == "table" then
            replyGroup(group_openid, msg_id, 1, reply.text, reply.keyboard)
        else
            replyGroup(group_openid, msg_id, 1, reply)
        end
    end
end

--- ws 下行消息处理 (在库回调上下文中执行, 只做非阻塞操作)
local function handleWsMessage(text)
    local ok, msg = pcall(json.decode, text)
    if not ok or type(msg) ~= "table" then
        log.error("util_qqbot", "ws 消息解析失败", text)
        return
    end

    if msg.s then
        last_seq = msg.s
    end

    local op = msg.op
    if op == 10 then
        -- HELLO: 记录心跳间隔后开始鉴权
        heartbeat_interval = (msg.d and msg.d.heartbeat_interval) or 30000
        startHeartbeat()
        sendHeartbeat()
        if session_id and last_seq and resume_fail < 2 then
            sendResume()
        else
            sendIdentify()
        end
    elseif op == 11 then
        last_ack_time = mcu.ticks()
    elseif op == 7 then
        log.warn("util_qqbot", "服务端要求重连")
        onDisconnected("服务端要求重连")
    elseif op == 0 then
        local t = msg.t
        if t == "READY" then
            session_id = (msg.d and msg.d.session_id) or session_id
            resume_fail = 0
            identify_fail = 0
            backoff_ms = 3000
            state = "RUNNING"
            last_ack_time = mcu.ticks()
            log.info("util_qqbot", "鉴权成功, 机器人已就绪",
                "用户名", (msg.d and msg.d.user and msg.d.user.username) or "未知")
            sys.publish(EVT, "READY")
        elseif t == "RESUMED" then
            backoff_ms = 3000
            state = "RUNNING"
            last_ack_time = mcu.ticks()
            log.info("util_qqbot", "会话恢复成功")
            sys.publish(EVT, "RESUMED")
        elseif t == "C2C_MESSAGE_CREATE" or t == "GROUP_AT_MESSAGE_CREATE" then
            -- 回调上下文禁止阻塞, 派生独立协程处理指令和回复
            local d = msg.d or {}
            sys.taskInit(function()
                local ok2, err = pcall(processMessage, t, d)
                if not ok2 then
                    log.error("util_qqbot", "消息处理异常", err)
                end
            end)
        else
            log.debug("util_qqbot", "忽略事件", t)
        end
    else
        log.debug("util_qqbot", "未知 op", op)
    end
end

-- ===== 连接生命周期 =====

onDisconnected = function(reason)
    if wsc == nil and state == "OFFLINE" then
        return
    end

    local was_running = (state == "RUNNING")
    state = "OFFLINE"
    stopHeartbeat()

    if wsc then
        pcall(function()
            wsc:close()
        end)
        wsc = nil
    end

    if was_running then
        log.warn("util_qqbot", "连接断开", reason or "", "保留会话待 RESUME 恢复")
    else
        log.warn("util_qqbot", "鉴权阶段断开", reason or "")
        if session_id and last_seq then
            -- RESUME 尝试失败: 连续 2 次后放弃会话, 改为全新鉴权
            resume_fail = resume_fail + 1
            if resume_fail >= 2 then
                session_id, last_seq, resume_fail = nil, nil, 0
                log.warn("util_qqbot", "RESUME 连续失败, 下次全新鉴权")
            end
        else
            -- IDENTIFY 失败: 连续 2 次后切换 token 格式重试
            identify_fail = identify_fail + 1
            if identify_fail >= 2 then
                identify_fail = 0
                auth_style = (auth_style == 1) and 2 or 1
                log.warn("util_qqbot", "IDENTIFY 连续失败, 切换 token 格式 style =", auth_style)
            end
        end
    end

    sys.publish(EVT, "DISCONNECT")
end

--- 建立 wss 连接并注册回调 (连接结果经状态/事件由主循环统一处理)
local function connectWs(gateway)
    if wsc then
        pcall(function()
            wsc:close()
        end)
        wsc = nil
    end

    wsc = websocket.create(nil, gateway, 30, false)
    if not wsc then
        log.error("util_qqbot", "websocket.create 失败")
        return false
    end

    -- 不用库的自动重连, 重连必须重新鉴权, 由主循环统一管理
    wsc:autoreconn(false, 3000)
    wsc:on(function(_, event, data, fin)
        if event == "conack" then
            log.info("util_qqbot", "wss 已连接, 等待 HELLO")
            state = "AUTHING"
        elseif event == "recv" then
            if fin == 0 then
                log.warn("util_qqbot", "收到分片消息, 忽略")
            else
                handleWsMessage(data)
            end
        elseif event == "disconnect" then
            onDisconnected("ws disconnect")
        end
    end)

    if not wsc:connect() then
        log.error("util_qqbot", "websocket 启动失败")
        onDisconnected("connect 启动失败")
        return false
    end
    return true
end

local function bumpBackoff()
    backoff_ms = math.min(backoff_ms * 2, 5 * 60 * 1000)
end

--- 主循环: 取 token -> 取网关 -> 连接 -> 运行 -> 断线退避重连
-- 采用状态轮询而非纯事件驱动, 避免回调与等待之间的发布丢失竞态
local function qqbotMainTask()
    while true do
        -- 网络已就绪则直接继续, 避免 IP_READY 已发布过导致白等
        if mobile.status() ~= 1 then
            sys.waitUntil("IP_READY", 60000)
        end

        if not fetchToken() then
            log.warn("util_qqbot", "token 未就绪", backoff_ms .. "ms 后重试")
        else
            local gateway = fetchGateway()
            if gateway then
                state = "CONNECTING"
                if connectWs(gateway) then
                    -- 等待鉴权结果 (最长 120 秒)
                    local deadline = mcu.ticks() + 120000
                    while state ~= "RUNNING" and state ~= "OFFLINE" and mcu.ticks() < deadline do
                        sys.waitUntil(EVT, 5000)
                    end
                    -- 运行中, 等待断线 (30 秒轮询兜底)
                    while state == "RUNNING" do
                        sys.waitUntil(EVT, 30000)
                    end
                end
            end
        end

        -- 清理并退避重连
        onDisconnected("主循环清理")
        state = "OFFLINE"
        sys.wait(backoff_ms)
        bumpBackoff()
    end
end

--- 看门狗: 主任务丢失自动重启; 心跳 ACK 停滞主动断开
local function watchdog()
    if not config.QQBOT_ENABLED then
        return
    end

    if not TaskManager.exists(TASK_MAIN) then
        log.warn("util_qqbot", "主任务丢失, 自动重启")
        TaskManager.create(TASK_MAIN, qqbotMainTask)
    end

    if state == "RUNNING" and heartbeat_interval then
        local limit = math.max(90000, heartbeat_interval * 3)
        if mcu.ticks() - last_ack_time > limit then
            log.warn("util_qqbot", "心跳 ACK 超时", limit .. "ms, 主动断开重连")
            onDisconnected("心跳超时")
        end
    end
end

--- qq 转发渠道配置检查 (主动推送只需要 AppID/Secret, 无需开启 QQBOT_ENABLED)
local function checkPushConfig()
    if type(config.QQBOT_APPID) ~= "string" or config.QQBOT_APPID == ""
        or type(config.QQBOT_SECRET) ~= "string" or config.QQBOT_SECRET == "" then
        log.error("util_qqbot", "qq 渠道需要先配置 QQBOT_APPID / QQBOT_SECRET")
        return false
    end
    return true
end

-- ===== 对外接口 =====

--- 启动 Qbot 交互通道 (失败只记日志, 不影响短信转发主流程)
function util_qqbot.start()
    if type(config) ~= "table" or not config.QQBOT_ENABLED then
        log.info("util_qqbot", "未启用 (config.QQBOT_ENABLED != true)")
        return
    end

    if type(config.QQBOT_APPID) ~= "string" or config.QQBOT_APPID == ""
        or type(config.QQBOT_SECRET) ~= "string" or config.QQBOT_SECRET == "" then
        log.error("util_qqbot", "已启用但未配置 QQBOT_APPID / QQBOT_SECRET")
        return
    end

    if websocket == nil then
        log.error("util_qqbot", "固件不含 websocket 库, 请刷入带 websocket 核心库的固件")
        return
    end

    if type(config.QQBOT_ALLOW) ~= "table" or #config.QQBOT_ALLOW == 0 then
        log.warn("util_qqbot", "QQBOT_ALLOW 白名单为空, 将对所有消息回复欢迎引导(含 openid 与配置方法)")
    end

    TaskManager.create(TASK_MAIN, qqbotMainTask)
    TaskManager.createLoop(TASK_WATCHDOG, watchdog, 10000)
    log.info("util_qqbot", "Qbot 交互通道已启动")
end

--- 停止并清理所有任务和连接
function util_qqbot.cleanup()
    stopHeartbeat()
    if wsc then
        pcall(function()
            wsc:close()
        end)
        wsc = nil
    end
    state = "OFFLINE"
    TaskManager.delete(TASK_MAIN)
    TaskManager.stopLoop(TASK_WATCHDOG)
    log.info("util_qqbot", "已停止")
end

--- 主动推送消息到 QQ 单聊 (转发规则 qq 渠道调用; 主动消息无 msg_id, 仅需 access token, 不依赖 wss 连接)
-- 频控: 每好友 20 条/分钟、1000 条/天, 超限返回 40034100
function util_qqbot.pushToUser(openid, content)
    if not checkPushConfig() then
        return false
    end
    if type(openid) ~= "string" or not openid:match("^[%w%-_]+$") then
        log.error("util_qqbot", "openid 非法, 拒绝推送", openid)
        return false
    end
    if type(content) ~= "string" or content == "" then
        return false
    end
    local code, resp = postMessage("/v2/users/" .. openid .. "/messages", utf8Sub(content, 1500), nil, nil)
    local ok = type(code) == "number" and code >= 200 and code < 300
    if ok then
        log.info("util_qqbot", "单聊推送成功", code)
    else
        log.error("util_qqbot", "单聊推送失败", "code", code, "resp", resp)
    end
    return ok
end

--- 主动推送消息到 QQ 群 (转发规则 qq 渠道调用; 频控: 每群 20 条/分钟、1000 条/天)
function util_qqbot.pushToGroup(group_openid, content)
    if not checkPushConfig() then
        return false
    end
    if type(group_openid) ~= "string" or not group_openid:match("^[%w%-_]+$") then
        log.error("util_qqbot", "group_openid 非法, 拒绝推送", group_openid)
        return false
    end
    if type(content) ~= "string" or content == "" then
        return false
    end
    local code, resp = postMessage("/v2/groups/" .. group_openid .. "/messages", utf8Sub(content, 1500), nil, nil)
    local ok = type(code) == "number" and code >= 200 and code < 300
    if ok then
        log.info("util_qqbot", "群推送成功", code)
    else
        log.error("util_qqbot", "群推送失败", "code", code, "resp", resp)
    end
    return ok
end

return util_qqbot
