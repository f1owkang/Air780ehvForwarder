-- ============================================================
-- 项目配置文件 —— 所有需要修改的配置全部集中在本文件
--
--   第 1 节: 系统与网络
--   第 2 节: Qbot
--   第 3 节: 短信控制安全
--   第 4 节: 转发规则 (FORWARD_RULES)
--   第 5 节: 备用通知
--
--   各渠道完整配置示例见 README.md "转发渠道" 一节
-- ============================================================
return {

    -- ==================== 1. 系统与网络 ====================

    -- 角色类型, 用于区分主从机, 仅当使用串口转发时才需要配置
    -- MASTER: 主机, 可主动联网; SLAVE: 从机, 不可主动联网, 通过串口发送数据
    ROLE = "MASTER",

    -- 电源键引脚 (GPIO 编号)
    -- nil = 按平台自动匹配; Air780EHV 等未收录平台可查硬件手册后填写(如 35)
    POWERKEY_PIN = nil,

    -- 设备自动重启配置
    RESTART_ENABLED = true,                    -- 是否启用自动重启
    RESTART_INTERVAL = 72 * 60 * 60 * 1000,    -- 重启间隔，72小时

    -- 定时查询流量间隔, 单位毫秒, 设置为 0 关闭
    QUERY_TRAFFIC_INTERVAL = 0,

    -- 定时基站定位间隔, 单位毫秒, 设置为 0 关闭
    LOCATION_INTERVAL = 0,

    -- 定时开关飞行模式间隔, 单位毫秒, 设置为 0 关闭
    FLYMODE_INTERVAL = 1000 * 60 * 60 * 12,

    -- 定时同步时间间隔, 单位毫秒, 设置为 0 关闭
    SNTP_INTERVAL = 1000 * 60 * 60 * 6,

    -- 定时上报间隔, 单位毫秒, 设置为 0 关闭
    REPORT_INTERVAL = 0,

    -- 开机通知 (会消耗流量)
    BOOT_NOTIFY = true,

    -- 是否过滤上线通知 (设置为false可以收到开机通知)
    FILTER_BOOT_NOTIFY = false,

    -- 通知内容追加更多信息 (通知内容增加会导致流量消耗增加)
    NOTIFY_APPEND_MORE_INFO = true,

    -- 通知最大重发次数
    NOTIFY_RETRY_MAX = 20,

    -- 本机号码, 优先使用 mobile.number() 接口获取, 如果获取不到则使用此号码
    FALLBACK_LOCAL_NUMBER = "",

    -- SIM 卡 pin 码
    PIN_CODE = "",

    -- 网络超时配置 (单位: 毫秒)
    NETWORK_TIMEOUT_DEFAULT = 1000 * 60,      -- 默认1分钟
    NETWORK_TIMEOUT_LONG = 1000 * 60 * 5,     -- 长超时5分钟
    NETWORK_TIMEOUT_SHORT = 1000 * 10,        -- 短超时10秒
    NETWORK_TIMEOUT_LOCATION = 1000 * 30,     -- 定位服务30秒

    -- 网络恢复配置
    FLYMODE_THRESHOLD = 4,                     -- 连续失败多少次才开启飞行模式
    FLYMODE_ENABLE = true,                     -- 是否启用飞行模式自动恢复

    -- ==================== 2. Qbot ====================
    -- 设备直连 Qbot, 单聊/群@下发指令, 开启步骤见 README "Qbot 交互"
    QQBOT_ENABLED = false,
    QQBOT_APPID = "",
    QQBOT_SECRET = "",

    -- 消息用 markdown 格式发送 (需机器人具备 markdown 消息权限; 发送失败自动回退纯文本)
    QQBOT_MARKDOWN = false,

    -- 允许下指令的 QQ openid 白名单 (防止他人操控设备)
    -- 未配置的用户发消息会收到欢迎回复(含其 openid 与配置方法), 每个 openid 最多 3 次
    QQBOT_ALLOW = {
        -- "你的openid",
    },

    -- ==================== 3. 短信控制安全 ====================
    -- 允许触发 "SMS,号码,内容" 短信控制指令的管理员号码白名单
    -- 空表 = 全部拒绝; 首次触发时串口日志会打印发件号码, 复制进来即可
    SMS_ADMIN_NUMBERS = {
        -- "13800138000",
    },

    -- ==================== 4. 转发规则 ====================
    -- 每条规则 = channel + 匹配字段(keyword/regular 二选一) + 渠道专属字段
    -- channel: wecom / feishu / dingding / custom_post / email / qq
    -- keyword: 关键词部分匹配, 不区分大小写, "all" 匹配所有消息
    -- regular: Lua 正则模式匹配, 区分大小写 (与 keyword 二选一)
    FORWARD_RULES = {
        {
            channel = "wecom",
            keyword = "all",
            webhook = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=your-webhook-key"
        },

        -- QQ 单聊推送 (openid 从 Qbot 欢迎回复中获取)
        -- {
        --     channel = "qq",
        --     keyword = "all",
        --     openid = "your-openid"
        -- },

        -- QQ 群推送 (group_openid 从串口日志"收到群@消息"处获取)
        -- {
        --     channel = "qq",
        --     keyword = "all",
        --     group_openid = "your-group-openid"
        -- },

        -- 邮件 (QQ 邮箱需使用授权码而非登录密码)
        -- {
        --     channel = "email",
        --     keyword = "验证码",
        --     smtp_server = "smtp.qq.com", smtp_port = 465, smtp_ssl = true,
        --     smtp_username = "user@qq.com", smtp_password = "授权码",
        --     email_from = "user@qq.com", email_to = "recipient@example.com"
        -- },
    },

    -- ==================== 5. 备用通知 ====================
    -- 转发规则失败/开机通知失败/来电时的兜底通知渠道, 留空 = 不启用
    -- 默认备用渠道为 feishu (见 util_notify)
    FEISHU_WEBHOOK = "",
    FEISHU_SECRET = "",                      -- 可选, 飞书签名
    WECOM_WEBHOOK = "",
    DINGTALK_WEBHOOK = "",
    DINGTALK_SECRET = "",                    -- 可选, 钉钉加签
    CUSTOM_POST_URL = "",
    CUSTOM_POST_CONTENT_TYPE = "application/x-www-form-urlencoded",
    CUSTOM_POST_BODY_TABLE = nil,            -- 例: { title = "通知", desp = "{msg}" }
}
