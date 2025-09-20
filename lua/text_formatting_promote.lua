-- @amzxyz  https://github.com/amzxyz/rime_wanxiang
-- 功能 A：候选文本中的转义序列格式化（始终开启）
--         \n \t \r \\ \s(空格) \d(-)
-- 功能 B：英文自动大写（始终开启）
--         - 首字母大写：输入首字母大写 → 候选首字母大写（Hello）
--         - 全部大写：输入前 2+ 个大写 → 候选全大写（HEllo → HELLO）
--         - 仅对 ASCII 单词生效；若候选含空格、-、@、#、· 等也认为是英文
-- 功能 C：候选重排（仅编码长度 2..6 时）
--         - 第一候选不动
--         - 其余按组输出：①不含字母(table/user_table) → ②其他
--         - 若第二候选为 table/user_table，则不排序，直接透传
-- 功能 D：成对符号包裹（触发：最后分段完整消耗且出现 prefix\suffix；suffix 命中映射时吞掉 \suffix）
-- 缓存/锁定：
--   - 未锁定时记录第一候选为缓存
--   - 出现 prefix\suffix 且 prefix 非空 ⇒ 锁定
--   - 输入为空时释放缓存/锁定
-- 镜像：
--   - schema: paired_symbols/mirror (bool，默认 true)
--   - 包裹后可抑制“包裹前文本/包裹后文本”再次出现在后续候选里

local M = {}

local byte, find, gsub, upper, sub = string.byte, string.find, string.gsub, string.upper, string.sub

-- ========= 工具 =========
local function fast_type(c)
    local t = c.type
    if t then return t end
    local g = c.get_genuine and c:get_genuine() or nil
    return (g and g.type) or ""
end

local function is_table_type(c)
    local t = fast_type(c)
    return t == "table" or t == "user_table"
end

local function has_english_token_fast(s)
    for i = 1, #s do
        local b = byte(s, i)
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return true end
        if b == 32 or b == 35 or b == 183 or b == 45 or b == 64 then return true end -- space/#/·/-/@
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

local function ascii_equal_ignore_case_to_pure(text, pure_code_lc)
    if #text ~= #pure_code_lc then return false end
    for i = 1, #text do
        local b = byte(text, i)
        if b >= 65 and b <= 90 then b = b + 32 end -- A..Z -> a..z
        if b ~= byte(pure_code_lc, i) then return false end
    end
    return true
end

-- ========= 文本格式化（转义 + 自动大写）=========
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

local function format_and_autocap(cand, code_ctx)
    local text = cand.text
    if not text or text == "" then return cand end

    local b1 = byte(text, 1)
    local has_backslash = (find(text, "\\", 1, true) ~= nil)
    if (not has_backslash) and b1 and b1 > 127 then
        return cand
    end

    local changed = false
    if has_backslash then
        local t2, ch = apply_escape_fast(text)
        if ch then text, changed = t2, true end
    end

    if code_ctx.enable_cap then
        if b1 and b1 <= 127 and is_ascii_word_fast(text) then
            if cand.type == "completion" or ascii_equal_ignore_case_to_pure(text, code_ctx.pure_code_lc) then
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

local function belong_group1_no_alpha(cand)
    return is_table_type(cand) and (not has_english_token_fast(cand.text))
end

-- ========= 包裹映射 =========
local default_wrap_map = {
    -- 单字母：常用成对括号/引号（每项恰好两个字符）
    a = "()",    -- 圆括号
    b = "[]",    -- 方括号
    c = "{}",    -- 花括号
    d = "<>",    -- 尖括号
    e = "\"\"",  -- 英文双引号
    f = "''",    -- 英文单引号
    g = "``",    -- 反引号
    h = "「」",  -- 直角引号
    i = "『』",  -- 双直角引号
    j = "“”",    -- 中文弯双引号
    k = "‘’",    -- 中文弯单引号
    l = "《》",  -- 书名号（双）
    m = "〈〉",  -- 书名号（单）
    n = "（）",  -- 全角圆括号
    o = "【】",  -- 黑方头括号
    p = "〔〕",  -- 方头括号
    q = "｛｝",  -- 全角花括号
    r = "［］",  -- 全角方括号
    s = "〈〉",   -- 数学尖括号
    t = "⟨⟩",   -- 数学角括号
    u = "⦅⦆",   -- 白圆括号
    v = "⦇⦈",   -- 白方括号
    w = "❰❱",   -- 装饰角括号
    x = "⟪⟫",   -- 双角括号
    y = "«»",    -- 法文双书名号
    z = "‹›",    -- 法文单书名号

    -- 双字母：其余成对括号族（不与上面重复）
    aa = "〖〗",
    bb = "〘〙",
    cc = "〚〛",
    dd = "❨❩",
    ee = "❪❫",
    ff = "❬❭",
    gg = "⦉⦊",
    hh = "⦋⦌",
    ii = "⦍⦎",
    jj = "⦏⦐",
    kk = "⦑⦒",
    ll = "❮❯",
    mm = "⌈⌉",
    nn = "⌊⌋",
    oo = "⟦⟧",
    pp = "⟮⟯",
    qq = "⟬⟭",
    rr = "❲❳",
    ss = "⌜⌝",
    tt = "⌞⌟",
    uu = "⸢⸣",
    vv = "⸤⸥",
    ww = "﹁﹂",
    xx = "﹃﹄",
    yy = "⌠⌡",
    zz = "⟅⟆",

    -- 双字母：重复/运算/标记类（值均为两字符，便于切左右）
    md = "**",       -- Markdown 粗体
    it = "__",       -- Markdown 斜体（下划线风格）
    st = "~~",       -- 删除线
    eq = "==",
    pl = "++",
    mi = "--",
    sl = "//",
    bs = "\\\\",     -- 反斜杠对（Lua 里写成 "\\\\")
    at = "@@",
    dl = "$$",
    pc = "%%",
    an = "&&",
    ["or"] = "||",
    cr = "^^",
    cl = "::",
    sc = ";;",
    ex = "!!",
    qu = "??",
}

local function load_mapping_from_config(config)
    local symbol_map = {}
    for k, v in pairs(default_wrap_map) do symbol_map[k] = v end
    local ok_map, map = pcall(function() return config:get_map("paired_symbols/symkey") end)
    if ok_map and map then
        local ok_keys, keys = pcall(function() return map:keys() end)
        if ok_keys and keys then
            for _, key in ipairs(keys) do
                local ok_val, v = pcall(function() return config:get_string("paired_symbols/symkey/" .. key) end)
                if ok_val and v and #v > 0 then symbol_map[string.lower(key)] = v end
            end
        end
    end
    return symbol_map
end

-- 预编译 wrap 对（优化项 1）
local function precompile_wrap_parts(wrap_map)
    local parts = {}
    for k, wrap_str in pairs(wrap_map) do
        local chars = {}
        for ch in wrap_str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do table.insert(chars, ch) end
        local l, r = "", ""
        if #chars >= 1 then l = chars[1] end
        if #chars >= 2 then r = chars[#chars] end
        parts[k] = { l = l, r = r }
    end
    return parts
end

local function clone_candidate(c)
    local nc = Candidate(c.type, c.start, c._end, c.text, c.comment)
    nc.preedit = c.preedit
    return nc
end

-- ========= 生命周期 =========
function M.init(env)
    local cfg = env.engine and env.engine.schema and env.engine.schema.config or nil
    env.wrap_map = cfg and load_mapping_from_config(cfg) or default_wrap_map

    -- 预编译左右括
    env.wrap_parts = precompile_wrap_parts(env.wrap_map)

    -- 分隔符：默认 "\\"；优先读取 paired_symbols/symbol，其次回退到 paired_symbols/trigger 的首字符
    env.symbol = "\\"
    if cfg then
        local ok_sym, sym = pcall(function() return cfg:get_string("paired_symbols/symbol") end)
        if ok_sym and sym and #sym > 0 then
            env.symbol = sub(sym, 1, 1)
        else
            local ok_tr, tr = pcall(function() return cfg:get_string("paired_symbols/trigger") end)
            if ok_tr and tr and #tr > 0 then
                env.symbol = sub(tr, 1, 1)
            end
        end
    end

    env.suppress_mirror = true
    if cfg then
        local okb, bv = pcall(function() return cfg:get_bool("paired_symbols/mirror") end)
        if okb and bv ~= nil then env.suppress_mirror = bv end
    end

    env.cache  = nil
    env.locked = false

    -- 可通过 schema 自定义排序窗口
    env.settings = env.settings or {}
    if cfg then
        local ok_win, win = pcall(function() return cfg:get_string("paired_symbols/sort_window") end)
        if ok_win and tonumber(win) then env.settings.sort_window = tonumber(win) end
    end
end

function M.fini(env) end

-- ========= 主流程 =========
function M.func(input, env)
    local ctx  = env and env.engine and env.engine.context or nil
    local code = ctx and (ctx.input or "") or ""
    local comp = ctx and ctx.composition or nil

    -- 输入为空：释放状态
    if (not code or code == "") or (comp and comp:empty()) then
        env.cache  = nil
        env.locked = false
        return
    end

    -- 仅在可能触发 wrap 时才做 segmentation
    local symbol = env.symbol
    local code_has_symbol = symbol and #symbol == 1 and (find(code, symbol, 1, true) ~= nil)

    -- 最后一段 & 是否完全消耗
    local last_seg, last_text, fully_consumed = nil, nil, false
    if code_has_symbol then
        last_seg = comp and comp:back()
        local segm = comp and comp:toSegmentation()
        local confirmed = 0
        if segm and segm.get_confirmed_position then confirmed = segm:get_confirmed_position() or 0 end
        if last_seg and last_seg.start and last_seg._end then
            fully_consumed = (last_seg.start == confirmed) and (last_seg._end == #code)
            if fully_consumed then last_text = sub(code, last_seg.start + 1, last_seg._end) end
        end
    end

    -- 解析 prefix\suffix（固定单字符分隔符）
    local lock_now, wrap_key, keep_tail_len = false, nil, 0
    if fully_consumed and last_text and symbol and #symbol == 1 then
        local pos = last_text:find(symbol, 1, true) -- plain 查找
        if pos and pos > 1 then
            local left  = sub(last_text, 1, pos - 1)
            local right = sub(last_text, pos + 1)
            if #left > 0 then
                lock_now = true
                keep_tail_len = 1 + #right
                local k = (right or ""):lower()
                if k ~= "" and env.wrap_map[k] then wrap_key = k end
            end
        end
    end
    env.locked = lock_now

    -- 大写/转义上下文
    local code_len    = #code
    local do_group    = (code_len >= 2 and code_len <= 6)
    local sort_window = 30
    if env and env.settings and tonumber(env.settings.sort_window) then
        sort_window = tonumber(env.settings.sort_window)
    end
    local pure_code   = gsub(code, "[%s%p]", "")
    local pure_code_lc = pure_code:lower()
    local all_upper   = code:find("^%u%u") ~= nil
    local first_upper = (not all_upper) and (code:find("^%u") ~= nil)
    local enable_cap  = (code_len > 1 and not code:find("^[%l%p]"))
    local code_ctx    = {
        pure_code = pure_code,
        pure_code_lc = pure_code_lc,
        all_upper = all_upper,
        first_upper = first_upper,
        enable_cap = enable_cap,
    }

    -- 真正吞尾（wrap_key 命中）时：把 end 统一到最后段，防止露出 \suffix
    local function unify_tail_span(c)
        if fully_consumed and wrap_key and last_seg and c and c._end ~= last_seg._end then
            local nc = Candidate(c.type, c.start, last_seg._end, c.text, c.comment)
            nc.preedit = c.preedit
            return nc
        end
        return c
    end

    -- 构造吞尾的包裹候选（使用预编译 parts
    local function build_wrapped_candidate(cand, wrapped)
        local start_pos = (last_seg and last_seg.start) or cand.start or 0
        local end_pos   = (last_seg and last_seg._end)  or (start_pos + #code)
        local nc = Candidate(cand.type, start_pos, end_pos, wrapped, cand.comment)
        nc.preedit = cand.preedit
        return nc
    end

    -- 置顶缓存但不吞尾
    local function build_cached_first_span(base_cand, keep_len)
        if not base_cand then return nil end
        local formatted = format_and_autocap(base_cand, code_ctx)
        local start_pos = (last_seg and last_seg.start) or 0
        local end_pos   = (last_seg and last_seg._end) or #code
        if keep_len and keep_len > 0 then end_pos = math.max(start_pos, end_pos - keep_len) end
        local nc = Candidate(formatted.type, start_pos, end_pos, formatted.text or "", formatted.comment)
        nc.preedit = formatted.preedit
        return nc
    end

    local function build_wrapped_from_base(base_cand, key)
        if not base_cand or not key then return nil end
        local pair = env.wrap_map[key]
        if not pair then return nil end
        local formatted = format_and_autocap(base_cand, code_ctx)
        local pr = env.wrap_parts[key] or {l = "", r = ""}
        local wrapped = (pr.l or "") .. (formatted.text or "") .. (pr.r or "")
        local nc = build_wrapped_candidate(formatted, wrapped)
        return nc, (formatted.text or ""), wrapped
    end

    -- 抑制镜像
    local suppress_set = nil

    -- ===== 非分组路径 =====
    if not do_group then
        local idx = 0
        for cand in input:iter() do
            idx = idx + 1

            -- 未锁定：记录第一候选（保留 clone 行为以保证数据独立性）
            if idx == 1 and (not env.locked) then
                env.cache = clone_candidate(cand)
            end

            if idx == 1 then
                if env.locked and (not wrap_key) and env.cache then
                    local nc = build_cached_first_span(env.cache, keep_tail_len)
                    if nc then yield(nc) end
                    goto continue_non_group
                end

                if wrap_key then
                    local base = env.cache or cand
                    local nc, base_text, wrapped_text = build_wrapped_from_base(base, wrap_key)
                    if nc then
                        yield(nc)
                        if env.suppress_mirror then
                            suppress_set = { }
                            suppress_set[base_text] = true
                            suppress_set[wrapped_text] = true
                        end
                    end
                    goto continue_non_group
                end

                cand = format_and_autocap(cand, code_ctx)
                yield(cand)
                goto continue_non_group
            end

            if env.suppress_mirror and suppress_set then
                local t = cand.text
                if suppress_set[t] then goto continue_non_group end
            end

            cand = format_and_autocap(cand, code_ctx)
            cand = unify_tail_span(cand)
            yield(cand)

            ::continue_non_group::
        end
        return
    end

    -- ===== 分组路径（2..6 码）=====
    local idx = 0
    local mode = "unknown"
    local grouped_cnt = 0
    local window_closed = false
    local group2_others = {}

    local function flush_groups()
        for _, c in ipairs(group2_others) do
            if env.suppress_mirror and suppress_set then
                local t = c.text
                if suppress_set[t] then
                    -- skip
                else
                    c = format_and_autocap(c, code_ctx)
                    c = unify_tail_span(c)
                    yield(c)
                end
            else
                c = format_and_autocap(c, code_ctx)
                c = unify_tail_span(c)
                yield(c)
            end
        end
        for i = #group2_others, 1, -1 do group2_others[i] = nil end -- 原地清空，降低 GC（轻优化）
    end

    for cand in input:iter() do
        idx = idx + 1

        if idx == 1 and (not env.locked) then
            env.cache = clone_candidate(cand)
        end

        if idx == 1 then
            local emitted = false

            if env.locked and (not wrap_key) and env.cache then
                local nc = build_cached_first_span(env.cache, keep_tail_len)
                if nc then yield(nc); emitted = true end
            elseif wrap_key then
                local base = env.cache or cand
                local nc, base_text, wrapped_text = build_wrapped_from_base(base, wrap_key)
                if nc then
                    yield(nc); emitted = true
                    if env.suppress_mirror then
                        suppress_set = {}
                        suppress_set[base_text] = true
                        suppress_set[wrapped_text] = true
                    end
                end
            end

            if not emitted then
                cand = format_and_autocap(cand, code_ctx)
                cand = unify_tail_span(cand)
                yield(cand)
            end

        elseif idx == 2 and mode == "unknown" then
            if is_table_type(cand) then
                mode = "passthrough"
                if env.suppress_mirror and suppress_set and suppress_set[cand.text] then
                    goto continue_group
                end
                cand = format_and_autocap(cand, code_ctx)
                cand = unify_tail_span(cand)
                yield(cand)
            else
                mode = "grouping"
                grouped_cnt = 1
                if belong_group1_no_alpha(cand) then
                    if env.suppress_mirror and suppress_set and suppress_set[cand.text] then
                        goto continue_group
                    end
                    cand = format_and_autocap(cand, code_ctx)
                    cand = unify_tail_span(cand)
                    yield(cand)
                else
                    table.insert(group2_others, cand)
                end
                if sort_window > 0 and grouped_cnt >= sort_window then
                    flush_groups()
                    window_closed = true
                end
            end

        else
            if mode == "passthrough" then
                if env.suppress_mirror and suppress_set and suppress_set[cand.text] then
                    goto continue_group
                end
                cand = format_and_autocap(cand, code_ctx)
                cand = unify_tail_span(cand)
                yield(cand)
            else
                if (not window_closed) and ((sort_window <= 0) or (grouped_cnt < sort_window)) then
                    grouped_cnt = grouped_cnt + 1
                    if belong_group1_no_alpha(cand) then
                        if env.suppress_mirror and suppress_set and suppress_set[cand.text] then
                            goto continue_group
                        end
                        cand = format_and_autocap(cand, code_ctx)
                        cand = unify_tail_span(cand)
                        yield(cand)
                    else
                        table.insert(group2_others, cand)
                    end
                    if sort_window > 0 and grouped_cnt >= sort_window then
                        flush_groups()
                        window_closed = true
                    end
                else
                    if env.suppress_mirror and suppress_set and suppress_set[cand.text] then
                        goto continue_group
                    end
                    cand = format_and_autocap(cand, code_ctx)
                    cand = unify_tail_span(cand)
                    yield(cand)
                end
            end
        end

        ::continue_group::
    end

    if mode == "grouping" and not window_closed then
        flush_groups()
    end
end

return M