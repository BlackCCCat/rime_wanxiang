-- @amzxyz  https://github.com/amzxyz/rime_wanxiang
-- 功能 A：候选文本中的转义序列格式化（始终开启）
--         \n \t \r \\ \s(空格) \d(-)
-- 功能 B：英文自动大写（始终开启）
--         - 首字母大写：输入首字母大写 → 候选首字母大写（Hello）
--         - 全部大写：输入前 2+ 个大写 → 候选全大写（HEllo → HELLO）
--         - 仅对 ASCII 单词生效；若候选含非 ASCII、含空格、或编码与候选不匹配等，则不转换
-- 功能 C：候选重排（仅编码长度 2..6 时）
--         - 第一候选永远不动
--         - 其余按组输出：①不含字母 → ②纯字母且与编码完全相同（忽略大小写）→ ③其他
--         - 仅 table 系列参与分组（table/user_table），非 table 归入“其他”
-- 新增规则：
--         - 若“第二候选”为 user_table，则不执行任何排序；按原顺序（仅做 A、B）直接输出并返回
-- 性能优化：
--         - 单次遍历；中文/emoji 等（首字节>0x7F）且不含 '\' 的候选极早退
--         - 正则改字节级判断；仅必要时 new Candidate
--         - 支持排序窗口（env.settings.sort_window，默认 30；<=0 表示无限制）

local M = {}

------------------------------------------------------------
-- 快路径：局部化常用 string API
------------------------------------------------------------
local byte, find, gsub, upper = string.byte, string.find, string.gsub, string.upper

------------------------------------------------------------
-- 候选类型判定（尽量避免频繁 get_genuine）
------------------------------------------------------------
local function fast_type(c)
    local t = c.type
    if t then return t end
    local g = c.get_genuine and c:get_genuine() or nil
    return (g and g.type) or ""
end

local function is_table_phrase(c)
    local t = fast_type(c)
    return t == "table" or t == "user_table"
end

local function is_user_table(c)
    return fast_type(c) == "user_table"
end

------------------------------------------------------------
-- ASCII 字节级工具（替代正则，减少分配）
------------------------------------------------------------
local function has_ascii_alpha_fast(s)
    for i = 1, #s do
        local b = byte(s, i)
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return true end
    end
    return false
end

local function is_ascii_word_fast(s)
    if s == "" then return false end
    for i = 1, #s do
        local b = byte(s, i)
        if not ((b >= 65 and b <= 90) or (b >= 97 and b <= 122)) then return false end
    end
    return true
end

local function ascii_equal_ignore_case(a, b)
    local la = #a
    if la ~= #b then return false end
    for i = 1, la do
        local ba, bb = byte(a, i), byte(b, i)
        if ba >= 65 and ba <= 90 then ba = ba + 32 end
        if bb >= 65 and bb <= 90 then bb = bb + 32 end
        if ba ~= bb then return false end
    end
    return true
end

------------------------------------------------------------
-- 功能 A：文本转义（仅在确有 '\' 时处理）
------------------------------------------------------------
local escape_map = {
    ["\\n"] = "\n",
    ["\\t"] = "\t",
    ["\\r"] = "\r",
    ["\\\\"] = "\\",
    ["\\s"] = " ",
    ["\\d"] = "-",
}
local esc_pattern = "\\[ntrsd\\\\]"

local function apply_escape_fast(text)
    if not text or find(text, "\\", 1, true) == nil then return text, false end
    local new_text = gsub(text, esc_pattern, function(esc) return escape_map[esc] or esc end)
    return new_text, new_text ~= text
end

------------------------------------------------------------
-- 功能 A+B 合并：仅在必要时 new Candidate；加入极早退
------------------------------------------------------------
local function format_and_autocap(cand, code_ctx)
    local text = cand.text
    if not text or text == "" then return cand end

    -- ★ 极早退：首字节非 ASCII 且不含 '\' → 直接返回（中文/emoji 等）
    local b1 = byte(text, 1)
    local has_backslash = (find(text, "\\", 1, true) ~= nil)
    if (not has_backslash) and b1 and b1 > 127 then
        return cand
    end

    local changed = false

    -- A：转义（仅在确有 '\' 时）
    if has_backslash then
        local t2, ch = apply_escape_fast(text)
        if ch then text, changed = t2, true end
    end

    -- B：自动大写（仅在编码形态触发时 + 文本可能是 ASCII 单词）
    if code_ctx.enable_cap then
        -- 快速否决：包含空格或首字节非 ASCII → 跳过
        if b1 and b1 <= 127 and find(text, " ", 1, true) == nil and is_ascii_word_fast(text) then
        -- 仅当 completion 或与 pure_code 忽略大小写一致时才改，避免 PS→Photoshop 误改
        if cand.type == "completion" or ascii_equal_ignore_case(text, code_ctx.pure_code) then
            local new_text
            if code_ctx.all_upper then
            new_text = upper(text)
            else
            new_text = text:gsub("^%a", string.upper)
            end
            if new_text and new_text ~= text then
            text, changed = new_text, true
            end
        end
        end
    end

    if not changed then return cand end
    local nc = Candidate(cand.type, cand.start, cand._end, text, cand.comment)
    nc.preedit = cand.preedit
    return nc
end

------------------------------------------------------------
-- 功能 C：分组判定（字节级）
------------------------------------------------------------
local function belong_group1_no_alpha(cand)
    return is_table_phrase(cand) and (not has_ascii_alpha_fast(cand.text))
end

local function belong_group2_equal_alpha(cand, pure_code)
    if not is_table_phrase(cand) then return false end
    local txt = cand.text
    return is_ascii_word_fast(txt) and is_ascii_word_fast(pure_code) and ascii_equal_ignore_case(txt, pure_code)
end

------------------------------------------------------------
-- 主滤镜：单次遍历 + “第二候选 user_table 直通” + 排序窗口
------------------------------------------------------------
function M.func(input, env)
    local code = env.engine.context.input or ""
    local code_len = #code
    local do_group = (code_len >= 2 and code_len <= 6)

    -- 排序窗口：只对前 N 个（不含第 1 个）参与分组；<=0 表示无限制
    local sort_window = 50
    if env and env.settings and tonumber(env.settings.sort_window) then
        sort_window = tonumber(env.settings.sort_window)
    end

    -- 预计算编码形态
    local pure_code = code:gsub("[%s%p]", "")
    local all_upper   = code:find("^%u%u") ~= nil
    local first_upper = (not all_upper) and (code:find("^%u") ~= nil)
    local enable_cap  = (code_len > 1 and not code:find("^[%l%p]"))

    local code_ctx = {
        pure_code = pure_code,      -- 仅字母的编码串（已去空格/标点）
        all_upper = all_upper,      -- 前 2+ 位大写
        first_upper = first_upper,  -- 首位大写
        enable_cap = enable_cap,    -- 是否触发自动大写逻辑
    }

    -- 非分组场景：仅做 A+B
    if not do_group then
        for cand in input:iter() do
        yield(format_and_autocap(cand, code_ctx))
        end
        return
    end

    local idx = 0
    local mode = "unknown"   -- "unknown" | "passthrough" | "grouping"
    local grouped_cnt = 0    -- 已参与分组的数量（不含第 1 个）
    local window_closed = false

    local group2_equal_alpha = {}
    local group3_others = {}

    local function flush_groups()
        for _, c in ipairs(group2_equal_alpha) do yield(c) end
        for _, c in ipairs(group3_others)     do yield(c) end
        group2_equal_alpha = {}
        group3_others = {}
    end

    for cand in input:iter() do
        idx = idx + 1
        cand = format_and_autocap(cand, code_ctx)

        if idx == 1 then
        -- 第一候选永远不动
        yield(cand)

        elseif idx == 2 and mode == "unknown" then
        -- 第二候选是否 user_table → 直通
        if is_user_table(cand) then
            mode = "passthrough"
            yield(cand)
        else
            mode = "grouping"
            grouped_cnt = 1
            if belong_group1_no_alpha(cand) then
            yield(cand) -- 组①即时吐
            elseif belong_group2_equal_alpha(cand, pure_code) then
            group2_equal_alpha[#group2_equal_alpha + 1] = cand
            else
            group3_others[#group3_others + 1] = cand
            end
            if sort_window > 0 and grouped_cnt >= sort_window then
            flush_groups()
            window_closed = true
            end
        end

        else
        if mode == "passthrough" then
            -- 完全直通：A+B 后原序输出
            yield(cand)

        else
            -- 分组模式
            if (not window_closed) and ((sort_window <= 0) or (grouped_cnt < sort_window)) then
            grouped_cnt = grouped_cnt + 1
            if belong_group1_no_alpha(cand) then
                yield(cand) -- 组①即时吐
            elseif belong_group2_equal_alpha(cand, pure_code) then
                group2_equal_alpha[#group2_equal_alpha + 1] = cand
            else
                group3_others[#group3_others + 1] = cand
            end
            -- 达到窗口上限：先冲洗，再把后续全部直通
            if sort_window > 0 and grouped_cnt >= sort_window then
                flush_groups()
                window_closed = true
            end
            else
            -- 已超出窗口：后续候选保持原序直通（仍做 A、B）
            yield(cand)
            end
        end
        end
    end

    -- 流结束但窗口未关：补一次冲洗
    if mode == "grouping" and not window_closed then
        flush_groups()
    end
end

return M