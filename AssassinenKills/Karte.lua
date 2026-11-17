-- Assassinen Jagdkarte – Rudel, gesichtete Feinde, Hilferufe und Zielansagen
-- als Punkte auf Weltkarte und Minimap, dazu Entfernung und Richtung.
-- Koordinaten: Kartennummer (uiMapID) + x/y von 0 bis 1.

local ADDON_NAME, ns = ...
local Karte = {}
ns.Karte = Karte

local S
local me = {}       -- eigene Position { map, x, y }, alle 0,25 s aktualisiert
Karte.me = me
local marks = {}    -- Hilferufe und Zielansagen: id -> { kind, map, x, y, t, ttl, title, text }

local ENEMY_SECONDS = 300 -- so lange bleiben Feindsichtungen auf der Karte
local MINI_ENEMY_SECONDS = 90
local atan2 = math.atan2 or atan2 or function(y, x) return math.atan(y, x) end
local ICON_SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local ICON_CROSS = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7"
local ICON_STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local ICON_DIAMOND = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3" -- lila Raute: getarnter Feind
local WHITE = "Interface\\Buttons\\WHITE8x8"

-- Minimap-Durchmesser in Metern (Yards) je Zoomstufe
local MINI_OUTDOOR = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 }
local MINI_INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }

---------------------------------------------------------------------------
-- Position und Entfernung
---------------------------------------------------------------------------

function Karte.MapPos(unit)
    if not (C_Map and C_Map.GetBestMapForUnit) then return end
    unit = unit or "player"
    local map = C_Map.GetBestMapForUnit(unit)
    if not map then return end
    local pos = C_Map.GetPlayerMapPosition(map, unit)
    if not pos then return end
    local x, y = pos:GetXY()
    x, y = ns.Safe(x), ns.Safe(y)
    if not x or not y or (x == 0 and y == 0) then return end
    return map, x, y
end

-- Weltkoordinaten in Yards: Osten, Norden, Kontinent
local function World(map, x, y)
    if not (map and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
    local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
    if not ok or not w then return end
    local north, west = w:GetXY()
    return -west, north, cont
end

-- Abstand von mir aus: Yards, Versatz Osten, Versatz Norden
function Karte.Offset(map, x, y)
    if not me.map or not map then return end
    local ax, ay, ac = World(me.map, me.x, me.y)
    local bx, by, bc = World(map, x, y)
    if not ax or not bx or ac ~= bc then return end
    local dx, dy = bx - ax, by - ay
    return math.sqrt(dx * dx + dy * dy), dx, dy
end

local DIRS = { "Norden", "Nordosten", "Osten", "Südosten", "Süden", "Südwesten", "Westen", "Nordwesten" }
function Karte.Direction(dx, dy)
    local a = math.deg(atan2(dx, dy)) -- 0 = Norden, 90 = Osten
    if a < 0 then a = a + 360 end
    return DIRS[math.floor((a + 22.5) / 45) % 8 + 1]
end

-- "ca. 230 m Nordosten" (nil, wenn unbekannt oder anderer Kontinent)
function Karte.Describe(map, x, y)
    local d, dx, dy = Karte.Offset(map, x, y)
    if not d then return nil end
    local m = d * 0.9144
    if m < 25 then return "direkt bei dir", d end
    local rounded = m < 1000 and math.floor(m / 10 + 0.5) * 10 or math.floor(m / 100 + 0.5) * 100
    return string.format("ca. %d m %s", rounded, Karte.Direction(dx, dy)), d
end

-- Koordinaten für Nachrichten: ganze Zahlen 0..10000
function Karte.Pack(map, x, y)
    if not map then return "", "", "" end
    return map, math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5)
end

function Karte.Unpack(map, x, y)
    map, x, y = tonumber(map), tonumber(x), tonumber(y)
    if not map or not x or not y then return end
    return map, x / 10000, y / 10000
end

---------------------------------------------------------------------------
-- Markierungen (Hilferuf, Zielansage)
---------------------------------------------------------------------------

function Karte.Mark(id, kind, map, x, y, ttl, title, text)
    if not map then marks[id] = nil return end
    marks[id] = { kind = kind, map = map, x = x, y = y, t = GetTime(), ttl = ttl or 90, title = title, text = text }
    Karte.dirty = true
end

function Karte.Unmark(id)
    marks[id] = nil
    Karte.dirty = true
end

-- Mitglieder der eigenen Gruppe zeigt das Spiel auf der Minimap schon selbst. Erkannt werden sie am Namen,
-- an der GUID oder – falls das Spiel beides verbirgt – an der Position (weniger als 20 Yards daneben).
local function GroupSet()
    local set = { names = {}, guids = {}, pos = {} }
    local raid = IsInRaid and IsInRaid()
    local inGroup = raid or (IsInGroup and IsInGroup())
    if not inGroup then return set end
    local n = raid and (GetNumGroupMembers and GetNumGroupMembers() or 0) or 4
    for i = 1, n do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        if ns.Safe(UnitExists(unit)) and not ns.Safe(UnitIsUnit(unit, "player")) then
            local name = ns.ShortName(ns.Safe(UnitName(unit)))
            if name then set.names[name:lower()] = true end
            local guid = ns.Safe(UnitGUID(unit))
            if type(guid) == "string" then set.guids[guid] = true end
            local ok, map, x, y = pcall(Karte.MapPos, unit)
            if ok and map then set.pos[#set.pos + 1] = { map, x, y } end
        end
    end
    return set
end

local function InGroupSet(set, name, p)
    if ns.Rudel.InMyGroup and ns.Rudel.InMyGroup(name) then return true end
    if set.names[(ns.ShortName(name) or name):lower()] then return true end
    if p.guid and set.guids[p.guid] then return true end
    for _, q in ipairs(set.pos) do
        if q[1] == p.map then
            local ax, ay = World(p.map, p.x, p.y)
            local bx, by = World(q[1], q[2], q[3])
            -- die geteilte Position ist bis zu ein paar Sekunden alt, daher großzügig
            if ax and bx and (ax - bx) ^ 2 + (ay - by) ^ 2 < 20 * 20 then return true end
        end
    end
    return false
end

-- Alles, was gerade auf die Karte gehört
function Karte.Collect(forMinimap)
    local out, now = {}, GetTime()
    for id, m in pairs(marks) do
        if now - m.t > m.ttl then marks[id] = nil
        else out[#out + 1] = m end
    end
    if ns.Rudel then
        local selfName = ns.PlayerName()
        local group = GroupSet() -- Gruppenmitglieder zeigt das Spiel auf Minimap und Weltkarte schon selbst
        for name, p in pairs(ns.Rudel.pack) do
            if now - p.t <= 75 and p.map and name ~= selfName and not (group and InGroupSet(group, name, p)) then
                out[#out + 1] = { kind = "member", map = p.map, x = p.x, y = p.y, name = name, p = p }
            end
        end
    end
    if ns.Spy and ns.Spy.MapContacts then
        local maxAge = forMinimap and MINI_ENEMY_SECONDS or ENEMY_SECONDS
        for _, e in ipairs(ns.Spy.MapContacts(maxAge)) do
            out[#out + 1] = { kind = "enemy", map = e.map, x = e.x, y = e.y, c = e.c, key = e.key, age = e.age, by = e.by }
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Pins
---------------------------------------------------------------------------

local function Tooltip(pin)
    local e = pin.e
    if not e then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    if e.kind == "member" then
        local p = e.p
        GameTooltip:AddLine("|c" .. ns.ClassColor(p.class) .. e.name .. "|r  |cffaaaaaaRudel|r")
        local state = {}
        if p.hp then state[#state + 1] = string.format("Leben %d%%", p.hp) end
        if p.stealth then state[#state + 1] = "getarnt" end
        if p.combat then state[#state + 1] = "|cffff4040im Kampf|r" end
        local same = ns.Rudel.SameLayer(p.map, p.layer)
        if same ~= nil then state[#state + 1] = same and "|cff00ff00gleicher Layer|r" or "|cffff8020anderer Layer|r" end
        if #state > 0 then GameTooltip:AddLine(table.concat(state, " · "), 1, 1, 1) end
    elseif e.kind == "enemy" then
        local c = e.c
        GameTooltip:AddLine(ns.Spy.Colored(c) .. (c.guild and ("  |cffaaaaaa<" .. c.guild .. ">|r") or ""))
        GameTooltip:AddLine(string.format("Stufe %s · gesichtet %s%s", c.level and (c.level > 0 and c.level or "??") or "?",
            ns.Spy.Ago(time() - math.floor(e.age or 0)), e.by and (" von " .. e.by) or ""), .8, .8, .8)
    else
        GameTooltip:AddLine(e.title or "", 1, .2, .2)
        if e.text then GameTooltip:AddLine(e.text, 1, 1, 1, true) end
    end
    local where = Karte.Describe(e.map, e.x, e.y)
    if where then GameTooltip:AddLine(where, .6, .8, 1) end
    GameTooltip:Show()
end

local function NewPin(parent, level)
    local pin = CreateFrame("Frame", nil, parent)
    pin:SetSize(12, 12)
    pin:SetFrameLevel(level)
    pin.border = pin:CreateTexture(nil, "BORDER")
    pin.border:SetAllPoints()
    pin.border:SetTexture(WHITE)
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetPoint("TOPLEFT", 2, -2)
    pin.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pin.label:SetPoint("TOP", pin, "BOTTOM", 0, -1)
    pin:EnableMouse(true)
    pin:SetScript("OnEnter", Tooltip)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:SetScript("OnUpdate", function(self, elapsed)
        if not self.pulse then return end
        self.pt = (self.pt or 0) + elapsed
        self:SetAlpha(.55 + .45 * math.abs(math.sin(self.pt * 3)))
    end)
    return pin
end

local function Style(pin, e, mini)
    pin.e = e
    pin.pulse = e.kind == "help"
    pin:SetAlpha(1)
    pin.label:SetText("")
    if e.kind == "member" then
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.p.class] or { r = 1, g = 1, b = 1 }
        local size = mini and 9 or 14
        pin:SetSize(size, size)
        pin.border:Show()
        pin.border:SetVertexColor(e.p.combat and 1 or 0, 0, 0, 1)
        pin.icon:SetTexture(WHITE)
        pin.icon:SetVertexColor(c.r, c.g, c.b, 1)
        pin:SetAlpha(e.p.stealth and .6 or 1)
        if not mini then pin.label:SetText(e.name) end
    elseif e.kind == "enemy" then
        local hot = e.c.kos or (e.c.contract and not e.c.contract.done)
        local size = (hot and 16 or 12) * (mini and .85 or 1)
        pin:SetSize(size, size)
        pin.border:Hide()
        pin.icon:SetTexture(ICON_SKULL)
        pin.icon:SetVertexColor(1, hot and .3 or 1, hot and .3 or 1, 1)
        pin:SetAlpha(math.max(.35, 1 - (e.age or 0) / ENEMY_SECONDS))
        if hot and not mini then pin.label:SetText(e.c.name) end
    else
        local size = mini and 18 or 24
        pin:SetSize(size, size)
        pin.border:Hide()
        pin.icon:SetTexture(e.kind == "help" and ICON_CROSS or e.kind == "rally" and ICON_STAR or e.kind == "stealth" and ICON_DIAMOND or ICON_SKULL)
        pin.icon:SetVertexColor(1, 1, 1, 1)
        if not mini then pin.label:SetText(e.title) end
    end
end

-- Weltkarte -----------------------------------------------------------------

local mapPins = {}

local function Canvas()
    return WorldMapFrame and WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

-- Position auf der gerade angezeigten Karte (auch Kontinentkarte)
local function OnShownMap(map, x, y, shown)
    if map == shown then return x, y end
    if not (C_Map.GetMapPosFromWorldPos and CreateVector2D) then return end
    local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
    if not ok or not w then return end
    local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, w, shown)
    if not ok2 or not pos then return end
    local px, py = pos:GetXY()
    if px < 0 or px > 1 or py < 0 or py > 1 then return end
    return px, py
end

function Karte.RefreshWorldMap()
    local canvas = Canvas()
    if not canvas or not WorldMapFrame:IsShown() then return end
    local shown = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    local n = 0
    if S.huntMap and shown then
        local w, h = canvas:GetWidth(), canvas:GetHeight()
        -- Punkte behalten beim Zoomen ihre Größe auf dem Bildschirm
        local scale = 1 / (canvas:GetScale() or 1)
        for _, e in ipairs(Karte.Collect(false)) do
            local px, py = OnShownMap(e.map, e.x, e.y, shown)
            if px then
                n = n + 1
                local pin = mapPins[n]
                if not pin then
                    pin = NewPin(canvas, 2000)
                    -- Ausdrücklich über die Kartenbilder legen, die Ebene der Karte kann je nach Addons wechseln
                    pin:SetFrameStrata("FULLSCREEN_DIALOG")
                    pin:SetFrameLevel(2000)
                    mapPins[n] = pin
                end
                Style(pin, e, false)
                pin:SetScale(scale)
                pin:ClearAllPoints()
                pin:SetPoint("CENTER", canvas, "TOPLEFT", px * w / scale, -py * h / scale)
                pin:Show()
            end
        end
    end
    for i = n + 1, #mapPins do mapPins[i]:Hide() end
end

-- Prüfbefehl /assa kartentest (Weltkarte vorher öffnen): zeigt, wo die Punkte im Fensteraufbau liegen
function Karte.Debug()
    local canvas = Canvas()
    if not canvas or not WorldMapFrame:IsShown() then
        ns.Print("Kartentest: Bitte zuerst die Weltkarte öffnen.")
        return
    end
    Karte.RefreshWorldMap()
    ns.Print(string.format("Karte %s: Ebene %s/%d, Bild %s/%d, Skalierung %.2f, Größe %.0f×%.0f",
        tostring(WorldMapFrame:GetMapID()), WorldMapFrame:GetFrameStrata(), WorldMapFrame:GetFrameLevel(),
        canvas:GetFrameStrata(), canvas:GetFrameLevel(), canvas:GetEffectiveScale(), canvas:GetWidth(), canvas:GetHeight()))
    local shown = 0
    for _, pin in ipairs(mapPins) do
        if pin:IsShown() then
            shown = shown + 1
            local name = pin.e and (pin.e.name or (pin.e.c and pin.e.c.name) or pin.e.title) or "?"
            ns.Print(string.format("Punkt %s: Ebene %s/%d, sichtbar %s, Deckkraft %.2f, Größe %.1f, Bildgröße %.1f, Textur %s",
                tostring(name), pin:GetFrameStrata(), pin:GetFrameLevel(), tostring(pin:IsVisible()), pin:GetEffectiveAlpha(),
                pin:GetWidth() * pin:GetEffectiveScale(), pin.icon:GetWidth() * pin:GetEffectiveScale(), tostring(pin.icon:GetTexture())))
        end
    end
    if shown == 0 then ns.Print("Kartentest: Auf dieser Karte liegt gerade kein Punkt.") end
end

-- Minimap -------------------------------------------------------------------

local miniPins = {}

local function MinimapRadius()
    local zoom = Minimap:GetZoom() or 0
    local indoor = GetCVar and tonumber(GetCVar("minimapZoom")) ~= zoom and tonumber(GetCVar("minimapInsideZoom")) == zoom
    return ((indoor and MINI_INDOOR or MINI_OUTDOOR)[zoom] or 300) / 2
end

function Karte.RefreshMinimap()
    local n = 0
    if S.huntMap and me.map and Minimap and Minimap.GetZoom then
        local radius = MinimapRadius()
        local px = (Minimap:GetWidth() or 140) / 2
        local rotate = GetCVar and GetCVar("rotateMinimap") == "1"
        local facing = rotate and GetPlayerFacing and GetPlayerFacing() or 0
        local cf, sf = math.cos(facing), math.sin(facing)
        for _, e in ipairs(Karte.Collect(true)) do
            local d, dx, dy = Karte.Offset(e.map, e.x, e.y)
            if d and d > 3 then
                if rotate then dx, dy = dx * cf + dy * sf, -dx * sf + dy * cf end
                local inside = d <= radius * .95
                if inside or e.kind == "help" or e.kind == "target" or e.kind == "rally" then
                    if not inside then dx, dy = dx / d * radius * .95, dy / d * radius * .95 end
                    n = n + 1
                    local pin = miniPins[n] or NewPin(Minimap, (Minimap:GetFrameLevel() or 1) + 5)
                    miniPins[n] = pin
                    Style(pin, e, true)
                    pin:ClearAllPoints()
                    pin:SetPoint("CENTER", Minimap, "CENTER", dx / radius * px, dy / radius * px)
                    pin:Show()
                end
            end
        end
    end
    for i = n + 1, #miniPins do miniPins[i]:Hide() end
end

---------------------------------------------------------------------------

function Karte.Update()
    local map, x, y = Karte.MapPos("player")
    me.map, me.x, me.y = map, x, y
    Karte.RefreshMinimap()
end

function Karte.Init()
    S = ns.settings
    local f = CreateFrame("Frame")
    local acc, mapAcc = 0, 0
    f:SetScript("OnUpdate", function(_, elapsed)
        acc, mapAcc = acc + elapsed, mapAcc + elapsed
        if acc >= .25 then
            acc = 0
            Karte.Update()
        end
        if mapAcc >= 1 or (Karte.dirty and mapAcc >= .2) then
            mapAcc, Karte.dirty = 0, false
            Karte.RefreshWorldMap()
        end
    end)
    if WorldMapFrame and WorldMapFrame.HookScript then
        WorldMapFrame:HookScript("OnShow", Karte.RefreshWorldMap)
    end
    Karte.Update()
end
