-- Assassinen Version – jedes Addon sagt der Gilde beim Einloggen seine Version.
-- Hat ein anderes Mitglied eine neuere, erscheint ein Hinweis mit dem Weg zum Update.
-- Selbst aktualisieren kann sich ein Addon nicht (WoW erlaubt keinen Download): das macht Assassinen-Update.bat.

local ADDON_NAME, ns = ...
local Version = {}
ns.Version = Version

Version.REPO = "mkahl395-cell/assassinen-addon"
Version.DOWNLOAD = "github.com/" .. Version.REPO .. "/releases/latest"

local S, Rudel
local mine
local known = {}        -- Name -> { v, t }
local told = false
local lastReply = -999

local function Print(msg) ns.Print(msg) end

local function Parse(v)
    local t = {}
    for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end

-- Ist Version a neuer als b?
function Version.Newer(a, b)
    local x, y = Parse(a), Parse(b)
    if #x == 0 then return false end
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

function Version.Mine()
    if not mine then
        local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        local ok, v = pcall(get or function() end, ADDON_NAME, "Version")
        mine = ok and type(ns.Safe(v)) == "string" and v or "?"
    end
    return mine
end

local function Tell(v)
    if told then return end
    told = true
    Print(string.format("|cff40ff40Neue Version %s verfügbar|r (du hast %s). WoW beenden und |cffffd100Assassinen-Update|r starten – oder herunterladen: %s",
        v, Version.Mine(), Version.DOWNLOAD))
    if ns.UI and ns.UI.Alert then ns.UI.Alert("Neue Assassinen-Version " .. v .. " verfügbar – siehe Chat", false) end
end

function Version.Announce()
    if IsInGuild() then Rudel.Send("GUILD", nil, "VER", Version.Mine()) end
end

local function OnVer(f, sender)
    local v = f[2]
    if type(v) ~= "string" or v == "" then return end
    known[ns.ShortName(sender) or sender] = { v = v, t = time() }
    if Version.Newer(v, Version.Mine()) then
        if not S.newestSeen or Version.Newer(v, S.newestSeen) then S.newestSeen = v end
        Tell(v)
    elseif Version.Newer(Version.Mine(), v) and GetTime() - lastReply > 60 then
        -- Wer eine ältere Version meldet, erfährt von der neueren (höchstens einmal pro Minute, leicht versetzt)
        lastReply = GetTime()
        C_Timer.After(1 + math.random() * 4, Version.Announce)
    end
end

function Version.List()
    local out = {}
    for name, e in pairs(known) do out[#out + 1] = { name = name, v = e.v } end
    table.sort(out, function(a, b)
        if a.v ~= b.v then return Version.Newer(a.v, b.v) end
        return a.name < b.name
    end)
    return out
end

function Version.Slash(cmd)
    if cmd == "versionen" or cmd == "version" then
        Print(string.format("Deine Version: |cffffd100%s|r. Gemeldet seit dem Einloggen:", Version.Mine()))
        local list = Version.List()
        if #list == 0 then Print("  noch niemand (nach dem Einloggen kurz warten)") end
        for _, e in ipairs(list) do
            local old = Version.Newer(Version.Mine(), e.v)
            Print(string.format("  %s: %s%s|r", e.name, old and "|cffff8040" or "|cffffffff", e.v))
        end
    elseif cmd == "update" then
        Print("Update: WoW beenden und |cffffd100Assassinen-Update.bat|r starten. Download: " .. Version.DOWNLOAD)
    else
        return false
    end
    return true
end

function Version.Init()
    S, Rudel = ns.settings, ns.Rudel
    -- schon aktualisiert? Dann den alten Hinweis vergessen
    if S.newestSeen and not Version.Newer(S.newestSeen, Version.Mine()) then S.newestSeen = nil end
    Rudel.On("VER", OnVer)
    C_Timer.After(12, function()
        Version.Announce()
        if S.newestSeen then Tell(S.newestSeen) end
    end)
end
