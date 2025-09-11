-- 欢迎使用万象拼音方案
-- @amzxyz
-- https://github.com/amzxyz/rime_wanxiang
--用来在声调辅助的时候当你输入2个数字的时候自动将声调替换为第二个数字，
--也就是说你发现输入错误声调你可以手动轮巡输入而不用回退删除直接输入下一个即可
--[[
local wanxiang = require("wanxiang")

---@return string
local function get_fallback_input(input_text)
    return input_text:gsub("%d+", function(match) return match:sub(-1) end)
end

local function should_ignore_context(ctx)
    return wanxiang.is_function_mode_active(ctx) or ctx.input == ""
end

local P = {}
function P.init(env)
    env.tone_fallback_update_connection =
        env.engine.context.update_notifier:connect(function(ctx)
            local input_text = ctx.input

            if should_ignore_context(ctx) then return end

            local new_input = get_fallback_input(input_text)
            if new_input ~= input_text then
                ctx.input = new_input
            end
        end)
end

function P.fini(env)
    if env.tone_fallback_update_connection then
        env.tone_fallback_update_connection:disconnect()
    end
end

---@return ProcessResult
function P.func(_, env)
    local ctx = env.engine.context
    local input_text = ctx.input

    if should_ignore_context(ctx) then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    local new_fallback = get_fallback_input(input_text)

    return new_fallback ~= input_text
        and wanxiang.RIME_PROCESS_RESULTS.kAccepted
        or wanxiang.RIME_PROCESS_RESULTS.kNoop
end

return P
]]-- 这面这个是数字回退


-- 用于在编码末尾对以下四个符号进行“轮换”：:"<>
-- 规则：末尾若出现由这些符号组成的连续串，则压缩为“只保留最后一个”。

local wanxiang = require("wanxiang")

-- 仅压缩“末尾的”连续符号串（:"<>）为其最后一个字符
local function collapse_trailing_marks(input_text)
    -- Lua pattern：([:"<>]+)$  —— 捕获“由 : " < > 组成的一个或多个，且在行尾”
    return input_text:gsub('([:"<>]+)$', function(run)
        -- run 至少长 1；当长度为 1 时返回自身（不改变）
        return run:sub(-1)
    end)
end

local function should_ignore_context(ctx)
    return wanxiang.is_function_mode_active(ctx) or ctx.input == ""
end

local P = {}

function P.init(env)
    local ctx = env.engine and env.engine.context
    if not ctx or not ctx.update_notifier then return end
    env.tone_fallback_update_connection = ctx.update_notifier:connect(function(c)
        if should_ignore_context(c) then return end
        local s = c.input
        local t = collapse_trailing_marks(s)
        if t ~= s then
        c.input = t
        end
    end)
end

function P.fini(env)
    if env.tone_fallback_update_connection then
        env.tone_fallback_update_connection:disconnect()
    end
end

---@return ProcessResult
function P.func(_, env)
    local ctx = env.engine.context
    if should_ignore_context(ctx) then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end
    local s = ctx.input
    local t = collapse_trailing_marks(s)
    -- 告知引擎“我做了有意义的处理”（实际修改已在 update_notifier 里完成）
    return (t ~= s) and wanxiang.RIME_PROCESS_RESULTS.kAccepted
                    or wanxiang.RIME_PROCESS_RESULTS.kNoop
end

return P