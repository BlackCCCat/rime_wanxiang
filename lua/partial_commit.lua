-- ctrl_partial_commit.lua
-- Ctrl+1..9：上屏首选前 N 字；按 preedit/script_text 的前 N 音节对齐 raw input
local wanxiang = require("wanxiang")

local M = {}
local DIGIT = { [0x31]=1,[0x32]=2,[0x33]=3,[0x34]=4,[0x35]=5,[0x36]=6,[0x37]=7,[0x38]=8,[0x39]=9,[0x30]=10 }
local KP    = { [0xFFB1]=1,[0xFFB2]=2,[0xFFB3]=3,[0xFFB4]=4,[0xFFB5]=5,[0xFFB6]=6,[0xFFB7]=7,[0xFFB8]=8,[0xFFB9]=9,[0xFFB0]=10 }

local function utf8_head(s, n)
    local i, c = 1, 0
    while i <= #s and c < n do
        local b = s:byte(i)
        i = i + ((b < 0x80) and 1 or ((b < 0xE0) and 2 or ((b < 0xF0) and 3 or 4)))
        c = c + 1
    end
    return s:sub(1, i - 1)
end

-- tone_display 开：用上下文保存的 preedit；否则用 script_text
local function script_prefix(ctx, n)
    local use_env = ctx:get_option("tone_display")
    local s = ""

    if use_env then
        if (ctx:get_property("sequence_preedit_key") or "") == (ctx.input or "") then
            s = ctx:get_property("sequence_preedit_val") or ""
        else
            return ""
        end
    else
        s = ctx:get_script_text() or ""
    end
    if s == "" then return "" end

    -- 按分隔符切音节 → 取前 n 个 → 无分隔符拼接
    local cfg = ctx.engine and ctx.engine.schema and ctx.engine.schema.config
    local delimiter = (cfg and cfg:get_string("speller/delimiter")) or " '"
    local auto   = delimiter:sub(1, 1)
    local manual = delimiter:sub(2, 2)
    local function esc(c) return (c:gsub("(%W)", "%%%1")) end
    local pat = "[^" .. esc(auto) .. esc(manual) .. "%s]+"

    local parts = {}
    for w in s:gmatch(pat) do parts[#parts + 1] = w end
    if #parts == 0 then return "" end

    local upto = math.min(n, #parts)
    return table.concat({ table.unpack(parts, 1, upto) }, "")
end

-- 简化版：不再跳过任何分隔符，严格逐字符对齐 raw 与 target
local function eat_len_by_target(ctx, target)
    if target == "" then return 0 end
    local raw = ctx.input or ""
    if raw == "" then return 0 end

    local i, j, Lr, Lt = 1, 1, #raw, #target
    while i <= Lr and j <= Lt do
        if raw:sub(i, i) ~= target:sub(j, j) then
            return 0
        end
        i, j = i + 1, j + 1
    end
    if j <= Lt then return 0 end
    return i - 1
end

-- 简单的“待回写”状态
local function set_pending(env, rest) env._cpc_pending_rest = rest or "" end
local function has_pending(env) return type(env._cpc_pending_rest) == "string" and env._cpc_pending_rest ~= nil end
local function take_pending(env) local r = env._cpc_pending_rest; env._cpc_pending_rest = nil; return r end

function M.init(env)
    -- 在组合更新里回写余码，并确保“先刷新→再设 caret→再刷新”
    env._cpc_update_conn = env.engine.context.update_notifier:connect(function(ctx)
        if not has_pending(env) then return end
        local rest = take_pending(env) or ""

        -- 先改 input
        ctx.input = rest

        -- 清理/刷新一次（部分前端会在此重置 caret）
        if ctx.clear_non_confirmed_composition then
            ctx:clear_non_confirmed_composition()
        end
        ctx:refresh_non_confirmed_composition()

        -- 把光标放到余码末尾
        if ctx.caret_pos ~= nil then
            ctx.caret_pos = #rest   -- raw 为 ASCII，字节数即长度
        end

        -- 再刷新一次巩固 caret
        ctx:refresh_non_confirmed_composition()
    end)
end

function M.fini(env)
    if env._cpc_update_conn then
        env._cpc_update_conn:disconnect()
        env._cpc_update_conn = nil
    end
end

function M.func(key, env)
    -- 只在按下时处理（release 忽略），避免依赖抬起；Ctrl 必须按下
    if not key:ctrl() or key:release() then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    local n = DIGIT[key.keycode] or KP[key.keycode]
    if not n then return wanxiang.RIME_PROCESS_RESULTS.kNoop end

    local ctx = env.engine.context
    if not ctx:is_composing() then return wanxiang.RIME_PROCESS_RESULTS.kNoop end

    local cand = ctx:get_selected_candidate() or ctx:get_candidate(0)
    if not cand or not cand.text or #cand.text == 0 then return wanxiang.RIME_PROCESS_RESULTS.kNoop end

    local h = utf8_head(cand.text, n)
    if h == "" then return wanxiang.RIME_PROCESS_RESULTS.kNoop end

    -- 预先计算余码（严格按前 N 音节对齐 raw）
    local target = script_prefix(ctx, n)
    local eat = eat_len_by_target(ctx, target)
    local raw = ctx.input or ""
    local rest = (eat > 0) and raw:sub(eat + 1) or raw

    -- 1) 先上屏前 n 字
    env.engine:commit_text(h)

    -- 2) 把余码交给 update_notifier 回写与定位 caret
    set_pending(env, rest)

    -- 3) 立即刷新，确保不依赖按键抬起
    ctx:refresh_non_confirmed_composition()

    return wanxiang.RIME_PROCESS_RESULTS.kAccepted
end

return M
