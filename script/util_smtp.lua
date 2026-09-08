local util_smtp = {}
local libnet = require "libnet"

-- SMTP超时配置(毫秒)
local SMTP_TIMEOUT = 10000
local SMTP_CONNECT_TIMEOUT = 15000

-- 任务名自增序号 (os.time 秒级会撞名: 同秒并发两封邮件会导致 socket/libnet 冲突)
local smtp_seq = 0

--- 从socket读取SMTP响应
-- 注意新版固件 socket.read 返回 (ok, data) 两个值, 只接第一个会得到布尔值;
-- libnet.wait 在任何网络事件时都会返回, 必须循环等到真正读到数据
-- @param netc socket控制对象
-- @param taskName 任务名称
-- @param timeout 超时时间(毫秒)
-- @return 响应字符串 or nil
local function readResponse(netc, taskName, timeout)
    local deadline = mcu.ticks() + (timeout or SMTP_TIMEOUT)
    local buffer = ""
    while mcu.ticks() < deadline do
        -- 两个返回值: 第1个 false=网络异常; 第2个 false=超时
        local no_err, has_evt = libnet.wait(taskName, deadline - mcu.ticks(), netc)
        if not no_err then
            return nil  -- 网络异常
        end
        if not has_evt then
            break  -- 等待超时
        end
        local read_ok, data = socket.read(netc, 1500)
        if read_ok and type(data) == "string" and data ~= "" then
            buffer = buffer .. data
            -- 凑齐一整行(以换行结尾)再返回, 防止响应分片
            if buffer:find("\n") then
                return buffer
            end
        end
        -- 非数据事件, 继续等待
    end
    return nil
end

--- 发送SMTP命令并读取响应
-- @param netc socket控制对象
-- @param taskName 任务名称
-- @param cmd SMTP命令
-- @param timeout 超时时间(毫秒)
-- @return 响应字符串 or nil
local function sendCommand(netc, taskName, cmd, timeout)
    timeout = timeout or SMTP_TIMEOUT
    local show = (cmd or ""):gsub("\r\n$", "")
    log.debug("util_smtp", "发送:", show)
    if not libnet.tx(taskName, timeout, netc, cmd) then
        log.error("util_smtp", "命令发送失败")
        return nil
    end
    return readResponse(netc, taskName, timeout)
end

--- 检查SMTP响应码
-- @param resp SMTP响应
-- @param expected 期望的响应码(如250, 220, 235)
-- @return true if matches
local function checkCode(resp, expected)
    if not resp then return false end
    local code = resp:match("^(%d+)")
    if not code then return false end
    return tonumber(code) == expected
end

--- 构建邮件内容(含邮件头)
-- @param from 发件人
-- @param to 收件人
-- @param subject 主题
-- @param body 正文
-- @return 格式化的邮件内容
local function buildEmail(from, to, subject, body)
    local b64_subject = crypto.base64_encode(subject) or ""
    local b64_body = crypto.base64_encode(body) or ""
    return table.concat({
        "From: <" .. from .. ">",
        "To: <" .. to .. ">",
        "Subject: =?UTF-8?B?" .. b64_subject .. "?=",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: base64",
        "",
        b64_body,
    }, "\r\n")
end

--- 安全关闭socket
local function closeSocket(netc)
    if netc then
        socket.close(netc)
        socket.release(netc)
    end
end

--- 通过SMTP发送邮件
-- @param rule 转发规则(含SMTP配置)
-- @param msg 消息内容
-- @param taskName 任务名 (必须与运行本函数的协程名一致, libnet 按任务名投递 socket 消息)
-- @return true成功, false失败
local function smtpSendInternal(rule, msg, taskName)
    -- 回收内存
    collectgarbage("collect")

    -- 校验配置
    if not rule.smtp_server or not rule.smtp_username or not rule.smtp_password
        or not rule.email_from or not rule.email_to then
        log.error("util_smtp", "SMTP配置不完整")
        return false
    end

    local ssl = rule.smtp_ssl ~= false
    local port = rule.smtp_port or (ssl and 465 or 25)

    log.info("util_smtp", "连接SMTP", rule.smtp_server, port, ssl and "SSL" or "明文")

    -- 创建socket (新版固件 socket.create 第一个参数是网络适配器编号, taskName 是第二个参数)
    local netc = socket.create(nil, taskName)
    if not netc then
        log.error("util_smtp", "创建socket失败")
        return false
    end

    -- 配置SSL (参数: netc, 本地端口, 是否UDP, 是否TLS; 显式传 false 防 nil 参数错位)
    local cfg_ok = socket.config(netc, nil, false, ssl)
    log.info("util_smtp", "socket.config", cfg_ok)

    -- 连接服务器
    if not libnet.connect(taskName, SMTP_CONNECT_TIMEOUT, netc, rule.smtp_server, port) then
        log.error("util_smtp", "连接SMTP服务器失败")
        closeSocket(netc)
        return false
    end

    -- SMTP协议步骤封装
    local function step(cmd, expected, err_msg)
        local resp = sendCommand(netc, taskName, cmd)
        if not checkCode(resp, expected) then
            log.error("util_smtp", err_msg, resp)
            socket.tx(netc, "QUIT\r\n")
            libnet.wait(taskName, 3000, netc)
            closeSocket(netc)
            return false
        end
        return true
    end

    -- 1. 读取服务器问候
    local resp = readResponse(netc, taskName)
    if not checkCode(resp, 220) then
        log.error("util_smtp", "SMTP问候失败", resp)
        closeSocket(netc)
        return false
    end

    -- 2. EHLO
    if not step("EHLO air780e\r\n", 250, "EHLO失败") then return false end

    -- 3. AUTH LOGIN
    if not step("AUTH LOGIN\r\n", 334, "AUTH LOGIN失败") then return false end

    -- 4. 用户名
    local user_b64 = crypto.base64_encode(rule.smtp_username) or ""
    if not step(user_b64 .. "\r\n", 334, "用户名验证失败") then return false end

    -- 5. 密码
    local pass_b64 = crypto.base64_encode(rule.smtp_password) or ""
    if not step(pass_b64 .. "\r\n", 235, "密码验证失败") then return false end

    -- 6. MAIL FROM
    if not step("MAIL FROM:<" .. rule.email_from .. ">\r\n", 250, "MAIL FROM失败") then return false end

    -- 7. RCPT TO
    if not step("RCPT TO:<" .. rule.email_to .. ">\r\n", 250, "RCPT TO失败") then return false end

    -- 8. DATA
    if not step("DATA\r\n", 354, "DATA失败") then return false end

    -- 9. 邮件内容 + 结束标记
    local email = buildEmail(rule.email_from, rule.email_to, "短信转发通知", msg)
    if not step(email .. "\r\n.\r\n", 250, "邮件发送失败") then return false end

    log.info("util_smtp", "邮件发送成功", rule.email_to)

    -- 10. QUIT
    socket.tx(netc, "QUIT\r\n")
    libnet.wait(taskName, 3000, netc)
    closeSocket(netc)

    collectgarbage("collect")
    return true
end

--- 通过SMTP发送邮件
-- libnet 依赖 waitMsg, 必须用 sysplus.taskInitEx 创建与 taskName 同名的协程,
-- 普通 sys.taskInit 协程里调用会报 "taskInitEx启动的task才能使用waitMsg"
-- 注意: taskInitEx 第 3 个回调是"收到非目标消息时的回调"(不是错误回调),
-- socket 事件类型不匹配的消息都会走到这里, 只能忽略, 不能当作失败处理
-- @param rule 转发规则(含SMTP配置)
-- @param msg 消息内容
-- @return true成功, false失败
function util_smtp.send(rule, msg)
    smtp_seq = smtp_seq + 1
    local taskName = "smtp_" .. smtp_seq
    local event = "SMTP_DONE_" .. taskName

    sysplus.taskInitEx(function()
        local ok, res = pcall(smtpSendInternal, rule, msg, taskName)
        if not ok then
            log.error("util_smtp", "发送协程异常", res)
        end
        -- 通知调用方协程取结果
        sys.publish(event, ok and res == true)
    end, taskName, function(_msg)
        -- 非目标消息(非 socket.EVENT 的事件), 忽略即可, 继续等待
        log.debug("util_smtp", "非目标消息, 忽略", type(_msg))
    end)

    -- 调用方在哪个协程都行, sys.waitUntil 普通协程可用; 90 秒兜底防挂死
    local _, result = sys.waitUntil(event, 90000)
    return result == true
end

return util_smtp
