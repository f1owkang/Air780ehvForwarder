local util_channel = require "util_channel"
local util_mobile = require "util_mobile"
local TaskManager = require "util_task"

local util_notify = {}

-- 任务名称常量
local POLL_TASK_NAME = "util_notify_poll"

-- fskv 断电恢复键前缀 (队列消息持久化)
local FSKV_KEY_PREFIX = "notify_msg_"

-- 消息队列
local msg_queue = {}
-- 发送计数
local msg_count = 0
local error_count = 0
-- 是否已从 fskv 恢复过 (每上电一次)
local restored = false

--- 默认备用渠道: 自动挑选第一个已配置的渠道, 都没配置时回退 feishu (发不出去也会按失败重试)
local function defaultChannels()
    local candidates = {
        { "feishu", config.FEISHU_WEBHOOK },
        { "dingtalk", config.DINGTALK_WEBHOOK },
        { "wecom", config.WECOM_WEBHOOK },
        { "custom_post", config.CUSTOM_POST_URL },
    }
    for _, c in ipairs(candidates) do
        if type(c[2]) == "string" and c[2] ~= "" then
            return { c[1] }
        end
    end
    return { "feishu" }
end

--- 发送通知
-- @param msg 消息内容
-- @param channel 通知渠道
-- @return true: 无需重发, false: 需要重发
local function send(msg, channel)
    log.info("util_notify.send", "发送通知", channel)

    -- 判断消息内容 msg
    if type(msg) ~= "string" or msg == "" then
        log.error("util_notify.send", "发送通知失败", "msg 参数错误", type(msg))
        return true
    end

    -- 判断通知渠道 channel
    if not channel or util_channel[channel] == nil then
        log.error("util_notify.send", "发送通知失败", "无效通知渠道", tostring(channel))
        return true
    end

    -- 发送通知
    local code, headers, body = util_channel[channel](msg)
    if code == nil then
        -- code 为 nil 说明渠道函数自身失败(未配置/内部异常), 按失败处理进入重试, 避免静默丢弃
        log.error("util_notify.send", "发送通知失败(nil code), 等待重发", "渠道", channel, "body:", body)
        return false
    end
    if code >= 200 and code < 400 and code ~= 408 and code ~= 409 and code ~= 425 and code ~= 429 then
        log.info("util_notify.send", "发送通知成功", "code:", code, "body:", body)
        return true
    end
    log.error("util_notify.send", "发送通知失败, 等待重发", "code:", code, "body:", body)
    return false
end

--- 添加到消息队列
-- @param msg 消息内容
-- @param channels 通知渠道
-- @param id 消息唯一标识
function util_notify.add(msg, channels, id)
    -- 添加调试信息
    log.info("util_notify.add", "收到通知消息", "类型", type(msg), "内容", tostring(msg))

    -- 可选：上线通知过滤（如果不需要可以注释掉）
    if config.FILTER_BOOT_NOTIFY and type(msg) == "string" and msg:find("#BOOT_") then
        log.info("util_notify.add", "过滤上线通知", "FILTER_BOOT_NOTIFY", config.FILTER_BOOT_NOTIFY)
        return
    end

    msg_count = msg_count + 1
    log.info("util_notify.add", "处理通知消息", "计数", msg_count, "渠道", channels)

    if id == nil or id == "" then
        id = FSKV_KEY_PREFIX .. "t" .. os.time() .. "c" .. msg_count .. "r" .. math.random(9999)
    end

    if type(msg) == "table" then
        msg = table.concat(msg, "\n")
    end

    channels = channels or defaultChannels()
    if type(channels) ~= "table" then
        channels = { channels }
    end

    log.info("util_notify.add", "通知渠道配置", table.concat(channels, ","))

    for _, channel in ipairs(channels) do
        table.insert(msg_queue, { id = id, channel = channel, msg = msg, retry = 0 })
        log.info("util_notify.add", "添加到队列", "渠道", channel, "消息ID", id)
    end

    sys.publish("NEW_MSG")
    log.info("util_notify.add", "发布NEW_MSG事件", "队列长度", #msg_queue)
end

--- 轮询消息队列, 发送成功则从队列中删除, 发送失败则等待下次
local function poll()
    -- 打印网络状态
    if mobile.status() ~= 1 then
        log.warn("util_notify.poll", "mobile.status", mobile.status(), util_mobile.status())
    end

    -- 消息队列非空
    if next(msg_queue) == nil then
        sys.waitUntil("NEW_MSG", 1000 * 10)
        return
    end

    local item = msg_queue[1]
    table.remove(msg_queue, 1)
    local msg = item.msg
    log.info("util_notify.poll", "轮询消息队列中", "总长度: " .. #msg_queue, "当前ID: " .. item.id, "当前重发次数: " .. item.retry, "连续失败次数: " .. error_count)

    -- 通知内容添加设备信息
    if config.NOTIFY_APPEND_MORE_INFO and not string.find(msg, "开机时长:") then
        msg = msg .. util_mobile.appendDeviceInfo()
    end
    -- 通知内容添加重发次数
    if error_count > 0 then
        msg = msg .. "\n重发次数: " .. error_count
    end

    -- 超过最大重发次数: 放弃并清理 fskv 键, 避免孤儿键长期堆积
    if item.retry > (config.NOTIFY_RETRY_MAX or 20) then
        log.warn("util_notify.poll", "超过最大重发次数, 放弃重发", item.msg)
        if fskv.get(item.id) then
            fskv.del(item.id)
        end
        return
    end

    -- 开始发送
    local result = send(msg, item.channel)

    -- 发送成功
    if result then
        error_count = 0
        -- 检查 fskv 中如果存在则删除
        if fskv.get(item.id) then
            fskv.del(item.id)
        end
        return
    end

    -- 发送失败
    error_count = error_count + 1
    item.retry = item.retry + 1
    table.insert(msg_queue, item)
    log.info("util_notify.poll", "等待下次重发", "当前重发次数", item.retry, "连续失败次数", error_count)
    sys.waitUntil("IP_READY", config.NETWORK_TIMEOUT_SHORT)

    -- 优化飞行模式操作策略，减少频率
    local flymode_threshold = config.FLYMODE_THRESHOLD or 4  -- 从配置读取阈值
    if config.FLYMODE_ENABLE and error_count >= flymode_threshold and error_count % flymode_threshold == 0 then
        -- 开关飞行模式，增加恢复时间
        log.warn("util_notify.poll", "连续失败次数过多, 开关飞行模式", error_count)
        log.info("util_notify.poll", "开启飞行模式")
        mobile.flymode(0, true)

        -- 等待更长时间让网络模块完全重启
        sys.wait(3000)  -- 等待3秒

        log.info("util_notify.poll", "关闭飞行模式")
        mobile.flymode(0, false)

        -- 等待网络重新注册
        sys.wait(5000)  -- 等待5秒

        -- 等待IP_READY事件，但设置超时
        if not sys.waitUntil("IP_READY", config.NETWORK_TIMEOUT_DEFAULT) then
            log.warn("util_notify.poll", "飞行模式操作后网络未就绪")
        else
            log.info("util_notify.poll", "飞行模式操作后网络已就绪")
        end
    end

    -- 每条消息第 1 次重发失败后, 保存到 fskv, 断电开机可恢复重发
    if item.retry == 1 then
        if not (string.find(item.msg, "#SMS") or string.find(item.msg, "#CALL")) then
            return
        end
        log.info("util_notify.poll", "当前第 1 次重发失败, 保存到 fskv", item.id)
        if fskv.get(item.id) then
            log.info("util_notify.poll", "fskv 已存在, 跳过写入", item.id)
            return
        end
        -- json 结构带渠道信息; 旧版本固件写入的纯文本值在恢复时按默认渠道处理
        local kv_set_result = fskv.set(item.id, json.encode({ channel = item.channel, msg = item.msg }))
        log.info("util_notify.poll", "fskv.set", kv_set_result, "used,total,count:", fskv.status())
    end
end

--- 启动时从 fskv 恢复断电前未发完的队列消息 (每上电执行一次)
local function restoreFromFskv()
    if restored then
        return
    end
    restored = true
    local iter = fskv.iter and fskv.iter()
    if not iter then
        log.warn("util_notify", "当前固件 fskv 不支持遍历, 跳过断电恢复")
        return
    end
    local count = 0
    local key, value = iter()
    while key do
        -- 兼容旧版 "msg-t" 前缀的遗留键
        if type(key) == "string" and (key:sub(1, #FSKV_KEY_PREFIX) == FSKV_KEY_PREFIX or key:sub(1, 5) == "msg-t") then
            local channel, msg = defaultChannels()[1], value
            local ok, data = pcall(json.decode, value)
            if ok and type(data) == "table" and type(data.channel) == "string" and type(data.msg) == "string" then
                channel, msg = data.channel, data.msg
            end
            if util_channel[channel] and type(msg) == "string" and msg ~= "" then
                table.insert(msg_queue, { id = key, channel = channel, msg = msg, retry = 1 })
                count = count + 1
                log.info("util_notify", "恢复队列消息", key, "渠道", channel)
            else
                -- 渠道已失效或内容异常, 清掉孤儿键
                log.warn("util_notify", "丢弃无效持久化消息", key)
                fskv.del(key)
            end
        end
        key, value = iter()
    end
    if count > 0 then
        log.info("util_notify", "断电恢复完成", "共", count, "条")
        sys.publish("NEW_MSG")
    end
end

-- 启动消息轮询任务
function util_notify.startPoll()
    restoreFromFskv()
    TaskManager.createLoop(POLL_TASK_NAME, function()
        poll()
    end, 100, function(success, err)
        if not success then
            log.error("util_notify", "poll task failed:", err)
        end
    end)
end

-- 停止消息轮询任务
function util_notify.stopPoll()
    TaskManager.stopLoop(POLL_TASK_NAME)
end

-- 清理所有任务
function util_notify.cleanup()
    util_notify.stopPoll()
end

-- 自动启动轮询任务
sys.taskInit(function()
    sys.waitUntil("IP_READY", config.NETWORK_TIMEOUT_SHORT)
    util_notify.startPoll()
end)

return util_notify
