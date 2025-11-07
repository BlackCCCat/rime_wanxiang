-- @amzxyz  https://github.com/amzxyz/rime_wanxiang
-- 功能：仅在特定前缀或者tag模式下，按 qwertyuio 选择第 1~9 个候选

local wanxiang = require("wanxiang")

local M = {}

-- 键码映射：q w e r t y u i o → 1..9
local KEY2IDX = {
    [0x71] = 1,  -- q
    [0x77] = 2,  -- w
    [0x65] = 3,  -- e
    [0x72] = 4,  -- r
    [0x74] = 5,  -- t
    [0x79] = 6,  -- y
    [0x75] = 7,  -- u
    [0x69] = 8,  -- i
    [0x6F] = 9,  -- o
}

-- 判断是否在命令模式
local function is_function_mode_active(context)
    if not context or not context.composition or context.composition:empty() then
        return false
    end
    local seg = context.composition:back()
    if not seg then return false end
    return seg:has_tag("number") or seg:has_tag("Ndate")
end

-- 缓存命令模式的状态，避免每次按键都计算
local function on_update(env, ctx)
    env._fn_active = is_function_mode_active(ctx)
end

function M.init(env)
    env._fn_active = false
    env._upd_conn = env.engine.context.update_notifier:connect(function(ctx)
        on_update(env, ctx)
    end)
end

function M.fini(env)
    if env._upd_conn then
        env._upd_conn:disconnect()
        env._upd_conn = nil
    end
end

local function handle_key(key_event, env)
    -- 只处理按下；有修饰键则忽略
    if key_event:release() or key_event:ctrl() or key_event:alt() or key_event:super() then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    local idx = KEY2IDX[key_event.keycode]
    if not idx then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    local context = env.engine.context
    if not env._fn_active then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end
    if not context or not context.composition or context.composition:empty() then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    local seg = context.composition:back()
    if not seg or not seg.menu then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    -- 准备最多 9 个候选
    local count = seg.menu:prepare(9)
    if idx < 1 or idx > count then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    -- 选择：候选索引从 0 开始
    context:select(idx - 1)
    return wanxiang.RIME_PROCESS_RESULTS.kAccepted
end

function M.func(key_event, env)
    return handle_key(key_event, env)
end

return M
