-- BindForge/scripts/window.lua
--
-- The keymap editor in a native Hammerspoon window: the same keyboard grid the
-- browser version shows, without a browser or an open port.
--
-- Toggle it with hyper+; (cmd+ctrl+alt+shift+;). Its sibling, hammer+;, serves
-- the same editor to a browser tab instead -- pick whichever you like; both
-- edit hotkeys.json through HotkeyBinder and apply changes to the live
-- keyboard.
--
-- The page itself is host-agnostic: assets/keymap.js renders and edits, and
-- talks only to window.KeymapTransport (assets/keymap_transport_hs.js). That
-- one file is the difference between this window and the browser page.

local Window = {}

-- Resolved once at load, for the reason spelled out in server.lua.
Window.assetDir = (function()
    -- Self-resolved fallback. init.lua overrides this with spoonPath, which
    -- Hammerspoon injects before calling init() and which does not depend on
    -- who is calling.
    local viaSpoon = hs.spoons.resourcePath("../assets/")
    if viaSpoon and hs.fs.attributes(viaSpoon .. "keymap.js") then return viaSpoon end
    return hs.configdir .. "/Spoons/BindForge.spoon/assets/"
end)()

local function log()
    return _G.AppLogger or hs.logger.new("Window")
end

--- Read an asset, or "" if it is not there. `optional` suppresses the error:
--- param_widgets.js and keymap_themes.js are genuinely allowed to be absent, and
--- logging those every time the editor opens would be noise, not a signal.
local function readAsset(name, optional)
    local file = io.open(Window.assetDir .. name, "r")
    if not file then
        if not optional then
            log():e("BindForge: could not read asset " .. tostring(name))
        end
        return ""
    end
    local contents = file:read("*a")
    file:close()
    return contents
end

-- Reach the binder the same way hotkeys.lua does. require() is enough: the
-- module guards itself as a singleton on _G, so this is the very same table
-- holding the live hs.hotkey handles, not a second copy that would stack
-- shadowed duplicates on every combo.
-- Shared singleton -- see the note in server.lua.
local function binder()
    local B = rawget(_G, "_HotkeyBinder")
    if not B then log():e("BindForge: HotkeyBinder not loaded") end
    return B
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Data
-- ─────────────────────────────────────────────────────────────────────────────

--- Everything the page needs, in one payload. Problems are merged from two
--- sources so a key shows as broken whether it failed to bind (macOS owns the
--- combo) or binds fine but points at a function that no longer exists.
function Window.buildPayload()
    local B = binder()
    if not B then return { bindings = {}, modifierSets = {}, actionTypes = {}, problems = {} } end

    local problems = {}
    for _, err in ipairs(B.errors or {}) do
        local id, msg = err:match("^([^:]+):%s*(.+)$")
        if id then problems[id] = msg end
    end
    for _, bad in ipairs(B.verify()) do problems[bad.id] = bad.error end

    return {
        bindings = (B.config or {}).bindings or {},
        modifierSets = (B.config or {}).modifierSets or {},
        -- Whatever action system the host registered, or {} for none -- the
        -- editor offers the "action" kind only when this is non-empty, which
        -- is what lets one editor serve a config with an action system and one
        -- without.
        actionTypes = B.actionTypes and B.actionTypes() or {},
        problems = problems,
        -- Autocomplete source for the function-path field. A hint, not a
        -- whitelist: paths resolve at press time, so one missing from here can
        -- still be valid later.
        functions = B.knownFunctions(),
    }
end

--- Push the current table into the page.
function Window.refresh()
    local win = Window.win
    if not win then return end
    local payload = hs.json.encode(Window.buildPayload())
    if not payload then
        log():e("Keymap window: could not encode payload")
        return
    end
    win:evaluateJavaScript(string.format("window.Keymap.render(%s)", payload))
end

-- hs.json.encode REQUIRES a table and throws on a bare string ("incorrect type
-- 'string' for argument 1"). Wrapping in an array and stripping the brackets
-- borrows Hammerspoon's own escaping instead of hand-rolling one.
local function jsonString(s)
    return (hs.json.encode({ tostring(s or "") }):sub(2, -2))
end

--- Report a one-line result into the editor's status area.
local function say(text)
    local win = Window.win
    if not win then return end
    win:evaluateJavaScript(string.format("window.Keymap.setStatus(%s)", jsonString(text)))
end

-- Percent-decode then JSON-decode a bridge payload, or nil (having said so) if
-- it is malformed. Callers must bail on nil rather than write half a binding.
function Window.decode(args)
    if not args or args == "" then return nil end
    local decoded = args:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    local ok, value = pcall(hs.json.decode, decoded)
    if not ok or type(value) ~= "table" then
        log():e("Keymap window: bad bridge payload: " .. tostring(decoded))
        return nil
    end
    return value
end

--- Handle one hammerspoon:// message from the page. The payload convention is
--- that the whole query string is one encodeURIComponent(JSON.stringify(...)).
function Window.handleURL(url)
    local cmd, args = url:match("hammerspoon://([^?]+)%??(.*)")
    if not cmd then return end

    local B = binder()
    if not B then return end

    if cmd == "keymapData" then
        Window.refresh()

    elseif cmd == "keymapSave" then
        local binding = Window.decode(args)
        if not binding then return say("Could not read that change.") end

        local ok, err = B.setBinding(binding)
        if ok then
            say("Saved and applied " .. tostring(binding.id) .. ".")
        else
            -- A refused bind is the normal failure here (macOS owns the combo),
            -- and the binder has already recorded why.
            local why = err or (B.errors[#B.errors] or "see the Hammerspoon console")
            say("Saved, but not bound: " .. tostring(why))
        end
        Window.refresh()

    elseif cmd == "keymapDelete" then
        local payload = Window.decode(args)
        if not payload or not payload.id then return say("Could not read that change.") end
        local removed = B.deleteBinding(payload.id)
        say(removed and ("Deleted " .. payload.id .. ".") or "Nothing to delete.")
        Window.refresh()

    elseif cmd == "keymapReload" then
        B.load()
        local n = B.applyAll()
        say("Reloaded from disk: " .. n .. " bound.")
        Window.refresh()
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Window
-- ─────────────────────────────────────────────────────────────────────────────

-- Escape Lua pattern magic so a filename matches literally. Filenames carry a
-- '.', which as a pattern means "any character".
local function escapePattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

-- A webview loaded with hs.webview:html() has no working origin for file://
-- subresources, so every <link> and <script src> in the page is inlined here
-- instead. Function replacements keep the asset bodies literal, so a '%' or a
-- brace inside them is not read as a gsub escape.
function Window.renderPage()
    local html = readAsset("keymap.html")
    if html == "" then
        return "<html><body><h1>Error</h1><p>Could not read assets/keymap.html</p></body></html>"
    end

    html = html:gsub('<link rel="stylesheet" href="styles.css">', function()
        return "<style>\n" .. readAsset("styles.css") .. "\n</style>"
    end)

    -- Order matters: param widgets and palettes must exist before the theme
    -- picker and renderer run, and the transport must define
    -- window.KeymapTransport before the renderer. param_widgets.js and
    -- keymap_themes.js are optional -- a missing one just means fewer knobs
    -- (no typed action parameters, no palette picker), not a broken page.
    local OPTIONAL = { ["param_widgets.js"] = true, ["keymap_themes.js"] = true }
    for _, name in ipairs({ "param_widgets.js", "keymap_themes.js",
                            "keymap_theme.js", "keymap_transport_hs.js", "keymap.js" }) do
        local body = readAsset(name, OPTIONAL[name])
        html = html:gsub('<script src="' .. escapePattern(name) .. '"></script>', function()
            return "<script>\n" .. body .. "\n</script>"
        end)
    end

    return html
end

--- Pull the URL out of a policyCallback's details table.
---
--- Hammerspoon changed the shape of this between builds: 6933 hands back
--- request.URL as a table with a .url field, 6936 hands back a plain string.
--- Reading only the table form is why the editor opened empty on the newer
--- build -- the match never fired, so the page's request for its data was
--- never seen and nothing was ever pushed back. Accept both.
function Window.navigationURL(details)
    local request = details and details.request
    local url = request and request.URL
    if type(url) == "table" then
        url = url.url or url.absoluteString
    end
    return type(url) == "string" and url or ""
end

function Window.create()
    local mainScreen = hs.screen.mainScreen()
    if not mainScreen then
        log():e("Keymap window: no main screen to open on")
        return nil
    end
    local screen = mainScreen:frame()
    -- Wide by default: the function row alone is 12 keys across, and the board
    -- now sizes its keys to the window, so a bigger window is a bigger
    -- keyboard rather than more empty space.
    local w = math.min(1500, screen.w - 80)
    local h = math.min(900, screen.h - 80)

    local win = hs.webview.new({
        x = screen.x + math.floor((screen.w - w) / 2),
        y = screen.y + math.floor((screen.h - h) / 2),
        w = w,
        h = h,
        show = false,
    })

    if not win then
        log():e("Keymap window: failed to create the webview")
        return nil
    end

    win:allowTextEntry(true)
    win:darkMode(true)
    win:windowStyle({ "titled", "closable", "resizable" })
    win:windowTitle("⌘ BindForge")
    win:allowNewWindows(false)

    -- The page talks to Lua by navigating to hammerspoon://... . Intercept
    -- those and return false, or the webview would blank itself trying to
    -- follow them.
    win:policyCallback(function(action, _, details)
        if action == "navigationAction" then
            if Window.navigationURL(details):match("^hammerspoon://") then
                Window.handleURL(Window.navigationURL(details))
                return false
            end
        end
        return true
    end)

    win:html(Window.renderPage(), Window.assetDir)
    return win
end

--- hyper+; -- open the editor, or put it away if it is already up.
function Window.toggle()
    local win = Window.win

    if win and win:isVisible() then
        win:hide()
        return false
    end

    if not win then
        win = Window.create()
        if not win then
            hs.alert.show("Keymap editor failed to open (see the console)")
            return false
        end
        Window.win = win
        -- No refresh here: the page asks for its data itself once it loads.
        win:show():bringToFront(true)
        return true
    end

    win:show():bringToFront(true)
    Window.refresh()   -- it may have gone stale while hidden
    return true
end

return Window
