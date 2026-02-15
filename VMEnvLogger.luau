--!strict
--[[
    VMEnvLogger.luau  —  Stable Total Capture Edition
    ════════════════════════════════════════════════════════════════════════
    Logs everything a VM-based obfuscated script touches.

    Fixed from previous version:
      - NO debug.sethook line hook (was causing stack overflow + lag)
      - NO recursive proxy-inside-proxy loops
      - NO task.spawn / RunService deps (pure module, no side effects)
      - Re-entrancy guard is now per-thread safe
      - Function wrapping is memoized (same fn = same wrapper, no dupes)
      - Stdlib proxies are opt-in and lazy
      - Upvalue scan is gated — only fires on first READ of a function

    Layers (all crash-safe):
      [1]  ENV __index / __newindex proxy
      [2]  rawget / rawset shims
      [3]  debug.getmetatable bypass (reads past __metatable locks)
      [4]  getfenv / setfenv intercept
      [5]  table.freeze trap (prevents tables being locked away)
      [6]  Stdlib sub-proxies (math, string, os, bit32)
      [7]  Coroutine spawn logging
      [8]  Upvalue scan on first function access
      [9]  watchUpvalue() — manual poll, no automatic loops
      [10] injectUpvalue() — force-replace VM dispatch upvalues
      [11] Snapshot / diff
      [12] Query + summary
    ════════════════════════════════════════════════════════════════════════
]]

-- ── Types ─────────────────────────────────────────────────────────────────

export type AccessType =
    "READ"       | "WRITE"      | "CALL"
  | "RAWREAD"    | "RAWWRITE"
  | "UPVALUE_R"  | "UPVALUE_W"
  | "META_R"     | "GETFENV"    | "SETFENV"
  | "COROUTINE"  | "FREEZE_TRAP"

export type KeyClass =
    "VM_INTERNAL" | "PAYLOAD" | "NATIVE_SHIM" | "UNKNOWN"

export type StackFrame = {
    level:  number,
    source: string,
    line:   number,
    name:   string,
    what:   string,
}

export type UpvalueInfo = {
    index:   number,
    name:    string,
    value:   string,
    vtype:   string,
    changed: boolean,
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
    sourceLabel: string,
    note:        string?,
}

export type VMLoggerConfig = {
    -- How many stack frames to capture per entry (0 = off, keep low ~6-8)
    stackDepth:       number?,
    -- Scan upvalues on first READ of a function
    scanUpvalues:     boolean?,
    -- Shim rawget / rawset
    hookRaw:          boolean?,
    -- Intercept getfenv / setfenv
    hookFenv:         boolean?,
    -- Intercept table.freeze (stops VM from locking tables)
    hookTableFreeze:  boolean?,
    -- Proxy math/string/os/bit32 sub-tables
    proxyStdlibs:     boolean?,
    -- Log coroutine.create / coroutine.wrap calls
    hookCoroutines:   boolean?,
    -- Use debug.getmetatable to bypass __metatable locks on reads
    forceMetaBypass:  boolean?,
    -- Drop keys matching these Lua patterns
    ignorePatterns:   { string }?,
    -- Redact values of matching keys
    redactPatterns:   { string }?,
    -- Callback on every new entry
    onEntry:          ((VMEntry) -> ())?,
    -- Max stored entries (0 = unlimited)
    maxEntries:       number?,
    -- Print entries live to output
    printLive:        boolean?,
}

-- ── Defaults ──────────────────────────────────────────────────────────────

local DEFAULT: VMLoggerConfig = {
    stackDepth       = 6,        -- low default — increase only if needed
    scanUpvalues     = true,
    hookRaw          = true,
    hookFenv         = true,
    hookTableFreeze  = true,
    proxyStdlibs     = false,    -- opt-in — can be noisy
    hookCoroutines   = true,
    forceMetaBypass  = true,
    ignorePatterns   = {},
    redactPatterns   = { "password","token","secret","apikey","auth","cookie","session" },
    maxEntries       = 0,
    printLive        = false,
}

-- ── Key classification ────────────────────────────────────────────────────

local VM_INTERNAL_PATTERNS: { string } = {
    "^[A-Z]$", "^[A-Z][A-Z]$", "^[A-Z][0-9]$",
    "^[a-z][0-9][a-z]$", "^[a-z][0-9][a-z][0-9]$",
    "^[O0]+$", "^[lI|1]+$",
    "^[a-z]%d$", "^[a-z]%d%d$",
    "^[A-Z][A-Z][A-Z]$", "^[A-Z][A-Z][A-Z][A-Z]$",
    "^[A-Z][A-Z][A-Z][A-Z][A-Z]$",
}

local NATIVE_SHIMS: { [string]: boolean } = {}
for _, k in ipairs({
    "print","warn","error","assert","pcall","xpcall",
    "type","typeof","tostring","tonumber","rawequal","rawlen",
    "pairs","ipairs","next","select","unpack",
    "setmetatable","getmetatable","rawget","rawset",
    "load","loadstring","dofile","require",
    "math","string","table","os","io","bit32",
    "coroutine","task","game","workspace","script",
    "Instance","Vector3","CFrame","Color3","UDim2","Enum",
    "getfenv","setfenv","debug","collectgarbage",
}) do NATIVE_SHIMS[k] = true end

local function classifyKey(key: string): KeyClass
    if NATIVE_SHIMS[key]  then return "NATIVE_SHIM" end
    for _, p in ipairs(VM_INTERNAL_PATTERNS) do
        if key:match(p) then return "VM_INTERNAL" end
    end
    if key:match("^[a-zA-Z_][a-zA-Z0-9_]*$") and #key > 2 then return "PAYLOAD" end
    return "UNKNOWN"
end

-- ── Utilities ─────────────────────────────────────────────────────────────

local function mergeConfig(base: VMLoggerConfig, over: VMLoggerConfig?): VMLoggerConfig
    local out: VMLoggerConfig = {}
    for k, v in pairs(base :: any) do (out :: any)[k] = v end
    if over then for k, v in pairs(over :: any) do (out :: any)[k] = v end end
    return out
end

local function safeStr(v: any): (string, string)
    local t = type(v)
    local s: string
    if t == "function" then
        local ok, src, ln = pcall(debug.info, v, "sl")
        s = ok and src and ("fn<%s:%s>"):format(tostring(src), tostring(ln))
                       or  ("fn<%p>"):format(v)
    elseif t == "table" then
        local n = 0; for _ in pairs(v :: any) do n += 1 end
        s = ("tbl{%d}<%p>"):format(n, v)
    elseif t == "userdata" then
        local ok, cn = pcall(function() return (v :: any).ClassName end)
        s = ok and cn and ("ud<%s>"):format(tostring(cn)) or ("ud<%p>"):format(v)
    elseif t == "thread" then
        s = ("th<%p>"):format(v)
    else
        s = tostring(v)
    end
    if #s > 180 then s = s:sub(1, 177) .. "..." end
    return s, t
end

local function captureStack(depth: number): { StackFrame }
    local frames: { StackFrame } = {}
    for i = 4, 4 + depth do
        local ok, src, line, name, what = pcall(debug.info, i, "slnw")
        if not ok or not src then break end
        table.insert(frames, {
            level  = i - 3,
            source = tostring(src),
            line   = tonumber(line) or 0,
            name   = name or "?",
            what   = what or "?",
        })
    end
    return frames
end

local function scanUpvalues(fn: (...any) -> ...any, prev: { [number]: string }?): { UpvalueInfo }
    local out: { UpvalueInfo } = {}
    local i = 1
    while true do
        local ok, name, val = pcall(debug.getupvalue, fn, i)
        if not ok or not name then break end
        local vs, vt = safeStr(val)
        table.insert(out, {
            index   = i,
            name    = name,
            value   = vs,
            vtype   = vt,
            changed = prev ~= nil and prev[i] ~= vs,
        })
        i += 1
    end
    return out
end

local function shouldIgnore(cfg: VMLoggerConfig, key: string): boolean
    if not cfg.ignorePatterns then return false end
    for _, p in ipairs(cfg.ignorePatterns) do
        if key:match(p) then return true end
    end
    return false
end

local function maybeRedact(cfg: VMLoggerConfig, key: string, val: string): string
    if not cfg.redactPatterns then return val end
    local kl = key:lower()
    for _, p in ipairs(cfg.redactPatterns) do
        if kl:match(p) then return "<REDACTED>" end
    end
    return val
end

local function formatEntry(e: VMEntry): string
    local lines: { string } = {}
    table.insert(lines, string.format(
        "[%012.6f] #%-5d %-13s %-12s %-22s depth=%-2d re=%s  src=%s%s",
        e.tick, e.id, e.accessType, e.keyClass, e.key,
        e.callDepth, tostring(e.reentrant), e.sourceLabel,
        e.note and ("  NOTE: " .. e.note) or ""
    ))
    if e.accessType == "WRITE" or e.accessType == "RAWWRITE" or e.accessType == "UPVALUE_W" then
        table.insert(lines, string.format(
            "  old=%-70s [%s]", e.oldValue or "nil", e.valueType))
        table.insert(lines, string.format(
            "  new=%s", e.newValue))
    else
        table.insert(lines, string.format(
            "  val=%-70s [%s]", e.newValue, e.valueType))
    end
    if #e.stack > 0 then
        table.insert(lines, "  stack:")
        for _, f in ipairs(e.stack) do
            table.insert(lines, string.format(
                "    [%d] %s:%d  fn=%s  (%s)",
                f.level, f.source, f.line, f.name, f.what))
        end
    end
    if e.upvalues and #e.upvalues > 0 then
        table.insert(lines, "  upvalues:")
        for _, uv in ipairs(e.upvalues) do
            table.insert(lines, string.format(
                "    [%d] %-18s = %-50s (%s)%s",
                uv.index, uv.name, uv.value, uv.vtype,
                uv.changed and "  ** CHANGED **" or ""))
        end
    end
    return table.concat(lines, "\n")
end

-- ── VMEnvLogger ───────────────────────────────────────────────────────────

local VMEnvLogger = {}
VMEnvLogger.__index = VMEnvLogger

function VMEnvLogger.new(config: VMLoggerConfig?)
    return setmetatable({
        _cfg        = mergeConfig(DEFAULT, config),
        _entries    = {} :: { VMEntry },
        _counter    = 0,
        _snapshots  = {} :: { { timestamp: number, label: string, state: { [string]: string } } },
        -- per-function wrapper memoization (prevents double-wrap)
        _wrapped    = {} :: { [any]: any },
        -- per-function upvalue cache for delta detection
        _uvCache    = {} :: { [any]: { [number]: string } },
        -- per-function "already scanned" flag
        _uvScanned  = {} :: { [any]: boolean },
        -- re-entrancy guard (simple boolean, Luau is single-threaded per actor)
        _inRecord   = false,
    }, VMEnvLogger)
end

-- ── _record ───────────────────────────────────────────────────────────────

function VMEnvLogger:_record(
    access:  AccessType,
    key:     string,
    newVal:  any,
    oldVal:  any?,
    note:    string?
)
    -- Hard re-entrancy guard — if we're already inside _record, bail immediately.
    -- This is the main crash-prevention mechanism.
    if self._inRecord then return end
    self._inRecord = true

    local cfg = self._cfg

    local ok, err = pcall(function()
        if shouldIgnore(cfg, key) then return end

        local newStr, newType = safeStr(newVal)
        newStr = maybeRedact(cfg, key, newStr)

        local oldStr: string? = nil
        if oldVal ~= nil then
            local s, _ = safeStr(oldVal)
            oldStr = maybeRedact(cfg, key, s)
        end

        -- Call depth — walk stack safely
        local depth = 0
        for i = 1, 64 do
            local ok2, s = pcall(debug.info, i, "s")
            if not ok2 or not s then break end
            depth = i
        end

        local stack: { StackFrame } = {}
        if (cfg.stackDepth or 0) > 0 then
            stack = captureStack(cfg.stackDepth or 6)
        end

        -- Upvalue scan: only on first READ of each function, not every access
        local upvalues: { UpvalueInfo }? = nil
        if cfg.scanUpvalues
            and type(newVal) == "function"
            and access == "READ"
            and not self._uvScanned[newVal]
        then
            self._uvScanned[newVal] = true
            local prev = self._uvCache[newVal]
            upvalues = scanUpvalues(newVal :: (...any) -> ...any, prev)
            local cache: { [number]: string } = {}
            for _, uv in ipairs(upvalues) do cache[uv.index] = uv.value end
            self._uvCache[newVal] = cache
        end

        local klass = classifyKey(key)

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
            reentrant   = false,  -- not needed now that guard is solid
            stack       = stack,
            upvalues    = upvalues,
            sourceLabel = "env",
            note        = note,
        }

        local entries = self._entries
        if cfg.maxEntries and cfg.maxEntries > 0 and #entries >= cfg.maxEntries then
            table.remove(entries, 1)
        end
        table.insert(entries, entry)

        if cfg.printLive then
            print(formatEntry(entry))
            print(string.rep("-", 100))
        end

        if cfg.onEntry then
            pcall(cfg.onEntry, entry)
        end
    end)

    self._inRecord = false

    if not ok then
        -- Last-resort: print error without recursing
        pcall(print, "[VMEnvLogger] _record error: " .. tostring(err))
    end
end

-- ── scanLoader ────────────────────────────────────────────────────────────

function VMEnvLogger:scanLoader(fn: (...any) -> ...any, label: string?)
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
            sourceLabel = src,
            note        = nil,
        }
        table.insert(self._entries, entry)
        if self._cfg.printLive then
            print(formatEntry(entry)); print(string.rep("-", 100))
        end
        if self._cfg.onEntry then pcall(self._cfg.onEntry, entry) end
    end
    return uvs
end

-- ── stdlib sub-proxy builder ──────────────────────────────────────────────

function VMEnvLogger:_proxyLib(lib: { [string]: any }, name: string): { [string]: any }
    local logger = self
    return setmetatable({} :: any, {
        __index = function(_t, key: string): any
            local val = lib[key]
            if type(val) == "function" then
                local orig = val :: (...any) -> ...any
                -- Memoize wrapper
                if not logger._wrapped[orig] then
                    logger._wrapped[orig] = function(...)
                        logger:_record("CALL", name .. "." .. key, orig, nil, name)
                        return orig(...)
                    end
                end
                logger:_record("READ", name .. "." .. key, orig, nil, name)
                return logger._wrapped[orig]
            end
            logger:_record("READ", name .. "." .. key, val, nil, name)
            return val
        end,
        __newindex = function(_t, key: string, v: any)
            local old = lib[key]; lib[key] = v
            logger:_record("WRITE", name .. "." .. key, v, old, name)
        end,
        __len      = function() return #lib end,
        __tostring = function() return ("LibProxy[%s]"):format(name) end,
        __metatable = false,
    })
end

-- ── wrapEnv ───────────────────────────────────────────────────────────────

function VMEnvLogger:wrapEnv(env: { [string]: any }, label: string?): { [string]: any }
    local cfg      = self._cfg
    local srcLabel = label or "vm"
    local logger   = self

    -- Layer 4: getfenv / setfenv
    if cfg.hookFenv then
        local proxyRef: { [string]: any } = nil :: any  -- set after proxy creation

        env.getfenv = function(_lvl: any): any
            logger:_record("GETFENV", "getfenv", proxyRef or env, nil, "fenv-shim")
            return proxyRef or env
        end

        env.setfenv = function(_lvl: any, newEnv: any): any
            logger:_record("SETFENV", "setfenv", newEnv, nil, "fenv-shim")
            if type(newEnv) == "table" then
                for k, v in pairs(newEnv :: any) do env[k] = v end
            end
            return newEnv
        end

        -- table.freeze trap — Layer 5
        if cfg.hookTableFreeze then
            local origTable = rawget(env, "table") or table
            env.table = setmetatable({} :: any, {
                __index = function(_t, key: string): any
                    if key == "freeze" then
                        return function(tbl: any): any
                            logger:_record("FREEZE_TRAP", "table.freeze", tbl, nil,
                                "freeze blocked — table left mutable")
                            return tbl  -- return as-is, NOT frozen
                        end
                    end
                    if key == "clone" then
                        local realClone = (origTable :: any).clone
                        return function(tbl: any): any
                            logger:_record("FREEZE_TRAP", "table.clone", tbl, nil, "clone intercepted")
                            return realClone and realClone(tbl) or tbl
                        end
                    end
                    return (origTable :: any)[key]
                end,
                __newindex = function(_t, key: string, v: any)
                    logger:_record("WRITE", "table." .. key, v, (origTable :: any)[key], "table-lib")
                    ;(origTable :: any)[key] = v
                end,
                __metatable = false,
            })
        end

        -- Coroutine intercept — Layer 7
        if cfg.hookCoroutines then
            local co = rawget(env, "coroutine") or coroutine
            env.coroutine = setmetatable({} :: any, {
                __index = function(_t, key: string): any
                    local val = (co :: any)[key]
                    if key == "create" or key == "wrap" then
                        return function(fn: (...any) -> ...any)
                            logger:_record("COROUTINE", "coroutine." .. key, fn, nil,
                                "coroutine spawned")
                            return (co :: any)[key](fn)
                        end
                    end
                    return val
                end,
                __newindex = function(_t, key: string, v: any)
                    logger:_record("WRITE", "coroutine." .. key, v, (co :: any)[key], "coroutine-lib")
                    ;(co :: any)[key] = v
                end,
                __metatable = false,
            })
        end

        -- Stdlib proxies — Layer 6 (opt-in)
        if cfg.proxyStdlibs then
            for _, libName in ipairs({ "math", "string", "os", "bit32" }) do
                local lib = rawget(env, libName)
                if type(lib) == "table" then
                    env[libName] = logger:_proxyLib(lib :: { [string]: any }, libName)
                end
            end
        end

        -- Main ENV proxy — Layers 1 + 2 + 3
        local meta: { [string]: any } = {}

        meta.__index = function(_t, key: string): any
            -- Layer 3: bypass __metatable lock via debug.getmetatable
            local val: any
            if cfg.forceMetaBypass then
                local ok2, v = pcall(rawget, env, key)
                if ok2 then
                    val = v
                    -- If rawget returned nil, check for a chained __index
                    if val == nil then
                        local mt = debug.getmetatable(env)
                        if mt then
                            local idx = rawget(mt, "__index")
                            if type(idx) == "function" then
                                local ok3, v2 = pcall(idx, env, key)
                                if ok3 then val = v2 end
                            elseif type(idx) == "table" then
                                val = (idx :: any)[key]
                            end
                        end
                    end
                else
                    val = env[key]
                end
            else
                val = env[key]
            end

            if type(val) == "function" then
                local origFn = val :: (...any) -> ...any
                -- Memoize: same function always gets the same wrapper
                if not logger._wrapped[origFn] then
                    logger._wrapped[origFn] = function(...)
                        logger:_record("CALL", key, origFn)
                        return origFn(...)
                    end
                end
                logger:_record("READ", key, origFn)
                return logger._wrapped[origFn]
            end

            logger:_record("READ", key, val)
            return val
        end

        meta.__newindex = function(_t, key: string, newVal: any)
            local oldVal: any
            -- Force rawset to bypass any __newindex lock on env
            if cfg.forceMetaBypass then
                oldVal = rawget(env, key)
                local ok2, _ = pcall(rawset, env, key, newVal)
                if not ok2 then
                    -- Table is frozen or locked — log the attempt
                    logger:_record("WRITE", key, newVal, oldVal, "rawset-failed-table-frozen")
                    return
                end
            else
                oldVal = env[key]; env[key] = newVal
            end
            logger:_record("WRITE", key, newVal, oldVal)
        end

        -- Layer 2: raw shims
        if cfg.hookRaw then
            env.rawget = function(tbl: any, key: any): any
                local v = rawget(tbl, key)
                if tbl == env then
                    logger:_record("RAWREAD", tostring(key), v)
                end
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
        meta.__metatable = ("VMEnvProxy<%s>"):format(srcLabel)

        local proxy = setmetatable({} :: any, meta)
        proxyRef = proxy  -- close the forward ref for getfenv
        return proxy
    end

    -- Fallback path if hookFenv is false (still builds proxy)
    local meta: { [string]: any } = {}
    meta.__index = function(_t, key: string): any
        local val = rawget(env, key)
        if type(val) == "function" then
            local orig = val :: (...any) -> ...any
            if not logger._wrapped[orig] then
                logger._wrapped[orig] = function(...)
                    logger:_record("CALL", key, orig)
                    return orig(...)
                end
            end
            logger:_record("READ", key, orig)
            return logger._wrapped[orig]
        end
        logger:_record("READ", key, val)
        return val
    end
    meta.__newindex = function(_t, key: string, v: any)
        local old = rawget(env, key); rawset(env, key, v)
        logger:_record("WRITE", key, v, old)
    end
    meta.__metatable = ("VMEnvProxy<%s>"):format(srcLabel)
    return setmetatable({} :: any, meta)
end

-- ── watchUpvalue ──────────────────────────────────────────────────────────
-- Returns a poll function. Call it manually whenever you want to check
-- for upvalue mutations (e.g. in a RunService.Heartbeat connection).
-- Does NOT install any automatic loop.

function VMEnvLogger:watchUpvalue(fn: (...any) -> ...any, label: string?)
    local src = label or "uv-watch"
    local prev: { [number]: string } = {}
    local uvs = scanUpvalues(fn)
    for _, uv in ipairs(uvs) do prev[uv.index] = uv.value end

    return function()
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
                    sourceLabel = src,
                    note        = "upvalue mutation detected",
                }
                table.insert(self._entries, entry)
                if self._cfg.printLive then
                    print(formatEntry(entry)); print(string.rep("-", 100))
                end
                if self._cfg.onEntry then pcall(self._cfg.onEntry, entry) end
                prev[uv.index] = uv.value
            end
        end
    end
end

-- ── injectUpvalue ─────────────────────────────────────────────────────────

function VMEnvLogger:injectUpvalue(fn: (...any) -> ...any, name: string, newVal: any): boolean
    local old: any
    local i = 1
    while true do
        local ok, n, v = pcall(debug.getupvalue, fn, i)
        if not ok or not n then break end
        if n == name then old = v; break end
        i += 1
    end
    -- Find index by name
    local idx = 0
    local j = 1
    while true do
        local ok, n = pcall(debug.getupvalue, fn, j)
        if not ok or not n then break end
        if n == name then idx = j; break end
        j += 1
    end
    local success = false
    if idx > 0 then
        success = pcall(debug.setupvalue, fn, idx, newVal) == true or
                  (function()
                      local ok2 = pcall(debug.setupvalue, fn, idx, newVal)
                      return ok2
                  end)()
    end
    self:_record("UPVALUE_W", name, newVal, old,
        ("inject into fn<%p> idx=%d ok=%s"):format(fn, idx, tostring(success)))
    return success
end

-- ── Snapshot / Diff ───────────────────────────────────────────────────────

function VMEnvLogger:snapshot(env: { [string]: any }, label: string)
    local state: { [string]: string } = {}
    for k, v in pairs(env) do
        local s, _ = safeStr(v); state[tostring(k)] = s
    end
    table.insert(self._snapshots, { timestamp = os.clock(), label = label, state = state })
end

function VMEnvLogger:diff(labelA: string, labelB: string): {
    added:   { [string]: string },
    removed: { [string]: string },
    changed: { [string]: { from: string, to: string } },
}
    local snapA: { timestamp: number, label: string, state: { [string]: string } }? = nil
    local snapB: { timestamp: number, label: string, state: { [string]: string } }? = nil
    for _, s in ipairs(self._snapshots) do
        if s.label == labelA then snapA = s end
        if s.label == labelB then snapB = s end
    end
    local added:   { [string]: string }                       = {}
    local removed: { [string]: string }                       = {}
    local changed: { [string]: { from: string, to: string } } = {}
    if not snapA or not snapB then
        return { added = added, removed = removed, changed = changed }
    end
    local all: { [string]: boolean } = {}
    for k in pairs(snapA.state) do all[k] = true end
    for k in pairs(snapB.state) do all[k] = true end
    for k in pairs(all) do
        local vA, vB = snapA.state[k], snapB.state[k]
        if     vA == nil and vB ~= nil then added[k]   = vB
        elseif vA ~= nil and vB == nil then removed[k] = vA
        elseif vA ~= vB               then changed[k]  = { from = vA, to = vB }
        end
    end
    return { added = added, removed = removed, changed = changed }
end

-- ── Query ─────────────────────────────────────────────────────────────────

export type QueryFilter = {
    accessType:  AccessType?,
    keyClass:    KeyClass?,
    keyPattern:  string?,
    minDepth:    number?,
    sourceLabel: string?,
    since:       number?,
}

function VMEnvLogger:query(f: QueryFilter?): { VMEntry }
    if not f then return self._entries end
    local out: { VMEntry } = {}
    for _, e in ipairs(self._entries) do
        if f.accessType  and e.accessType  ~= f.accessType                   then continue end
        if f.keyClass    and e.keyClass    ~= f.keyClass                     then continue end
        if f.minDepth    and e.callDepth   <  (f.minDepth :: number)         then continue end
        if f.sourceLabel and e.sourceLabel ~= f.sourceLabel                  then continue end
        if f.since       and e.tick        <  (f.since    :: number)         then continue end
        if f.keyPattern  and not e.key:match(f.keyPattern)                   then continue end
        table.insert(out, e)
    end
    return out
end

-- ── Summary ───────────────────────────────────────────────────────────────

function VMEnvLogger:printSummary()
    type Row = { r:number, w:number, c:number, raw:number, upv:number, class:string }
    local counts: { [string]: Row } = {}
    for _, e in ipairs(self._entries) do
        if not counts[e.key] then
            counts[e.key] = { r=0, w=0, c=0, raw=0, upv=0, class=e.keyClass }
        end
        local row = counts[e.key]
        local a = e.accessType
        if     a == "READ"                            then row.r   += 1
        elseif a == "WRITE"                           then row.w   += 1
        elseif a == "CALL"                            then row.c   += 1
        elseif a == "RAWREAD" or a == "RAWWRITE"      then row.raw += 1
        elseif a == "UPVALUE_R" or a == "UPVALUE_W"  then row.upv += 1
        end
    end
    local keys: { string } = {}
    for k in pairs(counts) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
        local ra, rb = counts[a], counts[b]
        return (ra.r+ra.w+ra.c+ra.raw+ra.upv) > (rb.r+rb.w+rb.c+rb.raw+rb.upv)
    end)
    local sep = string.rep("=", 100)
    print(sep)
    print(string.format("  VM ENV SUMMARY  |  %d entries  |  %d keys",
        #self._entries, #keys))
    print(sep)
    print(string.format("  %-28s %-14s %6s %6s %6s %5s %5s",
        "KEY", "CLASS", "READS", "WRITES", "CALLS", "RAW", "UPV"))
    print(string.rep("-", 100))
    for _, k in ipairs(keys) do
        local r = counts[k]
        print(string.format("  %-28s %-14s %6d %6d %6d %5d %5d",
            k, r.class, r.r, r.w, r.c, r.raw, r.upv))
    end
    print(sep)
end

-- ── Export / Clear ────────────────────────────────────────────────────────

function VMEnvLogger:export(): { VMEntry }
    local out: { VMEntry } = {}
    for i, e in ipairs(self._entries) do out[i] = e end
    return out
end

function VMEnvLogger:clear()
    table.clear(self._entries)
    table.clear(self._snapshots)
    table.clear(self._wrapped)
    table.clear(self._uvCache)
    table.clear(self._uvScanned)
    self._counter  = 0
    self._inRecord = false
end

return VMEnvLogger


--[[
────────────────────────────────────────────────────────────────────────────
 USAGE
────────────────────────────────────────────────────────────────────────────

local VMEnvLogger = require(path.to.VMEnvLogger)

local logger = VMEnvLogger.new({
    stackDepth      = 6,      -- keep this low, raise only when debugging
    scanUpvalues    = true,   -- scans each fn once on first READ
    hookRaw         = true,
    hookFenv        = true,
    hookTableFreeze = true,   -- prevents table.freeze from locking env
    hookCoroutines  = true,
    forceMetaBypass = true,
    proxyStdlibs    = false,  -- enable only if you need math/string/os logs
    printLive       = true,
})

-- Scan loader upvalues before running (finds bytecode blob, const pool, dispatch fn)
logger:scanLoader(vmLoaderFunction, "loader")

-- Snapshot env before
local env = { print=print, math=math, string=string, table=table, os=os }
logger:snapshot(env, "before")

-- Wrap and run
local proxied = logger:wrapEnv(env, "my-vm")
local chunk = load(obfuscatedSource, "obf", "t", proxied)
if chunk then chunk() end

-- Snapshot after and diff
logger:snapshot(env, "after")
local d = logger:diff("before", "after")
for k, v   in pairs(d.added)   do print("ADDED",   k, v) end
for k, v   in pairs(d.removed) do print("REMOVED", k, v) end
for k, c   in pairs(d.changed) do print("CHANGED", k, c.from, "->", c.to) end

-- Summary
logger:printSummary()

-- Queries
logger:query({ accessType = "WRITE" })
logger:query({ keyClass   = "VM_INTERNAL" })
logger:query({ accessType = "FREEZE_TRAP" })

-- Upvalue polling (call in Heartbeat or manually)
local poll = logger:watchUpvalue(vmDispatchFn, "dispatch")
poll()  -- call whenever you want to check for mutations

-- Force-inject a value into a VM upvalue
logger:injectUpvalue(vmDispatchFn, "_ENV", proxied)

────────────────────────────────────────────────────────────────────────────
]]
