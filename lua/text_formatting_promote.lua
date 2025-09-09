-- @amzxyz https://github.com/amzxyz/rime_wanxiang
--[[
  功能 A：候选文本中的转义序列格式化（始终开启）
           \n \t \r \\ \s(空格) \d(-)
  功能 B：英文自动大写（始终开启）
           - 首字母大写：输入首字母大写 → 候选首字母大写（Hello）
           - 全部大写：输入前 2+ 个大写 → 候选全大写（HEllo → HELLO）
           - 若候选含非 ASCII（如汉字）、含空格、或编码与候选不匹配等，则不转换
  功能 C：候选重排（仅编码长度 2..6 时）
           - 仅“table 词组类型”且 cand.text 字符数 ≥ 编码长度 的候选被前置到第 2/3/4…
           - 第 1 候选永远不动（避免干扰置顶）
]]

local M = {}

------------------------------------------------------------
-- 工具函数：UTF-8 字符长度
------------------------------------------------------------
local function ulen(s)
    if type(s) ~= "string" then return 0 end
    if utf8 and utf8.len then
        local n = utf8.len(s)
        if n then return n end
        local c = 0
        for _ in utf8.codes(s) do c = c + 1 end
        return c
    end
    local c = 0
    for _ in string.gmatch(s, "[%z\1-\127\194-\244][\128-\191]*") do c = c + 1 end
    return c
end

------------------------------------------------------------
-- 功能 C：判定 table 词组类型
------------------------------------------------------------
local function is_table_phrase(cand)
    local g = cand.get_genuine and cand:get_genuine() or cand
    local t = (g and g.type) or cand.type or ""
    return t == "table" or t == "user_table" or t == "table_phrase"
end

------------------------------------------------------------
-- 功能 A：文本转义格式化
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

local function format_text(text)
    if type(text) ~= "string" then return text, false end
    if not text:find(esc_pattern) then return text, false end
    local new_text = text:gsub(esc_pattern, function(esc) return escape_map[esc] or esc end)
    return new_text, new_text ~= text
end

local function with_formatted_text(cand)
    local new_text, changed = format_text(cand.text)
    if not changed then return cand end
    local nc = Candidate(cand.type, cand.start, cand._end, new_text, cand.comment)
    nc.preedit = cand.preedit
    return nc
end

------------------------------------------------------------
-- 功能 B：英文自动大写（依据输入码形态）
------------------------------------------------------------
local function autocap_candidate(cand, code)
    local code_len = #code
    -- 码长为 1 或首位为小写/标点：不转换
    if code_len == 1 or code:find("^[%l%p]") then
        return cand
    end

    -- 输入码形态判断
    local all_upper  = code:find("^%u%u") ~= nil   -- 前 2+ 位大写 → 全大写
    local first_upper = (not all_upper) and (code:find("^%u") ~= nil)

    if not (all_upper or first_upper) then
        return cand
    end

    -- 仅对“ASCII 单词”做大写：含非 ASCII/含空格 跳过
    local text = cand.text
    if text:find("[^%w%p%s]") or text:find("%s") then
        return cand
    end

    -- 编码/候选一致性检查
    local pure_code = code:gsub("[%s%p]", "")
    local pure_text = text:gsub("[%s%p]", "")
    -- 编码完全匹配候选（忽略大小写）→ 不改，以免影响词频学习
    if pure_text:lower() == pure_code:lower() then
        return cand
    end
    -- 非 completion 且编码与候选不一致 → 不改，避免 PS→Photoshop 之类
    if cand.type ~= "completion" and pure_code:lower() ~= pure_text:lower() then
        return cand
    end

    -- 应用大小写变换
    local new_text
    if all_upper then
        new_text = text:upper()
    elseif first_upper then
        new_text = text:gsub("^%a", string.upper)
    end
    if not new_text or new_text == text then
        return cand
    end

    local nc = Candidate(cand.type, cand.start, cand._end, new_text, cand.comment)
    nc.preedit = cand.preedit
    return nc
end

------------------------------------------------------------
-- 主滤镜：A(格式化) → B(自动大写) → C(按需重排)
------------------------------------------------------------
function M.func(input, env)
    local code = env.engine.context.input or ""
    local code_len = #code
    local do_promote = (code_len > 1 and code_len <= 6)

    if not do_promote then
        -- 仅 A + B，不重排
        for cand in input:iter() do
        cand = with_formatted_text(cand)
        cand = autocap_candidate(cand, code)
        yield(cand)
        end
        return
    end

    -- A + B + C：第一候选不动，其余根据规则挑出“长词”前置
    local first
    local promote, rest = {}, {}
    local i = 0

    for cand in input:iter() do
        cand = with_formatted_text(cand)       -- 功能 A
        cand = autocap_candidate(cand, code)   -- 功能 B

        i = i + 1
        if i == 1 then
        first = cand                          -- 第 1 候选永远不动
        else
        if is_table_phrase(cand) and ulen(cand.text) >= code_len then
            promote[#promote + 1] = cand        -- 符合条件：保持原相对顺序，前置
        else
            rest[#rest + 1] = cand              -- 其余：顺序不变跟在后
        end
        end
    end

    if first then yield(first) end
    for _, c in ipairs(promote) do yield(c) end
    for _, c in ipairs(rest)   do yield(c) end
end

return M