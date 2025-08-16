local wanxiang = require('wanxiang')

local correcter = {}

correcter.correction_map = {}
correcter.min_depth = 0
correcter.max_depth = 0

--- 按输入类型挑选纠错表并加载
---@param env Env
function correcter:load_corrections_from_file(env)
    self.correction_map = {}
    self.min_depth = 0
    self.max_depth = 0

    -- 1) 取输入类型 id（由 wanxiang.lua 提供）
    local id = "unknown"
    if wanxiang.get_input_method_type then
        id = wanxiang.get_input_method_type(env) or "unknown"
    end

    -- 2) 按类型加载表
    local candidates = {
        ("lua/data/typo_%s.txt"):format(id),
    }

    local file, close_file, err
    for _, path in ipairs(candidates) do
        local f, closef, e = wanxiang.load_file_with_fallback(path, "r")
        if f then
        file, close_file, err = f, closef, nil
        break
        else
        err = e -- 记录最后一次错误用于日志
        end
    end

    if not file then
        log.error(("[typo_corrector] 纠错数据未找到（输入类型：%s） err: %s"):format(id, tostring(err)))
        return
    end

    -- 3) 加载纠错表
    for line in file:lines() do
        if not line:match("^#") then
        local corrected, typo = line:match("^([^\t]+)\t([^\t]+)")
        if typo and corrected then
            local typo_len = #typo
            if self.min_depth == 0 or typo_len < self.min_depth then
            self.min_depth = typo_len
            end
            if typo_len > self.max_depth then
            self.max_depth = typo_len
            end
            self.correction_map[typo] = corrected
        end
        end
    end
    close_file()
end

--- 从末尾扫描并返回可纠错的片段
---@param input string
---@return table|nil  -- { length = n, corrected = "..." }
function correcter:get_correct(input)
    if #input < self.min_depth then return nil end
    for scan_len = self.min_depth, math.min(#input, self.max_depth), 1 do
        local scan_pos = #input - scan_len + 1
        local scan_input = input:sub(scan_pos)
        local corrected = self.correction_map[scan_input]
        if corrected then
        return { length = scan_len, corrected = corrected }
        end
    end
    return nil
end

local P = {}

--- 初始化：加载纠错表 + 绑定监听器
---@param env Env
function P.init(env)
    correcter:load_corrections_from_file(env)

    local context = env.engine.context
    -- 重入保护：避免在回调里修改 input 再次触发回调造成循环
    env._in_update = false

    -- 关键：在同一生命周期（一次上下文更新）内完成纠错
    env._conn_update = context.update_notifier:connect(function(ctx)
        if env._in_update then return end
        if not ctx or not ctx:is_composing() then return end

        local input = ctx.input
        if not input or #input < correcter.min_depth then return end

        local ok, res = pcall(function()
        return correcter:get_correct(input)
        end)
        if not ok or not res then return end

        -- 执行替换（末尾片段 -> 正确串）
        env._in_update = true
        -- 注意：在 update 回调里修改输入会再次触发 update，所以要用重入锁
        ctx:pop_input(res.length)
        ctx:push_input(res.corrected)
        env._in_update = false
    end)

    -- 可选：当配置/方案切换时重载纠错表（若你的 wanxiang 暴露了相应通知器可用）
    if env.engine and env.engine.schema_change_notifier then
        env._conn_schema = env.engine.schema_change_notifier:connect(function()
        correcter:load_corrections_from_file(env)
        end)
    end
end

--- 结束：断开监听，防止泄漏
function P.fini(env)
    if env._conn_update then
        env._conn_update:disconnect()
        env._conn_update = nil
    end
    if env._conn_schema then
        env._conn_schema:disconnect()
        env._conn_schema = nil
    end
end

---@param key KeyEvent
---@param env Env
---@return ProcessResult
function P.func(key, env)
    -- 有了 update_notifier 即时处理，这里保持轻量兜底
    local context = env.engine.context
    if not context or not context:is_composing() then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    local input = context.input
    if not input or #input < correcter.min_depth then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    local correct = correcter:get_correct(input)
    if correct then
        context:pop_input(correct.length)
        context:push_input(correct.corrected)
        return wanxiang.RIME_PROCESS_RESULTS.kAccepted
    end
    return wanxiang.RIME_PROCESS_RESULTS.kNoop
end

return P
