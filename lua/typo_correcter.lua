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

    local file, close_file, err, picked
    for _, path in ipairs(candidates) do
        local f, closef, e = wanxiang.load_file_with_fallback(path, "r")
        if f then
            file, close_file, picked, err = f, closef, path, nil
            break
        else
            err = e -- 记录最后一次错误用于日志
        end
    end

    if not file then
        log.error(string.format("[typo_corrector] 纠错数据未找到（输入类型：%s） err: %s", id, tostring(err)))
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

--- 初始化时按输入类型加载纠错表
---@param env Env
function P.init(env)
    correcter:load_corrections_from_file(env)
end

---@param key KeyEvent
---@param env Env
---@return ProcessResult
function P.func(key, env)
    local context = env.engine.context
    if not context or not context:is_composing() then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end
    local input = context.input
    local correct = correcter:get_correct(input)
    if correct then
        context:pop_input(correct.length)
        context:push_input(correct.corrected)
        return wanxiang.RIME_PROCESS_RESULTS.kAccepted
    end
    return wanxiang.RIME_PROCESS_RESULTS.kNoop
end

return P
