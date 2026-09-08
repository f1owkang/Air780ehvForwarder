-- 最近短信环形缓存 (fskv 持久化, 断电不丢失)
-- 供 Qbot 等交互通道查询最近收到的短信

local util_sms_store = {}

local MAX_COUNT = 20            -- 环形容量(条)
local MAX_CONTENT_BYTES = 300   -- 单条内容截断长度(字节)

--- 按字节截断字符串, 保证不把 UTF-8 多字节字符切成两半
local function utf8Sub(s, max_bytes)
    if type(s) ~= "string" or #s <= max_bytes then
        return s or ""
    end
    local i = max_bytes
    -- 回退到字符起始边界 (ASCII 或多字节首字节)
    while i > 0 do
        local b = s:byte(i)
        if b and (b < 0x80 or b >= 0xC0) then
            break
        end
        i = i - 1
    end
    return s:sub(1, i) .. "…"
end

--- 保存一条最近短信
-- @param sender 发件号码
-- @param content 短信内容
-- @param time 接收时间文本
function util_sms_store.save(sender, content, time)
    if type(content) ~= "string" or content == "" then
        return
    end

    local idx = tonumber(fskv.get("sms_recent_idx")) or 0
    local total = tonumber(fskv.get("sms_recent_total")) or 0

    idx = idx % MAX_COUNT + 1
    if total < MAX_COUNT then
        total = total + 1
    end

    fskv.set("sms_recent_idx", idx)
    fskv.set("sms_recent_total", total)
    fskv.set("sms_recent_" .. idx, json.encode({
        sender = tostring(sender or ""),
        content = utf8Sub(content, MAX_CONTENT_BYTES),
        time = tostring(time or ""),
    }))
    log.debug("util_sms_store", "缓存短信", idx .. "/" .. total, sender)
end

--- 取最近 n 条短信 (新→旧)
-- @return table 数组, 元素为 {sender, content, time}
function util_sms_store.recent(n)
    n = math.min(math.max(tonumber(n) or 5, 1), MAX_COUNT)

    local idx = tonumber(fskv.get("sms_recent_idx")) or 0
    local total = tonumber(fskv.get("sms_recent_total")) or 0

    local list = {}
    for i = 0, math.min(n, total) - 1 do
        local pos = idx - i
        while pos < 1 do
            pos = pos + MAX_COUNT
        end
        local raw = fskv.get("sms_recent_" .. pos)
        if type(raw) == "string" and raw ~= "" then
            local ok, item = pcall(json.decode, raw)
            if ok and type(item) == "table" then
                table.insert(list, item)
            end
        end
    end
    return list
end

--- 已缓存条数
function util_sms_store.count()
    return tonumber(fskv.get("sms_recent_total")) or 0
end

--- 最近 n 条短信的文本格式 (直接用于聊天回复)
function util_sms_store.recentText(n)
    local list = util_sms_store.recent(n)
    if #list == 0 then
        return "暂无短信记录"
    end
    local parts = {}
    for i, item in ipairs(list) do
        table.insert(parts, string.format("[%d] %s\n来自: %s\n%s",
            i, item.time or "", item.sender or "", item.content or ""))
    end
    return table.concat(parts, "\n----\n")
end

return util_sms_store
