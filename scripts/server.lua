-- BindForge/scripts/server.lua
--
-- Serves a visual keymap editor to your browser: a picture of the keyboard,
-- click a key, edit what it does, save. Changes hit the live keyboard
-- immediately -- it edits hotkeys.json through HotkeyBinder, the same path a
-- hand edit takes.
--
-- Toggle it with hammer+; (cmd+ctrl+alt+;). That starts the server and opens
-- the page; press it again to stop the server.
--
-- SECURITY. This opens a port that mutates the user's keyboard, so:
--   * bound to localhost only, and Bonjour advertising is off -- a keyboard
--     config server has no business announcing itself on the LAN.
--   * every /api/ call must carry a per-start random token in the
--     X-Keymap-Token header. The token lives in the page the server itself
--     serves, never in the URL, so it stays out of history and Referer.
--   * no CORS headers are ever sent. A page on another origin can reach the
--     port, but a request with a custom header needs a preflight this server
--     does not answer, and it could not read the response anyway. That is
--     what stops a random site the user is visiting from rebinding their keys.
-- Loopback alone would not be enough: anything running as the user can reach
-- 127.0.0.1, and browsers happily send cross-origin requests to it.

local Server = {}

Server.server = nil
Server.port = 27123          -- arbitrary, unprivileged, unlikely to collide
Server.token = nil

local function log()
    return _G.AppLogger or hs.logger.new("Server")
end

-- hs.json.encode REQUIRES a table and throws on a bare string ("incorrect type
-- 'string' for argument 1"). Wrapping in an array and stripping the brackets
-- borrows Hammerspoon's own escaping instead of hand-rolling one.
local function jsonString(s)
    return (hs.json.encode({ tostring(s or "") }):sub(2, -2))
end

-- Resolved ONCE, at load. hs.spoons.resourcePath resolves relative to whatever
-- file is CALLING it, and inside an hs.httpserver callback that is no longer
-- this file: every asset read failed and the server could only report a 503.
-- At load time the caller is this file, so it resolves correctly.
Server.assetDir = (function()
    -- Self-resolved fallback. init.lua overrides this with spoonPath, which
    -- Hammerspoon injects before calling init() and which does not depend on
    -- who is calling.
    local viaSpoon = hs.spoons.resourcePath("../assets/")
    if viaSpoon and hs.fs.attributes(viaSpoon .. "keymap.js") then return viaSpoon end
    return hs.configdir .. "/Spoons/BindForge.spoon/assets/"
end)()

local function assetPath(name)
    return Server.assetDir .. name
end

local function readAsset(name)
    local file = io.open(assetPath(name), "r")
    if not file then
        log():e("BindForge: could not read asset " .. tostring(name))
        return nil
    end
    local contents = file:read("*a")
    file:close()
    return contents
end

-- The binder ships inside this spoon and registers itself as a singleton on
-- _G._HotkeyBinder, so every surface shares the table holding the live
-- hs.hotkey handles rather than starting a second one.
local function binder()
    return rawget(_G, "_HotkeyBinder")
end

-- Same payload every surface renders. Kept here rather than imported from
-- keymap_window.lua so the server does not depend on a window existing.
function Server.buildPayload()
    local B = binder()
    if not B then return { bindings = {}, modifierSets = {}, actionTypes = {}, problems = {} } end


    local problems = {}
    for _, err in ipairs(B.errors or {}) do
        local id, msg = err:match("^([^:]+):%s*(.+)$")
        if id then problems[id] = msg end
    end
    for _, bad in ipairs(B.verify()) do problems[bad.id] = bad.error end

    -- This config binds keys to functions only, so the editor is told there
    -- are no "action types" and hides that half of the form.
    local actionTypes = {}

    return {
        bindings = (B.config or {}).bindings or {},
        modifierSets = (B.config or {}).modifierSets or {},
        actionTypes = actionTypes,
        problems = problems,
        -- Autocomplete source for the editor's function-path field. A hint, not
        -- a whitelist: paths resolve at press time, so one missing from here can
        -- still be valid later.
        functions = B.knownFunctions(),
    }
end

-- hs.json.encode turns an empty table into "[]", but the page does
-- data.problems[id] and Object.keys(actionTypes). Force object syntax for the
-- two maps that can legitimately be empty.
local function encodePayload(payload)
    local encoded = hs.json.encode(payload)
    if not encoded then return nil end
    encoded = encoded:gsub('"problems":%[%]', '"problems":{}')
    encoded = encoded:gsub('"actionTypes":%[%]', '"actionTypes":{}')
    return encoded
end

-- Build the page: shared shell + this surface's notice, transport and the one
-- renderer. Mirrors build_keymap_artifact.py and editor_window.lua -- three
-- hosts, one editor.
function Server.renderPage()
    local shell = readAsset("keymap_page.html")
    local transport = readAsset("keymap_transport_http.js")
    local renderer = readAsset("keymap.js")
    local theme = readAsset("keymap_theme.js")
    -- Two optional extras. Absent just means the editor offers fewer knobs:
    -- no palette picker, and no typed widgets for action parameters (which
    -- this config has none of anyway).
    local themes = readAsset("keymap_themes.js") or ""
    local widgets = readAsset("param_widgets.js") or ""
    if not (shell and transport and renderer and theme) then return nil end

    local notice = [[<p>
                    <strong>Connected to Hammerspoon.</strong> Changes apply to the live
                    keyboard the moment you save them &mdash; no reload, no export. This page is
                    served from your own Mac on localhost and is not reachable from anywhere else.
                </p>]]

    -- Function replacements so a '%' or brace in an asset body is not read as a
    -- gsub escape.
    shell = shell:gsub("__NOTICE__", function() return notice end)
    shell = shell:gsub("__TRANSPORT__", function()
        return "window.KEYMAP_TOKEN = " .. jsonString(Server.token) .. ";\n" .. transport
    end)
    shell = shell:gsub("__WIDGETS__", function() return widgets end)
    shell = shell:gsub("__THEMES__", function() return themes end)
    shell = shell:gsub("__THEME__", function() return theme end)
    shell = shell:gsub("__RENDERER__", function() return renderer end)
    return shell
end

local JSON_HEADERS = { ["Content-Type"] = "application/json" }
local HTML_HEADERS = { ["Content-Type"] = "text/html; charset=utf-8" }

local function jsonResponse(tbl, code)
    return hs.json.encode(tbl) or "{}", code or 200, JSON_HEADERS
end

local function tableResponse(message)
    local encoded = encodePayload(Server.buildPayload())
    if not encoded then return jsonResponse({ error = "could not encode table" }, 500) end
    -- Splice the pre-encoded table in rather than re-encoding it, so the
    -- object-vs-array fixups above survive.
    local body = '{"message":' .. jsonString(message) .. ',"table":' .. encoded .. '}'
    return body, 200, JSON_HEADERS
end

function Server.handler(method, path, headers, body)
    -- Strip any query string; the page is served from "/" and the API paths
    -- carry no parameters.
    local route = path:match("^([^?]*)") or path

    if route == "/" or route == "/index.html" then
        local page = Server.renderPage()
        if not page then return "Could not build the keymap page", 500, {} end
        return page, 200, HTML_HEADERS
    end

    if not route:match("^/api/") then
        return "Not found", 404, {}
    end

    -- Header names arrive with varying case depending on the client.
    local token
    for k, v in pairs(headers or {}) do
        if k:lower() == "x-keymap-token" then token = v end
    end
    if not Server.token or token ~= Server.token then
        return "Forbidden", 403, {}
    end

    local B = binder()
    if not B then return jsonResponse({ error = "HotkeyBinder unavailable" }, 500) end

    if method == "GET" and route == "/api/bindings" then
        local encoded = encodePayload(Server.buildPayload())
        if not encoded then return jsonResponse({ error = "could not encode table" }, 500) end
        return encoded, 200, JSON_HEADERS
    end

    if method ~= "POST" then return "Not found", 404, {} end

    local ok, payload = pcall(hs.json.decode, body or "")
    if route ~= "/api/reload" and (not ok or type(payload) ~= "table") then
        return jsonResponse({ error = "body must be a JSON object" }, 400)
    end

    if route == "/api/binding" then
        if not payload.id then return jsonResponse({ error = "binding needs an id" }, 400) end
        local bound, err = B.setBinding(payload)
        local message = bound and ("Saved and applied " .. payload.id .. ".")
            or ("Saved, but not bound: " .. tostring(err or (B.errors[#B.errors] or "see the console")))
        return tableResponse(message)
    end

    if route == "/api/binding/delete" then
        if not payload.id then return jsonResponse({ error = "need an id" }, 400) end
        local removed = B.deleteBinding(payload.id)
        return tableResponse(removed and ("Deleted " .. payload.id .. ".") or "Nothing to delete.")
    end

    if route == "/api/reload" then
        B.load()
        local n = B.applyAll()
        return tableResponse("Reloaded from disk: " .. n .. " bound.")
    end

    return "Not found", 404, {}
end

function Server.url()
    return "http://localhost:" .. Server.port .. "/"
end

function Server.isRunning()
    return Server.server ~= nil
end

function Server.start()
    if Server.server then return Server.url() end

    -- 32 hex chars from the system RNG. math.random is seeded predictably
    -- enough at startup that it has no business guarding a write API.
    local handle = io.open("/dev/urandom", "rb")
    if handle then
        local bytes = handle:read(16)
        handle:close()
        Server.token = (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    else
        Server.token = tostring(hs.host.uuid()):gsub("-", "")
    end

    -- new(ssl, bonjour): both explicit. Bonjour must be off -- see the header.
    local server = hs.httpserver.new(false, false)
    if not server then
        log():e("Keymap server: could not create hs.httpserver")
        return nil
    end

    server:setPort(Server.port)
    server:setInterface("localhost")
    server:setCallback(Server.handler)

    local started, err = pcall(function() return server:start() end)
    if not started then
        log():e("Keymap server: start failed: " .. tostring(err))
        return nil
    end

    Server.server = server
    Server.installShutdownHook()
    log():i("Keymap server listening on " .. Server.url())
    return Server.url()
end

-- hs.reload() builds a fresh Lua state but does NOT run Server.stop(), and the old
-- listening socket can outlive the state that owned it. The next start then
-- fails to bind while the PREVIOUS callback keeps answering on the port -- which
-- looks exactly like new code that will not take effect (it served stale 503s
-- through several reloads before this hook existed). Releasing the socket on
-- shutdown is the fix. Chain rather than replace: hs.shutdownCallback is a
-- single global slot and other code may already own it.
function Server.installShutdownHook()
    if Server.shutdownHooked then return end
    Server.shutdownHooked = true
    local previous = hs.shutdownCallback
    hs.shutdownCallback = function()
        pcall(Server.stop)
        if type(previous) == "function" then pcall(previous) end
    end
end

function Server.stop()
    if not Server.server then return false end
    pcall(function() Server.server:stop() end)
    Server.server = nil
    Server.token = nil
    log():i("Keymap server stopped")
    return true
end

function Server.toggle()
    if Server.server then
        Server.stop()
        hs.alert.show("Keymap server stopped")
        return nil
    end
    local url = Server.start()
    if url then
        hs.alert.show("Keymap server: " .. url)
        -- The token only reaches the browser through the page this server
        -- serves, so opening it here is also how the session is authorised.
        hs.urlevent.openURL(url)
    else
        hs.alert.show("Keymap server failed to start (see console)")
    end
    return url
end

return Server
