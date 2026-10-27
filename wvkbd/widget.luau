--!nonstrict
-- wvkbd - bar pill ([[widget]]).
--
-- A thin client: it mirrors the service's "status" and asks the service to
-- toggle through the "command" channel, so the pill stays correct even when the
-- keyboard was started from a keybinding or an older launcher script.
--
--   left click   show the keyboard, or hide it while it is up
--   right click  open this plugin's settings (binary, height, layers, font)
--
-- The glyph carries the state, which keeps the pill one control wide on a
-- horizontal bar and inside the capsule of a vertical one:
--   stopped or hidden  keyboard-off, muted
--   shown              keyboard, accent
--   unavailable        keyboard-off, error colour, with the reason in the tooltip

local state = "stopped"
local available = true
local lastError = ""

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

local function detail()
    if lastError ~= "" then
        return lastError
    end
    if not available then
        return tr("widget.unavailable")
    end
    return if state == "shown" then tr("widget.shown") else tr("widget.hidden")
end

local function render()
    if available and state == "shown" then
        barWidget.setGlyph("keyboard")
        barWidget.setGlyphColor("primary")
    else
        barWidget.setGlyph("keyboard-off")
        barWidget.setGlyphColor(if available then "on_surface_variant" else "error")
    end
    barWidget.setTooltip({ { key = tr("title"), value = detail() } })
    barWidget.setVisible(true)
end

local function applyStatus(status)
    if type(status) == "table" then
        state = status.state or "stopped"
        available = status.available ~= false
        lastError = status.error or ""
    end
    render()
end

function onClick()
    if not available then
        noctalia.notifyError(tr("title"), detail())
        return
    end
    noctalia.state.set("command", { action = "toggle" })
end

function onRightClick()
    noctalia.openSettings()
end

-- `noctalia msg plugin nuarthy/wvkbd:keyboard focused toggle` behaves like a click.
function onIpc(event)
    if event == "toggle" then
        onClick()
    elseif event == "show" then
        noctalia.state.set("command", { action = "show" })
    elseif event == "hide" then
        noctalia.state.set("command", { action = "hide" })
    end
end

noctalia.state.watch("status", applyStatus)
applyStatus(noctalia.state.get("status"))
