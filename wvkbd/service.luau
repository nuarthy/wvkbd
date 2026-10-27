--!nonstrict
-- wvkbd - headless service ([[service]]).
--
-- Owns the keyboard process for the whole session and publishes its state on
-- the "status" channel; the bar pill mirrors that state and drives the
-- keyboard by writing to the "command" channel. Owning the
-- process here, rather than in the widget, keeps the keyboard alive across
-- widget reloads and makes it togglable from a keybinding with no pill placed:
--
--   noctalia msg plugin nuarthy/wvkbd:service all toggle
--
-- The default "lifetime = stop" is the plain toggle a shell script does: the
-- second click ends the process. "lifetime = keep" leaves wvkbd running and uses
-- its own SIGUSR1 (hide) and SIGUSR2 (show), so a hidden keyboard comes back
-- without a restart. Either way the process stops when the service exits.

noctalia.setUpdateInterval(250)

-- Preference order for "binary = auto": a custom build first, because that is
-- the one compiled with the user's own layout, then the packaged layouts.
local AUTO_BINARIES = { "wvkbd-custom", "wvkbd-mobintl", "wvkbd-deskintl" }
-- Where "make LAYOUT=custom" leaves a wvkbd checkout's binary.
local AUTO_BUILD_DIR = "~/applications/wvkbd"

-- wvkbd takes its colours once, at startup, so the plugin passes them as flags
-- and restarts the process when the palette moves. Keys use the surface variant,
-- special keys a slightly deeper mix of it, and a pressed key the accent.
local SPECIAL_KEY_MIX = 0.12

local CHECK_TICKS = 8 -- 8 * 250 ms = 2 s between process checks

local state = "stopped" -- stopped | hidden | shown | unavailable
local running = false
local available = false
local binary = ""
local processName = ""
local wantedBinary = "wvkbd"
local flags = {}
local lastError = ""
local keepLoaded = false
local themeSignature = ""
local lastSpawnMs = 0
local lastStopMs = 0
local tick = 0
local checkPending = false
local spawnPending = false
local lastStatusKey

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function log(msg)
    noctalia.log(`wvkbd: {msg}`)
end

local function trimmed(value)
    if type(value) ~= "string" then
        return ""
    end
    return noctalia.string.trim(value)
end

local function basename(path)
    local name = path:gsub("/+$", ""):match("[^/]+$")
    return name or path
end

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Where wvkbd's own stdout and stderr go. The process is detached, so this file
-- is the only place a startup failure explains itself.
local function logPath()
    local dir = noctalia.pluginDataDir()
    if type(dir) ~= "string" or dir == "" then
        return "/dev/null"
    end
    noctalia.mkdirAll(dir)
    return `{dir}/wvkbd.log`
end

local function logTail()
    local contents = noctalia.readFile(logPath())
    if type(contents) ~= "string" or contents == "" then
        return ""
    end
    local tail = {}
    for line in contents:gmatch("[^\n]+") do
        tail[#tail + 1] = line
        if #tail > 3 then
            table.remove(tail, 1)
        end
    end
    return table.concat(tail, " ")
end

-- ── Command line ─────────────────────────────────────────────────────────────

local function resolveBinary()
    local configured = trimmed(noctalia.getConfig("binary"))
    if configured ~= "" then
        if configured:sub(1, 1) == "~" or configured:find("/", 1, true) then
            local path = noctalia.expandPath(configured)
            if noctalia.fileExists(path) then
                return path
            end
            return nil, configured
        end
        if noctalia.commandExists(configured) then
            return configured
        end
        return nil, configured
    end

    for _, name in ipairs(AUTO_BINARIES) do
        if noctalia.commandExists(name) then
            return name
        end
    end
    for _, name in ipairs(AUTO_BINARIES) do
        local path = noctalia.expandPath(`{AUTO_BUILD_DIR}/{name}`)
        if noctalia.fileExists(path) then
            return path
        end
    end
    return nil, "wvkbd"
end

local function paletteHex(role)
    local hex = noctalia.getColor(role)
    if type(hex) ~= "string" then
        return nil
    end
    return hex:match("^#(%x%x%x%x%x%x)")
end

-- Moves a colour `amount` (0..1) towards `target`, as "rrggbb". The special keys
-- need a shade of their own, and plugin API 34 exposes no container role for one.
local function mixHex(base, target, amount)
    local br, bg, bb = base:match("^(%x%x)(%x%x)(%x%x)")
    local tr, tg, tb = target:match("^(%x%x)(%x%x)(%x%x)")
    if br == nil or tr == nil then
        return base
    end
    local function blend(from, to)
        local value = tonumber(from, 16) + (tonumber(to, 16) - tonumber(from, 16)) * amount
        return string.format("%02x", math.floor(value + 0.5))
    end
    return blend(br, tr) .. blend(bg, tg) .. blend(bb, tb)
end

-- The colour flags for the current palette, plus a signature of every colour
-- used. A changed signature means the theme moved under a running keyboard, which
-- is what update() watches for.
local function colorArgs()
    local surface = paletteHex("surface")
    local keys = paletteHex("surface_variant") or surface
    local text = paletteHex("on_surface")
    local textMuted = paletteHex("on_surface_variant") or text
    local accent = paletteHex("primary")
    local onAccent = paletteHex("on_primary") or text

    local special = keys
    if keys ~= nil and text ~= nil then
        special = mixHex(keys, text, SPECIAL_KEY_MIX)
    end

    local flags = {
        { "--bg", surface },
        { "--fg", keys },
        { "--fg-sp", special },
        { "--press", accent },
        { "--press-sp", accent },
        { "--text", text },
        { "--text-sp", textMuted },
        { "--text-press", onAccent },
        { "--text-press-sp", onAccent },
    }

    local argv, signature = {}, {}
    for _, entry in ipairs(flags) do
        if entry[2] ~= nil then
            argv[#argv + 1] = entry[1]
            argv[#argv + 1] = entry[2]
            signature[#signature + 1] = entry[2]
        end
    end
    return argv, table.concat(signature, "/")
end

-- Everything after the binary name. Unset settings are left out entirely so the
-- binary keeps the value it was compiled with.
local function buildFlags()
    local argv = {}

    local height = tonumber(noctalia.getConfig("height"))
    if height ~= nil and height > 0 then
        argv[#argv + 1] = "-H"
        argv[#argv + 1] = tostring(math.floor(height))
    end

    local layers = trimmed(noctalia.getConfig("layers"))
    if layers ~= "" then
        argv[#argv + 1] = "-l"
        argv[#argv + 1] = layers
    end

    local font = trimmed(noctalia.getConfig("font"))
    if font ~= "" then
        argv[#argv + 1] = "--fn"
        argv[#argv + 1] = font
    end

    local rounding = tonumber(noctalia.getConfig("rounding"))
    if rounding ~= nil and rounding >= 0 then
        argv[#argv + 1] = "-R"
        argv[#argv + 1] = tostring(math.floor(rounding))
    end

    if noctalia.getConfig("colors") == "shell" then
        local colors, signature = colorArgs()
        for _, arg in ipairs(colors) do
            argv[#argv + 1] = arg
        end
        themeSignature = signature
    end

    return argv
end

-- ── Status ───────────────────────────────────────────────────────────────────

local function statusTable()
    return {
        state = state,
        available = available,
        error = lastError,
        binary = processName,
    }
end

local function publish()
    local key = `{state}/{available and "+" or "-"}/{lastError}`
    if key == lastStatusKey then
        return
    end
    lastStatusKey = key
    noctalia.state.set("status", statusTable())
end

local function setState(next)
    state = next
    publish()
end

-- ── Process ──────────────────────────────────────────────────────────────────

-- Runs the keyboard detached: the shell that starts it exits at once, so the
-- process outlives this entry's runtime. `visible` false starts it with
-- --hidden, which is how a settings change keeps a hidden keyboard hidden.
local function spawn(visible)
    local argv = { quote(binary) }
    for _, arg in ipairs(flags) do
        argv[#argv + 1] = quote(arg)
    end
    if not visible then
        argv[#argv + 1] = "--hidden"
    end

    local command = `{table.concat(argv, " ")} >> {quote(logPath())} 2>&1 &`
    running = true
    spawnPending = true
    lastSpawnMs = noctalia.nowMs()
    log(`start {processName}{if visible then "" else " (hidden)"}`)

    noctalia.runAsync(command, function(result)
        spawnPending = false
        if result.exitCode == 0 then
            return
        end
        running = false
        lastError = logTail()
        if lastError == "" then
            lastError = noctalia.tr("service.start-failed", { name = processName })
        end
        log(`start failed: {lastError}`)
        setState("stopped")
    end)
end

-- Signals reach every process of that name, which also covers an instance a
-- launcher script started outside the plugin: it is adopted instead of doubled.
local function signal(sig, callback)
    noctalia.runAsync({ "pkill", "-" .. sig, "-x", processName }, callback)
end

local function stop()
    if processName ~= "" then
        signal("TERM")
    end
    running = false
    lastStopMs = noctalia.nowMs()
    setState("stopped")
end

local function showKeyboard()
    if not available then
        return
    end
    if not running then
        spawn(true)
        setState("shown")
        return
    end
    if state ~= "shown" then
        signal("USR2")
        setState("shown")
    end
end

local function hideKeyboard()
    if not running then
        setState("stopped")
        return
    end
    if not keepLoaded then
        -- The plain toggle: the second click ends the process, as a shell script
        -- would. Nothing is left holding a virtual keyboard device.
        stop()
        return
    end
    if state ~= "hidden" then
        signal("USR1")
        setState("hidden")
    end
end

local function toggle()
    if state == "shown" then
        hideKeyboard()
    else
        showKeyboard()
    end
end

-- Kills the old command line, then starts the new one with the visibility it had.
local function restart()
    local wasShown = state == "shown"
    local wasHidden = state == "hidden"
    local previous = processName
    running = false
    if previous == "" then
        if wasShown then
            showKeyboard()
        else
            setState("stopped")
        end
        return
    end
    noctalia.runAsync({ "pkill", "-TERM", "-x", previous }, function()
        if available and wasShown then
            spawn(true)
            setState("shown")
        elseif available and wasHidden then
            spawn(false)
            setState("hidden")
        else
            setState("stopped")
        end
    end)
end

-- ── Configuration ────────────────────────────────────────────────────────────

local function applyConfig()
    local resolved, wanted = resolveBinary()
    wantedBinary = wanted or "wvkbd"
    available = resolved ~= nil
    binary = resolved or ""
    processName = basename(available and binary or wantedBinary)
    flags = buildFlags()
    keepLoaded = noctalia.getConfig("lifetime") == "keep"


    if not available then
        lastError = noctalia.tr("service.not-found", { name = wantedBinary })
        log(lastError)
        setState("unavailable")
        return
    end

    if lastError ~= "" then
        lastError = ""
    end
    if state == "unavailable" then
        setState("stopped")
    else
        publish()
    end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

local function detect()
    if processName == "" then
        return
    end
    checkPending = true
    noctalia.runAsync({ "pgrep", "-x", processName }, function(result)
        checkPending = false
        local found = result.exitCode == 0
        if found and not running then
            -- A process we just asked to stop is still listed while it exits; do
            -- not take that as a keyboard to adopt.
            if noctalia.nowMs() - lastStopMs < 3000 then
                return
            end
            -- Started outside the plugin (a launcher script, an older set-up):
            -- adopt it. A wvkbd that is not started with --hidden is visible.
            running = true
            log(`adopted running {processName}`)
            if state == "stopped" or state == "unavailable" then
                setState(available and "shown" or "stopped")
            end
        elseif not found and running then
            -- A just-spawned wvkbd is not in the process table for a moment after
            -- the launching shell exits; do not call that a death.
            if noctalia.nowMs() - lastSpawnMs < 2000 then
                return
            end
            running = false
            if state ~= "unavailable" then
                setState("stopped")
            end
        end
    end)
end

function update()
    tick += 1
    if tick < CHECK_TICKS then
        return
    end
    tick = 0

    -- A missing binary is re-resolved on every check, so installing wvkbd is
    -- enough to make the pill usable again without a shell restart.
    if not available then
        applyConfig()
        return
    end
    -- A palette change (mode switch, new wallpaper) moves the colours. Re-flag
    -- and restart a running keyboard so it repaints in the new theme.
    if noctalia.getConfig("colors") == "shell" then
        local _, signature = colorArgs()
        if signature ~= themeSignature then
            themeSignature = signature
            flags = buildFlags()
            if running then
                restart()
                return
            end
        end
    end

    if checkPending or spawnPending then
        return
    end
    detect()
end

function onConfigChanged()
    applyConfig()
    if running then
        restart()
    end
end

function onIpc(event, payload)
    if event == "toggle" then
        toggle()
    elseif event == "show" then
        showKeyboard()
    elseif event == "hide" then
        hideKeyboard()
    elseif event == "stop" then
        stop()
    elseif event == "restart" then
        applyConfig()
        if running then
            restart()
        else
            showKeyboard()
        end
    elseif event == "status" then
        local encoded = noctalia.json.encode(statusTable(), false)
        log(encoded or "{}")
        local message = noctalia.tr("service.status", { state = state })
        if available then
            noctalia.notify(noctalia.tr("title"), message)
        else
            noctalia.notifyError(noctalia.tr("title"), lastError)
        end
    end
end

function onExit(_signal, reason)
    if running and processName ~= "" then
        -- Detached on purpose: the kill has to outlive this runtime.
        noctalia.runAsync({ "pkill", "-TERM", "-x", processName })
        log(`stopped ({reason or "exit"})`)
    end
end

noctalia.state.watch("command", function(command)
    if type(command) ~= "table" then
        return
    end
    local action = command.action
    if action == "toggle" then
        toggle()
    elseif action == "show" then
        showKeyboard()
    elseif action == "hide" then
        hideKeyboard()
    elseif action == "stop" then
        stop()
    elseif action == "restart" then
        applyConfig()
        restart()
    end
end)

applyConfig()
publish()
