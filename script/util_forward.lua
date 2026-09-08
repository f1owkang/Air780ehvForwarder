local util_notify = require "util_notify"
local util_http = require "util_http"
local util_smtp = require "util_smtp"
local util_mobile = require "util_mobile"
local TaskManager = require "util_task"

local util_forward = {}

-- 转发任务序号 (TaskManager 任务名唯一)
local forward_seq = 0

-- 转发规则配置 (统一在 config.lua 的 FORWARD_RULES 段)
local forward_rules = config.FORWARD_RULES or {}

-- 规则匹配条件的日志描述
local function matchDesc(rule)
    if rule.regular then
        return "正则:" .. rule.regular
    elseif rule.keyword then
        return "关键词:" .. rule.keyword
    else
        return "无匹配条件(匹配所有)"
    end
end

-- 初始化转发规则
local function initForwardRules()
    log.info("util_forward", "初始化转发规则", "规则数量", #forward_rules)

    -- 打印所有规则用于调试
    for i, rule in ipairs(forward_rules) do
        log.info("util_forward", "规则" .. i, "渠道", rule.channel, matchDesc(rule), "webhook", rule.webhook and "已配置" or "未配置")
    end

    return true
end

-- 匹配函数
-- keyword: 关键词部分匹配，不区分大小写
-- regular: Lua正则模式匹配，区分大小写
local function matchRule(content, rule)
    if not content then
        return false
    end

    local pattern = rule.regular or rule.keyword

    if not pattern then
        log.warn("util_forward", "规则未配置keyword或regular，将匹配所有消息")
        return true
    end

    if pattern == "all" then
        return true
    end

    if rule.regular then
        -- 正则模式匹配
        local ok, result = pcall(string.find, content, pattern)
        if not ok then
            log.error("util_forward", "正则模式语法错误", pattern, result)
            return false
        end
        return result ~= nil
    else
        -- 关键词部分匹配，不区分大小写
        return string.find(string.lower(content), string.lower(pattern)) ~= nil
    end
end

-- 企业微信转发函数
local function sendToWeCom(msg, webhook)
    if not webhook or webhook == "" then
        log.error("util_forward", "企业微信webhook为空")
        return false
    end

    local header = { ["Content-Type"] = "application/json; charset=utf-8" }
    local body = { msgtype = "text", text = { content = msg } }

    log.info("util_forward", "发送到企业微信", "webhook", webhook)
    local code, headers, response = util_http.fetch(nil, "POST", webhook, header, json.encode(body))

    -- 企业微信 200 但 errcode 非 0 也算失败 (系统繁忙 -1 / 接口限流 45009)
    if code == 200 and type(response) == "string" and response ~= "" then
        local ok, data = pcall(json.decode, response)
        if ok and type(data) == "table" and (data.errcode == -1 or data.errcode == 45009) then
            log.error("util_forward", "企业微信发送失败(errcode)", data.errcode, response)
            return false
        end
    end

    if code and code >= 200 and code < 300 then
        log.info("util_forward", "企业微信发送成功", "状态码", code)
        return true
    else
        log.error("util_forward", "企业微信发送失败", "状态码", code, "响应", response)
        return false
    end
end

-- 飞书转发函数（支持加签，与备用通知渠道能力对齐）
local function sendToFeishu(msg, webhook, secret)
    if not webhook or webhook == "" then
        log.error("util_forward", "飞书webhook为空")
        return false
    end

    local header = { ["Content-Type"] = "application/json; charset=utf-8" }
    local body = { msg_type = "text", content = { text = msg } }

    -- 如果配置了密钥，需要签名（与 util_channel.feishu 同一套算法）
    if secret and secret ~= "" then
        local timestamp = tostring(os.time())
        local string_to_sign = timestamp .. "\n" .. secret
        body.timestamp = timestamp
        body.sign = crypto.hmac_sha256(string_to_sign, secret):fromHex():toBase64():urlEncode()
    end

    log.info("util_forward", "发送到飞书", "webhook", webhook)
    local code, headers, response = util_http.fetch(nil, "POST", webhook, header, json.encode(body))

    if code and code >= 200 and code < 300 then
        log.info("util_forward", "飞书发送成功", "状态码", code)
        return true
    else
        log.error("util_forward", "飞书发送失败", "状态码", code, "响应", response)
        return false
    end
end

-- 钉钉转发函数
local function sendToDingding(msg, webhook, secret)
    if not webhook or webhook == "" then
        log.error("util_forward", "钉钉webhook为空")
        return false
    end

    local url = webhook

    -- 如果配置了密钥，需要签名
    if secret and secret ~= "" then
        local timestamp = tostring(os.time()) .. "000"
        local sign = crypto.hmac_sha256(timestamp .. "\n" .. secret, secret):fromHex():toBase64():urlEncode()
        url = url .. "&timestamp=" .. timestamp .. "&sign=" .. sign
    end

    local header = { ["Content-Type"] = "application/json; charset=utf-8" }
    local body = { msgtype = "text", text = { content = msg } }

    log.info("util_forward", "发送到钉钉", "url", url)
    local code, headers, response = util_http.fetch(nil, "POST", url, header, json.encode(body))

    -- 钉钉 200 但 errcode 非 0 也算失败: 限流 -1/410100、时间戳过期 310000 (与 util_channel 对齐)
    if code == 200 and type(response) == "string" and response ~= "" then
        local ok, data = pcall(json.decode, response)
        if ok and type(data) == "table" then
            local errcode = data.errcode or 0
            if errcode == -1 or errcode == 410100 then
                log.error("util_forward", "钉钉发送失败(限流)", errcode, response)
                return false
            end
            if errcode == 310000 and data.errmsg and (data.errmsg:find("timestamp") or data.errmsg:find("过期")) then
                socket.sntp()
                log.error("util_forward", "钉钉发送失败(时间戳过期)", response)
                return false
            end
        end
    end

    if code and code >= 200 and code < 300 then
        log.info("util_forward", "钉钉发送成功", "状态码", code)
        return true
    else
        log.error("util_forward", "钉钉发送失败", "状态码", code, "响应", response)
        return false
    end
end

-- 自定义POST转发函数
local function sendToCustomPost(msg, webhook, content_type, post_body)
    if not webhook or webhook == "" then
        log.error("util_forward", "自定义POST webhook为空")
        return false
    end

    local header = { ["content-type"] = content_type or "application/json" }
    local body = post_body or { title = "消息通知", desp = msg }

    -- 替换消息占位符
    local function replacePlaceholders(obj)
        for k, v in pairs(obj) do
            if type(v) == "string" then
                obj[k] = string.gsub(v, "{msg}", msg)
            elseif type(v) == "table" then
                replacePlaceholders(v)
            end
        end
    end

    replacePlaceholders(body)

    local body_json = json.encode(body)

    log.info("util_forward", "发送自定义POST", "url", webhook, "content-type", content_type)
    local code, headers, response = util_http.fetch(nil, "POST", webhook, header, body_json)

    if code and code >= 200 and code < 300 then
        log.info("util_forward", "自定义POST发送成功", "状态码", code)
        return true
    else
        log.error("util_forward", "自定义POST发送失败", "状态码", code, "响应", response)
        return false
    end
end

-- 根据渠道发送消息
local function sendByChannel(msg, channel, rule)
    if not msg or msg == "" then
        log.error("util_forward", "消息内容为空")
        return false
    end

    log.info("util_forward", "根据渠道发送消息", "渠道", channel, "消息", msg)

    local success = false

    if channel == "wecom" then
        success = sendToWeCom(msg, rule.webhook)
    elseif channel == "feishu" then
        success = sendToFeishu(msg, rule.webhook, rule.secret)
    elseif channel == "dingding" then
        success = sendToDingding(msg, rule.webhook, rule.secret)
    elseif channel == "custom_post" then
        success = sendToCustomPost(msg, rule.webhook, rule.content_type, rule.post_body)
    elseif channel == "email" then
        success = util_smtp.send(rule, msg)
    elseif channel == "qq" then
        -- util_qqbot 顶层 require 了本模块, 存在循环依赖, 这里在运行期惰性加载
        local qqbot = util_qqbot
        if not qqbot then
            local ok, mod = pcall(require, "util_qqbot")
            if ok then
                qqbot = mod
            end
        end
        if qqbot and qqbot.pushToUser then
            if rule.group_openid and rule.group_openid ~= "" then
                success = qqbot.pushToGroup(rule.group_openid, msg)
            elseif rule.openid and rule.openid ~= "" then
                success = qqbot.pushToUser(rule.openid, msg)
            else
                log.error("util_forward", "qq 渠道缺少 openid 或 group_openid 字段")
                success = false
            end
        else
            log.error("util_forward", "Qbot 模块未加载 (util_qqbot)")
            success = false
        end
    else
        log.error("util_forward", "不支持的转发渠道", channel)
        return false
    end

    return success
end

-- 匹配所有规则并记录日志, 返回命中的规则表
local function matchRules(msg)
    local matched_rules = {}
    for i, rule in ipairs(forward_rules) do
        if matchRule(msg, rule) then
            table.insert(matched_rules, rule)
            log.info("util_forward", "匹配到规则", "索引", i, "渠道", rule.channel, matchDesc(rule))
        end
    end
    return matched_rules
end

-- 对命中的规则逐个异步转发 (1 秒限速)
-- 注意: 必须用 sysplus.taskInitEx 创建的协程 (TaskManager.create),
-- libnet(SMTP 渠道) 的 waitMsg 在普通 sys.taskInit 协程里会报 "taskInitEx启动的task才能使用waitMsg"
local function dispatchRules(content, matched_rules)
    forward_seq = forward_seq + 1
    TaskManager.create("forward_" .. forward_seq, function()
        local success_count = 0
        for i, rule in ipairs(matched_rules) do
            log.info("util_forward", "执行转发规则", i .. "/" .. #matched_rules, "渠道", rule.channel)

            if sendByChannel(content, rule.channel, rule) then
                success_count = success_count + 1
                log.info("util_forward", "转发成功", "渠道", rule.channel)
            else
                log.error("util_forward", "转发失败", "渠道", rule.channel)
            end

            -- 避免请求过于频繁
            if i < #matched_rules then
                sys.wait(1000)
            end
        end
        log.info("util_forward", "转发完成", "成功", success_count, "总计", #matched_rules)
    end)
end

--- 通用消息转发函数（异步版本）
-- @param msg 消息内容
-- @param msg_type 消息类型 (可选)
function util_forward.forwardMessage(msg, msg_type)
    if not forward_rules or #forward_rules == 0 then
        log.warn("util_forward", "没有配置转发规则，跳过转发")
        return false
    end

    log.info("util_forward", "开始转发消息", "类型", msg_type or "未知", "内容", msg)

    local matched_rules = matchRules(msg)
    if #matched_rules == 0 then
        log.warn("util_forward", "没有匹配到任何转发规则")
        return false
    end

    log.info("util_forward", "匹配到规则数量", #matched_rules)
    dispatchRules(msg, matched_rules)
    return true  -- 表示任务已启动
end

--- 主要的转发函数
-- @param msg 消息内容
-- @param sender_number 发件人号码
-- @param time 接收时间
function util_forward.forwardSms(msg, sender_number, time)
    if not forward_rules or #forward_rules == 0 then
        log.warn("util_forward", "没有配置转发规则，使用默认转发")
        -- 使用默认转发方式
        util_notify.add({ msg, "", "发件号码: " .. sender_number, "发件时间: " .. time, "#SMS" })
        return
    end

    log.info("util_forward", "开始转发短信", "发件人", sender_number, "内容", msg, "时间", time)

    local full_msg = { msg, "", "发件号码: " .. sender_number, "发件时间: " .. time, "#SMS" }
    local content = table.concat(full_msg, "\n")

    -- 添加设备信息（如果配置启用）
    if config.NOTIFY_APPEND_MORE_INFO and not string.find(msg, "开机时长:") then
        content = content .. util_mobile.appendDeviceInfo()
    end

    local matched_rules = matchRules(msg)
    if #matched_rules == 0 then
        log.warn("util_forward", "没有匹配到任何转发规则")
        return
    end

    log.info("util_forward", "匹配到规则数量", #matched_rules)
    dispatchRules(content, matched_rules)
end

--- 重新加载转发规则
function util_forward.reloadRules()
    log.info("util_forward", "重新加载转发规则")
    return initForwardRules()
end

--- 获取当前转发规则
function util_forward.getRules()
    return forward_rules
end

--- 初始化转发模块
function util_forward.init()
    log.info("util_forward", "初始化转发模块")
    return initForwardRules()
end

return util_forward