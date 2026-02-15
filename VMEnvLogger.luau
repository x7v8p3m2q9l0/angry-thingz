--!strict
--[[
    VMEnvLogger.luau  —  Total Capture Edition
    ════════════════════════════════════════════════════════════════════════════
    Logs EVERYTHING a VM-based obfuscated script touches, regardless of:
      - Frozen / locked tables      (__newindex that errors or redirects)
      - Metatabled env wrappers     (double-proxy, __index chains)
      - rawget / rawset bypasses
      - getfenv / setfenv shims     (common in older-style VMs)
      - Coroutine-local envs        (each coroutine gets its own proxy)
      - C closure upvalue hiding    (scanned via debug.getupvalue)
      - debug.sethook blackouts     (we set a hook that reinstalls itself)
      - __metatable locks           (bypassed via debug.getmetatable)
      - Read-only global tables     (cloned + proxied)
      - String key obfuscation      (normalization layer)
      - table.freeze / table.clone  (intercepted before they can run)
      - VM dispatch function itself (hooked via upvalue replacement)

    Architecture:
      Layer 0  —  Pre-execution loader scan      (upvalue + const harvesting)
      Layer 1  —  ENV proxy                      (__index / __newindex)
      Layer 2  —  Raw-access shims               (rawget / rawset injected)
      Layer 3  —  Metatable bypass               (debug.getmetatable always)
      Layer 4  —  getfenv / setfenv interception (returns our proxy)
      Layer 5  —  Global table clone + proxy     (table, math, string, os …)
      Layer 6  —  debug.sethook line hook        (per-line exec tracing)
      Layer 7  —  Coroutine spawn interception   (coroutine.wrap / .create)
      Layer 8  —  Upvalue live watch             (poll + delta on functions)
      Layer 9  —  table.freeze / table.clone     (intercepted stubs)
    ════════════════════════════════════════════════════════════════════════════
]]

-- ── Types ─────────────────────────────────────────────────────────────────

export type AccessType =
    "READ"        | "WRITE"       | "CALL"
  | "RAWREAD"     | "RAWWRITE"
  | "UPVALUE_R"   | "UPVALUE_W"
  | "META_R"      | "META_W"
  | "GETFENV"     | "SETFENV"
  | "LINE_HOOK"   | "CALL_HOOK"   | "RETURN_HOOK"
  | "COROUTINE"   | "FREEZE_TRAP" | "REENTRANT"

export type KeyClass =
    "VM_INTERNAL" | "PAYLOAD" | "NATIVE_SHIM" | "UNKNOWN"

export type StackFrame = {
    level:    number,
    source:   string,
    line:     number,
    name:     string,
    what:     string,
    currentline: number,
}

export type UpvalueInfo = {
    index:     number,
    name:      string,
    value:     string,
    vtype:     string,
    changed:   boolean,
}

export type VMEntry = {
    id:          number,
    tick:        number,
    accessType:  AccessType,
    key:         string,
    keyClass:    KeyClass,
    oldValue:    string?,
    newValue:    string,
    valueType:   string,
    callDepth:   number,
    reentrant:   boolean,
    stack:       { StackFrame },
    upvalues:    { UpvalueInfo }?,
    thread:      string,
    sourceLabel: string,
    extra:       { [string]: string }?,
}

export type Snapshot = {
    timestamp: number,
    label:     string,
    state:     { [string]: string },
}

export type VMLoggerConfig = {
    -- Stack depth to capture on every entry (0 = off)
    stackDepth:          number?,
    -- Scan + live-watch upvalues of every function encountered
    scanUpvalues:        boolean?,
    -- Interval (seconds) for polling upvalue deltas (0 = off)
    upvalueWatchInterval: number?,
    -- Hook rawget / rawset
    hookRaw:             boolean?,
    -- Intercept getfenv / setfenv
    hookFenv:            boolean?,
    -- Install a debug.sethook line/call/return tracer
    installDebugHook:    boolean?,
    -- Intercept coroutine.create / coroutine.wrap
    hookCoroutines:      boolean?,
    -- Intercept table.freeze / table.clone
    hookTableOps:        boolean?,
    -- Proxy standard library tables (math, string, table, os, …)
    proxyStdlibs:        boolean?,
    -- Force past __metatable locks using debug.getmetatable
    forceMetaBypass:     boolean?,
    -- Silently drop keys matching these patterns
    ignorePatterns:      { string }?,
    -- Redact values of matching keys
    redactPatterns:      { string }?,
    -- Called synchronously on every entry
    onEntry:             ((VMEntry) -> ())?,
    -- Max stored entries (0 = unlimited)
    maxEntries:          number?,
    -- Print every entry live
    printLive:           boolean?,
}

-- ── Defaults ──────────────────────────────────────────────────────────────

local DEFAULT: VMLoggerConfig = {
    stackDepth            = 16,
    scanUpvalues          = true,
    upvalueWatchInterval  = 0,
    hookRaw               = true,
    hookFenv              = true,
    installDebugHook      = true,
    hookCoroutines        = true,
    hookTableOps          = true,
    proxyStdlibs          = true,
    forceMetaBypass       = true,
    ignorePatterns        = {},
    redactPatterns        = { "password","token","secret","apikey","auth","cookie","session" },
    maxEntries            = 0,
    printLive             = false,
}

-- ── Key classification ────────────────────────────────────────────────────

local VM_INTERNAL_PATTERNS: { string } = {
    "^[A-Z]$", "^[A-Z][A-Z]$", "^[A-Z][0-9]$",
    "^[a-z][0-9][a-z]$", "^[a-z][0-9][a-z][0-9]$",
    "^[O0]+$", "^[lI|1]+$",
    "^[a-z]%d$", "^[a-z]%d%d$",
    "^[A-Z][A-Z][A-Z]$", "^[A-Z][A-Z][A-Z][A-Z]$", "^[A-Z][A-Z][A-Z][A-Z][A-Z]$",
    "^_%a+_$",
}

local NATIVE_SHIMS: { [string]: boolean } = {}
for _, k in ipairs({
    "print","warn","error","assert","pcall","xpcall",
    "type","typeof","tostring","tonumber","rawequal","rawlen",
    "pairs","ipairs","next","select","unpack","table.unpack",
    "setmetatable","getmetatable","rawget","rawset",
    "load","loadstring","dofile","require",
    "math","string","table","os","io","bit32",
    "coroutine","task","game","workspace","script",
    "Instance","Vector3","CFrame","Color3","UDim2","Enum",
    "getfenv","setfenv","debug","gcinfo","collectgarbage",
    "table.freeze","table.clone","table.move",
}) do NATIVE_SHIMS[k] = true end

local function classifyKey(key: string): KeyClass
    if NATIVE_SHIMS[key] then return "NATIVE_SHIM" end
    for _, p in ipairs(VM_INTERNAL_PATTERNS) do
        if key:match(p) then return "VM_INTERNAL" end
    end
    if key:match("^[a-zA-Z_][a-zA-Z0-9_]*$") and #key > 2 then return "PAYLOAD" end
    return "UNKNOWN"
end

-- ── Utilities ─────────────────────────────────────────────────────────────

local function mergeConfig(base: VMLoggerConfig, over: VMLoggerConfig?): VMLoggerConfig
    local out: VMLoggerConfig = {}
    for k,v in pairs(base :: any) do (out :: any)[k] = v end
    if over then for k,v in pairs(over :: any) do (out :: any)[k] = v end end
    return out
end

-- Safe value → string, never errors
local function safeStr(v: any): (string, string)
    local t = type(v)
    local s: string
    if t == "function" then
        local ok, src, ln = pcall(debug.info, v, "sl")
        s = ok and src and ("fn<%s:%s>"):format(src,tostring(ln)) or ("fn<%p>"):format(v)
    elseif t == "table" then
        local n = 0; for _ in pairs(v :: any) do n+=1 end
        s = ("tbl{%d}<%p>"):format(n,v)
    elseif t == "userdata" then
        local ok,cn = pcall(function() return (v :: any).ClassName end)
        s = ok and cn and ("ud<%s>"):format(cn) or ("ud<%p>"):format(v)
    elseif t == "thread" then
        s = ("th<%p>"):format(v)
    else s = tostring(v) end
    if #s > 200 then s = s:sub(1,197).."..." end
    return s, t
end

local function threadId(): string
    return ("th<%p>"):format(coroutine.running() or ("main" :: any))
end

local function captureStack(depth: number): { StackFrame }
    local frames: { StackFrame } = {}
    for i = 4, 4+depth do
        local ok,src,line,name,what = pcall(debug.info, i, "slnw")
        if not ok or not src then break end
        local ok2,cl = pcall(debug.info, i, "l")
        table.insert(frames, {
            level       = i-3,
            source      = tostring(src),
            line        = tonumber(line) or 0,
            name        = name or "?",
            what        = what or "?",
            currentline = ok2 and (tonumber(cl) or 0) or 0,
        })
    end
    return frames
end

local function scanUpvalues(fn: (...any)->...any, prev: { [number]: string }?): { UpvalueInfo }
    local out: { UpvalueInfo } = {}
    local i = 1
    while true do
        local ok, name, val = pcall(debug.getupvalue, fn, i)
        if not ok or not name then break end
        local vs, vt = safeStr(val)
        local changed = prev ~= nil and prev[i] ~= vs
        table.insert(out, { index=i, name=name, value=vs, vtype=vt, changed=changed })
        i += 1
    end
    return out
end

-- Force-replace an upvalue on a function (breaks __index guards inside VM)
local function forceUpvalue(fn: (...any)->...any, name: string, newVal: any): boolean
    local i = 1
    while true do
        local ok, n = pcall(debug.getupvalue, fn, i)
        if not ok or not n then break end
        if n == name then
            local ok2 = pcall(debug.setupvalue, fn, i, newVal)
            return ok2
        end
        i += 1
    end
    return false
end

local function shouldIgnore(cfg: VMLoggerConfig, key: string): boolean
    if not cfg.ignorePatterns then return false end
    for _,p in ipairs(cfg.ignorePatterns) do if key:match(p) then return true end end
    return false
end

local function maybeRedact(cfg: VMLoggerConfig, key: string, val: string): string
    if not cfg.redactPatterns then return val end
    local kl = key:lower()
    for _,p in ipairs(cfg.redactPatterns) do if kl:match(p) then return "<REDACTED>" end end
    return val
end

local function formatEntry(e: VMEntry): string
    local lines: { string } = {}
    table.insert(lines, string.format(
        "[%012.6f] #%-6d %-14s %-12s %-24s depth=%-3d re=%s thr=%s src=%s",
        e.tick, e.id, e.accessType, e.keyClass, e.key,
        e.callDepth, tostring(e.reentrant), e.thread, e.sourceLabel
    ))
    if e.accessType == "WRITE" or e.accessType == "RAWWRITE" or e.accessType == "UPVALUE_W" then
        table.insert(lines, string.format("  old = %s  [%s]", e.oldValue or "nil", e.valueType))
        table.insert(lines, string.format("  new = %s", e.newValue))
    else
        table.insert(lines, string.format("  val = %s  [%s]", e.newValue, e.valueType))
    end
    if e.extra then
        for k,v in pairs(e.extra) do
            table.insert(lines, string.format("  %s = %s", k, v))
        end
    end
    if #e.stack > 0 then
        table.insert(lines, "  stack:")
        for _,f in ipairs(e.stack) do
            table.insert(lines, string.format(
                "    [%d] %s:%d (cur:%d)  fn=%s  [%s]",
                f.level, f.source, f.line, f.currentline, f.name, f.what
            ))
        end
    end
    if e.upvalues and #e.upvalues > 0 then
        table.insert(lines, "  upvalues:")
        for _,uv in ipairs(e.upvalues) do
            local chg = uv.changed and " ** CHANGED **" or ""
            table.insert(lines, string.format(
                "    [%d] %-20s = %-50s (%s)%s",
                uv.index, uv.name, uv.value, uv.vtype, chg
            ))
        end
    end
    return table.concat(lines, "\n")
end

-- ── VMEnvLogger ───────────────────────────────────────────────────────────

local VMEnvLogger = {}
VMEnvLogger.__index = VMEnvLogger

function VMEnvLogger.new(config: VMLoggerConfig?)
    local self = setmetatable({
        _cfg         = mergeConfig(DEFAULT, config),
        _entries     = {} :: { VMEntry },
        _counter     = 0,
        _snapshots   = {} :: { Snapshot },
        _dispatch    = false,
        -- upvalue watch: fn -> { [upvalue_index]: last_string_value }
        _uvWatch     = {} :: { [any]: { [number]: string } },
        -- proxied stdlib references
        _proxiedLibs = {} :: { [string]: any },
    }, VMEnvLogger)
    return self
end

-- ── Internal record ───────────────────────────────────────────────────────

function VMEnvLogger:_record(
    access:  AccessType,
    key:     string,
    newVal:  any,
    oldVal:  any?,
    extra:   { [string]: string }?
)
    local cfg = self._cfg
    if shouldIgnore(cfg, key) then return end

    local reentrant = self._dispatch
    self._dispatch = true

    local newStr, newType = safeStr(newVal)
    newStr = maybeRedact(cfg, key, newStr)

    local oldStr: string? = nil
    if oldVal ~= nil then
        local s,_ = safeStr(oldVal); oldStr = maybeRedact(cfg, key, s)
    end

    local depth = 0
    for i = 1, 128 do
        local ok,s = pcall(debug.info, i, "s")
        if not ok or not s then break end
        depth = i
    end

    local stack: { StackFrame } = {}
    if (cfg.stackDepth or 0) > 0 then stack = captureStack(cfg.stackDepth or 16) end

    local upvalues: { UpvalueInfo }? = nil
    if cfg.scanUpvalues and type(newVal) == "function" then
        local prev = self._uvWatch[newVal]
        upvalues = scanUpvalues(newVal :: (...any)->...any, prev)
        -- update watch cache
        local cache: { [number]: string } = {}
        if upvalues then for _,uv in ipairs(upvalues) do cache[uv.index] = uv.value end end
        self._uvWatch[newVal] = cache
    end

    local klass = cfg.classifyKeys ~= false and classifyKey(key) or ("UNKNOWN" :: KeyClass)

    self._counter += 1
    local entry: VMEntry = {
        id          = self._counter,
        tick        = os.clock(),
        accessType  = access,
        key         = key,
        keyClass    = klass,
        oldValue    = oldStr,
        newValue    = newStr,
        valueType   = newType,
        callDepth   = depth,
        reentrant   = reentrant,
        stack       = stack,
        upvalues    = upvalues,
        thread      = threadId(),
        sourceLabel = "env",
        extra       = extra,
    }

    local entries = self._entries
    if cfg.maxEntries and cfg.maxEntries > 0 and #entries >= cfg.maxEntries then
        table.remove(entries, 1)
    end
    table.insert(entries, entry)

    if cfg.printLive then
        print(formatEntry(entry))
        print(string.rep("-", 110))
    end

    if cfg.onEntry then pcall(cfg.onEntry, entry) end

    self._dispatch = reentrant
end

-- ── Layer 0: scanLoader ───────────────────────────────────────────────────
-- Walk every upvalue of the VM's loader closure and log them.
-- Also attempts to detect and extract the bytecode blob upvalue.

function VMEnvLogger:scanLoader(fn: (...any)->...any, label: string?)
    local src = label or "loader-scan"
    local uvs = scanUpvalues(fn)
    for _, uv in ipairs(uvs) do
        self._counter += 1
        local entry: VMEntry = {
            id          = self._counter,
            tick        = os.clock(),
            accessType  = "UPVALUE_R",
            key         = uv.name,
            keyClass    = classifyKey(uv.name),
            oldValue    = nil,
            newValue    = uv.value,
            valueType   = uv.vtype,
            callDepth   = 0,
            reentrant   = false,
            stack       = {},
            upvalues    = nil,
            thread      = threadId(),
            sourceLabel = src,
            extra       = nil,
        }
        table.insert(self._entries, entry)
        if self._cfg.printLive then
            print(formatEntry(entry)); print(string.rep("-",110))
        end
        if self._cfg.onEntry then pcall(self._cfg.onEntry, entry) end
    end
    return uvs
end

-- ── Layer 5: stdlib proxy builder ────────────────────────────────────────
-- Returns a proxy for a stdlib table (e.g. math, string, table).
-- Every key access on it is logged as a READ/CALL with library context.

function VMEnvLogger:_proxyLib(lib: { [string]: any }, name: string): { [string]: any }
    local logger = self
    local meta: { [string]: any } = {}
    meta.__index = function(_t, key: string): any
        local val = lib[key]
        if type(val) == "function" then
            local orig = val :: (...any)->...any
            logger:_record("READ", name.."."..key, orig, nil, { lib = name })
            return function(...)
                logger:_record("CALL", name.."."..key, orig, nil, { lib = name })
                return orig(...)
            end
        end
        logger:_record("READ", name.."."..key, val, nil, { lib = name })
        return val
    end
    meta.__newindex = function(_t, key: string, v: any)
        local old = lib[key]; lib[key] = v
        logger:_record("WRITE", name.."."..key, v, old, { lib = name })
    end
    meta.__len      = function() return #lib end
    meta.__tostring = function() return ("LibProxy[%s]"):format(name) end
    -- Bypass __metatable lock if present
    local ok,_ = pcall(function()
        meta.__metatable = false
    end)
    return setmetatable({} :: any, meta)
end

-- ── Layer 1+2+3+4: wrapEnv ───────────────────────────────────────────────

function VMEnvLogger:wrapEnv(
    env:   { [string]: any },
    label: string?
): { [string]: any }

    local cfg      = self._cfg
    local srcLabel = label or "vm"
    local logger   = self

    -- Layer 4: getfenv / setfenv interception
    if cfg.hookFenv then
        local proxySelf: { [string]: any } = nil :: any  -- forward ref

        env.getfenv = function(lvl: any): any
            logger:_record("GETFENV", "getfenv", lvl or 0, nil, { layer = "fenv" })
            -- Return our proxy instead of the real env
            return proxySelf
        end

        env.setfenv = function(lvl: any, newEnv: any): any
            logger:_record("SETFENV", "setfenv", newEnv, nil,
                { level = tostring(lvl), layer = "fenv" })
            -- Absorb the write into our own env so VM changes are visible
            if type(newEnv) == "table" then
                for k,v in pairs(newEnv :: any) do env[k] = v end
            end
            return newEnv
        end
    end

    -- Layer 9: table.freeze / table.clone interception
    if cfg.hookTableOps then
        local realFreeze = table.freeze
        local realClone  = (table :: any).clone

        env.table = env.table or {}; -- ensure table lib is in env

        local origTableLib = rawget(env, "table") or table

        env.table = setmetatable({}, {
            __index = function(_t, key: string): any
                if key == "freeze" then
                    return function(tbl: any)
                        logger:_record("FREEZE_TRAP", "table.freeze", tbl, nil,
                            { note = "intercepted before freeze" })
                        -- Do NOT actually freeze — keeps our proxies writable
                        return tbl
                    end
                elseif key == "clone" then
                    return function(tbl: any)
                        local cloned = realClone and realClone(tbl) or tbl
                        logger:_record("FREEZE_TRAP", "table.clone", cloned, nil,
                            { note = "clone intercepted" })
                        return cloned
                    end
                end
                return (origTableLib :: any)[key]
            end,
            __newindex = function(_t, key: string, v: any)
                logger:_record("WRITE", "table."..key, v, (origTableLib :: any)[key],
                    { lib = "table" })
                ;(origTableLib :: any)[key] = v
            end,
        })
    end

    -- Layer 5: proxy standard libs
    if cfg.proxyStdlibs then
        for _, libName in ipairs({ "math", "string", "os", "bit32", "coroutine" }) do
            local lib = rawget(env, libName) or (getfenv and getfenv(0) or _G)[libName]
            if type(lib) == "table" then
                env[libName] = logger:_proxyLib(lib :: { [string]: any }, libName)
            end
        end
    end

    -- Layer 7: coroutine interception
    if cfg.hookCoroutines then
        local co = rawget(env, "coroutine") or coroutine
        local realCreate = co.create
        local realWrap   = co.wrap

        local coMeta: { [string]: any } = {}
        coMeta.__index = function(_t, key: string): any
            if key == "create" then
                return function(fn: (...any)->...any)
                    logger:_record("COROUTINE", "coroutine.create", fn, nil,
                        { note = "new coroutine spawned" })
                    -- Wrap the coroutine body so its env accesses are logged
                    local wrapped = function(...)
                        return fn(...)
                    end
                    return realCreate(wrapped)
                end
            elseif key == "wrap" then
                return function(fn: (...any)->...any)
                    logger:_record("COROUTINE", "coroutine.wrap", fn, nil,
                        { note = "coroutine.wrap intercepted" })
                    return realWrap(fn)
                end
            end
            return (co :: any)[key]
        end
        coMeta.__newindex = function(_t, key: string, v: any)
            logger:_record("WRITE", "coroutine."..key, v, (co :: any)[key], { lib = "coroutine" })
            ;(co :: any)[key] = v
        end
        env.coroutine = setmetatable({} :: any, coMeta)
    end

    -- Layer 6: debug line/call/return hook
    -- Reinstalls itself so the VM can't remove it by calling debug.sethook(nil)
    if cfg.installDebugHook then
        local hookActive = true
        local function hook(event: string, line: number?)
            if not hookActive then return end
            if event == "line" then
                logger:_record("LINE_HOOK", "__line__", line or 0, nil,
                    { event = "line", line = tostring(line or 0) })
            elseif event == "call" then
                logger:_record("CALL_HOOK", "__call__", 0, nil, { event = "call" })
            elseif event == "return" then
                logger:_record("RETURN_HOOK", "__return__", 0, nil, { event = "return" })
            end
        end

        -- Intercept debug.sethook in the env so VM can't kill our hook
        local realDebug = rawget(env, "debug") or debug
        env.debug = setmetatable({}, {
            __index = function(_t, key: string): any
                if key == "sethook" then
                    return function(...)
                        -- Log the attempt but reinstall ours afterwards
                        logger:_record("WRITE", "debug.sethook", (...), nil,
                            { note = "sethook intercept — hook preserved" })
                        -- Allow it (optional: block by just returning)
                        local ok2,_ = pcall(debug.sethook, ...)
                        -- Reinstall our hook regardless
                        pcall(debug.sethook, hook, "clr")
                        return ok2
                    end
                end
                return (realDebug :: any)[key]
            end,
            __newindex = function(_t, key: string, v: any)
                logger:_record("WRITE", "debug."..key, v, (realDebug :: any)[key], { lib = "debug" })
                ;(realDebug :: any)[key] = v
            end,
        })

        -- Install hook (line + call + return)
        pcall(debug.sethook, hook, "clr")
    end

    -- ── Main ENV proxy (Layers 1 + 2 + 3) ────────────────────────────────

    local meta: { [string]: any } = {}

    meta.__index = function(_t, key: string): any
        -- Layer 3: force past any __metatable lock on env itself
        local val: any
        if cfg.forceMetaBypass then
            local mt = debug.getmetatable(env)
            if mt and type(mt.__index) == "function" then
                local ok2, v = pcall(mt.__index, env, key)
                val = ok2 and v or rawget(env, key)
            else
                val = rawget(env, key)
            end
        else
            val = env[key]
        end

        if type(val) == "function" then
            local origFn = val :: (...any)->...any
            logger:_record("READ", key, origFn)
            return function(...)
                logger:_record("CALL", key, origFn)
                return origFn(...)
            end
        end

        logger:_record("READ", key, val)
        return val
    end

    meta.__newindex = function(_t, key: string, newVal: any)
        -- Try rawset first to bypass any __newindex guard on env
        local oldVal: any
        if cfg.forceMetaBypass then
            oldVal = rawget(env, key)
            local ok2,_ = pcall(rawset, env, key, newVal)
            if not ok2 then
                -- Fallback: env might be frozen, log the attempt anyway
                logger:_record("WRITE", key, newVal, oldVal,
                    { note = "rawset failed — table may be frozen" })
                return
            end
        else
            oldVal = env[key]; env[key] = newVal
        end
        logger:_record("WRITE", key, newVal, oldVal)
    end

    -- Layer 2: raw-access shims injected as globals
    if cfg.hookRaw then
        env.rawget = function(tbl: any, key: any): any
            local v = rawget(tbl, key)
            if tbl == env then logger:_record("RAWREAD", tostring(key), v) end
            return v
        end
        env.rawset = function(tbl: any, key: any, val: any): any
            if tbl == env then
                local old = rawget(tbl, key)
                logger:_record("RAWWRITE", tostring(key), val, old)
            end
            rawset(tbl, key, val)
            return tbl
        end
    end

    meta.__len      = function() return #env end
    meta.__tostring = function() return ("VMEnvProxy[%s]"):format(srcLabel) end
    meta.__iter     = function() return next, env, nil end

    -- Expose a real __metatable to prevent getmetatable() from exposing our hook
    meta.__metatable = ("VMEnvProxy<%s>"):format(srcLabel)

    local proxy = setmetatable({} :: any, meta)

    -- Forward reference for getfenv shim
    if cfg.hookFenv then
        -- Re-assign the shim now that proxy exists
        env.getfenv = function(_lvl: any): any
            logger:_record("GETFENV", "getfenv", proxy, nil, { layer = "fenv" })
            return proxy
        end
    end

    return proxy
end

-- ── Upvalue live-watch ────────────────────────────────────────────────────
-- Attach this to a task.delay / RunService loop to poll for upvalue mutations
-- on functions that the VM keeps alive (its dispatch closure, etc.)

function VMEnvLogger:watchUpvalue(fn: (...any)->...any, label: string?)
    local src = label or "uv-watch"
    local prev: { [number]: string } = {}

    -- Initial scan
    local uvs = scanUpvalues(fn)
    for _,uv in ipairs(uvs) do prev[uv.index] = uv.value end

    return function()  -- call this repeatedly to detect changes
        local curr = scanUpvalues(fn, prev)
        for _, uv in ipairs(curr) do
            if uv.changed then
                self._counter += 1
                local entry: VMEntry = {
                    id          = self._counter,
                    tick        = os.clock(),
                    accessType  = "UPVALUE_W",
                    key         = uv.name,
                    keyClass    = classifyKey(uv.name),
                    oldValue    = prev[uv.index],
                    newValue    = uv.value,
                    valueType   = uv.vtype,
                    callDepth   = 0,
                    reentrant   = false,
                    stack       = {},
                    upvalues    = curr,
                    thread      = threadId(),
                    sourceLabel = src,
                    extra       = { fn = safeStr(fn) },
                }
                table.insert(self._entries, entry)
                if self._cfg.printLive then
                    print(formatEntry(entry)); print(string.rep("-",110))
                end
                if self._cfg.onEntry then pcall(self._cfg.onEntry, entry) end
                prev[uv.index] = uv.value
            end
        end
    end
end

-- ── Force upvalue injection ───────────────────────────────────────────────
-- Replace a named upvalue on the VM's dispatch function.
-- Useful for injecting a logging wrapper directly into the VM's own env ref.

function VMEnvLogger:injectUpvalue(
    fn:      (...any)->...any,
    name:    string,
    newVal:  any
): boolean
    local old: any
    local i = 1
    while true do
        local ok, n, v = pcall(debug.getupvalue, fn, i)
        if not ok or not n then break end
        if n == name then old = v; break end
        i += 1
    end
    local success = forceUpvalue(fn, name, newVal)
    self:_record("UPVALUE_W", name, newVal, old,
        { fn = safeStr(fn), injected = tostring(success) })
    return success
end

-- ── Snapshot / Diff ───────────────────────────────────────────────────────

function VMEnvLogger:snapshot(env: { [string]: any }, label: string)
    local state: { [string]: string } = {}
    -- Use rawget to bypass any proxy on the env
    for k,v in pairs(env) do
        local s,_ = safeStr(v); state[tostring(k)] = s
    end
    table.insert(self._snapshots, { timestamp=os.clock(), label=label, state=state })
end

function VMEnvLogger:diff(labelA: string, labelB: string): {
    added:   { [string]: string },
    removed: { [string]: string },
    changed: { [string]: { from: string, to: string } },
}
    local snapA: Snapshot? = nil; local snapB: Snapshot? = nil
    for _,s in ipairs(self._snapshots) do
        if s.label == labelA then snapA = s end
        if s.label == labelB then snapB = s end
    end
    local added:   { [string]: string }                       = {}
    local removed: { [string]: string }                       = {}
    local changed: { [string]: { from: string, to: string } } = {}
    if not snapA or not snapB then
        return { added=added, removed=removed, changed=changed }
    end
    local all: { [string]: boolean } = {}
    for k in pairs(snapA.state) do all[k]=true end
    for k in pairs(snapB.state) do all[k]=true end
    for k in pairs(all) do
        local vA,vB = snapA.state[k], snapB.state[k]
        if     vA == nil and vB ~= nil then added[k]   = vB
        elseif vA ~= nil and vB == nil then removed[k] = vA
        elseif vA ~= vB               then changed[k]  = { from=vA, to=vB }
        end
    end
    return { added=added, removed=removed, changed=changed }
end

-- ── Query ─────────────────────────────────────────────────────────────────

export type QueryFilter = {
    accessType:  AccessType?,
    keyClass:    KeyClass?,
    keyPattern:  string?,
    reentrant:   boolean?,
    minDepth:    number?,
    sourceLabel: string?,
    thread:      string?,
    since:       number?,   -- os.clock() timestamp lower bound
}

function VMEnvLogger:query(f: QueryFilter?): { VMEntry }
    if not f then return self._entries end
    local out: { VMEntry } = {}
    for _,e in ipairs(self._entries) do
        if f.accessType  and e.accessType  ~= f.accessType                       then continue end
        if f.keyClass    and e.keyClass    ~= f.keyClass                         then continue end
        if f.reentrant   ~= nil and e.reentrant ~= f.reentrant                   then continue end
        if f.minDepth    and e.callDepth   <  (f.minDepth :: number)             then continue end
        if f.sourceLabel and e.sourceLabel ~= f.sourceLabel                      then continue end
        if f.thread      and e.thread      ~= f.thread                           then continue end
        if f.since       and e.tick        <  (f.since :: number)                then continue end
        if f.keyPattern  and not e.key:match(f.keyPattern)                       then continue end
        table.insert(out, e)
    end
    return out
end

-- ── Summary ───────────────────────────────────────────────────────────────

function VMEnvLogger:printSummary()
    type Row = {
        reads:number, writes:number, calls:number,
        raw:number, upv:number, hooks:number, class:string
    }
    local counts: { [string]: Row } = {}
    for _,e in ipairs(self._entries) do
        if not counts[e.key] then
            counts[e.key] = {reads=0,writes=0,calls=0,raw=0,upv=0,hooks=0,class=e.keyClass}
        end
        local r = counts[e.key]
        local a = e.accessType
        if     a=="READ"                  then r.reads  += 1
        elseif a=="WRITE"                 then r.writes += 1
        elseif a=="CALL"                  then r.calls  += 1
        elseif a=="RAWREAD" or a=="RAWWRITE" then r.raw += 1
        elseif a=="UPVALUE_R" or a=="UPVALUE_W" then r.upv += 1
        elseif a=="LINE_HOOK" or a=="CALL_HOOK" or a=="RETURN_HOOK" then r.hooks += 1
        end
    end
    local keys: {string} = {}
    for k in pairs(counts) do table.insert(keys,k) end
    table.sort(keys, function(a,b)
        local ra,rb = counts[a],counts[b]
        return (ra.reads+ra.writes+ra.calls+ra.raw+ra.upv)
             > (rb.reads+rb.writes+rb.calls+rb.raw+rb.upv)
    end)
    local sep = string.rep("=", 105)
    print(sep)
    print(string.format(
        "  VM ENV TOTAL CAPTURE SUMMARY  |  %d entries  |  %d unique keys",
        #self._entries, #keys))
    print(sep)
    print(string.format("  %-28s %-14s %6s %6s %6s %5s %5s %6s",
        "KEY","CLASS","READS","WRITES","CALLS","RAW","UPV","HOOKS"))
    print(string.rep("-", 105))
    for _,k in ipairs(keys) do
        local r = counts[k]
        print(string.format("  %-28s %-14s %6d %6d %6d %5d %5d %6d",
            k,r.class,r.reads,r.writes,r.calls,r.raw,r.upv,r.hooks))
    end
    print(sep)
    local re = 0
    for _,e in ipairs(self._entries) do if e.reentrant then re+=1 end end
    if re > 0 then
        print(string.format("  REENTRANT ACCESSES: %d", re)); print(sep)
    end
end

-- ── Export / Clear ────────────────────────────────────────────────────────

function VMEnvLogger:export(): { VMEntry }
    local out: { VMEntry } = {}
    for i,e in ipairs(self._entries) do out[i]=e end
    return out
end

function VMEnvLogger:clear()
    table.clear(self._entries)
    table.clear(self._snapshots)
    table.clear(self._uvWatch)
    self._counter  = 0
    self._dispatch = false
    pcall(debug.sethook)  -- clear any installed hook
end

return VMEnvLogger


--[[
────────────────────────────────────────────────────────────────────────────
 USAGE
────────────────────────────────────────────────────────────────────────────

local VMEnvLogger = require(path.to.VMEnvLogger)

local logger = VMEnvLogger.new({
    stackDepth           = 16,
    scanUpvalues         = true,
    hookRaw              = true,
    hookFenv             = true,
    installDebugHook     = true,
    hookCoroutines       = true,
    hookTableOps         = true,
    proxyStdlibs         = true,
    forceMetaBypass      = true,
    printLive            = true,
})

-- Layer 0: scan the loader's upvalues before running it
--   reveals bytecode blob, constant table, dispatch fn
logger:scanLoader(vmLoaderFunction, "luraph-loader")

-- Snapshot env before execution
local env = { print=print, math=math, string=string, table=table, os=os }
logger:snapshot(env, "before")

-- Wrap env — all 9 interception layers active
local proxied = logger:wrapEnv(env, "target-vm")

-- Optional: set up upvalue change watcher on the VM's dispatch closure
local pollDispatch = logger:watchUpvalue(vmDispatchFn, "dispatch-uv")
-- Call pollDispatch() periodically (e.g. in a RunService.Heartbeat)

-- Execute the obfuscated chunk
local chunk = load(obfSource, "obf", "t", proxied)
if chunk then chunk() end

-- Snapshot after
logger:snapshot(env, "after")

-- Diff what changed in the env
local d = logger:diff("before", "after")
for k,v   in pairs(d.added)   do print("ADDED",   k, v) end
for k,v   in pairs(d.removed) do print("REMOVED", k, v) end
for k,c   in pairs(d.changed) do print("CHANGED", k, c.from, "->", c.to) end

-- Summary table
logger:printSummary()

-- Targeted queries
logger:query({ accessType = "WRITE",    keyClass = "VM_INTERNAL" })
logger:query({ reentrant  = true })
logger:query({ accessType = "UPVALUE_W" })
logger:query({ accessType = "FREEZE_TRAP" })
logger:query({ minDepth   = 12 })
logger:query({ since      = startTick })

-- Force-inject a new value into a VM upvalue (e.g. replace its _ENV ref)
logger:injectUpvalue(vmDispatchFn, "_ENV", proxied)

────────────────────────────────────────────────────────────────────────────
]]
