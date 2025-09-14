-- 万象拼音 · 手动自由排序
-- 核心规则： 向前移动 = "Control+j", 向后移动 = "Control+k", 重置 = "Control+l", 置顶 = "Control+p
-- 1) p>0：有效排序（DB upsert + 导出）
-- 2) p=0：墓碑（DB 删除 + 导出墓碑）
-- 3) 初始化：先 flush 本机增量到导出 → 外部合并(所有设备文件+本机DB，LWW) → 重写本机导出(含墓碑) → 导入覆盖DB，p=0删除键，不导入
-- 4) 关于同步的使用方法：先点击同步确保同步目录已经创建，建立sequence_device_list.txt设备清单，内部填写不同设备导出文件名称
-- sequence_ff9b2823-8733-44bb-a497-daf382b74ca5.txt
-- sequence_deepin.txt
-- 可能是自定义名称，可能是随机串号
-- sequence_开头，后面跟着installation_id，这个参数来自用户目录installation.yaml
-- 清单有什么文件就会读取什么文件
local wanxiang = require("wanxiang")
local userdb   = require("lib/userdb")

------------------------------------------------------------
-- 一、常量与键位
------------------------------------------------------------
local DEFAULT_SEQ_KEY = { up = "Control+j", down = "Control+k", reset = "Control+l", pin = "Control+p" }
local SYNC_FILE_PREFIX, SYNC_FILE_SUFFIX = "sequence", ".txt"
local function _manifest_path(dir) return dir .. "/sequence_device_list.txt" end

------------------------------------------------------------
-- 二、通用工具
------------------------------------------------------------
local function _path_join(a, b)
    if not a or a == "" then return b end
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
    return a .. "/" .. b
end

local function _read_lines(path)
    local t, f = {}, io.open(path, "r")
    if not f then return t end
    for line in f:lines() do t[#t + 1] = line end
    f:close()
    return t
end

local function _write_lines(path, lines)
    local f = io.open(path, "w"); if not f then return false end
    for _, line in ipairs(lines) do f:write(line, "\n") end
    f:close()
    return true
end

local function _trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function _is_abs_path(p) return p:sub(1, 1) == "/" or p:match("^[A-Za-z]:[\\/]") end
local function _file_exists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r"); if f then f:close(); return true end
    return false
end

------------------------------------------------------------
-- 三、安装信息 & 同步目录
------------------------------------------------------------
local function _read_installation_yaml()
    local user_dir = rime_api.get_user_data_dir()
    if not user_dir or user_dir == "" then return nil, nil end
    local path = _path_join(user_dir, "installation.yaml")
    local f = io.open(path, "r"); if not f then return nil, nil end
    local installation_id, sync_dir
    for line in f:lines() do
        line = line:gsub("%s+#.*$", "")
        local key, val = line:match("^%s*([%w_]+)%s*:%s*(.+)$")
        if key and val then
            val = val:gsub('^%s*"(.*)"%s*$', "%1"):gsub("^%s*'(.*)'%s*$", "%1")
            val = val:gsub("^%s+", ""):gsub("%s+$", "")
            if key == "installation_id" then installation_id = val
            elseif key == "sync_dir"     then sync_dir        = val end
        end
    end
    f:close()
    return installation_id, sync_dir
end

local function _sync_dir()
    local user_dir = rime_api.get_user_data_dir() or ""
    local d = rime_api.get_sync_dir()
    if d and d ~= "" then
        return d == "sync" and ((user_dir ~= "" and (user_dir .. "/sync")) or "sync") or d
    end
    local _, ysync = _read_installation_yaml()
    if ysync and ysync ~= "" then
        return ysync == "sync" and ((user_dir ~= "" and (user_dir .. "/sync")) or "sync") or ysync
    end
    return user_dir .. "/sync"
end

local function _sync_ready()
    local install_id, install_sync = _read_installation_yaml()
    local api_sync = rime_api.get_sync_dir()
    local dir = (api_sync and api_sync ~= "" and api_sync) or install_sync
    local ok = (install_id and install_id ~= "") and (dir and dir ~= "")
    return ok, dir, install_id
end

local function _detect_device_name()
    local installation_id = select(1, _read_installation_yaml())
    local function _san(s) return tostring(s):gsub("[%s/\\:%*%?\"<>|]", "_") end
    if installation_id and installation_id ~= "" then return _san(installation_id) end
    local dir = _sync_dir()
    for _, raw in ipairs(_read_lines(_manifest_path(dir))) do
        local name = _trim(raw or "")
        local m = name:match("^sequence_(.+)%.txt$")
        if m and not _is_abs_path(name) then return _san(m) end
    end
    return "device"
end

------------------------------------------------------------
-- 四、时间
------------------------------------------------------------
local function get_timestamp()
    local ms = type(rime_api.get_time_ms) == "function" and tonumber(rime_api.get_time_ms()) or nil
    return ms and (os.time() + ms / 1000.0) or os.time()
end

------------------------------------------------------------
-- 五、DB 与状态
------------------------------------------------------------
local seq_db = userdb.LevelDb("lua/sequence")

local seq_property = {
    ADJUST_KEY = "sequence_adjustment_code",
}
---@param context Context
function seq_property.get(context)
    return context:get_property(seq_property.ADJUST_KEY)
end

---@param context Context
function seq_property.reset(context)
    local code = seq_property.get(context)
    if code ~= nil and code ~= "" then
        context:set_property(seq_property.ADJUST_KEY, "")
    end
end

local curr_state = {}
curr_state.ADJUST_MODE = { None = -1, Reset = 0, Pin = 1, Adjust = 2 }
curr_state.default = {
    selected_phrase = nil, offset = 0, mode = curr_state.ADJUST_MODE.None,
    highlight_index = nil, adjust_code = nil, adjust_key = nil,
    dirty = false, last_dirty_ts = 0,
}
function curr_state.reset()
    if curr_state.mode == curr_state.ADJUST_MODE.None then return end
    for k, v in pairs(curr_state.default) do curr_state[k] = v end
end
function curr_state.is_pin_mode()    return curr_state.mode == curr_state.ADJUST_MODE.Pin end
function curr_state.is_reset_mode()  return curr_state.mode == curr_state.ADJUST_MODE.Reset end
function curr_state.is_adjust_mode() return curr_state.mode == curr_state.ADJUST_MODE.Adjust end
function curr_state.has_adjustment() return curr_state.mode ~= curr_state.ADJUST_MODE.None end

local function _debug_paths_once()
    local api_sync = tostring(rime_api.get_sync_dir() or "")
    local user_dir = tostring(rime_api.get_user_data_dir() or "")
    local install_id, install_sync = _read_installation_yaml()
    local dir = _sync_dir()
    local device_name = _detect_device_name()
    local export_name = string.format("%s_%s%s", SYNC_FILE_PREFIX, device_name, SYNC_FILE_SUFFIX)
    local export_path = _path_join(dir, export_name)
    local manifest = _manifest_path(dir)
    log.info(string.format("[sequence] api_sync_dir=%s", api_sync))
    log.info(string.format("[sequence] installation_id=%s", tostring(install_id)))
    log.info(string.format("[sequence] installation_sync_dir=%s", tostring(install_sync)))
    log.info(string.format("[sequence] user_data_dir=%s", user_dir))
    log.info(string.format("[sequence] chosen_sync_dir=%s manifest_exists=%s", tostring(dir), tostring(_file_exists(_manifest_path(dir)))))
    log.info(string.format("[sequence] manifest=%s exists=%s", tostring(manifest), tostring(_file_exists(manifest))))
    log.info(string.format("[sequence] export_name=%s", tostring(export_name)))
    log.info(string.format("[sequence] export_path=%s exists=%s", tostring(export_path), tostring(_file_exists(export_path))))
end

------------------------------------------------------------
-- 六、记录解析（新格式）
------------------------------------------------------------
local function parse_adjustment_value_item(value_item)
    local item, p, o, t = value_item:match("i=(.+) p=(%S+) o=(%S*) t=(%S+)")  -- item 可能包含空格（英文）；offset 可能为 0（旧数据格式）
    if not item then return nil, nil end
    return item, { fixed_position = tonumber(p) or 0, offset = tonumber(o) or 0, updated_at = tonumber(t) }
end

local function parse_adjustment_values(values_str)
    local mp = {}
    for seg in values_str:gmatch("[^\t]+") do
        local item, adj = parse_adjustment_value_item(seg)
        if item then mp[item] = adj end
    end
    return next(mp) and mp or nil
end

local function get_input_adjustments(input)
    if not input or input == "" then return nil end
    local value_str = seq_db:fetch(input)
    return value_str and parse_adjustment_values(value_str) or nil
end

------------------------------------------------------------
-- 七、导出缓冲（去重 + 节流）
------------------------------------------------------------
local seq_data = {
    status = "pending",
    device_name = "device",
    last_export_ts = 0,
    export_interval = 1.2,      -- 秒
    pending_map = {},           -- key: input.."\t"..item  =>  line
}

local function _pending_count() local n = 0; for _ in pairs(seq_data.pending_map) do n = n + 1 end; return n end

function seq_data._current_paths()
    local dir = _sync_dir()
    local device_name = seq_data.device_name or "device"
    local export_name = string.format("%s_%s%s", SYNC_FILE_PREFIX, device_name, SYNC_FILE_SUFFIX)
    local export_path = _path_join(dir, export_name)
    local manifest = _manifest_path(dir)
    return dir, device_name, export_name, export_path, manifest
end

function seq_data._ensure_export_file()
    local ok = _sync_ready()
    if not ok then
        log.info("[sequence] installation_id 或 sync_dir 缺失，跳过导出")
        return false
    end
    local _, _, export_name, export_path, manifest = seq_data._current_paths()
    if not _file_exists(manifest) then
        local mf = io.open(manifest, "w"); if not mf then return false end; mf:close()
    end
    if not _file_exists(export_path) then
        local f = io.open(export_path, "w"); if not f then return false end
        local user_id = wanxiang.get_user_id()
        if user_id then f:write("\001/user_id\t", user_id, "\n") end
        f:write("\001/device_name\t", seq_data.device_name or "device", "\n")
        f:close()
    end
    local names = _read_lines(manifest)
    local seen = {}; for _, n in ipairs(names) do seen[_trim(n)] = true end
    if not seen[export_name] then names[#names + 1] = export_name; _write_lines(manifest, names) end
    return true
end

local function _enqueue_export(input, item, adj)
    local k = input .. "\t" .. item
    seq_data.pending_map[k] = string.format("%s\ti=%s p=%s o=%s t=%s\n",
        input, item, adj.fixed_position or 0, adj.offset or 0, adj.updated_at or "")
end

function seq_data.flush_pending(max_lines)
    if _pending_count() == 0 then return end
    if not seq_data._ensure_export_file() then return end
    local _, _, _, export_path = seq_data._current_paths()
    local f = io.open(export_path, "a"); if not f then return end
    local wrote = 0
    for _, line in pairs(seq_data.pending_map) do
        if max_lines and wrote >= max_lines then break end
        f:write(line); wrote = wrote + 1
    end
    f:close()
    seq_data.pending_map = {}
end

function seq_data.maybe_export(force)
    if force then
        seq_data.flush_pending(nil)
        seq_data.last_export_ts = get_timestamp()
        return
    end
    if _pending_count() == 0 then return end
    local now = get_timestamp()
    if now - (seq_data.last_export_ts or 0) < (seq_data.export_interval or 1.2) then return end
    seq_data.flush_pending(200)
    seq_data.last_export_ts = now
end

------------------------------------------------------------
-- 八、保存（本机操作）：p=0 也导出墓碑（DB 不存墓碑）
------------------------------------------------------------
local function save_adjustment(input, item, adjustment, no_export)
    if not input or input == "" or not item or item == "" then return end
    local p = tonumber(adjustment.fixed_position) or 0
    local o = tonumber(adjustment.offset) or 0
    local t = adjustment.updated_at

    local mp = get_input_adjustments(input) or {}
    if p <= 0 then
        mp[item] = nil
    else
        mp[item] = { fixed_position = p, offset = o, updated_at = t }
    end

    if next(mp) == nil then
        seq_db:erase(input)
    else
        local arr = {}
        for it, a in pairs(mp) do
            arr[#arr + 1] = string.format("i=%s p=%s o=%s t=%s",
                it, a.fixed_position, a.offset or 0, a.updated_at or "")
        end
        seq_db:update(input, table.concat(arr, "\t"))
    end

    if not no_export then
        _enqueue_export(input, item, { fixed_position = p, offset = o, updated_at = t }) -- 包含 p=0 墓碑
    end
end

------------------------------------------------------------
-- 九、合并器：收集“所有文件 + 本机DB”，按 t 取最新（包含 p=0）
------------------------------------------------------------
local function _keep_latest(latest, input, item, adj)
    latest[input] = latest[input] or {}
    local prev = latest[input][item]
    if (not prev) or ((adj.updated_at or 0) > (prev.updated_at or 0)) then
        latest[input][item] = {
            fixed_position = tonumber(adj.fixed_position) or 0,
            offset         = tonumber(adj.offset) or 0,
            updated_at     = tonumber(adj.updated_at) or 0
        }
    end
end

local function collect_latest_from_all_sources()
    local latest = {}

    -- A) 本机 DB（仅 p>0）
    seq_db:query_with("", function(key, value)
        local mp = parse_adjustment_values(value)
        if mp then
            for item, a in pairs(mp) do
                local p = tonumber(a.fixed_position) or 0
                if p > 0 then _keep_latest(latest, key, item, a) end
            end
        end
    end)

    -- B) 清单里的所有导出文件（包含 p=0）
    local dir = _sync_dir()
    local names = _read_lines(_manifest_path(dir))
    for _, raw in ipairs(names) do
        local name = _trim(raw or "")
        if name ~= "" and name:sub(1, 1) ~= "#" then
            if name:sub(1, #SYNC_FILE_PREFIX) == SYNC_FILE_PREFIX
                and name:sub(-#SYNC_FILE_SUFFIX) == SYNC_FILE_SUFFIX then
                local path = _is_abs_path(name) and name or _path_join(dir, name)
                local f = io.open(path, "r")
                if f then
                    for line in f:lines() do
                        if line ~= "" and line:sub(1, 2) ~= "\001" .. "/" then
                            local key, value = line:match("^(%S+)\t(.+)$")
                            if key and value then
                                local item, adj1 = parse_adjustment_value_item(value)
                                if item then
                                    _keep_latest(latest, key, item, adj1)
                                else
                                    local mp = parse_adjustment_values(value)
                                    if mp then for it, a in pairs(mp) do _keep_latest(latest, key, it, a) end end
                                end
                            end
                        end
                    end
                    f:close()
                end
            end
        end
    end

    return latest
end

------------------------------------------------------------
-- 十、把“合并结果”重写到我机导出（含 p=0）
------------------------------------------------------------
local function rewrite_export_from_latest(latest)
    local ok = _sync_ready()
    if not ok then return end
    local dir = _sync_dir()
    local installation_id = select(1, _read_installation_yaml())
    local device_name = (installation_id and installation_id ~= "") and tostring(installation_id):gsub("[%s/\\:%*%?\"<>|]", "_") or "device"
    local export_name = string.format("%s_%s%s", SYNC_FILE_PREFIX, device_name, SYNC_FILE_SUFFIX)
    local export_path = _path_join(dir, export_name)
    local manifest = _manifest_path(dir)

    if not _file_exists(manifest) then local mf = io.open(manifest, "w"); if mf then mf:close() end end
    do
        local names = _read_lines(manifest); local seen = {}; for _, n in ipairs(names) do seen[_trim(n)] = true end
        if not seen[export_name] then names[#names + 1] = export_name; _write_lines(manifest, names) end
    end

    local f = io.open(export_path, "w"); if not f then return end
    local user_id = wanxiang.get_user_id()
    if user_id then f:write("\001/user_id\t", user_id, "\n") end
    f:write("\001/device_name\t", device_name, "\n")

    local inputs = {}
    for input, _ in pairs(latest) do inputs[#inputs + 1] = input end
    table.sort(inputs)
    for _, input in ipairs(inputs) do
        local items, keys = latest[input], {}
        for item, _ in pairs(items) do keys[#keys + 1] = item end
        table.sort(keys)
        for _, item in ipairs(keys) do
            local a = items[item]
            f:write(string.format("%s\ti=%s p=%s o=%s t=%s\n",
                input, item, a.fixed_position or 0, a.offset or 0, a.updated_at or ""))
        end
    end

    f:close()
    log.info(string.format("[sequence] export rewritten (merged LWW, incl tombstones): %s", export_path))
end

------------------------------------------------------------
-- 十一、把“合并结果”导入覆盖 DB（p<=0 删）
------------------------------------------------------------
local function apply_latest_to_db(latest)
    local updated_keys = 0
    for input, kv in pairs(latest) do
        local keep = {}
        for item, a in pairs(kv) do
            if (tonumber(a.fixed_position) or 0) > 0 then
                keep[item] = { fixed_position = a.fixed_position, offset = a.offset or 0, updated_at = a.updated_at }
            end
        end
        if next(keep) == nil then
            seq_db:erase(input)
        else
            local arr = {}
            for item, a in pairs(keep) do
                arr[#arr + 1] = string.format("i=%s p=%s o=%s t=%s", item, a.fixed_position, a.offset or 0, a.updated_at or "")
            end
            seq_db:update(input, table.concat(arr, "\t"))
        end
        updated_keys = updated_keys + 1
    end
    log.info(string.format("[sequence] DB applied from merged LWW: %d keys", updated_keys))
end

------------------------------------------------------------
-- 十二、初始化：先导出→合并→重写导出→导入DB
------------------------------------------------------------
local function init_once()
    seq_data._ensure_export_file()
    -- 1) 先导出：把本机 pending 增量写出去（含墓碑）
    seq_data.maybe_export(true)
    -- 2) 外部合并（所有设备文件 + 本机 DB），LWW（含 p=0）
    local latest = collect_latest_from_all_sources()
    -- 3) 用合并结果重写我机导出（包含 p=0）
    rewrite_export_from_latest(latest)
    -- 4) 导入合并结果覆盖 DB（p<=0 删）
    apply_latest_to_db(latest)
end

------------------------------------------------------------
-- 十三、Pipeline：P / F
------------------------------------------------------------
local P = {}
function P.init(env)
    seq_db:open()
    seq_data.device_name = _detect_device_name()
    _debug_paths_once()
    init_once()
end

local function process_adjustment(context)
    local c = context:get_selected_candidate()
    curr_state.selected_phrase = c and c.text or nil
    context:refresh_non_confirmed_composition()
    if context.highlight and curr_state.highlight_index and curr_state.highlight_index > 0 then
        context:highlight(curr_state.highlight_index)
    end
end

function P.func(key_event, env)
    local context = env.engine.context
    curr_state.reset()

    local selected_cand = context:get_selected_candidate()
    if not context:has_menu() or not selected_cand or not selected_cand.text then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    local key_repr = key_event:repr()
    local function get_seq_key(type)
        return env.engine.schema.config:get_string("key_binder/sequence/" .. type) or DEFAULT_SEQ_KEY[type]
    end

    if key_repr == get_seq_key("up") then
        curr_state.offset = -1; curr_state.mode = curr_state.ADJUST_MODE.Adjust
    elseif key_repr == get_seq_key("down") then
        curr_state.offset = 1;  curr_state.mode = curr_state.ADJUST_MODE.Adjust
    elseif key_repr == get_seq_key("reset") then
        curr_state.offset = nil; curr_state.mode = curr_state.ADJUST_MODE.Reset
    elseif key_repr == get_seq_key("pin") then
        curr_state.offset = nil; curr_state.mode = curr_state.ADJUST_MODE.Pin
    else
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    process_adjustment(context)
    return wanxiang.RIME_PROCESS_RESULTS.kAccepted
end

local F = {}

function F.fini()
    -- 退出时：把 pending 增量刷掉（如果你希望“退出也不写”，可注释掉）
    seq_data.maybe_export(true)
end

local function apply_prev_adjustment(cands, prev)
    local list = {}
    for _, info in pairs(prev or {}) do
        if info.raw_position then info.from_position = info.raw_position; table.insert(list, info) end
    end
    table.sort(list, function(a, b) return (a.updated_at or 0) < (b.updated_at or 0) end)

    local n = #cands
    for i, record in ipairs(list) do
        local fromp = record.from_position
        if fromp and (record.fixed_position or 0) > 0 then
            local top = (record.offset == 0) and record.fixed_position or (record.raw_position + record.offset)
            if top < 1 then top = 1 elseif top > n then top = n end
            if fromp ~= top then
                local cand = table.remove(cands, fromp)
                table.insert(cands, top, cand)
                local lo, hi = math.min(fromp, top), math.max(fromp, top)
                for j = i, #list do
                    local r = list[j]
                    if lo <= r.from_position and r.from_position <= hi then
                        r.from_position = r.from_position + ((top < fromp) and 1 or -1)
                    end
                end
            end
        end
    end
end

local function apply_curr_adjustment(candidates, curr_adjustment)
    if curr_adjustment == nil then return end

    ---@type integer | nil
    local from_position = nil
    for position, cand in ipairs(candidates) do
        if cand.text == curr_state.selected_phrase then
            from_position = position
            break
        end
    end

    if from_position == nil then return end

    local to_position = from_position
    if curr_state.is_adjust_mode() then
        to_position = from_position + curr_state.offset
        curr_adjustment.offset = to_position - curr_adjustment.raw_position
        curr_adjustment.fixed_position = to_position

        local min_position, max_position = 1, #candidates
        if from_position ~= to_position then
            if to_position < min_position then
                to_position = min_position
            elseif to_position > max_position then
                to_position = max_position
            end

            local candidate = table.remove(candidates, from_position)
            table.insert(candidates, to_position, candidate)

            save_adjustment(curr_state.adjust_code, curr_state.adjust_key, curr_adjustment)
        end
    end

    curr_state.highlight_index = to_position - 1
end

local function extract_adjustment_code(context)
    if wanxiang.is_function_mode_active(context) then
        local code = seq_property.get(context)
        if code and code ~= "" then return code end
        return nil
    end
    return context.input:sub(1, context.caret_pos)
end

function F.func(input, env)
    local function original_list() for cand in input:iter() do yield(cand) end end

    local context = env.engine.context
    local adjustment_allowed = not (wanxiang.is_function_mode_active(context) and seq_property.get(context) == nil)
    if not adjustment_allowed then
        log.warning("[sequence] 当前指令不支持手动排序")
        return original_list()
    end

    local adjust_code = extract_adjustment_code(context)
    if not adjust_code then return original_list() end

    local prev_adjustments = get_input_adjustments(adjust_code)
    local curr_adjustment = curr_state.has_adjustment() and { fixed_position = 0, offset = 0, updated_at = get_timestamp() } or nil
    if (not curr_adjustment) and (not prev_adjustments) then return original_list() end

    local cands, seen = {}, {}
    local is_fun_mode = wanxiang.is_function_mode_active(context)
    local pos = 0
    for candidate in input:iter() do
        local phrase = candidate.text
        if not seen[phrase] then
            seen[phrase] = true; pos = pos + 1; table.insert(cands, candidate)
            local curr_key = is_fun_mode and tostring(pos - 1) or phrase
            if curr_adjustment and curr_state.selected_phrase == phrase then
                curr_state.adjust_code = adjust_code
                curr_state.adjust_key  = curr_key
                curr_adjustment.raw_position = pos
            end
            if prev_adjustments and prev_adjustments[curr_key] then
                prev_adjustments[curr_key].raw_position = pos
            end
        end
    end
    prev_adjustments = prev_adjustments or {}

    -- 非位移：置顶/重置立即保存；重置(p=0)不立刻写导出
    if curr_adjustment and not curr_state.is_adjust_mode() then
        curr_adjustment.offset = 0
        local key = tostring(curr_state.adjust_key)
        if curr_state.is_reset_mode() then
            curr_adjustment.fixed_position = 0
            prev_adjustments[key] = nil
            save_adjustment(curr_state.adjust_code, curr_state.adjust_key, curr_adjustment)
        elseif curr_state.is_pin_mode() then
            curr_adjustment.fixed_position = 1
            prev_adjustments[key] = curr_adjustment
            save_adjustment(curr_state.adjust_code, curr_state.adjust_key, curr_adjustment)
        end
    end

    apply_prev_adjustment(cands, prev_adjustments)
    apply_curr_adjustment(cands, curr_adjustment)

    for _, cand in ipairs(cands) do yield(cand) end

    -- 位移 / 置顶可节流写出；重置不写
    if not curr_state.is_reset_mode() then
        seq_data.maybe_export(false)
    end
end

return { P = P, F = F }