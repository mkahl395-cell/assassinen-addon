-- Assassinen Alarm – "Du bist im Ziel" und Tarnungs-Alarm.
-- Ohne Kampflog bleiben nur die Namensplaketten: Wir schauen alle Viertelsekunde nach, wer dich im Ziel hat,
-- und merken uns, welcher feindliche Schurke oder Druide gerade nah war. Verschwindet dessen Plakette,
-- ohne dass er tot ist, zählt das nur bei sichtbarem Tarnzauber oder wenn er nah und mitten im Bild verschwand
-- (am Bildrand ist er nur aus dem Blick geraten, z. B. beim Vorbeireiten).

local ADDON_NAME, ns = ...
local Alarm = {}
ns.Alarm = Alarm

local SCAN_SECONDS = 0.25
local AIM_HOLD = 1.0          -- so lange gilt "hat dich im Ziel" nach der letzten Beobachtung
local AIM_REALERT = 12        -- frühestens dann für denselben Feind erneut Ton und Rand
local STEALTH_MARK = 20       -- Sekunden: Punkt auf der Karte
local STEALTH_REALERT = 8
local STEALTHERS = { ROGUE = true, DRUID = true }
-- Plaketten verschwinden auch, wenn der Feind nur aus dem Bild gerät (vorbeireiten, Kamera drehen).
-- Das passiert immer am Bildrand. Ohne sichtbaren Tarnzauber zählt darum nur ein Verschwinden mitten im Bild.
local EDGE = 0.15             -- Anteil des Bildschirms je Rand, der als "aus dem Bild gelaufen" gilt
local CAST_HOLD = 3           -- so lange gilt ein gesehener Tarnzauber als Beweis
-- Verstohlenheit (alle Ränge), Verschwinden, Schleichen (Druide), Schattenmimik
local STEALTH_SPELLS = { [1784] = true, [1785] = true, [1786] = true, [1787] = true, [1856] = true, [1857] = true,
    [11327] = true, [11329] = true, [26888] = true, [26889] = true, [5215] = true, [6783] = true, [9913] = true, [20580] = true }
local stealthNames

local S, UI, Spy, Karte, Rudel
local frame
local aiming = {}             -- key -> { c, first, last, alerted }
local plates = {}             -- nameplateN -> { key, c, near, dead, t }
local stealthAlerted = {}     -- key -> GetTime()
local aimAlerted = {}         -- key -> GetTime()
local casts = {}               -- key -> GetTime() des zuletzt gesehenen Tarnzaubers
local removals = {}           -- Zeitpunkte verschwundener Plaketten (Ladebildschirm, Reittier: alle auf einmal)
local playerName

local function Print(msg) ns.Print(msg) end
local function Safe(v) return ns.Safe(v) end
local function Locked() return InCombatLockdown and InCombatLockdown() end

local function ClassName(token)
    return token and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token] or token) or "?"
end

local function Level(c)
    return c.level and (c.level > 0 and tostring(c.level) or "??") or "?"
end

local function Sound(kind)
    ns.Sound(kind, true)
end

-- Feindlicher Spieler hinter einem Unit-Token: Akte und Schlüssel, sonst nil
local function Enemy(unit)
    if not Safe(UnitExists(unit)) or not Safe(UnitIsPlayer(unit)) or Safe(UnitIsUnit(unit, "player")) then return end
    if not (Safe(UnitIsEnemy("player", unit)) or Safe(UnitCanAttack("player", unit))) then return end
    local name, realm = UnitName(unit)
    name, realm = Safe(name), Safe(realm)
    if not name or name == "" or name == UNKNOWNOBJECT then return end
    local c, key = Spy.ContactFor(name, realm ~= "" and realm or nil)
    local _, class = UnitClass(unit)
    c.class = Safe(class) or c.class
    local lv = Safe(UnitLevel(unit))
    if lv and lv ~= 0 then c.level = lv end
    return c, key
end

-- Ist der Feind so nah, dass ein Verschwinden kein Weglaufen aus der Plakettenreichweite sein kann?
-- Außerhalb des Kampfes misst das Spiel die Entfernung (11 Yards, bei großer Plakettenreichweite 28).
-- Im Kampf ist die Messung gesperrt: dann zählt, ob er mit dir zu tun hat (dich oder du ihn im Ziel).
local function IsNear(unit)
    if not Locked() and CheckInteractDistance then
        local range = Spy.PlateRange and Spy.PlateRange()
        local ok, near = pcall(CheckInteractDistance, unit, (range and range >= 38) and 4 or 2)
        if ok and near ~= nil then return Safe(near) and true or false end
    end
    return (Safe(UnitIsUnit(unit .. "target", "player")) or Safe(UnitIsUnit(unit, "target"))) and true or false
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return Safe(C_Spell.GetSpellName(id)) end
    if GetSpellInfo then return Safe((GetSpellInfo(id))) end
end

-- Tarnzauber an Nummer oder (für unbekannte Ränge) am Namen erkennen
local function IsStealthSpell(id, name)
    if type(id) == "number" and STEALTH_SPELLS[id] then return true end
    if type(name) ~= "string" or name == "" then return false end
    if not stealthNames then
        stealthNames = {}
        for sid in pairs(STEALTH_SPELLS) do
            local ok, n = pcall(SpellName, sid)
            if ok and type(n) == "string" and n ~= "" then stealthNames[n] = true end
        end
    end
    return stealthNames[name] or false
end

-- Trägt die Einheit gerade eine Tarnung? (Beim Entfernen der Plakette ist das Token noch gültig)
local function HasStealthAura(unit)
    for i = 1, 40 do
        local name, id
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local a = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
            if type(a) ~= "table" then return false end
            name, id = Safe(a.name), Safe(a.spellId)
        elseif UnitBuff then
            local n, _, _, _, _, _, _, _, _, sid = UnitBuff(unit, i)
            name, id = Safe(n), Safe(sid)
            if not name then return false end
        else
            return false
        end
        if IsStealthSpell(id, name) then return true end
    end
    return false
end

-- Wo im Bild steht die Plakette? 0..1 von links und von unten, nil wenn unbekannt
local function PlateSpot(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
    local p = C_NamePlate.GetNamePlateForUnit(unit)
    if type(p) ~= "table" or not p.GetCenter then return end
    local x, y = p:GetCenter()
    x, y = Safe(x), Safe(y)
    if type(x) ~= "number" or type(y) ~= "number" then return end
    local s = p.GetEffectiveScale and Safe(p:GetEffectiveScale()) or 1
    local W = WorldFrame or UIParent
    if not W then return end
    local ws = W.GetEffectiveScale and Safe(W:GetEffectiveScale()) or 1
    local w, h = Safe(W:GetWidth()), Safe(W:GetHeight())
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return end
    if type(s) ~= "number" then s = 1 end
    if type(ws) ~= "number" then ws = 1 end
    return x * s / (w * ws), y * s / (h * ws)
end

local function MidScreen(fx, fy)
    return fx and fy and fx > EDGE and fx < 1 - EDGE and fy > EDGE and fy < 1 - EDGE or false
end

---------------------------------------------------------------------------
-- Anzeige "Im Ziel von"
---------------------------------------------------------------------------

local function Build()
    local f = CreateFrame("Frame", "AssassinenImZiel", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame = f
    UI.Skin(f, .9)
    if f.SetBackdropBorderColor then f:SetBackdropBorderColor(.9, .1, .12) end
    f:SetSize(240, 30)
    f:SetFrameStrata("HIGH")
    UI.MakeMovable(f, "aimPos")
    UI.RestorePos(f, "aimPos", "CENTER", UIParent, "CENTER", 0, 250)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", 0, -6)
    f.title:SetText("|cffff2020DU BIST IM ZIEL|r")
    f.list = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.list:SetPoint("TOP", f.title, "BOTTOM", 0, -3)
    f.list:SetJustifyH("CENTER")
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Diese Feinde haben dich gerade im Ziel", 1, .25, .25)
        GameTooltip:AddLine("Ziehen verschiebt die Anzeige. Abschalten: /assa imziel aus", .7, .7, .7, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:Hide()
end

local function Redraw()
    if not frame then return end
    local now, lines = GetTime(), {}
    for key, a in pairs(aiming) do
        if now - a.last > AIM_HOLD then
            aiming[key] = nil
        else
            local c = a.c
            lines[#lines + 1] = { score = Spy.Threat(key, c),
                text = string.format("%s%s  |cffaaaaaa%s %s|r", (c.kos and "|cffff2020KOS|r " or ""), Spy.Colored(c), ClassName(c.class), Level(c)) }
        end
    end
    if #lines == 0 then frame:Hide() return end
    table.sort(lines, function(a, b) return a.score > b.score end)
    local out = {}
    for i, l in ipairs(lines) do if i <= 5 then out[#out + 1] = l.text end end
    frame.list:SetText(table.concat(out, "\n"))
    frame:SetHeight(28 + #out * 14)
    frame:Show()
end

-- Neues Anvisieren: Ton und roter Rand (je Feind höchstens alle paar Sekunden), die Anzeige bleibt stehen
local function Aimed(c, key)
    local now = GetTime()
    local a = aiming[key]
    if not a then
        a = { c = c, first = now }
        aiming[key] = a
        if not aimAlerted[key] or now - aimAlerted[key] > AIM_REALERT then
            aimAlerted[key] = now
            UI.Alert(string.format("IM ZIEL: %s (%s %s) hat dich anvisiert!", Spy.Colored(c), ClassName(c.class), Level(c)), true)
            Sound("aim")
        end
    end
    a.last = now
end

---------------------------------------------------------------------------
-- Tarnungs-Alarm
---------------------------------------------------------------------------

function Alarm.ShowStealth(c, by, map, x, y, sure)
    local key = c.name .. "-" .. (c.realm or "")
    local now = GetTime()
    if stealthAlerted[key] and now - stealthAlerted[key] < STEALTH_REALERT then return end
    stealthAlerted[key] = now
    local who = string.format("%s (%s %s)", Spy.Colored(c), ClassName(c.class), Level(c))
    if by then
        UI.Alert(string.format("GETARNT bei %s: %s", by, who), false)
        Print(string.format("|cffb040ffGetarnt|r: %s ist bei %s verschwunden – vermutlich in der Tarnung.", who, by))
    else
        UI.Alert(string.format("GETARNT: %s ist neben dir verschwunden!", who), true)
        Print(string.format("|cffb040ffGetarnt|r: %s ist direkt neben dir %s", who,
            sure and "in die Tarnung gegangen." or "mitten im Bild verschwunden – vermutlich Verstohlenheit oder Verschwinden."))
    end
    Sound("stealth")
    if map and Karte and Karte.Mark then
        Karte.Mark("stealth:" .. c.name, "stealth", map, x, y, STEALTH_MARK, "Getarnt: " .. c.name,
            by and ("Gemeldet von " .. by) or "Hier zuletzt gesehen")
    end
end

local function CheckVanish(info, removedAt)
    if not S.stealthAlarm or not info or not info.c then return end
    local c = info.c
    if not STEALTHERS[c.class] or info.dead then return end
    if GetTime() - info.t > 1.5 then return end
    -- Beweis: Tarnzauber gesehen oder Tarnung auf der Einheit. Sonst nur, wenn er nah war und mitten im Bild verschwand.
    local sure = info.aura or (casts[info.key] and GetTime() - casts[info.key] < CAST_HOLD) or false
    if not sure and not (info.near and MidScreen(info.fx, info.fy)) then return end
    if UnitIsDeadOrGhost and Safe(UnitIsDeadOrGhost("player")) then return end
    C_Timer.After(0.6, function()
        local now = GetTime()
        local burst = 0 -- viele Plaketten auf einmal weg: Ladebildschirm o. Ä., kein Tarnen
        for _, t in ipairs(removals) do if math.abs(t - removedAt) < 0.3 then burst = burst + 1 end end
        if burst >= 3 then return end
        for _, p in pairs(plates) do if p.key == info.key then return end end -- wieder sichtbar
        if c.lastWin and time() - c.lastWin < 5 then return end            -- gerade getötet
        if ns.char and ns.char.kills then
            local k = ns.char.kills[#ns.char.kills]
            if k and k.victim == c.name and time() - (k.t or 0) < 5 then return end
        end
        local me = Karte and Karte.me or {}
        Alarm.ShowStealth(c, nil, me.map, me.x, me.y, sure)
        -- Gruppe (sonst Gilde in der Nähe) mitwarnen
        local channel = Rudel.GroupChannel() or (IsInGuild() and "GUILD")
        if channel and me.map then
            local m, px, py = Karte.Pack(me.map, me.x, me.y)
            Rudel.Send(channel, { urgent = true }, "TA", c.name, c.realm or "", c.class or "", c.level or "", m, px, py)
        end
    end)
end

local function OnStealthReport(f, sender)
    if not S.stealthAlarm or sender == playerName then return end
    local map, x, y = Karte.Unpack(f[6], f[7], f[8])
    local d = map and Karte.Offset(map, x, y)
    if not d or d > 300 then return end -- nur wer in der Nähe ist, muss es wissen
    local c = Spy.ContactFor(f[2], f[3] ~= "" and f[3] or nil)
    c.class = f[4] ~= "" and f[4] or c.class
    local lv = tonumber(f[5]); if lv and lv ~= 0 then c.level = lv end
    Alarm.ShowStealth(c, sender, map, x, y)
end

---------------------------------------------------------------------------
-- Abtasten
---------------------------------------------------------------------------

function Alarm.Scan()
    if not S.spy then return end
    local now = GetTime()
    local seen = {}
    for i = 1, 40 do
        local unit = "nameplate" .. i
        local c, key = Enemy(unit)
        if c then
            local dead = UnitIsDeadOrGhost and Safe(UnitIsDeadOrGhost(unit)) or false
            local ok, fx, fy = pcall(PlateSpot, unit)
            plates[unit] = { key = key, c = c, near = IsNear(unit), dead = dead, t = now, fx = ok and fx or nil, fy = ok and fy or nil }
            if S.aimAlarm and not dead and Safe(UnitIsUnit(unit .. "target", "player")) then
                Aimed(c, key)
                seen[key] = true
            end
        else
            plates[unit] = nil
        end
    end
    if S.aimAlarm then
        for _, unit in ipairs({ "target", "mouseover", "focus" }) do
            local c, key = Enemy(unit)
            if c and not seen[key] and Safe(UnitIsUnit(unit .. "target", "player")) then Aimed(c, key) end
        end
    end
    Redraw()
end

function Alarm.Aiming()
    local n = 0
    for _ in pairs(aiming) do n = n + 1 end
    return n
end

function Alarm.Slash(cmd, raw, arg)
    if cmd == "imziel" then
        Print("Warnung »Du bist im Ziel«: " .. ns.OnOff(ns.Toggle("aimAlarm", arg)))
        if not S.aimAlarm then for k in pairs(aiming) do aiming[k] = nil end Redraw() end
    elseif cmd == "tarnalarm" then
        Print("Tarnungs-Alarm (feindlicher Schurke/Druide verschwindet neben dir): " .. ns.OnOff(ns.Toggle("stealthAlarm", arg)))
    else
        return false
    end
    return true
end

function Alarm.Init()
    S, UI, Spy, Karte, Rudel = ns.settings, ns.UI, ns.Spy, ns.Karte, ns.Rudel
    playerName = ns.PlayerName()
    ns.WatchSelfName(function(n) playerName = n end)
    Build()
    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "NAME_PLATE_UNIT_REMOVED", "UNIT_TARGET", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_AURA" }) do pcall(ev.RegisterEvent, ev, e) end
    ev:SetScript("OnEvent", function(_, event, unit, _, spellID)
        if event == "NAME_PLATE_UNIT_REMOVED" then
            local info = plates[unit]
            plates[unit] = nil
            local now = GetTime()
            removals[#removals + 1] = now
            while removals[1] and now - removals[1] > 2 do table.remove(removals, 1) end
            -- Gestorben statt getarnt? Das Token gilt beim Entfernen noch
            if info and UnitIsDeadOrGhost and Safe(UnitIsDeadOrGhost(unit)) then info.dead = true end
            if info then
                -- letzte Lage der Plakette (die Viertelsekunde davor kann schon veraltet sein) und Tarnung prüfen
                local ok, fx, fy = pcall(PlateSpot, unit)
                if ok and fx then info.fx, info.fy = fx, fy end
                local ok2, aura = pcall(HasStealthAura, unit)
                if ok2 and aura then info.aura = true end
            end
            pcall(CheckVanish, info, now)
        elseif event == "UNIT_TARGET" and unit and unit:find("^nameplate") then
            pcall(Alarm.Scan)
        elseif (event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_AURA") and type(unit) == "string" and unit:find("^nameplate") then
            -- Tarnzauber oder Tarnung bei einer sichtbaren Plakette: echter Beweis
            local info = plates[unit]
            if not info or not STEALTHERS[info.c.class] then return end
            local hit
            if event == "UNIT_SPELLCAST_SUCCEEDED" then
                local id = Safe(spellID)
                local ok, n = pcall(SpellName, id)
                hit = IsStealthSpell(id, ok and n or nil)
            else
                local ok, a = pcall(HasStealthAura, unit)
                hit = ok and a
            end
            if hit then casts[info.key] = GetTime() end
        end
    end)
    Rudel.On("TA", OnStealthReport)
    C_Timer.NewTicker(SCAN_SECONDS, function() pcall(Alarm.Scan) end)
end
