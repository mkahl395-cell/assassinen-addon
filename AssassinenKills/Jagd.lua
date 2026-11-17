-- Assassinen Jagd – Werkzeuge, um als Rudel zusammenzufinden und gemeinsam zuzuschlagen:
-- Pfeil (zeigt zum Hilferuf, Sammelpunkt, angesagten Ziel oder einem Mitglied),
-- Sammelpunkt, Opener-Countdown und Wachposten.
-- Nachrichten laufen über die Rudel-Warteschlange (Präfix "ASSAR").

local ADDON_NAME, ns = ...
local Jagd = {}
ns.Jagd = Jagd

local S, UI, Karte, Rudel
local playerName
local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local RANGE = 2500          -- Yards: Meldungen aus dieser Nähe gibt es groß auf dem Bildschirm
local ARRIVE = 15           -- Yards: angekommen
local RALLY_TTL = 600
local WATCH_LEAVE = 100     -- Yards: wer sich so weit vom Posten entfernt, beendet die Wache

BINDING_NAME_ASSASSINEN_LOS = "Opener-Countdown starten"
BINDING_NAME_ASSASSINEN_SAMMELN = "Sammelpunkt hier setzen"
BINDING_NAME_ASSASSINEN_WACHE = "Wachposten an/aus"
BINDING_NAME_ASSASSINEN_PFEIL = "Pfeil ausblenden"

local function Print(text) ns.Print(text) end

-- "140 m"
local function Meters(d)
    local m = d * 0.9144
    if m < 1000 then return string.format("%d m", math.floor(m / 10 + 0.5) * 10) end
    return string.format("%.1f km", m / 1000)
end

-- Liegt ein Punkt in meiner Nähe? (gleiche Zone zählt, wenn die Entfernung unbekannt ist)
local function Near(map, x, y, zone)
    local d = map and Karte.Offset(map, x, y)
    if d then return d <= RANGE, d end
    return zone ~= nil and zone == GetRealZoneText(), nil
end

---------------------------------------------------------------------------
-- Pfeil
---------------------------------------------------------------------------

-- Wichtigeres verdrängt Unwichtigeres, nie umgekehrt
local KINDS = {
    help = { prio = 4, r = 1, g = .2, b = .2 },
    rally = { prio = 3, r = 1, g = .82, b = .1 },
    target = { prio = 2, r = 1, g = .45, b = .1 },
    member = { prio = 2, r = .55, g = .8, b = 1 },
    watch = { prio = 1, r = .95, g = .3, b = .3 },
}
local arrow
local way -- { kind, id, map, x, y, title, t, ttl, follow, arrived }

local function Expired(w)
    return not w or GetTime() - w.t > w.ttl
end

function Jagd.Point(kind, id, map, x, y, title, ttl, follow)
    if not S.arrow or not map or not arrow then return end
    local k = KINDS[kind] or KINDS.member
    if not Expired(way) and way.kind ~= kind and (KINDS[way.kind] or k).prio > k.prio then return end
    way = { kind = kind, id = id, map = map, x = x, y = y, title = title, t = GetTime(), ttl = ttl or 120, follow = follow }
    arrow.title:SetText(title or "")
    arrow.title:SetTextColor(k.r, k.g, k.b)
    arrow.tex:SetVertexColor(1, 1, 1)
    arrow:Show()
    Jagd.UpdateArrow()
end

-- Ohne Angaben: jeden Pfeil ausblenden; sonst nur, wenn Art (und Kennung) passen
function Jagd.Clear(kind, id)
    if not way then return end
    if kind and (way.kind ~= kind or (id and way.id ~= id)) then return end
    way = nil
    if arrow then arrow:Hide() end
end

function Jagd.Current() return way end

function Jagd.UpdateArrow()
    if not arrow or not arrow:IsShown() then return end
    if Expired(way) then Jagd.Clear() return end
    -- Einem Mitglied folgen: dessen neueste Position aus dem Rudel nehmen
    if way.follow and Rudel.pack[way.follow] then
        local p = Rudel.pack[way.follow]
        if p.map and p.t >= way.t - 1 then way.map, way.x, way.y = p.map, p.x, p.y end
    end
    local d, dx, dy = Karte.Offset(way.map, way.x, way.y)
    if not d then
        arrow.tex:Hide()
        arrow.dist:SetText("|cff8f8a8aandere Zone|r")
        return
    end
    if d <= ARRIVE then
        arrow.tex:Hide()
        arrow.dist:SetText("|cff00ff00Angekommen|r")
        if way.kind ~= "help" then
            way.arrived = way.arrived or GetTime()
            if GetTime() - way.arrived > 6 then Jagd.Clear() end
        end
        return
    end
    way.arrived = nil
    local facing = GetPlayerFacing and ns.Safe(GetPlayerFacing())
    if facing then
        arrow.tex:Show()
        -- Peilung gegen den Uhrzeigersinn ab Norden, wie die Blickrichtung des Spiels
        arrow.tex:SetRotation(atan2(-dx, dy) - facing)
        arrow.dist:SetText(Meters(d))
    else
        -- Ohne Blickrichtung (z. B. in Instanzen) nur Himmelsrichtung
        arrow.tex:Hide()
        arrow.dist:SetText(Meters(d) .. " " .. Karte.Direction(dx, dy))
    end
end

local function BuildArrow()
    local f = CreateFrame("Frame", "AssassinenPfeil", UIParent)
    arrow = f
    f:SetSize(110, 92)
    f:SetFrameStrata("HIGH")
    UI.MakeMovable(f, "arrowPos")
    UI.RestorePos(f, "arrowPos", "CENTER", UIParent, "CENTER", 0, 190)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", 0, 0)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetSize(56, 56)
    f.tex:SetPoint("CENTER", 0, 2)
    f.tex:SetTexture(MEDIA .. "arrow")
    f.dist = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.dist:SetPoint("BOTTOM", 0, 0)
    f:SetScript("OnMouseUp", function(_, button) if button == "RightButton" then Jagd.Clear() end end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(way and way.title or "Pfeil")
        local where = way and Karte.Describe(way.map, way.x, way.y)
        if where then GameTooltip:AddLine(where, .6, .8, 1) end
        GameTooltip:AddLine("Ziehen: verschieben · Rechtsklick: ausblenden", .5, .5, .5)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local acc = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc >= .05 then acc = 0 Jagd.UpdateArrow() end
    end)
    f:Hide()
end

-- Pfeil auf ein Rudelmitglied (/assa pfeil Name)
local function PointMember(query)
    query = query:lower()
    for name, p in pairs(Rudel.pack) do
        if name:lower() == query or name:lower():find(query, 1, true) == 1 then
            Jagd.Point("member", name, p.map, p.x, p.y, name, 600, name)
            Print(string.format("Pfeil zeigt auf %s.", name))
            return
        end
    end
    Print("Kein Rudelmitglied mit Position gefunden: " .. query .. " (nur Mitglieder mit Addon in der Nähe).")
end

---------------------------------------------------------------------------
-- Sammelpunkt
---------------------------------------------------------------------------

local function ShowRally(sender, map, x, y, note)
    local title = "Sammeln" .. ((note and note ~= "") and (": " .. note) or "")
    Karte.Mark("rally", "rally", map, x, y, RALLY_TTL, title, "Gesetzt von " .. sender)
    local where = Karte.Describe(map, x, y)
    if sender ~= playerName then
        Jagd.Point("rally", sender, map, x, y, title, RALLY_TTL)
        UI.Alert(string.format("SAMMELN – %s%s", sender, where and (": " .. where) or ""), true)
        Rudel.Sound("rally")
    end
    Print(string.format("|cffffd100Sammelpunkt|r von %s%s%s", sender, (note and note ~= "") and (" – " .. note) or "",
        where and (" · " .. where) or ""))
end

local myRally -- Zeitpunkt des eigenen Sammelpunkts
function Jagd.MyRally() return myRally ~= nil and GetTime() - myRally < RALLY_TTL end

function Jagd.Rally(map, x, y, note)
    if not map then Print("Deine Position ist gerade unbekannt.") return end
    local channel = Rudel.GroupChannel() or (IsInGuild() and "GUILD")
    if not channel then Print("Weder Gruppe noch Gilde – niemand sieht den Sammelpunkt.") return end
    local m, px, py = Karte.Pack(map, x, y)
    Rudel.Send(channel, { urgent = true, key = "SP" }, "SP", m, px, py, note or "")
    ShowRally(playerName, map, x, y, note)
    myRally = GetTime()
    Print(channel == "GUILD" and "Sammelpunkt an die Gilde in der Nähe gesendet." or "Sammelpunkt an die Gruppe gesendet.")
end

function Jagd.EndRally()
    local channel = Rudel.GroupChannel() or (IsInGuild() and "GUILD")
    if channel then Rudel.Send(channel, { urgent = true, key = "SP" }, "SPE") end
    Karte.Unmark("rally")
    Jagd.Clear("rally")
    myRally = nil
    Print("Sammelpunkt aufgehoben.")
end

local function OnRally(f, sender, channel)
    local map, x, y = Karte.Unpack(f[2], f[3], f[4])
    if not map then return end
    if channel == "GUILD" then
        -- Aus der Gilde nur von Anführern oder aus der Nähe, damit nicht jeder alle herumschickt
        local rank = Rudel.RankOf and Rudel.RankOf(sender)
        if not (rank and rank <= 1) and not Near(map, x, y) then return end
    end
    ShowRally(sender, map, x, y, f[5])
end

-- Alt+Klick auf die Weltkarte setzt den Sammelpunkt dort
local function HookWorldMap()
    if not WorldMapFrame then return end
    local function Clicked(button, cx, cy)
        if button ~= "LeftButton" or not (IsAltKeyDown and IsAltKeyDown()) then return false end
        local map = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
        if not cx and WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.GetNormalizedCursorPosition then
            cx, cy = WorldMapFrame.ScrollContainer:GetNormalizedCursorPosition()
        end
        if not map or not cx or cx < 0 or cx > 1 or cy < 0 or cy > 1 then return false end
        Jagd.Rally(map, cx, cy, nil)
        return true
    end
    if WorldMapFrame.AddCanvasClickHandler then
        pcall(WorldMapFrame.AddCanvasClickHandler, WorldMapFrame, function(_, button, cx, cy) return Clicked(button, cx, cy) end, 100)
    elseif WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.HookScript then
        WorldMapFrame.ScrollContainer:HookScript("OnMouseUp", function(_, button) Clicked(button) end)
    end
end

---------------------------------------------------------------------------
-- Opener-Countdown
---------------------------------------------------------------------------

local cd -- Anzeige

local function BuildCountdown()
    local f = CreateFrame("Frame", "AssassinenCountdown", UIParent)
    cd = f
    f:SetSize(400, 160)
    f:SetPoint("CENTER", 0, 120)
    f:SetFrameStrata("HIGH")
    f.by = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.by:SetPoint("TOP", 0, 0)
    f.num = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    f.num:SetPoint("CENTER", 0, 4)
    pcall(f.num.SetFont, f.num, STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 72, "THICKOUTLINE")
    f.role = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.role:SetPoint("BOTTOM", 0, 0)
    f:SetScript("OnUpdate", function(self)
        local left = self.secs - (GetTime() - self.start)
        if left > 0 then
            local n = math.ceil(left)
            if n ~= self.lastNum then
                self.lastNum = n
                self.num:SetText(tostring(n))
                self.num:SetTextColor(1, .85, .85)
                Rudel.Sound("tick")
            end
        elseif left > -1.5 then
            if self.lastNum ~= 0 then
                self.lastNum = 0
                self.num:SetText("LOS!")
                self.num:SetTextColor(1, .15, .15)
                Rudel.Sound("go")
            end
        else
            self:Hide()
        end
    end)
    f:Hide()
end

local function RunCountdown(secs, by)
    cd.secs, cd.start, cd.lastNum = secs, GetTime(), nil
    cd.by:SetText(by == playerName and "Opener" or ("Opener von " .. by))
    local role = Rudel.myRole and GetTime() - Rudel.myRole.t < 600 and Rudel.myRole.text
    cd.role:SetText(role and ("|cffffd100" .. role .. "|r") or "")
    cd:Show()
end

function Jagd.Countdown(arg)
    local secs = math.max(2, math.min(10, math.floor(tonumber(arg) or 3)))
    local channel = Rudel.GroupChannel()
    if channel then
        Rudel.Send(channel, { urgent = true, key = "CD" }, "CD", secs)
    else
        Print("Du bist in keiner Gruppe – den Countdown siehst nur du.")
    end
    RunCountdown(secs, playerName)
end

---------------------------------------------------------------------------
-- Wachposten
---------------------------------------------------------------------------

local watch -- { map, x, y, place, t, n }

local function Place()
    local zone, sub = GetRealZoneText() or "?", GetSubZoneText() or ""
    return (sub ~= "" and sub ~= zone) and (sub .. ", " .. zone) or zone
end

function Jagd.Watching() return watch ~= nil end

local function EndWatch(reason)
    if not watch then return end
    local n = watch.n
    watch = nil
    if IsInGuild() then Rudel.Send("GUILD", { urgent = true }, "W-", reason or "") end
    Print(string.format("Wachposten %s. %d Feind%s gemeldet.", reason or "beendet", n, n == 1 and "" or "e"))
    if ns.Spy then ns.Spy.dirty = true end
end

function Jagd.ToggleWatch()
    if watch then EndWatch("beendet") return end
    if not IsInGuild() then Print("Ein Wachposten meldet an die Gilde – du bist in keiner.") return end
    local me = Karte.me
    if not me.map then Print("Deine Position ist gerade unbekannt.") return end
    watch = { map = me.map, x = me.x, y = me.y, place = Place(), t = GetTime(), n = 0 }
    local m, x, y = Karte.Pack(me.map, me.x, me.y)
    Rudel.Send("GUILD", { urgent = true }, "W+", watch.place, m, x, y)
    UI.Alert("WACHPOSTEN bezogen – jeder Feind geht sofort an die Gilde", false)
    Print(string.format("|cffff4040Wachposten|r bei %s. Jeder Feind, den du siehst, geht sofort an die Gilde in der Nähe. " ..
        "Beenden: /assa wache oder mehr als 90 m weggehen.", watch.place))
    if ns.Spy then ns.Spy.dirty = true end
end

-- Aus dem Späher: neuer Feind in Sicht
function Jagd.OnSighting(key, c, important)
    if not watch then return end
    watch.n = watch.n + 1
    local m, x, y = Karte.Pack(c.map or watch.map, c.x or watch.x, c.y or watch.y)
    Rudel.Send("GUILD", { urgent = important }, "W", c.name, c.realm or "", c.class or "", c.level or "", c.guild or "",
        c.kos and 1 or 0, (c.contract and not c.contract.done) and 1 or 0, m, x, y, watch.place)
end

local function OnWatchReport(f, sender)
    local name = f[2]
    if not name or name == "" or not ns.Spy then return end
    local Spy = ns.Spy
    local c = Spy.ContactFor(name, f[3] ~= "" and f[3] or nil)
    c.class = f[4] ~= "" and f[4] or c.class
    local lv = tonumber(f[5]); if lv and lv ~= 0 then c.level = lv end
    c.guild = f[6] ~= "" and f[6] or c.guild
    local map, x, y = Karte.Unpack(f[9], f[10], f[11])
    c.reported, c.reportBy, c.reportZone = time(), sender, f[12]
    c.reportMap, c.reportX, c.reportY = map, x, y
    Spy.dirty = true
    Karte.dirty = true
    local hot = f[7] == "1" or f[8] == "1" or (Rudel.IsFeud and Rudel.IsFeud(c.guild))
    local near = Near(map, x, y)
    if not near and not hot then return end
    local lvl = c.level and (c.level > 0 and c.level or "??") or "?"
    local mark = f[8] == "1" and "AUFTRAG " or f[7] == "1" and "KOS " or ""
    local where = map and Karte.Describe(map, x, y)
    Print(string.format("|cffff4040Wache %s|r: %s%s (Stufe %s)%s bei %s%s", sender, mark, Spy.Colored(c), lvl,
        c.guild and (" <" .. c.guild .. ">") or "", f[12] ~= "" and f[12] or "?", where and (" · " .. where) or ""))
    if near then
        UI.Alert(string.format("WACHE %s: %s%s (%s)%s", sender, mark, Spy.Colored(c), lvl, where and (" – " .. where) or ""), hot)
        Rudel.Sound(hot and "kos" or "watch")
        if hot then Jagd.Point("watch", name, map, x, y, mark .. name, 60) end
    end
end

---------------------------------------------------------------------------
-- Befehle, Tasten, Start
---------------------------------------------------------------------------

function Jagd.Slash(cmd, raw, arg)
    if cmd == "pfeil" then
        if arg == "an" or arg == "aus" then
            Print("Pfeil zu Hilferuf, Sammelpunkt und Ziel: " .. ns.OnOff(ns.Toggle("arrow", arg)))
            if not S.arrow then Jagd.Clear() end
        elseif raw ~= "" then
            PointMember(raw)
        else
            Jagd.Clear()
        end
    elseif cmd == "sammeln" then
        if arg == "aus" or arg == "ende" then Jagd.EndRally()
        else Jagd.Rally(Karte.me.map, Karte.me.x, Karte.me.y, raw) end
    elseif cmd == "los" or cmd == "countdown" then
        Jagd.Countdown(arg)
    elseif cmd == "wache" then
        Jagd.ToggleWatch()
    else
        return false
    end
    return true
end

function Jagd.Binding(what)
    if what == "los" then Jagd.Countdown()
    elseif what == "sammeln" then Jagd.Rally(Karte.me.map, Karte.me.x, Karte.me.y, nil)
    elseif what == "wache" then Jagd.ToggleWatch()
    elseif what == "pfeil" then Jagd.Clear()
    else return false end
    return true
end

function Jagd.Tick()
    if watch then
        local d = Karte.Offset(watch.map, watch.x, watch.y)
        if d and d > WATCH_LEAVE then EndWatch("verlassen") end
    end
end

function Jagd.Init()
    S, UI, Karte, Rudel = ns.settings, ns.UI, ns.Karte, ns.Rudel
    playerName = ns.PlayerName()
    ns.WatchSelfName(function(n) playerName = n end)
    BuildArrow()
    BuildCountdown()
    Rudel.On("SP", OnRally)
    Rudel.On("SPE", function(_, sender)
        if Karte.Unmark then Karte.Unmark("rally") end
        local w = Jagd.Current()
        if w and w.kind == "rally" and w.id == sender then Jagd.Clear("rally") end
    end)
    Rudel.On("CD", function(f, sender, channel)
        if channel ~= "PARTY" and channel ~= "RAID" then return end
        RunCountdown(math.max(2, math.min(10, tonumber(f[2]) or 3)), sender)
    end)
    Rudel.On("W", OnWatchReport)
    Rudel.On("W+", function(f, sender)
        local map, x, y = Karte.Unpack(f[3], f[4], f[5])
        if Near(map, x, y, f[2]) then Print(string.format("%s hält Wache bei %s.", sender, f[2] ~= "" and f[2] or "?")) end
    end)
    Rudel.On("W-", function() end)
    HookWorldMap()
    C_Timer.NewTicker(1, Jagd.Tick)
end
