-- Assassinen Rudel – alles, was die Gilde im Open PvP zusammen macht:
-- Positionen fürs Rudel, Hilferuf, Zielansage, Opener-Plan, Fehden und der Kill-Feed.
-- Eigenes Nachrichtenpräfix "ASSAR", damit Positionen nicht die Späher-Meldungen ausbremsen.

local ADDON_NAME, ns = ...
local Rudel = {}
ns.Rudel = Rudel

local PREFIX = "ASSAR"
local POS_MOVING = 15      -- Position alle 15 s, wenn ich mich bewege
local POS_IDLE = 30        -- sonst alle 30 s
local PACK_SECONDS = 75    -- so lange bleibt ein Mitglied auf der Karte
local HELP_TTL = 90
local AUTO_HELP_CD = 60
local HELP_RANGE = 2500    -- Yards: näher dran gibt es Fenster + Alarm, sonst nur eine Chatzeile
local TARGET_RANGE = 500
local BT = BackdropTemplateMixin and "BackdropTemplate" or nil
local SKULL = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12|t"

BINDING_HEADER_ASSASSINEN = "Assassinen"
BINDING_NAME_ASSASSINEN_HILFE = "Hilferuf an die Gilde"
BINDING_NAME_ASSASSINEN_ZIEL = "Ziel ansagen"
_G["BINDING_NAME_CLICK AssassinenZielButton:LeftButton"] = "Angesagtes Ziel anvisieren"
BINDING_NAME_ASSASSINEN_PLAN = "Opener-Plan an die Gruppe"
BINDING_NAME_ASSASSINEN_BEREIT = "Bereitschaftscheck"
BINDING_NAME_ASSASSINEN_SPAEHER = "Späher-Fenster ein/aus"

local S, Spy, Karte, UI
local playerName
local pack = {}            -- Name -> { map, x, y, hp, stealth, combat, class, level, t }
Rudel.pack = pack
local feuds                -- AssassinenKillsDB.intel.feuds: Gilde -> { t, by }
local handlers = {}
local groupMates = {}      -- Name (klein) -> GetTime(): hat zuletzt über den Gruppenkanal gesendet
local idNonce = tostring(math.random(100000, 999999))
local queue, tokens, lastRefill = {}, 6, 0
local lastPos = {}
local helpActive, lastHelpSent, lastCaller = nil, -999, nil
local calledTarget, pendingMacro, targetButton, helpFrame

-- Serien: Kills ohne zu sterben
Rudel.STREAKS = { [3] = "Blutrausch", [5] = "Gemetzel", [10] = "Unaufhaltsam", [15] = "Gnadenlos" }

-- Opener-Plan für Schurken und Druiden. Kürzel werden verschickt, jeder Client kennt die Texte.
-- Schurken: Betäubungskette. Druiden: Heilung und Wurzeln – eröffnen nur, wenn kein Schurke dabei ist.
Rudel.ROLES = {
    R1 = "Eröffnen mit Fieser Trick",
    R2 = "Nierenhieb, sobald Fieser Trick ausläuft",
    R3 = "Tritt – jeden Zauber unterbrechen",
    R4 = "Solarplexus, danach Blenden als Reserve",
    R5 = "Kopfnuss auf den zweiten Gegner",
    RX = "Schaden – und verfolgen, wenn er flieht",
    D0 = "Eröffnen mit Anspringen aus dem Schleichen",
    D1 = "Heilen und Anregen – bleib hinten in Reichweite",
    D2 = "Wucherwurzeln, sobald er flieht oder Hilfe kommt",
    D3 = "Hieb in Bärengestalt, wenn die Betäubung endet",
    DX = "Katzengestalt: Schaden, Krallenhieb und Zerfleischen",
}
local ROGUE_ORDER = { "R1", "R2", "R3", "R4", "R5" }
local DRUID_ORDER = { "D1", "D2", "D3" }

-- Rollen nach Klasse verteilen: Namen in Reihenfolge, Klasse je Name (nil = Schurke)
function Rudel.AssignRoles(names, classOf)
    local rogues = 0
    for _, n in ipairs(names) do if (classOf[n] or "ROGUE") ~= "DRUID" then rogues = rogues + 1 end end
    local out, r, d = {}, 0, 0
    for _, n in ipairs(names) do
        if (classOf[n] or "ROGUE") == "DRUID" then
            d = d + 1
            if rogues == 0 then
                out[#out + 1] = { n, d == 1 and "D0" or DRUID_ORDER[d - 1] or "DX" }
            else
                out[#out + 1] = { n, DRUID_ORDER[d] or "DX" }
            end
        else
            r = r + 1
            out[#out + 1] = { n, ROGUE_ORDER[r] or "RX" }
        end
    end
    return out
end

local function Print(text) ns.Print(text) end

-- Leben in Prozent, nil wenn das Spiel den Wert verbirgt (in WoW Forever der Normalfall)
local function HealthPct(unit)
    if not (UnitHealth and UnitHealthMax) then return nil end
    local hp, max = ns.Safe(UnitHealth(unit)), ns.Safe(UnitHealthMax(unit))
    if not hp or not max or max <= 0 then return nil end
    return math.floor(hp / max * 100 + 0.5)
end
Rudel.HealthPct = HealthPct

local function Split(msg)
    local out = {}
    for field in (msg .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = field end
    return out
end

-- Ton aus der Ton-Zentrale (Toene.lua); kind ist das Ereignis, z. B. "help" oder "target"
local function Sound(kind)
    ns.Sound(kind or "new")
end
Rudel.Sound = Sound

local function LevelText(lv)
    lv = tonumber(lv)
    return lv and (lv > 0 and tostring(lv) or "??") or "?"
end

---------------------------------------------------------------------------
-- Senden: eigene Warteschlange, bis zu 8 Nachrichten am Stück, dann 1 pro Sekunde
---------------------------------------------------------------------------

function Rudel.GroupChannel()
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    if not IsInGroup and GetNumPartyMembers and GetNumPartyMembers() > 0 then return "PARTY" end
end

-- Gruppe, falls vorhanden, sonst Gilde
local function Channel(preferGroup)
    if preferGroup then
        local g = Rudel.GroupChannel()
        if g then return g end
    end
    if IsInGuild() then return "GUILD" end
end

-- opts: key (ersetzt eine noch wartende Nachricht gleicher Art), urgent (vorne anstellen), target (WHISPER)
function Rudel.Send(channel, opts, kind, ...)
    if not channel or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    local parts = { kind }
    for i = 1, select("#", ...) do
        local v = ns.Safe((select(i, ...)))
        parts[#parts + 1] = tostring(v == nil and "" or v):gsub("\t", " ")
    end
    local item = { msg = table.concat(parts, "\t"):sub(1, 250), channel = channel, target = opts and opts.target, key = opts and opts.key }
    if item.key then
        for i, q in ipairs(queue) do
            if q.key == item.key then queue[i] = item return end
        end
    end
    if opts and opts.urgent then table.insert(queue, 1, item) else table.insert(queue, item) end
end

local function Flush()
    local now = GetTime()
    tokens = math.min(8, tokens + (now - lastRefill))
    lastRefill = now
    while #queue > 0 and tokens >= 1 do
        local q = table.remove(queue, 1)
        tokens = tokens - 1
        pcall(C_ChatInfo.SendAddonMessage, PREFIX, q.msg, q.channel, q.target)
    end
end

function Rudel.On(kind, fn) handlers[kind] = fn end

---------------------------------------------------------------------------
-- Layer: Kein Addon kann den Layer wechseln. Das Spiel bietet ihn aber an, wenn man von
-- jemandem auf dem Ziel-Layer in die Gruppe eingeladen wird ("Refresh Now" oder nach 5 Min.).
-- Das Addon erledigt Einladen und Annehmen; den Wechsel bestätigt der Spieler selbst.
-- Die Layer-Nummer steckt in der GUID von NPCs (zoneUID) und gilt nur innerhalb einer Zone.
---------------------------------------------------------------------------

local LAYER_INVITE_WINDOW = 120
local myLayer          -- { uid, map, t }
local expectInvite     -- { from, t }: von diesem Mitglied nehmen wir eine Einladung an

-- Der eigene Layer gilt nur, solange er frisch gemessen ist: Nach einem Gruppenbeitritt oder "Refresh Now"
-- wechselt das Spiel den Layer ohne Ereignis. Ein alter Wert ergäbe sonst "gleicher Layer", obwohl es nicht stimmt.
local LAYER_FRESH = 60
local lastLayerSweep = 0

local function LayerOf(unit)
    local guid = ns.Safe(UnitGUID(unit))
    if type(guid) ~= "string" then return end
    local kind, uid = guid:match("^(%a+)%-0%-%d+%-%d+%-(%d+)%-%d+%-")
    if (kind == "Creature" or kind == "Vehicle") and uid then return uid end
end

local function ScanLayer(unit)
    local uid = LayerOf(unit)
    if uid then myLayer = { uid = uid, map = Karte.me.map, t = GetTime() } end
end

-- Alle sichtbaren NPC-Plaketten: der häufigste Wert gewinnt (ein einzelner Ausreißer stört nicht)
local function SweepLayer()
    local count, best, bestN = {}, nil, 0
    for i = 1, 40 do
        local uid = LayerOf("nameplate" .. i)
        if uid then
            count[uid] = (count[uid] or 0) + 1
            if count[uid] > bestN then best, bestN = uid, count[uid] end
        end
    end
    if best then myLayer = { uid = best, map = Karte.me.map, t = GetTime() } end
end

function Rudel.MyLayer()
    if myLayer and myLayer.map and myLayer.map == Karte.me.map and GetTime() - myLayer.t <= LAYER_FRESH then
        return myLayer.uid
    end
end

-- true/false, wenn vergleichbar (gleiche Karte, beide bekannt), sonst nil
function Rudel.SameLayer(map, layer)
    local mine = Rudel.MyLayer()
    if not mine or not layer or layer == "" or map ~= Karte.me.map then return nil end
    return layer == mine
end

local function InGroup()
    return (IsInGroup and IsInGroup()) or (IsInRaid and IsInRaid()) or false
end

local function CanInvite()
    if not InGroup() then return true end
    local lead = UnitIsGroupLeader and UnitIsGroupLeader("player")
    if IsInRaid and IsInRaid() then return lead or (UnitIsGroupAssistant and UnitIsGroupAssistant("player")) end
    return lead and (GetNumGroupMembers and GetNumGroupMembers() or 1) < 5
end

-- Ein Mitglied auf den eigenen Layer holen: einladen
local function TryInvite(name)
    if not CanInvite() then
        Rudel.Send("WHISPER", { urgent = true, target = name }, "LN", "Ich bin in einer Gruppe und kann nicht einladen.")
        return
    end
    local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    if invite then
        pcall(invite, name)
        Print(string.format("%s eingeladen – so kann er auf deinen Layer wechseln.", name))
    end
end

-- Auf den Layer eines Mitglieds wechseln: um Einladung bitten
function Rudel.RequestLayer(name)
    if InGroup() then Print("Du bist schon in einer Gruppe. Für einen Layerwechsel erst austreten.") return end
    expectInvite = { from = name, t = GetTime() }
    Rudel.Send("WHISPER", { urgent = true, target = name }, "LQ")
    Print(string.format("Frage %s nach einer Einladung …", name))
end

-- Rudel bilden: alle Mitglieder in der Nähe, die noch nicht in der Gruppe sind, einladen (nächste zuerst).
-- Ihr Addon weiß vorher Bescheid und nimmt die Einladung an.
local FORM_RANGE = 400 -- Yards

function Rudel.FormPack()
    if not CanInvite() then Print("Nur der Gruppenleiter (im Schlachtzug auch Assistenten) kann einladen.") return end
    local inGroup = {}
    local raid = IsInRaid and IsInRaid()
    for i = 1, raid and (GetNumGroupMembers and GetNumGroupMembers() or 0) or 4 do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        local name = ns.Safe(UnitExists(unit)) and ns.ShortName(ns.Safe(UnitName(unit)))
        if name then inGroup[name:lower()] = true end
    end
    local want = {}
    for name, p in pairs(pack) do
        local short = ns.ShortName(name) or name
        local d = p.map and Karte.Offset(p.map, p.x, p.y)
        if short ~= playerName and not inGroup[short:lower()] and d and d <= FORM_RANGE and GetTime() - (p.t or 0) <= 75 then
            want[#want + 1] = { name = name, d = d }
        end
    end
    if #want == 0 then Print("Kein Rudelmitglied in der Nähe, das noch nicht in deiner Gruppe ist.") return end
    table.sort(want, function(a, b) return a.d < b.d end)
    local members = InGroup() and (GetNumGroupMembers and GetNumGroupMembers() or 1) or 1
    local free = raid and (40 - members) or (5 - members)
    -- Mehr als in eine Gruppe passt: aus einer bestehenden Gruppe einen Schlachtzug machen
    if not raid and #want > free and InGroup() then
        local convert = (C_PartyInfo and C_PartyInfo.ConvertToRaid) or ConvertToRaid
        if convert and pcall(convert) then free = 40 - members; Print("Gruppe in einen Schlachtzug umgewandelt.") end
    end
    local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    local names = {}
    for i, w in ipairs(want) do
        if i > free then break end
        Rudel.Send("WHISPER", { urgent = true, target = w.name }, "RB")
        names[#names + 1] = w.name
    end
    -- kurz warten, damit die Ankündigung vor der Einladung ankommt
    C_Timer.After(0.8, function()
        for _, n in ipairs(names) do if invite then pcall(invite, n) end end
    end)
    local rest = #want - #names
    Print(string.format("Rudel gerufen: %s%s", table.concat(names, ", "),
        rest > 0 and string.format(" – %d weitere passen nicht in die Gruppe (erst ein Mitglied einladen, dann nochmal klicken)", rest) or ""))
end

-- Jagd-Radar im Chat
function Rudel.PrintRadar()
    local list = ns.Spy.Radar(30)
    if #list == 0 then Print("Jagd-Radar: In den letzten 30 Minuten keine Feinde gesichtet oder gemeldet.") return end
    Print("|cffffd100Jagd-Radar|r (letzte 30 Minuten, eigene Sichtungen und Meldungen der Gilde):")
    for i, z in ipairs(list) do
        if i > 6 then break end
        Print(string.format("  %s: %d Feind%s%s%s · %s", z.zone, z.n, z.n == 1 and "" or "e",
            z.kos > 0 and string.format(", davon |cffff4040%d KOS|r", z.kos) or "", z.hot and (" – meist " .. z.hot) or "", ns.Spy.Ago(z.newest)))
    end
end

handlers.RB = function(f, sender)
    if not S.autoJoin or InGroup() then return end
    expectInvite = { from = sender, t = GetTime(), reason = "rudel" }
end

local function ShowLayers()
    local mine = Rudel.MyLayer()
    Print(mine and string.format("Dein Layer in %s: |cffffd100%s|r", GetRealZoneText() or "?", mine)
        or "Dein Layer ist noch unbekannt – einen NPC ins Ziel nehmen oder kurz umsehen.")
    for name, p in pairs(pack) do
        local same = Rudel.SameLayer(p.map, p.layer)
        if same ~= nil then
            Print(string.format("  %s: %s", name, same and "|cff00ff00gleicher Layer|r" or "|cffff8020anderer Layer|r  (/assa layer " .. name .. ")"))
        end
    end
end

handlers.LQ = function(f, sender)
    if not S.layerHop then
        Rudel.Send("WHISPER", { urgent = true, target = sender }, "LN", "Layerwechsel ist bei mir ausgeschaltet.")
        return
    end
    TryInvite(sender)
end

handlers.LN = function(f, sender)
    if expectInvite and expectInvite.from:lower() == sender:lower() then expectInvite = nil end
    Print(string.format("%s: %s", sender, f[2] or "Einladung nicht möglich."))
end

-- Nur die erwartete Einladung annehmen, alle anderen bleiben dem Spieler überlassen
local function OnInvite(inviter)
    inviter = ns.ShortName(ns.Safe(inviter))
    if not (expectInvite and inviter) or GetTime() - expectInvite.t > LAYER_INVITE_WINDOW then return end
    if inviter:lower() ~= expectInvite.from:lower() then return end
    local reason = expectInvite.reason
    expectInvite = nil
    if AcceptGroup then pcall(AcceptGroup) end
    if StaticPopup_Hide then pcall(StaticPopup_Hide, "PARTY_INVITE") end
    if reason == "rudel" then
        UI.Alert(string.format("Rudel: in %ss Gruppe", inviter), false)
        Print(string.format("%s hat das Rudel gerufen – Einladung automatisch angenommen. (Abschalten: /assa autorudel aus)", inviter))
        return
    end
    UI.Alert("Gruppe beigetreten – jetzt »Refresh Now« klicken, um den Layer zu wechseln", true)
    Print(string.format("In %ss Gruppe. Klick im Hinweis auf |cffffd100Refresh Now|r (nicht im Kampf), sonst wechselt das Spiel nach etwa 5 Minuten von selbst.", inviter))
end

---------------------------------------------------------------------------
-- Rudel-Positionen
---------------------------------------------------------------------------

local function SharePosition()
    if not S.huntMap or not S.guildSync or not IsInGuild() then return end
    local _, instanceType = IsInInstance()
    if instanceType and instanceType ~= "none" then return end
    local me = Karte.me
    if not me.map then return end
    local now = GetTime()
    local moved = lastPos.map ~= me.map or math.abs((lastPos.x or 0) - me.x) + math.abs((lastPos.y or 0) - me.y) > 0.002
    if now - (lastPos.t or -999) < (moved and POS_MOVING or POS_IDLE) then return end
    lastPos.map, lastPos.x, lastPos.y, lastPos.t = me.map, me.x, me.y, now
    local m, x, y = Karte.Pack(me.map, me.x, me.y)
    local _, class = UnitClass("player")
    Rudel.Send("GUILD", { key = "P" }, "P", m, x, y, HealthPct("player"), (IsStealthed and IsStealthed()) and 1 or 0,
        UnitAffectingCombat("player") and 1 or 0, class, UnitLevel("player"), UnitGUID("player"), Rudel.MyLayer() or "")
end

handlers.P = function(f, sender)
    if f[10] and f[10] == UnitGUID("player") then -- die eigene Position nicht als Rudelmitglied zeigen
        ns.LearnSelfName(sender)
        pack[sender] = nil
        return
    end
    local map, x, y = Karte.Unpack(f[2], f[3], f[4])
    if not map then pack[sender] = nil return end
    pack[sender] = {
        map = map, x = x, y = y, hp = tonumber(f[5]), stealth = f[6] == "1", combat = f[7] == "1",
        class = f[8] ~= "" and f[8] or nil, level = tonumber(f[9]), t = GetTime(),
        layer = (f[11] and f[11] ~= "") and f[11] or nil,
        guid = (f[10] and f[10] ~= "") and f[10] or nil,
    }
    Karte.dirty = true
end

---------------------------------------------------------------------------
-- Hilferuf
---------------------------------------------------------------------------

local function BuildHelpFrame()
    local f = CreateFrame("Frame", "AssassinenHilfeFrame", UIParent, BT)
    helpFrame = f
    UI.Skin(f, .95)
    f:SetSize(320, 92)
    f:SetFrameStrata("DIALOG")
    UI.MakeMovable(f, "helpPos")
    UI.RestorePos(f, "helpPos", "TOP", UIParent, "TOP", 0, -140)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 10, -8)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("TOPLEFT", 10, -30)
    f.text:SetWidth(300)
    f.text:SetJustifyH("LEFT")
    f.come = UI.TextButton(f, "Ich komme", 90, function() Rudel.Respond() end, "Der Rufer sieht, dass du unterwegs bist")
    f.come:SetHeight(20)
    f.come:SetPoint("BOTTOMLEFT", 10, 8)
    f.close = UI.TextButton(f, "x", 18, function() f:Hide() end, "Schließen")
    f.close:SetPoint("TOPRIGHT", -6, -6)
    f:SetScript("OnUpdate", function(self, elapsed)
        self.left = (self.left or 0) - elapsed
        if self.left <= 0 then self:Hide() end
    end)
    f:Hide()
end

function Rudel.CallHelp(auto)
    if not IsInGuild() then Print("Ein Hilferuf geht nur in einer Gilde.") return end
    local now = GetTime()
    if now - lastHelpSent < (auto and AUTO_HELP_CD or 8) then
        if not auto then Print("Hilferuf wurde gerade erst gesendet.") end
        return
    end
    lastHelpSent = now
    helpActive = { t = now, auto = auto }
    local foe = Spy.GuessKiller()
    local n = Spy.NearbyCount()
    local me = Karte.me
    local m, x, y = Karte.Pack(me.map, me.x, me.y)
    Rudel.Send("GUILD", { urgent = true, key = "H" }, "H", m, x, y, GetRealZoneText(), GetSubZoneText(), HealthPct("player"),
        foe and foe.name or "", foe and foe.class or "", foe and foe.level or "", n, Rudel.MyLayer() or "")
    Print(auto and "|cffff2020Automatischer Hilferuf|r an die Gilde gesendet (unter 50 % Leben, Feind im Nacken)."
        or "|cffff2020Hilferuf|r an die Gilde gesendet.")
    return true
end

function Rudel.EndHelp(reason)
    if not helpActive then return end
    helpActive = nil
    Rudel.Send("GUILD", { urgent = true, key = "H" }, "HE", reason or "sicher")
end

function Rudel.HelpActive() return helpActive ~= nil end
function Rudel.Caller() return lastCaller end

function Rudel.Respond()
    if helpFrame then helpFrame:Hide() end
    if not lastCaller then Print("Gerade ruft niemand um Hilfe.") return end
    local where = Karte.Describe(lastCaller.map, lastCaller.x, lastCaller.y)
    -- Layerwechsel: Ist der Layer anders oder unbekannt, lädt der Rufer uns ein und wir nehmen an
    local wantInvite = S.layerHop and not InGroup() and Rudel.SameLayer(lastCaller.map, lastCaller.layer) ~= true
    Rudel.Send("GUILD", { urgent = true }, "HK", lastCaller.name, where or "", wantInvite and 1 or 0)
    Print(string.format("%s weiß, dass du kommst.", lastCaller.name))
    if ns.Jagd and lastCaller.map then
        ns.Jagd.Point("help", lastCaller.name, lastCaller.map, lastCaller.x, lastCaller.y, "HILFE: " .. lastCaller.name, HELP_TTL, lastCaller.name)
    end
    if wantInvite then
        expectInvite = { from = lastCaller.name, t = GetTime() }
        Print(string.format("%s lädt dich gleich in die Gruppe ein – dann kannst du auf seinen Layer wechseln.", lastCaller.name))
    elseif S.layerHop and InGroup() and Rudel.SameLayer(lastCaller.map, lastCaller.layer) == false then
        Print("Du bist auf einem anderen Layer, aber in einer Gruppe. Für den Layerwechsel erst austreten.")
    end
end

handlers.H = function(f, sender)
    local map, x, y = Karte.Unpack(f[2], f[3], f[4])
    local zone, sub, hp = f[5] or "?", f[6] or "", tonumber(f[7])
    local foe = (f[8] and f[8] ~= "") and string.format("|c%s%s|r (%s)", ns.ClassColor(f[9]), f[8], LevelText(f[10])) or "Feinde"
    local count = tonumber(f[11]) or 0
    local text = foe .. (hp and string.format(" – noch %d%% Leben", hp) or "") .. (count > 1 and string.format(", %d Feinde in Sicht", count) or "")
    local place = (sub ~= "" and sub ~= zone) and (sub .. ", " .. zone) or zone
    Karte.Mark("help:" .. sender, "help", map, x, y, HELP_TTL, sender, text)
    lastCaller = { name = sender, map = map, x = x, y = y, t = GetTime(), layer = (f[12] and f[12] ~= "") and f[12] or nil }
    if Rudel.SameLayer(map, lastCaller.layer) == false then text = text .. "\n|cffff8020Anderer Layer|r – »Ich komme« holt dich in seine Gruppe" end
    if not S.helpAlerts then return end
    local where, d = nil, nil
    if map then where, d = Karte.Describe(map, x, y) end
    Print(string.format("|cffff2020HILFERUF|r von %s in %s: %s%s", sender, place, text, where and (" – " .. where) or ""))
    local close = (d and d <= HELP_RANGE) or (not d and zone == GetRealZoneText())
    if not close then return end
    if ns.Jagd then ns.Jagd.Point("help", sender, map, x, y, "HILFE: " .. sender, HELP_TTL, sender) end
    helpFrame.title:SetText("|cffff2020HILFERUF|r  " .. sender)
    helpFrame.text:SetText(string.format("%s\n%s%s", text, place, where and ("  ·  |cff88ccff" .. where .. "|r") or ""))
    helpFrame.left = 45
    helpFrame:Show()
    UI.Alert(string.format("HILFE: %s wird angegriffen%s", sender, where and (" – " .. where) or ""), true)
    Sound("help")
end

handlers.HE = function(f, sender)
    Karte.Unmark("help:" .. sender)
    if ns.Jagd then ns.Jagd.Clear("help", sender) end
    if lastCaller and lastCaller.name == sender then
        lastCaller = nil
        if helpFrame then helpFrame:Hide() end
    end
    if S.helpAlerts then
        Print(string.format("%s: Hilferuf beendet (%s).", sender, f[2] == "gefallen" and "|cffff4040gefallen|r" or "in Sicherheit"))
    end
end

handlers.HK = function(f, sender)
    if f[2] ~= playerName then return end
    Print(string.format("|cff00ff00%s kommt dir zu Hilfe|r%s.", sender, (f[3] and f[3] ~= "") and (" (" .. f[3] .. " entfernt)") or ""))
    Sound("coming")
    if f[4] == "1" and S.layerHop then TryInvite(sender) end -- Helfer auf den eigenen Layer holen
end

---------------------------------------------------------------------------
-- Zielansage + Opener-Plan
---------------------------------------------------------------------------

-- Unsichtbarer, sicherer Knopf: per Tastenbelegung das angesagte Ziel anvisieren
local function BuildTargetButton()
    local b = CreateFrame("Button", "AssassinenZielButton", UIParent, "SecureActionButtonTemplate")
    b:SetAttribute("type", "macro")
    b:SetAttribute("macrotext", "")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:Hide()
    targetButton = b
end

local function SetMacro(name)
    if not targetButton then return end
    if InCombatLockdown and InCombatLockdown() then pendingMacro = name return end
    targetButton:SetAttribute("macrotext", "/targetexact " .. name)
    pendingMacro = nil
end

local function SetCalled(name, realm, class, level, guild, by)
    calledTarget = { name = name, realm = realm, class = class, level = level, guild = guild, by = by, t = GetTime() }
    Rudel.called = calledTarget
    SetMacro(name)
end

function Rudel.CallTarget()
    local Safe = ns.Safe
    if not Safe(UnitExists("target")) or not Safe(UnitIsPlayer("target")) or not Safe(UnitCanAttack("player", "target")) then
        Print("Kein feindlicher Spieler im Ziel.")
        return
    end
    local channel = Channel(true)
    if not channel then Print("Weder Gruppe noch Gilde – niemand hört die Ansage.") return end
    local name, realm = UnitName("target")
    name, realm = Safe(name), Safe(realm)
    if not name then Print("Das Spiel verbirgt gerade den Namen des Ziels.") return end
    local _, class = UnitClass("target")
    class = Safe(class)
    local level, guild = Safe(UnitLevel("target")), Safe(GetGuildInfo("target"))
    if channel ~= "GUILD" and SetRaidTarget then pcall(SetRaidTarget, "target", 8) end
    local m, x, y = Karte.Pack(Karte.me.map, Karte.me.x, Karte.me.y)
    Rudel.Send(channel, { urgent = true, key = "T" }, "T", name, realm or "", class or "", level or "", guild or "", m, x, y)
    SetCalled(name, realm, class, level, guild, playerName)
    Print(string.format("Ziel angesagt (%s): |c%s%s|r", channel == "GUILD" and "Gilde" or "Gruppe", ns.ClassColor(class), name))
end

handlers.T = function(f, sender, channel)
    local name = f[2]
    if not name or name == "" then return end
    local class, level, guild = f[4] ~= "" and f[4] or nil, tonumber(f[5]), f[6] ~= "" and f[6] or nil
    local map, x, y = Karte.Unpack(f[7], f[8], f[9])
    local where, d = nil, nil
    if map then where, d = Karte.Describe(map, x, y) end
    if channel == "GUILD" and not (d and d <= TARGET_RANGE) then
        Print(string.format("%s sagt |c%s%s|r an%s.", sender, ns.ClassColor(class), name, where and (" – " .. where) or ""))
        return
    end
    SetCalled(name, f[3], class, level, guild, sender)
    Karte.Mark("target", "target", map, x, y, 120, name, "Angesagt von " .. sender)
    if ns.Jagd then ns.Jagd.Point("target", name, map, x, y, "Ziel: " .. name, 60) end
    local text = string.format("ZIEL: |c%s%s|r (%s %s) – von %s", ns.ClassColor(class), name, LevelText(level),
        LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or class or "", sender)
    UI.Alert(text, true)
    Print(text .. (GetBindingKey and GetBindingKey("CLICK AssassinenZielButton:LeftButton") and "" or
        " |cffaaaaaa(Taste dafür: Tastaturbelegung → AddOns → Assassinen)|r"))
    Sound("target")
end

-- Gruppe in Reihenfolge (ich zuerst) und Klasse je Name
local function GroupRoster()
    local _, myClass = UnitClass("player")
    local names, classOf = { playerName }, { [playerName] = myClass }
    local raid = IsInRaid and IsInRaid()
    for i = 1, raid and GetNumGroupMembers() or 4 do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        local n = ns.Safe(UnitExists(unit)) and ns.Safe(UnitName(unit))
        if n and n ~= playerName then
            names[#names + 1] = n
            local _, class = UnitClass(unit)
            classOf[n] = ns.Safe(class)
        end
    end
    return names, classOf
end

-- plan: Liste { Name, Rollenkürzel }
local function ShowPlan(target, plan, by)
    Print(string.format("|cffffd100Opener-Plan|r von %s gegen |cffff4040%s|r:", by, target))
    local mine
    for i, e in ipairs(plan) do
        local role = Rudel.ROLES[e[2]] or Rudel.ROLES.RX
        Print(string.format("  %d. %s – %s", i, e[1], role))
        if e[1]:lower() == playerName:lower() then mine = role end
    end
    if mine then
        UI.Alert("DEINE ROLLE: " .. mine, true)
        Rudel.myRole = { text = mine, t = GetTime() } -- der Countdown zeigt die Rolle noch einmal an
    end
end

function Rudel.Plan(raw)
    local channel = Rudel.GroupChannel()
    if not channel then Print("Der Opener-Plan geht nur in einer Gruppe.") return end
    local names, classOf = GroupRoster()
    if raw and raw ~= "" then
        names = {}
        for n in raw:gmatch("[^,%s]+") do names[#names + 1] = n:sub(1, 1):upper() .. n:sub(2) end
    end
    local plan = Rudel.AssignRoles(names, classOf)
    local target = (calledTarget and GetTime() - calledTarget.t < 300 and calledTarget.name)
        or (ns.Safe(UnitExists("target")) and ns.Safe(UnitName("target"))) or "das Ziel"
    local parts = {}
    for _, e in ipairs(plan) do parts[#parts + 1] = e[1] .. ":" .. e[2] end
    Rudel.Send(channel, { urgent = true }, "PL", target, table.concat(parts, ","))
    ShowPlan(target, plan, playerName)
end

handlers.PL = function(f, sender)
    local plan = {}
    for n, code in (f[3] or ""):gmatch("([^,:]+):?([^,]*)") do plan[#plan + 1] = { n, code } end
    if #plan > 0 then
        ShowPlan(f[2] or "?", plan, sender)
        Sound("plan")
    end
end

---------------------------------------------------------------------------
-- Fehden: verfeindete Gilden
---------------------------------------------------------------------------

function Rudel.IsFeud(guild)
    return guild ~= nil and feuds ~= nil and feuds[guild] ~= nil
end

local function MyRank()
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex
end

-- Rangnummer eines Gildenmitglieds (0 = Gildenleiter, 1 = Offiziere)
local function RankOf(name)
    if not (GetNumGuildMembers and GetGuildRosterInfo) then return end
    for i = 1, GetNumGuildMembers() do
        local n, _, rankIndex = GetGuildRosterInfo(i)
        if n and ns.ShortName(n) == name then return rankIndex end
    end
end
Rudel.RankOf = RankOf

local function FindGuild(query)
    query = (query or ""):lower()
    for g in pairs(feuds) do if g:lower() == query then return g end end
    for _, c in pairs(ns.db.intel.contacts) do
        if c.guild and c.guild:lower() == query then return c.guild end
    end
end

function Rudel.SetFeud(guild, on, by)
    if on then feuds[guild] = { t = time(), by = by } else feuds[guild] = nil end
    Spy.dirty = true
end

-- Bilanz gegen eine Gilde aus meinen Kills und Toden
local function FeudRecord(guild)
    local char, w, l = ns.char, 0, 0
    for _, k in ipairs(char.kills) do if k.guild == guild then w = w + 1 end end
    for _, d in ipairs(char.deaths) do if d.guild == guild then l = l + 1 end end
    return w, l
end

local function ListFeuds()
    local any
    for g, info in pairs(feuds) do
        any = true
        local w, l = FeudRecord(g)
        Print(string.format("  <%s> – seit %s, von %s · deine Bilanz |cff00ff00%d|r : |cffff4040%d|r",
            g, date("%d.%m.%Y", info.t), info.by or "?", w, l))
    end
    if not any then Print("Keine Fehden. /assa fehde <Gilde> erklärt eine.") end
end

handlers.F = function(f, sender)
    local guild = f[2]
    if not guild or guild == "" then return end
    local rank = RankOf(sender)
    if not rank or rank > 1 then return end -- nur Gildenleiter und Dunkler Rat
    local on = f[3] == "1"
    if Rudel.IsFeud(guild) == on then return end
    Rudel.SetFeud(guild, on, sender)
    Print(on and string.format("|cffff2020FEHDE|r: %s erklärt <%s> zum Feind der Gilde.", sender, guild)
        or string.format("%s hat die Fehde mit <%s> beendet.", sender, guild))
    if on then UI.Alert(string.format("FEHDE gegen <%s>", guild), true) Sound("feud") end
end

---------------------------------------------------------------------------
-- Kill-Feed, Gildenrache, Serien
---------------------------------------------------------------------------

function Rudel.OnKill(rec)
    if ns.Bilanz then pcall(ns.Bilanz.OnKill) end
    local title = Rudel.STREAKS[rec.streak or 0]
    if title then
        UI.Alert(string.format("%s! %d Kills ohne Tod", title:upper(), rec.streak), true)
        Print(string.format("|cffff2020%s|r – %d Kills ohne zu sterben.", title, rec.streak))
    end
    if rec.revenge then Print(string.format("|cffffd100Rache!|r %s hat für deinen Tod bezahlt.", rec.victim)) end
    if rec.avenged then Print(string.format("|cffffd100Gildenrache!|r Du hast %s an %s gerächt.", rec.avenged, rec.victim)) end
    if rec.giant then Print("|cffffd100Riesentöter!|r Das Opfer war deutlich stärker als du.") end
    if not S.guildSync or not IsInGuild() then return end
    local flags = {}
    if rec.revenge then flags[#flags + 1] = "R" end
    if rec.giant then flags[#flags + 1] = "G" end
    if rec.contract or rec.contractId then flags[#flags + 1] = "C" end
    if rec.avenged then flags[#flags + 1] = "A=" .. rec.avenged end
    Rudel.Send("GUILD", nil, "K", rec.victim, rec.class or "", rec.level or "", rec.zone or "", rec.streak or "", table.concat(flags, ","))
end

-- Todesstoß ohne Kampflog: Jeder in der Gruppe, der den Kill gemeldet bekommt, sagt an, wie lange sein
-- letzter Angriff auf das Opfer her ist. Wer am kürzesten her ist, bekommt den Kill (Gleichstand: Name).
local CLAIM_WINDOW = 1.5
local claims = {} -- Opfer (klein) -> { [Name] = { age, t } }

function Rudel.ClaimKill(victim, age, onWin, onLose)
    local v = (victim or "?"):lower()
    local now = GetTime()
    claims[v] = claims[v] or {}
    for n, c in pairs(claims[v]) do if now - c.t > 15 then claims[v][n] = nil end end
    claims[v][playerName] = { age = age, t = now }
    local channel = Rudel.GroupChannel()
    if channel then Rudel.Send(channel, { urgent = true }, "KC", victim, string.format("%.1f", age)) end
    C_Timer.After(CLAIM_WINDOW, function()
        local best, bestAge
        for n, c in pairs(claims[v] or {}) do
            if GetTime() - c.t <= 15 and (not best or c.age < bestAge or (c.age == bestAge and n < best)) then
                best, bestAge = n, c.age
            end
        end
        claims[v] = nil
        if not best or best == playerName then onWin() else onLose(best) end
    end)
end

handlers.KC = function(f, sender)
    local v = (f[2] or ""):lower()
    if v == "" or sender == playerName then return end
    claims[v] = claims[v] or {}
    claims[v][sender] = { age = tonumber(f[3]) or 99, t = GetTime() }
end

local feedSeen = {} -- Opfer (klein) -> GetTime(): denselben Kill nicht doppelt im Feed zeigen

handlers.K = function(f, sender)
    local victimKey = (f[2] or ""):lower()
    local dup = feedSeen[victimKey] and GetTime() - feedSeen[victimKey] < 60
    feedSeen[victimKey] = GetTime()
    local flags, avenged = f[7] or "", nil
    avenged = flags:match("A=([^,]+)")
    if avenged and avenged == playerName then
        UI.Alert(string.format("%s hat dich an %s gerächt!", sender, f[2]), true)
        Sound("feud")
    end
    if not S.feed or dup then return end
    local extra = {}
    local streak = tonumber(f[6])
    local title = streak and Rudel.STREAKS[streak]
    if title then extra[#extra + 1] = "|cffff2020" .. title .. "|r" end
    if flags:find("R") then extra[#extra + 1] = "Rache" end
    if avenged then extra[#extra + 1] = "rächt " .. avenged end
    if flags:find("G") then extra[#extra + 1] = "Riesentöter" end
    if flags:find("C") then extra[#extra + 1] = "Auftrag" end
    Print(string.format("%s %s tötet |c%s%s|r (%s) in %s%s", SKULL, sender, ns.ClassColor(f[3]), f[2] or "?", LevelText(f[4]),
        f[5] ~= "" and f[5] or "?", #extra > 0 and (" – " .. table.concat(extra, " · ")) or ""))
end

function Rudel.OnDeath(rec)
    if helpActive then Rudel.EndHelp("gefallen") end
    if not rec.pvp or not rec.killer or not S.guildSync or not IsInGuild() then return end
    local name, realm = ns.ShortName(rec.killer), rec.killer:match("%-(.+)$")
    Rudel.Send("GUILD", nil, "D", name, realm or "", rec.class or "", rec.level or "", rec.guild or "", rec.zone or "")
end

-- Ein Mitglied ist gefallen: der Mörder ist 15 Minuten lang "zu rächen"
handlers.D = function(f, sender)
    local name = f[2]
    if not name or name == "" then return end
    local c = Spy.ContactFor(name, f[3] ~= "" and f[3] or nil)
    c.class = f[4] ~= "" and f[4] or c.class
    local lv = tonumber(f[5]); if lv and lv ~= 0 then c.level = lv end
    c.guild = f[6] ~= "" and f[6] or c.guild
    c.guildLoss = { t = time(), who = sender }
    c.guildKills = (c.guildKills or 0) + 1
    Spy.dirty = true
    if S.feed then
        Print(string.format("|cffff4040%s ist gefallen|r durch %s in %s. Wer ihn in 15 Minuten erwischt, nimmt Rache.",
            sender, Spy.Colored(c), f[7] ~= "" and f[7] or "?"))
    end
end

---------------------------------------------------------------------------
-- Slash-Befehle
---------------------------------------------------------------------------

function Rudel.Slash(cmd, raw, arg)
    if cmd == "hilfe" or cmd == "help" then
        if arg == "aus" or arg == "sicher" then Rudel.EndHelp("sicher") Print("Hilferuf beendet.")
        else Rudel.CallHelp(false) end
    elseif cmd == "komme" then
        Rudel.Respond()
    elseif cmd == "autohilfe" then
        Print("Automatischer Hilferuf unter 50 % Leben: " .. ns.OnOff(ns.Toggle("autoHelp", arg)))
    elseif cmd == "hilferufe" then
        Print("Hilferufe anderer anzeigen: " .. ns.OnOff(ns.Toggle("helpAlerts", arg)))
    elseif cmd == "karte" then
        Print("Jagdkarte (Rudel + Feinde auf Welt- und Minimap): " .. ns.OnOff(ns.Toggle("huntMap", arg)))
        Karte.dirty = true
    elseif cmd == "ziele" or cmd == "ziel liste" then
        if ns.Ziele then ns.Ziele.Toggle() end
    elseif cmd == "leiste" then
        if ns.Leiste then ns.Leiste.Toggle() end
    elseif cmd == "gruppentest" then
        Rudel.GroupTest()
    elseif cmd == "kartentest" then
        Karte.Debug()
    elseif cmd == "layer" then
        if raw == "" then ShowLayers() else Rudel.RequestLayer(raw:sub(1, 1):upper() .. raw:sub(2)) end
    elseif cmd == "layerwechsel" then
        Print("Layerwechsel (Helfer einladen, Einladung annehmen): " .. ns.OnOff(ns.Toggle("layerHop", arg)))
    elseif cmd == "sichtungen" then
        Print("Alle Feindsichtungen mit der Gilde teilen: " .. ns.OnOff(ns.Toggle("sightShare", arg)))
    elseif cmd == "ziel" then
        Rudel.CallTarget()
    elseif cmd == "plan" then
        Rudel.Plan(raw)
    elseif cmd == "feed" then
        Print("Kill-Feed der Gilde im Chat: " .. ns.OnOff(ns.Toggle("feed", arg)))
    elseif cmd == "fehden" then
        ListFeuds()
    elseif cmd == "fehde" then
        if raw == "" then ListFeuds() return true end
        local guild = FindGuild(raw) or raw
        local on = not Rudel.IsFeud(guild)
        local rank = MyRank()
        if rank and rank <= 1 and IsInGuild() then
            Rudel.SetFeud(guild, on, playerName)
            Rudel.Send("GUILD", nil, "F", guild, on and 1 or 0)
            Print(on and string.format("|cffff2020Fehde erklärt|r: <%s> – die ganze Gilde wird gewarnt.", guild)
                or string.format("Fehde mit <%s> beendet.", guild))
        else
            Rudel.SetFeud(guild, on, playerName)
            Print((on and "Fehde (nur für dich) gegen <%s> eingetragen." or "Fehde mit <%s> entfernt.") :format(guild)
                .. " Gildenweit erklären können nur Gildenleiter und Dunkler Rat.")
        end
    elseif cmd == "rudel" or cmd == "rudelbilden" then
        Rudel.FormPack()
    elseif cmd == "autorudel" then
        Print("Rudel-Einladungen automatisch annehmen: " .. ns.OnOff(ns.Toggle("autoJoin", arg)))
    elseif cmd == "radar" then
        Rudel.PrintRadar()
    elseif ns.Alarm and ns.Alarm.Slash(cmd, raw, arg) then
        -- erledigt
    elseif ns.Version and ns.Version.Slash(cmd, raw, arg) then
        -- Versionen / Update
    elseif ns.Bilanz and ns.Bilanz.Slash(cmd, raw, arg) then
        -- erledigt
    elseif ns.Jagd and ns.Jagd.Slash(cmd, raw, arg) then
        -- erledigt
    elseif ns.Bereit and ns.Bereit.Slash(cmd, raw, arg) then
        -- erledigt
    else
        return false
    end
    return true
end

function AssassinenKills_Binding(what)
    if what == "hilfe" then Rudel.CallHelp(false)
    elseif what == "ziel" then Rudel.CallTarget()
    elseif what == "plan" then Rudel.Plan("")
    elseif what == "bereit" and ns.Bereit then ns.Bereit.Check("")
    elseif what == "spaeher" and ns.UI then ns.UI.ToggleScanner()
    elseif what == "ziele" and ns.Ziele then ns.Ziele.Toggle()
    elseif what == "leiste" and ns.Leiste then ns.Leiste.Toggle()
    elseif what == "rudel" then Rudel.FormPack()
    elseif ns.Jagd then ns.Jagd.Binding(what) end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------

-- Gruppenkameraden mit Addon: melden sich alle 15 Sekunden kurz im Gruppenkanal
local GROUP_PING = 15
local lastGroupPing, lastRoster = -999, -1

function Rudel.InMyGroup(name)
    if not InGroup() or not name then return false end
    local t = groupMates[(ns.ShortName(name) or name):lower()]
    return t ~= nil and GetTime() - t <= GROUP_PING * 3
end

local function GroupPing()
    local channel = Rudel.GroupChannel()
    if not channel then
        for k in pairs(groupMates) do groupMates[k] = nil end
        lastRoster = -1
        return
    end
    local roster = GetNumGroupMembers and GetNumGroupMembers() or 0
    if roster ~= lastRoster or GetTime() - lastGroupPing >= GROUP_PING then
        lastRoster, lastGroupPing = roster, GetTime()
        Rudel.Send(channel, nil, "GH")
    end
end

handlers.GH = function() end

-- Prüfbefehl /assa gruppentest: was das Addon über die eigene Gruppe weiß
function Rudel.GroupTest()
    Print(string.format("Gruppe: %s, Kanal %s, Mitglieder %s", tostring(InGroup()), tostring(Rudel.GroupChannel()),
        tostring(GetNumGroupMembers and GetNumGroupMembers())))
    local raid = IsInRaid and IsInRaid()
    for i = 1, raid and (GetNumGroupMembers and GetNumGroupMembers() or 0) or 4 do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        if ns.Safe(UnitExists(unit)) then
            local name = ns.Safe(UnitName(unit))
            local guid = ns.Safe(UnitGUID(unit))
            local ok, map, x, y = pcall(Karte.MapPos, unit)
            Print(string.format("  %s: Name %s, GUID %s, Position %s", unit, tostring(name), guid and "lesbar" or "verborgen",
                (ok and map) and string.format("%d %.3f %.3f", map, x, y) or "verborgen"))
        end
    end
    for name, p in pairs(pack) do
        Print(string.format("  Rudel %s: GUID %s, meldet sich im Gruppenkanal: %s", name, p.guid and "ja" or "nein", tostring(Rudel.InMyGroup(name))))
    end
end

function Rudel.Tick()
    pcall(GroupPing)
    if GetTime() - lastLayerSweep >= 5 then lastLayerSweep = GetTime(); pcall(SweepLayer) end
    pcall(SharePosition) -- ein Fehler hier darf das Senden nicht aufhalten
    Flush()
    local now = GetTime()
    for name, p in pairs(pack) do
        if now - p.t > PACK_SECONDS then pack[name] = nil end
    end
end

local function OnEvent(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix ~= PREFIX or not msg then return end
        sender = ns.ShortName(ns.Safe(sender))
        if not sender then return end
        local f = Split(msg)
        -- eigene Kennung zurückbekommen: so heißen wir für die anderen (mit Nachname)
        if f[1] == "ID" then
            if f[2] == idNonce then ns.LearnSelfName(sender) end
            return
        end
        if ns.IsMe(sender) then return end
        -- Wer über den Gruppenkanal sendet, ist sicher in meiner Gruppe (auch wenn das Spiel Namen verbirgt)
        if channel == "PARTY" or channel == "RAID" then groupMates[sender:lower()] = GetTime() end
        local h = handlers[f[1]]
        if h then h(f, sender, channel) end
    elseif event == "UNIT_HEALTH" then
        if (...) ~= "player" or not S.autoHelp or helpActive then return end
        if GetTime() - lastHelpSent < AUTO_HELP_CD then return end
        -- Verbirgt das Spiel das Leben, gibt es keinen automatischen Ruf, nur den von Hand
        local hp = HealthPct("player")
        if not hp or hp >= 50 then return end
        if UnitIsDeadOrGhost and ns.Safe(UnitIsDeadOrGhost("player")) then return end
        local _, instanceType = IsInInstance()
        if instanceType and instanceType ~= "none" then return end
        if Spy.GuessKiller() then Rudel.CallHelp(true) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingMacro then SetMacro(pendingMacro) end
        if helpActive and not (UnitIsDeadOrGhost and ns.Safe(UnitIsDeadOrGhost("player"))) then Rudel.EndHelp("sicher") end
    elseif event == "PARTY_INVITE_REQUEST" then
        OnInvite((...))
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        ScanLayer((...))
    elseif event == "PLAYER_TARGET_CHANGED" then
        ScanLayer("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        ScanLayer("mouseover")
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        -- neue Zone, Gruppenwechsel oder Ladebildschirm: der Layer kann sich geändert haben, neu messen
        myLayer = nil
        lastLayerSweep = 0
    end
end

function Rudel.Init()
    S, Spy, Karte, UI = ns.settings, ns.Spy, ns.Karte, ns.UI
    playerName = ns.PlayerName()
    ns.WatchSelfName(function(n) playerName = n end)
    ns.db.intel.feuds = ns.db.intel.feuds or {}
    feuds = ns.db.intel.feuds
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
    local f = CreateFrame("Frame")
    for _, e in ipairs({ "CHAT_MSG_ADDON", "UNIT_HEALTH", "PLAYER_REGEN_ENABLED", "PARTY_INVITE_REQUEST", "NAME_PLATE_UNIT_ADDED",
        "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }) do
        pcall(f.RegisterEvent, f, e)
    end
    f:SetScript("OnEvent", OnEvent)
    BuildHelpFrame()
    BuildTargetButton()
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
    lastRefill = GetTime()
    C_Timer.NewTicker(0.5, Rudel.Tick)
    -- an sich selbst: der Absendername verrät den vollen eigenen Namen
    C_Timer.After(3, function()
        if IsInGuild() then Rudel.Send("GUILD", { urgent = true }, "ID", idNonce) end
    end)
    if ns.Bereit then ns.Bereit.Init() end
end
