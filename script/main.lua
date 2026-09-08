PROJECT = "air780ehv_forwarder"
VERSION = "1.4.0"

log.setLevel("DEBUG")
log.info("main", PROJECT, VERSION)
log.info("main", "开机原因", pm.lastReson())

sys = require "sys"
sysplus = require "sysplus"

-- config.lua 为本地配置(已 gitignore), 首次使用请复制 config.example.lua 为 config.lua 并修改
local okConfig = pcall(function()
    config = require "config"
end)
if not okConfig then
    log.error("main", "缺少 config.lua! 请复制 script/config.example.lua 为 script/config.lua, 修改后重新烧录")
    -- rtos.restart 可能立即复位也可能返回, 原地挂死避免后续 nil 崩溃
    while true do
        sys.wait(60000)
    end
end

-- 添加硬狗防止程序卡死
wdt.init(9000)
sys.timerLoopStart(wdt.feed, 3000)


-- 定时回收内存, 避免长期运行内存增长
sys.timerLoopStart(function()
       log.info("回收一次内存")
       collectgarbage("collect")
end,3600000) -- 每小时回收一次内存


-- 设置 DNS
socket.setDNS(nil, 1, "119.29.29.29")
socket.setDNS(nil, 2, "223.5.5.5")

-- SIM 自动恢复, 周期性获取小区信息, 网络遇到严重故障时尝试自动恢复等功能
mobile.setAuto(10000, 300000, 8, true, 120000)


-- 初始化 fskv
log.info("main", "fskv.init", fskv.init())

-- POWERKEY
local rtos_bsp = rtos.bsp()
local pin_table = {
    ["EC618"] = 35,
    ["EC718P"] = 46,
    ["AIR780E"] = 35,
    ["AIR780EP"] = 35,
    ["AIR780E4G"] = 35
}
-- 电源键引脚: 优先使用 config.POWERKEY_PIN, 未配置则按平台表自动匹配
local powerkey_pin = config.POWERKEY_PIN or pin_table[rtos_bsp]

log.info("main", "硬件平台:", rtos_bsp, "电源键引脚:", powerkey_pin or "未找到")

if powerkey_pin then
    local button_last_press_time, button_last_release_time = 0, 0
    log.info("main", "配置电源键引脚:", powerkey_pin)

    local gpio_result = gpio.setup(powerkey_pin, function()
        local current_time = mcu.ticks()
        local pin_state = gpio.get(powerkey_pin)
        log.debug("main", "电源键中断触发，引脚状态:", pin_state)

        -- 按下
        if pin_state == 0 then
            button_last_press_time = current_time -- 记录最后一次按下时间
            log.debug("main", "电源键按下")
            return
        end
        -- 释放
        if button_last_press_time == 0 then -- 开机前已经按下, 开机后释放
            log.debug("main", "电源键释放，但按下时间为0，忽略")
            return
        end
        if current_time - button_last_release_time < 250 then -- 防止连按
            log.debug("main", "电源键连按，忽略")
            return
        end
        local duration = current_time - button_last_press_time -- 按键持续时间
        button_last_release_time = current_time -- 记录最后一次释放时间
        log.info("main", "电源键释放，持续时间:", duration, "ms")

        if duration > 2000 then
            log.info("main", "电源键长按事件")
            sys.publish("POWERKEY_LONG_PRESS", duration)
        elseif duration > 50 then
            log.info("main", "电源键短按事件")
            sys.publish("POWERKEY_SHORT_PRESS", duration)
        end
    end, gpio.PULLUP)

    log.info("main", "电源键GPIO配置结果:", gpio_result)
else
    log.warn("main", "未找到支持的平台电源键引脚配置")
end

-- 加载模块
util_http = require "util_http"
util_netled = require "util_netled"
util_mobile = require "util_mobile"
util_location = require "util_location"
util_notify = require "util_notify"
util_forward = require "util_forward"
util_task = require "util_task"
util_sms_store = require "util_sms_store"
util_qqbot = require "util_qqbot"



if config.ROLE == "SLAVE" then
    -- 串口配置
    uart.setup(1, 115200, 8, 1, uart.NONE)
    -- 串口接收回调
    uart.on(1, "receive", function(id, len)
        -- 限制单次读取最大数据量，防止内存溢出
        local max_read_len = 1024  -- 最大1KB
        if len > max_read_len then
            len = max_read_len
            log.warn("uart", "数据量过大，截断处理", len)
        end

        local data = uart.read(id, len)
        if not data or data == "" then
            return
        end

        log.info("uart read:", id, len, data)
        -- 从机, 通过串口发送数据
        uart.write(1, data)
    end)
end

-- 短信控制管理员白名单校验 (config.SMS_ADMIN_NUMBERS, 空表 = 全部拒绝)
local function isSmsAdmin(sender_number)
    if type(config.SMS_ADMIN_NUMBERS) ~= "table" then
        return false
    end
    for _, admin in ipairs(config.SMS_ADMIN_NUMBERS) do
        if admin == sender_number then
            return true
        end
    end
    return false
end

-- 短信接收回调
-- 短信编码兜底: 部分运营商网关下发 GBK/GB2312, 固件按错误编码解码会乱码,
-- 检测到非合法 UTF-8 时尝试用 iconv 转码 (101 号固件内置, 全 pcall 保护)
local function tryGbkConvert(content)
    local ok_cd, cd = pcall(iconv.open, "utf8", "gb2312")
    if not ok_cd or not cd then
        return content
    end
    local ok_cv, converted = pcall(function()
        local out = cd:iconv(content)
        iconv.close(cd)
        return out
    end)
    if ok_cv and type(converted) == "string" and converted ~= "" then
        log.info("smsCallback", "短信按 GB2312 转码, 原长度", #content, "新长度", #converted)
        return converted
    end
    pcall(iconv.close, cd)
    return content
end

-- 快速校验是否为合法 UTF-8, 不合法则尝试转码
local function fixSmsEncoding(content)
    if type(content) ~= "string" or content == "" then
        return content
    end
    local i, n = 1, #content
    while i <= n do
        local b = content:byte(i)
        if b < 0x80 then
            i = i + 1
        elseif b < 0xC0 then
            return tryGbkConvert(content)  -- 以续字节开头, 非法
        else
            local len = (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
            if i + len - 1 > n then
                return tryGbkConvert(content)  -- 尾部截断的半个字符
            end
            for j = i + 1, i + len - 1 do
                local c = content:byte(j)
                if c < 0x80 or c >= 0xC0 then
                    return tryGbkConvert(content)  -- 续字节不连续
                end
            end
            i = i + len
        end
    end
    return content
end

sms.setNewSmsCb(function(sender_number, sms_content, m)
    local time = string.format("%d/%02d/%02d %02d:%02d:%02d", m.year + 2000, m.mon, m.day, m.hour, m.min, m.sec)
    sms_content = fixSmsEncoding(sms_content)
    log.info("smsCallback", time, sender_number, sms_content)

    -- 缓存最近短信, 供 Qbot 等交互通道查询
    util_sms_store.save(sender_number, sms_content, time)

    -- 短信控制
    local is_sms_ctrl = false
    -- 改进的正则表达式，支持国际号码格式
    -- 号码位数统一在下方校验（5~20 位），这里只负责拆分指令格式
    local receiver_number, sms_content_to_be_sent = sms_content:match("^SMS,([%+]?%d+),(.+)$")
    receiver_number, sms_content_to_be_sent = receiver_number or "", sms_content_to_be_sent or ""

    -- 增强号码验证
    if sms_content_to_be_sent ~= "" and receiver_number ~= "" then
        -- 管理员白名单校验, 防止任意发件人消耗本机短信
        if not isSmsAdmin(sender_number) then
            log.warn("smsCtrl", "非管理员号码, 已拒绝短信控制", "发件人", sender_number,
                "如需放行, 将该号码加入 config.SMS_ADMIN_NUMBERS")
        else
            -- 去除可能的空格和分隔符
            receiver_number = receiver_number:gsub("[%s%-]", "")

            -- 验证号码格式（5-20位数字，可含+号开头）
            if string.match(receiver_number, "^%+?%d%d%d%d%d%d?%d?%d?%d?%d?%d?%d?%d?%d?$") and
               #receiver_number >= 5 and #receiver_number <= 20 then
                sms.send(receiver_number, sms_content_to_be_sent)
                is_sms_ctrl = true
                log.info("smsCtrl", "发送短信", receiver_number, sms_content_to_be_sent)
            else
                log.warn("smsCtrl", "号码格式无效", receiver_number)
            end
        end
    end

    -- 使用转发模块处理短信
    local msg_with_tag = sms_content .. (is_sms_ctrl and " #CTRL" or "")
    util_forward.forwardSms(msg_with_tag, sender_number, time)
end)

sys.taskInit(function()
    -- 等待网络环境准备就绪
    sys.waitUntil("IP_READY", config.NETWORK_TIMEOUT_LONG)

    util_netled.init()

    -- 初始化转发模块
    if util_forward.init() then
        log.info("main", "转发模块初始化成功")
    else
        log.error("main", "转发模块初始化失败")
    end

    -- 启动 Qbot 交互通道 (独立任务, 异常不影响转发主流程)
    util_qqbot.start()

    -- 开机通知
    if config.BOOT_NOTIFY then
        local boot_reason = pm.lastReson()
        local boot_msg = "#BOOT_" .. boot_reason

        -- 添加设备信息到开机通知
        if config.NOTIFY_APPEND_MORE_INFO then
            boot_msg = boot_msg .. util_mobile.appendDeviceInfo()
        end

        log.info("main", "准备发送开机通知", "BOOT_NOTIFY", config.BOOT_NOTIFY, "开机原因", boot_reason, "消息", boot_msg)

        local timer_id = sys.timerStart(function()
            log.info("main", "定时器触发，开始发送开机通知", "消息", boot_msg, "定时器ID", timer_id)

            -- 尝试使用转发规则发送开机通知
            local forward_success = util_forward.forwardMessage(boot_msg, "BOOT")
            if forward_success then
                log.info("main", "开机通知通过转发规则发送成功")
            else
                log.info("main", "转发规则发送失败或无规则，使用默认通知方式")
                local result = util_notify.add(boot_msg)
                log.info("main", "开机通知发送结果", result)
            end
        end, 1000 * 5)

        log.info("main", "定时器已启动", "ID", timer_id, "延迟", 5000, "毫秒")
    else
        log.info("main", "开机通知已禁用", "BOOT_NOTIFY", config.BOOT_NOTIFY)
    end

    -- 定时同步时间
    if os.time() < 1714500000 then
        socket.sntp()
    end
    if type(config.SNTP_INTERVAL) == "number" and config.SNTP_INTERVAL >= 1000 * 60 then
        sys.timerLoopStart(socket.sntp, config.SNTP_INTERVAL)
    end

    -- 定时查询流量
    if type(config.QUERY_TRAFFIC_INTERVAL) == "number" and config.QUERY_TRAFFIC_INTERVAL >= 1000 * 60 then
        sys.timerLoopStart(util_mobile.queryTraffic, config.QUERY_TRAFFIC_INTERVAL)
    end

    -- 定时基站定位
    if type(config.LOCATION_INTERVAL) == "number" and config.LOCATION_INTERVAL >= 1000 * 60 then
        util_location.refresh(nil, true)
        sys.timerLoopStart(util_location.refresh, config.LOCATION_INTERVAL)
    end

    -- 定时上报
    if type(config.REPORT_INTERVAL) == "number" and config.REPORT_INTERVAL >= 1000 * 60 then
        sys.timerLoopStart(function() util_notify.add("#ALIVE_REPORT") end, config.REPORT_INTERVAL)
    end

    -- 设备重启管理（增加状态检查）
    local restart_enabled = config.RESTART_ENABLED  -- 从配置读取重启开关
    local restart_interval = config.RESTART_INTERVAL -- 从配置读取重启间隔

    -- 设备重启管理：定时器回调里严禁 sys.wait, 统一发 DEVICE_RESTART 事件,
    -- 由常驻重启协程完成清理与重启 (cleanupAllTasks 定义在本文件尾部, 协程启动时全局已就绪)
    if restart_enabled then
        sys.timerLoopStart(function()
            log.info("main", "准备重启设备", "重启间隔", restart_interval / 1000 / 60, "分钟")

            -- 检查是否有正在进行的操作
            local task_list = util_task.list()
            if #task_list > 0 then
                log.info("main", "发现活跃任务，延迟重启", "任务数量", #task_list)
                for _, task_name in ipairs(task_list) do
                    log.info("main", "活跃任务", task_name)
                end
                sys.timerStart(function()
                    log.info("main", "延迟重启设备")
                    sys.publish("DEVICE_RESTART")
                end, 60000)
            else
                log.info("main", "无活跃任务，立即重启设备")
                sys.publish("DEVICE_RESTART")
            end
        end, restart_interval)
    else
        log.info("main", "设备自动重启已禁用")
    end

    -- 电源键处理（短按/双击功能，带延迟区分）
    local single_click_timer = nil
    log.info("main", "注册电源键短按事件订阅")
    sys.subscribe("POWERKEY_SHORT_PRESS", function()
        log.info("main", "收到电源键短按事件")

        if single_click_timer then
            -- 双击：取消单击定时器，执行双击动作
            sys.timerStop(single_click_timer)
            single_click_timer = nil
            log.info("main", "检测到双击，发送开机通知测试")
            local boot_test_msg = "#BOOT_TEST_" .. pm.lastReson()
            local forward_success = util_forward.forwardMessage(boot_test_msg, "BOOT_TEST")
            if forward_success then
                log.info("main", "开机测试通知通过转发规则发送成功")
            else
                log.info("main", "转发规则发送失败，使用默认通知方式")
                util_notify.add(boot_test_msg)
            end
        else
            -- 首次按下：延迟500ms执行单击，等待可能的第二次按下
            single_click_timer = sys.timerStart(function()
                single_click_timer = nil
                log.info("main", "短按电源键，发送测试通知")
                local test_msg = "#ALIVE"
                local forward_success = util_forward.forwardMessage(test_msg, "TEST")
                if forward_success then
                    log.info("main", "测试通知通过转发规则发送成功")
                else
                    log.info("main", "转发规则发送失败，使用默认通知方式")
                    util_notify.add(test_msg)
                end
            end, 500)
        end
    end)

    -- 电源键长按查询流量
    log.info("main", "注册电源键长按事件订阅")
    sys.subscribe("POWERKEY_LONG_PRESS", function(duration)
        log.info("main", "收到电源键长按事件，持续时间:", duration, "ms")
        util_mobile.queryTraffic()
    end)
end)

sys.taskInit(function()
    if type(config.PIN_CODE) ~= "string" or config.PIN_CODE == "" then
        return
    end
    -- 开机等待短时间仍未联网, 再进行 pin 验证
    if not sys.waitUntil("IP_READY", config.NETWORK_TIMEOUT_SHORT) then
        util_mobile.pinVerify(config.PIN_CODE)
    end
end)

-- 定时开关飞行模式
if type(config.FLYMODE_INTERVAL) == "number" and config.FLYMODE_INTERVAL >= 1000 * 60 then
    sys.timerLoopStart(function()
        mobile.flymode(0, true)
        mobile.flymode(0, false)
    end, config.FLYMODE_INTERVAL)
end

-- 通话相关
local is_calling = false

sys.subscribe("CC_IND", function(status)
    if cc == nil then return end

    if status == "INCOMINGCALL" then
        -- 来电事件, 期间会重复触发
        if is_calling then return end
        is_calling = true

        log.info("cc_status", "INCOMINGCALL", "来电事件", cc.lastNum())

        -- 发送通知
        util_notify.add({ "来电号码: " .. cc.lastNum(), "来电时间: " .. os.date("%Y-%m-%d %H:%M:%S"), "#CALL #CALL_IN" })
        return
    end

    if status == "DISCONNECTED" then
        -- 挂断事件
        is_calling = false
        log.info("cc_status", "DISCONNECTED", "挂断事件", cc.lastNum())

        -- 发送通知
        util_notify.add({ "来电号码: " .. cc.lastNum(), "挂断时间: " .. os.date("%Y-%m-%d %H:%M:%S"), "#CALL #CALL_DISCONNECTED" })
        return
    end

    log.info("cc_status", status)
end)

-- 全局任务清理函数
function cleanupAllTasks()
    log.info("main", "开始清理所有任务")

    -- 清理各模块任务
    if util_notify.cleanup then
        util_notify.cleanup()
    end
    if util_location.cleanup then
        util_location.cleanup()
    end
    if util_netled.cleanup then
        util_netled.cleanup()
    end
    if util_qqbot.cleanup then
        util_qqbot.cleanup()
    end

    -- 清理任务管理器中的所有任务
    util_task.cleanup()

    log.info("main", "所有任务清理完成")
end

-- 设置调试模式
util_task.setDebug(false)  -- 可设置为true查看详细日志

-- 统一重启协程: 所有重启请求(DEVICE_RESTART 事件)都在协程内完成清理与复位,
-- 定时器/回调里严禁 sys.wait, 只发事件
sys.taskInit(function()
    while true do
        sys.waitUntil("DEVICE_RESTART")
        log.info("main", "执行设备重启流程")
        cleanupAllTasks()
        sys.wait(1000)  -- 等待任务清理完成
        rtos.restart()
    end
end)

-- 供电电压监控: 周期读取 VBAT, 低于阈值时走备用通知告警 (config.BAT_MONITOR 关闭则跳过)
sys.taskInit(function()
    if config.BAT_MONITOR == false then
        log.info("main", "电压监控已禁用", "BAT_MONITOR", config.BAT_MONITOR)
        return
    end
    sys.waitUntil("IP_READY", config.NETWORK_TIMEOUT_LONG)
    local low_threshold = config.BAT_LOW_MV or 3500  -- 毫伏
    local last_warn = 0
    while true do
        local mv = util_mobile.getVoltage()
        if mv and mv > 0 then
            log.info("main", "供电电压", string.format("%.2f V", mv / 1000))
            if mv < low_threshold and mcu.ticks() - last_warn > 3600000 then  -- 低电每小时最多告警一次
                last_warn = mcu.ticks()
                log.warn("main", "供电电压过低", mv .. "mV < " .. low_threshold .. "mV")
                util_notify.add("#BAT_LOW 供电电压过低: " .. string.format("%.2f V", mv / 1000)
                    .. "（阈值 " .. string.format("%.2f V", low_threshold / 1000) .. "），请检查供电")
            end
        end
        sys.wait(config.BAT_CHECK_INTERVAL or 600000)  -- 默认 10 分钟一次
    end
end)

sys.run()
