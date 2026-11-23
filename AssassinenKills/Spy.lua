-- Assassinen Späher – Feinderkennung, Bedrohung, Warnungen, Gildensync und Aufträge.
-- Quellen: Namensplaketten, Ziel, Mouseover und (falls erlaubt) das Kampflog.
-- Daten: AssassinenKillsDB.intel.contacts["Name-Realm"]

local ADDON_NAME, ns = ...
local Spy = {}
ns.Spy = Spy

local MSG_PREFIX = "ASSA"
local NEARBY_SECONDS = 60     -- so lange gilt ein Feind als "in der Nähe"
local REALERT_SECONDS = 120   -- frühestens dann erneut warnen
local REPORT_SECONDS = 120    -- Sichtung frühestens dann erneut an die Gilde melden
local KEEP_DAYS = 45          -- unwichtige Kontakte danach vergessen

local band = bit.band
local TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x00000400
local REACTION_HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x00000040

-- Bedrohungsstufen: Mindestwert, Name, r, g, b
Spy.TIERS = {
    { 70, "Tödlich", 1, .15, .2 },
    { 50, "Ernst", 1, .5, .1 },
    { 30, "Vorsicht", 1, .85, .2 },
    { 0, "Gering", .45, .8, .45 },
}
local CLASS_DANGER = {
    ROGUE = 14, MAGE = 12, WARRIOR = 12, WARLOCK = 11, HUNTER = 10, SHAMAN = 10,
    PALADIN = 8, DRUID = 8, PRIEST = 7,
}

local S, intel, contacts
local nearby, attacked, alerted, reported = {}, {}, {}, {}
local sendQueue, lastSend = {}, 0
local stealthSpells = {}
local mustered = {}           -- Gilde -> GetTime() der letzten Aufmarsch-Warnung
local playerName
local REVENGE_SECONDS = 900   -- Rache zählt 15 Minuten

local function Print(text) ns.Print(text) end
local function Muted() return S.snoozeUntil and time() < S.snoozeUntil end
Spy.Muted = Muted

-- Neutrale Städte: dort laufen beide Fraktionen herum, Warnungen wären Dauerlärm.
-- Deutsche und englische Namen; eigene Orte kommen mit /assa neutral hier dazu.
local NEUTRAL_TOWNS = {}
for _, n in ipairs({
    "Beutebucht", "Booty Bay", "Gadgetzan", "Ratschet", "Ratchet", "Ewige Warte", "Everlook",
    "Kapelle des Hoffnungsvollen Lichts", "Light's Hope Chapel", "Burg Cenarius", "Cenarion Hold",
    "Thoriumspitze", "Thorium Point", "Dampfdruckpier", "Steamwheedle Port", "Marschalls Zuflucht", "Marshal's Refuge",
    "Morastwinkel", "Mudsprocket", "Shattrath", "Dalaran",
}) do NEUTRAL_TOWNS[n:lower()] = true end

function Spy.InNeutralTown()
    local pvp = GetZonePVPInfo and GetZonePVPInfo()
    if pvp == "sanctuary" then return true end
    local own = S and S.neutralOwn or {}
    for _, z in ipairs({ GetSubZoneText and GetSubZoneText() or "", GetMinimapZoneText and GetMinimapZoneText() or "" }) do
        local k = z:lower()
        if k ~= "" and (NEUTRAL_TOWNS[k] or own[k]) then return true, z end
    end
    return false
end

-- Ruhe in neutralen Städten: nur KOS, Aufträge und Fehden melden sich noch
function Spy.Calm()
    return S and S.neutralQuiet == true and Spy.InNeutralTown() == true
end

local function Key(name, realm)
    if not realm or realm == "" then realm = GetRealmName() end
    return name .. "-" .. realm
end

local function IsFeud(guild)
    return ns.Rudel and ns.Rudel.IsFeud(guild)
end

-- ink: Name in schwarzer Tinte (für Fenster mit Pergament; helle Klassenfarben wären dort unlesbar)
local function Colored(c, ink)
    local hex = (ink and ns.Design and ns.Design.On()) and ns.Design.InkHex() or ns.ClassColor(c.class)
    return "|c" .. hex .. c.name .. "|r"
end
Spy.Colored = Colored

local function Ago(t)
    if not t then return "nie" end
    local s = time() - t
    if s < 60 then return "gerade eben" end
    if s < 3600 then return string.format("vor %d Min.", math.floor(s / 60)) end
    if s < 86400 then return string.format("vor %d Std.", math.floor(s / 3600)) end
    return string.format("vor %d Tagen", math.floor(s / 86400))
end
Spy.Ago = Ago

-- Töne kommen aus der Ton-Zentrale (Toene.lua), dort kann jeder sie selbst wählen
local function PlayAlert(kind)
    if Muted() then return end
    ns.Sound(kind)
end

---------------------------------------------------------------------------
-- Kontakte
---------------------------------------------------------------------------

local function GetContact(name, realm, create)
    local key = Key(name, realm)
    local c = contacts[key]
    if not c and create then
        c = { name = name, realm = (realm and realm ~= "") and realm or GetRealmName(), first = time(), seen = 0, wins = 0, losses = 0 }
        contacts[key] = c
    end
    return c, key
end

-- Gold/Silber/Kupfer lesbar machen (Betrag in Kupfer)
function Spy.Money(copper)
    copper = math.floor(copper or 0)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local out = {}
    if g > 0 then out[#out + 1] = g .. "g" end
    if s > 0 then out[#out + 1] = s .. "s" end
    if c > 0 or #out == 0 then out[#out + 1] = c .. "k" end
    return table.concat(out, " ")
end

-- Zuteilung: "alle" oder kommagetrennte Namen
function Spy.IsAssigned(assignee, name)
    if not assignee or assignee == "" or assignee:lower() == "alle" then return true end
    for n in assignee:gmatch("[^,%s]+") do
        if n:lower() == (name or ""):lower() then return true end
    end
    return false
end

function Spy.ContactFor(name, realm)
    return GetContact(name, realm, true)
end

-- Eigenes Profil: Person merken, Grund (c.note) und Erlebnisse mit Datum
function Spy.SetSaved(c, on)
    if not c then return end
    c.saved = on and true or nil
    if ns.UI then ns.UI.Refresh() end
end

function Spy.AddLog(c, text)
    if not c or type(text) ~= "string" then return end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    c.log = c.log or {}
    table.insert(c.log, { t = time(), text = text:sub(1, 200), zone = GetRealZoneText and GetRealZoneText() or nil })
    while #c.log > 30 do table.remove(c.log, 1) end
    c.saved = true
    if ns.UI then ns.UI.Refresh() end
end

function Spy.DelLog(c, i)
    if not (c and c.log and c.log[i]) then return end
    table.remove(c.log, i)
    if #c.log == 0 then c.log = nil end
    if ns.UI then ns.UI.Refresh() end
end

-- Profil teilen: Kopf (Grund, KOS) und die letzten fünf eigenen Erlebnisse.
-- channel: "GUILD", "PARTY"/"RAID" oder "WHISPER" mit target. Fremde Einträge werden nicht weitergereicht.
function Spy.ShareProfile(c, channel, target)
    local R = ns.Rudel
    if not (c and R and R.Send) then return end
    if not channel then
        Print("Teilen geht in der Gilde, in der Gruppe oder per Flüstern an einen Spieler.")
        return
    end
    local opts = target and { target = target } or nil
    R.Send(channel, opts, "PF", c.name, c.realm or "", c.class or "", c.level or "", c.guild or "", c.kos and "1" or "", c.note or "")
    local own = {}
    for _, e in ipairs(c.log or {}) do if not e.by then own[#own + 1] = e end end
    for i = math.max(1, #own - 4), #own do
        local e = own[i]
        R.Send(channel, opts, "PE", c.name, c.realm or "", e.t, e.zone or "", e.text)
    end
    local where = channel == "WHISPER" and target or (channel == "GUILD" and "der Gilde") or "der Gruppe"
    Print(string.format("Profil von %s mit %s geteilt (%d Erlebnis%s).", c.name, where, math.min(#own, 5), math.min(#own, 5) == 1 and "" or "se"))
end

local sharedNotice = {}
local function OnSharedProfile(f, sender)
    local name = f[2]
    if type(name) ~= "string" or name == "" then return end
    local c = GetContact(name, f[3] ~= "" and f[3] or nil, true)
    if f[4] and f[4] ~= "" and not c.class then c.class = f[4] end
    local lv = tonumber(f[5]); if lv and lv ~= 0 and not c.level then c.level = lv end
    if f[6] and f[6] ~= "" and not c.guild then c.guild = f[6] end
    local who = ns.ShortName(sender) or sender
    c.shared = c.shared or {}
    c.shared[who] = { reason = (f[8] and f[8] ~= "") and f[8] or nil, kos = f[7] == "1", t = time() }
    local k = who .. ":" .. name
    if not sharedNotice[k] or GetTime() - sharedNotice[k] > 60 then
        sharedNotice[k] = GetTime()
        Print(string.format("|cffffd100%s teilt sein Profil|r zu %s%s – ansehen: /assa akte %s", who, Colored(c),
            c.shared[who].reason and (": „" .. c.shared[who].reason .. "“") or "", name))
    end
    if ns.UI then ns.UI.Refresh() end
end

local function OnSharedLog(f, sender)
    local name, t, text = f[2], tonumber(f[4]), f[6]
    if type(name) ~= "string" or name == "" or not t or type(text) ~= "string" or text == "" then return end
    local c = GetContact(name, f[3] ~= "" and f[3] or nil, true)
    c.log = c.log or {}
    for _, e in ipairs(c.log) do if e.t == t and e.text == text then return end end
    table.insert(c.log, { t = t, text = text:sub(1, 200), zone = (f[5] and f[5] ~= "") and f[5] or nil, by = ns.ShortName(sender) or sender })
    table.sort(c.log, function(a, b) return a.t < b.t end)
    while #c.log > 30 do table.remove(c.log, 1) end
    if ns.UI then ns.UI.Refresh() end
end

function Spy.InitSharing()
    if not (ns.Rudel and ns.Rudel.On) then return end
    ns.Rudel.On("PF", OnSharedProfile)
    ns.Rudel.On("PE", OnSharedLog)
end

function Spy.Get(key)
    return key and contacts and contacts[key]
end

function Spy.Find(query)
    if not query or query == "" then return end
    query = query:lower()
    local best, bestKey
    for key, c in pairs(contacts) do
        if key:lower() == query or c.name:lower() == query then
            if not best or (c.last or 0) > (best.last or 0) then best, bestKey = c, key end
        end
    end
    return best, bestKey
end

function Spy.Threat(key, c)
    local score = 25
    local my = UnitLevel("player") or 1
    if not c.level or c.level == 0 then
        score = score + 5
    elseif c.level < 0 then
        score = score + 35 -- Totenkopf: viel höher als ich
    else
        score = score + math.max(-25, math.min(30, (c.level - my) * 4))
    end
    score = score + (CLASS_DANGER[c.class] or 8)
    if c.kos then score = score + 25 end
    if c.contract and not c.contract.done then score = score + 10 end
    if IsFeud(c.guild) then score = score + 10 end
    score = score + math.min((c.losses or 0) * 6, 20) - math.min((c.wins or 0) * 3, 12)
    if attacked[key] and GetTime() - attacked[key] < 30 then score = score + 15 end
    return math.max(1, math.min(100, math.floor(score + 0.5)))
end

function Spy.Tier(score)
    for _, t in ipairs(Spy.TIERS) do
        if score >= t[1] then return t end
    end
end

-- Liste für das Späher-Fenster und die Intel-Zentrale
function Spy.List(mode, filter)
    local out, now = {}, GetTime()
    filter = filter and filter ~= "" and filter:lower() or nil
    for key, c in pairs(contacts) do
        local age = nearby[key] and (now - nearby[key])
        local include
        if mode == "nah" then include = age and age <= NEARBY_SECONDS
        elseif mode == "kos" then include = c.kos
        elseif mode == "auftraege" then include = c.contract ~= nil
        elseif mode == "nemesis" then include = (c.losses or 0) > 0
        elseif mode == "opfer" then include = (c.wins or 0) > 0
        elseif mode == "fehde" then include = IsFeud(c.guild)
        elseif mode == "gemerkt" then include = c.saved or (c.log and #c.log > 0) or c.shared ~= nil or false
        else include = true end
        if include and filter and not c.name:lower():find(filter, 1, true) and not (c.guild or ""):lower():find(filter, 1, true) then
            include = false
        end
        if include then
            table.insert(out, { key = key, c = c, score = Spy.Threat(key, c), age = age })
        end
    end
    local sorters = {
        nah = function(a, b) if a.score ~= b.score then return a.score > b.score end return a.age < b.age end,
        nemesis = function(a, b) return (a.c.losses or 0) > (b.c.losses or 0) end,
        opfer = function(a, b) return (a.c.wins or 0) > (b.c.wins or 0) end,
        fehde = function(a, b)
            if a.c.guild ~= b.c.guild then return (a.c.guild or "") < (b.c.guild or "") end
            return (a.c.last or 0) > (b.c.last or 0)
        end,
    }
    table.sort(out, sorters[mode] or function(a, b) return (a.c.last or 0) > (b.c.last or 0) end)
    return out
end

function Spy.NearbyCount()
    local n, top, now = 0, 0, GetTime()
    for key, t in pairs(nearby) do
        if now - t <= NEARBY_SECONDS and contacts[key] then
            n = n + 1
            top = math.max(top, Spy.Threat(key, contacts[key]))
        end
    end
    return n, top
end

-- Jagd-Radar: Wo waren in den letzten Minuten Feinde? Eigene Sichtungen und Meldungen der Gilde.
-- Ergebnis: { { zone, n, kos, newest, subs = { [Teilgebiet] = n } }, ... } nach Anzahl
function Spy.Radar(minutes)
    local cutoff = time() - (minutes or 30) * 60
    local byZone = {}
    for _, c in pairs(contacts or {}) do
        local t, zone, sub = c.last, c.zone, c.sub
        if c.reported and c.reported > (t or 0) then t, zone, sub = c.reported, c.reportZone, nil end
        if t and t >= cutoff and zone and zone ~= "" then
            local z = byZone[zone]
            if not z then
                z = { zone = zone, n = 0, kos = 0, newest = 0, subs = {} }
                byZone[zone] = z
            end
            z.n = z.n + 1
            if c.kos or (c.contract and not c.contract.done) then z.kos = z.kos + 1 end
            z.newest = math.max(z.newest, t)
            if sub and sub ~= "" and sub ~= zone then z.subs[sub] = (z.subs[sub] or 0) + 1 end
        end
    end
    local out = {}
    for _, z in pairs(byZone) do
        local best, bestN = nil, 0
        for s, k in pairs(z.subs) do if k > bestN then best, bestN = s, k end end
        z.hot = best
        out[#out + 1] = z
    end
    table.sort(out, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.newest > b.newest end)
    return out
end

---------------------------------------------------------------------------
-- Erkennung
---------------------------------------------------------------------------

-- Übermacht: mehrere Feinde gerade gleichzeitig in Sicht, dazu wie viele von uns in der Nähe sind
local OUTNUMBER_VISIBLE = 8   -- Sekunden: so frisch muss eine Sichtung sein, um "gerade in Sicht" zu zählen
local outnumbered = { t = -999, n = 0 }

local function Allies()
    local n = 1
    local seen = {}
    if ns.Rudel and ns.Karte then
        for name, p in pairs(ns.Rudel.pack) do
            local d = p.map and ns.Karte.Offset(p.map, p.x, p.y)
            if d and d <= 150 and GetTime() - (p.t or 0) <= 60 then n = n + 1; seen[(ns.ShortName(name) or name):lower()] = true end
        end
    end
    local raid = IsInRaid and IsInRaid()
    for i = 1, raid and (GetNumGroupMembers and GetNumGroupMembers() or 0) or 4 do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        local name = ns.Safe(UnitExists(unit)) and ns.ShortName(ns.Safe(UnitName(unit)))
        if name and not seen[name:lower()] and name ~= playerName then
            local inRange = UnitInRange and ns.Safe(UnitInRange(unit))
            if inRange then n = n + 1 end
        end
    end
    return n
end

local function CheckOutnumbered()
    local need = S.outnumber or 3
    if need <= 0 then return end
    local now, n, guilds = GetTime(), 0, {}
    for key, t in pairs(nearby) do
        local o = contacts[key]
        if o and now - t <= OUTNUMBER_VISIBLE then
            n = n + 1
            local g = o.guild or "ohne Gilde"
            guilds[g] = (guilds[g] or 0) + 1
        end
    end
    if n < need then return end
    -- nicht dauernd: erst nach einer Minute wieder, oder sofort, wenn es deutlich mehr werden
    if now - outnumbered.t < 60 and n < outnumbered.n + 2 then return end
    outnumbered.t, outnumbered.n = now, n
    local parts = {}
    for g, k in pairs(guilds) do parts[#parts + 1] = { g = g, k = k } end
    table.sort(parts, function(a, b) return a.k > b.k end)
    local lines = {}
    for i, p in ipairs(parts) do
        if i <= 3 then lines[#lines + 1] = p.k .. (p.g == "ohne Gilde" and " ohne Gilde" or (" <" .. p.g .. ">")) end
    end
    local allies = Allies()
    local text = string.format("ÜBERMACHT: %d Feinde in Sicht – ihr seid %d", n, allies)
    if ns.UI then ns.UI.Alert(text, true) end
    Print(string.format("|cffff2020%s|r (%s)", text, table.concat(lines, ", ")))
    PlayAlert("outnumber")
    return true
end
Spy.CheckOutnumbered = CheckOutnumbered

-- Aufmarsch: 3 oder mehr Feinde derselben Gilde gleichzeitig in der Nähe
-- Aufmarsch (eine Gilde) hat Vorrang, sonst Übermacht (alle Feinde in Sicht)
local function CheckMuster(c)
    local now = GetTime()
    if c.guild then
        local n = 0
        for key, t in pairs(nearby) do
            local o = contacts[key]
            if o and o.guild == c.guild and now - t <= NEARBY_SECONDS then n = n + 1 end
        end
        if n >= 3 and not (mustered[c.guild] and now - mustered[c.guild] < 300) then
            mustered[c.guild] = now
            local text = string.format("%s: %d× <%s> in der Nähe! Ihr seid %d.", IsFeud(c.guild) and "FEHDE" or "Aufmarsch", n, c.guild, Allies())
            if ns.UI then ns.UI.Alert(text, true) end
            Print("|cffff2020" .. text .. "|r")
            PlayAlert("outnumber")
            outnumbered.t, outnumbered.n = now, math.max(outnumbered.n, n)
            return
        end
    end
    CheckOutnumbered()
end

local function OnNewContact(key, c)
    local score = Spy.Threat(key, c)
    local feud = IsFeud(c.guild)
    local important = c.kos or (c.contract and not c.contract.done) or score >= 70 or feud
    if ns.UI then ns.UI.OnContact(key, c, score) end
    if S.guildSync and (important or (S.sightShare and not Spy.Calm())) then Spy.Report(key, c, important) end
    if ns.Jagd then pcall(ns.Jagd.OnSighting, key, c, important) end -- Wachposten meldet sofort

    if Muted() then return end
    local calm = Spy.Calm()
    if not calm then CheckMuster(c) end
    local now = GetTime()
    if alerted[key] and now - alerted[key] < REALERT_SECONDS then return end
    alerted[key] = now
    local _, instanceType = IsInInstance()
    if not important and (calm or (S.quietResting and IsResting()) or instanceType == "pvp" or instanceType == "arena") then return end

    if important then
        local why = c.contract and not c.contract.done and "AUFTRAG" or c.kos and "KOS" or feud and "FEHDE" or "Tödlich"
        local lvl = c.level and (c.level > 0 and c.level or "??") or "?"
        if ns.UI then ns.UI.Alert(string.format("%s: %s (Stufe %s) in der Nähe!", why, Colored(c), lvl), true) end
        Print(string.format("|cffff2020%s|r %s gesichtet – Stufe %s%s", why, Colored(c), lvl, c.guild and (" <" .. c.guild .. ">") or ""))
        PlayAlert("kos")
    else
        PlayAlert("new")
    end
end

function Spy.Sight(unit)
    if not contacts or not S.spy then return end
    local Safe = ns.Safe
    if not Safe(UnitExists(unit)) or not Safe(UnitIsPlayer(unit)) or Safe(UnitIsUnit(unit, "player")) then return end
    if not (Safe(UnitIsEnemy("player", unit)) or Safe(UnitCanAttack("player", unit))) then return end
    local name, realm = UnitName(unit)
    name, realm = Safe(name), Safe(realm)
    if not name or name == "" or name == UNKNOWNOBJECT then return end

    local c, key = GetContact(name, realm, true)
    local _, classToken = UnitClass(unit)
    c.class = Safe(classToken) or c.class
    c.race = Safe(UnitRace(unit)) or c.race
    local lv = Safe(UnitLevel(unit))
    if lv and lv > 0 then c.level = lv elseif lv == -1 and not (c.level and c.level > 0) then c.level = -1 end
    c.guild = Safe(GetGuildInfo(unit)) or c.guild
    c.last = time()
    c.zone, c.sub = GetRealZoneText(), GetSubZoneText()
    local me = ns.Karte and ns.Karte.me
    if me and me.map then c.map, c.x, c.y = me.map, me.x, me.y end
    if UnitIsDeadOrGhost and Safe(UnitIsDeadOrGhost(unit)) then return end -- Leichen lösen keinen Alarm aus
    if Safe(UnitExists(unit .. "target")) and Safe(UnitIsUnit(unit .. "target", "player")) then attacked[key] = GetTime() end

    local now = GetTime()
    local isNew = not nearby[key] or now - nearby[key] > NEARBY_SECONDS
    nearby[key] = now
    if isNew then
        c.seen = (c.seen or 0) + 1
        OnNewContact(key, c)
    end
    Spy.dirty = true
end

-- Sichtung nur aus dem Kampflog (kein Unit-Token, daher ohne Stufe/Gilde)
local function SightGUID(guid, fullName)
    if not guid or not fullName or not guid:find("^Player") then return end
    local _, classToken, raceName, _, _, name, realm
    if GetPlayerInfoByGUID then _, classToken, raceName, _, _, name, realm = GetPlayerInfoByGUID(guid) end
    name = name or ns.ShortName(fullName)
    realm = (realm and realm ~= "") and realm or fullName:match("%-(.+)$")
    local c, key = GetContact(name, realm, true)
    c.class, c.race = classToken or c.class, raceName or c.race
    c.last = time()
    c.zone, c.sub = GetRealZoneText(), GetSubZoneText()
    local me = ns.Karte and ns.Karte.me
    if me and me.map then c.map, c.x, c.y = me.map, me.x, me.y end
    local now = GetTime()
    local isNew = not nearby[key] or now - nearby[key] > NEARBY_SECONDS
    nearby[key] = now
    if isNew then
        c.seen = (c.seen or 0) + 1
        OnNewContact(key, c)
    end
    Spy.dirty = true
    return c, key
end

function Spy.OnCombatLog(sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, spellName)
    if not contacts or not S.spy then return end
    local me = UnitGUID("player")
    local hostileSrc = band(srcFlags or 0, TYPE_PLAYER) > 0 and band(srcFlags or 0, REACTION_HOSTILE) > 0
    local hostileDst = band(dstFlags or 0, TYPE_PLAYER) > 0 and band(dstFlags or 0, REACTION_HOSTILE) > 0
    if hostileSrc then
        local c, key = SightGUID(srcGUID, srcName)
        if key and dstGUID == me then attacked[key] = GetTime() end
        if c and spellName and stealthSpells[spellName] and (sub == "SPELL_AURA_APPLIED" or sub == "SPELL_CAST_SUCCESS") then
            if not Muted() and not Spy.Calm() then
                if ns.UI then ns.UI.Alert(string.format("%s ist in die Schatten getreten!", Colored(c)), true) end
                PlayAlert("stealth")
            end
        end
    end
    if hostileDst then SightGUID(dstGUID, dstName) end
end

-- Ohne Kampflog: wer hatte mich im Ziel, als ich gestorben bin?
function Spy.GuessKiller()
    local units = { "target", "mouseover" }
    for i = 1, 40 do units[#units + 1] = "nameplate" .. i end
    local Safe = ns.Safe
    for _, unit in ipairs(units) do
        if Safe(UnitExists(unit)) and Safe(UnitIsPlayer(unit)) and Safe(UnitIsEnemy("player", unit))
            and Safe(UnitExists(unit .. "target")) and Safe(UnitIsUnit(unit .. "target", "player")) then
            local name, realm = UnitName(unit)
            name = Safe(name)
            if name then
                local _, classToken = UnitClass(unit)
                return { name = name, realm = Safe(realm), class = Safe(classToken), level = Safe(UnitLevel(unit)), guild = Safe(GetGuildInfo(unit)) }
            end
        end
    end
    local bestKey, bestT
    for key, t in pairs(attacked) do
        if GetTime() - t < 10 and (not bestT or t > bestT) then bestKey, bestT = key, t end
    end
    local c = bestKey and contacts[bestKey]
    if c then return { name = c.name, realm = c.realm, class = c.class, level = c.level, guild = c.guild } end
end

---------------------------------------------------------------------------
-- Kills, Tode, KOS, Aufträge
---------------------------------------------------------------------------

function Spy.OnKill(rec)
    if not contacts or rec.victim == "?" then return end
    local c = GetContact(rec.victim, rec.victimRealm, true)
    -- Rache: er hat mich vor kurzem getötet · Gildenrache: er hat vor kurzem ein Mitglied getötet
    if c.lastLoss and rec.t - c.lastLoss <= REVENGE_SECONDS and c.lastLoss > (c.lastWin or 0) then rec.revenge = true end
    local gl = c.guildLoss
    if gl and rec.t - (gl.t or 0) <= REVENGE_SECONDS and gl.who ~= playerName then rec.avenged = gl.who end
    c.guildLoss = nil
    c.class, c.race = rec.class or c.class, rec.race or c.race
    if rec.level and rec.level ~= 0 then c.level = rec.level end
    c.guild = rec.guild or c.guild
    c.wins = (c.wins or 0) + 1
    c.lastWin, c.last = rec.t, rec.t
    local ct = c.contract
    if ct and not ct.done then
        rec.contract = ct.by
        if ct.id then
            -- Kontor-Auftrag: der Vermittler zählt die Kills und schließt den Auftrag
            rec.contractId = ct.id
            ct.myKills = (ct.myKills or 0) + 1
            Print(string.format("|cff00ff00Auftragskill gemeldet:|r %s (Auftrag #%s).", Colored(c), ct.id))
            if S.guildSync then Spy.Send("X", c.name, c.realm, ct.id, rec.id) end
            if ns.Kontor then ns.Kontor.OnContractKill(ct.id, playerName, rec.id) end
        else
            ct.done, ct.doneBy = rec.t, playerName
            Print(string.format("|cff00ff00Auftrag erfüllt:|r %s ist erledigt.", Colored(c)))
            if S.guildSync then Spy.Send("X", c.name, c.realm) end
        end
    end
    Spy.dirty = true
end

function Spy.OnDeath(rec)
    if not contacts or not rec.pvp or not rec.killer then return end
    local name, realm = ns.ShortName(rec.killer), rec.killer:match("%-(.+)$")
    local c = GetContact(name, realm, true)
    c.class = rec.class or c.class
    if rec.level and rec.level ~= 0 then c.level = rec.level end
    c.guild = rec.guild or c.guild
    c.losses = (c.losses or 0) + 1
    c.lastLoss = rec.t
    Print(string.format("Gefallen durch %s%s – deine Bilanz gegen %s: |cff00ff00%d|r : |cffff4040%d|r.%s",
        Colored(c), rec.guess and " (vermutlich)" or "", c.name, c.wins or 0, c.losses,
        c.kos and "" or " |cffaaaaaa/assa kos " .. c.name .. "|r"))
    if S.autoKos and not c.kos and c.losses >= 3 then
        c.kos, c.kosReason = true, "3 Niederlagen"
        Print(Colored(c) .. " steht jetzt auf deiner KOS-Liste.")
    end
    Spy.dirty = true
end

function Spy.SetKos(c, on, reason)
    c.kos = on and true or nil
    c.kosReason = on and reason ~= "" and reason or nil
    Print(Colored(c) .. (on and " auf die KOS-Liste gesetzt." or " von der KOS-Liste entfernt."))
    Spy.dirty = true
end

function Spy.SetContract(c, reason)
    c.contract = { by = playerName, t = time(), reason = reason ~= "" and reason or nil }
    c.kos = true
    Print(string.format("Auftrag erteilt: %s%s", Colored(c), reason ~= "" and (" – " .. reason) or ""))
    if S.guildSync then Spy.Send("A", c.name, c.realm, reason or "") end
    Spy.dirty = true
end

function Spy.Forget(key)
    contacts[key], nearby[key], attacked[key] = nil, nil, nil
    Spy.dirty = true
end

---------------------------------------------------------------------------
-- Gildensync über Addon-Nachrichten
---------------------------------------------------------------------------

function Spy.Send(kind, ...)
    if not IsInGuild() or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    local parts = { kind }
    for i = 1, select("#", ...) do
        local v = ns.Safe((select(i, ...)))
        parts[#parts + 1] = tostring(v == nil and "" or v):gsub("\t", " ")
    end
    local msg = table.concat(parts, "\t"):sub(1, 250)
    if kind == "S" then
        table.insert(sendQueue, msg)
    else
        -- Aufträge und Kills vor gewöhnliche Sichtungen
        local pos = 1
        while sendQueue[pos] and sendQueue[pos]:sub(1, 2) ~= "S\t" do pos = pos + 1 end
        table.insert(sendQueue, pos, msg)
    end
end

function Spy.Report(key, c, important)
    local now = GetTime()
    if reported[key] and now - reported[key] < REPORT_SECONDS then return end
    if not important and #sendQueue >= 6 then return end -- viel los: nur Wichtiges melden
    reported[key] = now
    local m, x, y = "", "", ""
    if ns.Karte and c.map then m, x, y = ns.Karte.Pack(c.map, c.x, c.y) end
    Spy.Send("S", c.name, c.realm, c.class, c.level, c.guild, c.zone, c.sub, c.kos and 1 or 0,
        (c.contract and not c.contract.done) and 1 or 0, m, x, y)
end

-- Feinde mit bekannter Position (eigene Sichtung oder Meldung aus der Gilde) für die Jagdkarte
function Spy.MapContacts(maxAge)
    local out, now = {}, time()
    if not contacts then return out end
    for key, c in pairs(contacts) do
        local own = c.map and c.last and now - c.last <= maxAge
        local rep = c.reportMap and c.reported and now - c.reported <= maxAge
        local newest = math.max(own and c.last or 0, rep and c.reported or 0)
        if c.lastWin and c.lastWin >= newest - 10 then own, rep = false, false end -- gerade erst getötet
        if own and (not rep or c.last >= c.reported) then
            out[#out + 1] = { key = key, c = c, map = c.map, x = c.x, y = c.y, age = now - c.last }
        elseif rep then
            out[#out + 1] = { key = key, c = c, map = c.reportMap, x = c.reportX, y = c.reportY, age = now - c.reported, by = c.reportBy }
        end
    end
    return out
end

local function Split(msg)
    local out = {}
    for field in (msg .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = field end
    return out
end

local function OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= MSG_PREFIX or not S.guildSync or not contacts then return end
    sender = ns.ShortName(sender)
    if ns.IsMe(sender) then return end
    local f = Split(msg)
    local kind, name, realm = f[1], f[2], f[3]
    if not name or name == "" then return end
    local c = GetContact(name, realm, true)

    if kind == "S" then
        c.class = f[4] ~= "" and f[4] or c.class
        local lv = tonumber(f[5]); if lv and lv ~= 0 then c.level = lv end
        c.guild = f[6] ~= "" and f[6] or c.guild
        c.reported, c.reportBy, c.reportZone = time(), sender, f[7]
        local map, x, y
        if ns.Karte then map, x, y = ns.Karte.Unpack(f[11], f[12], f[13]) end
        c.reportMap, c.reportX, c.reportY = map, x, y
        if f[9] == "1" or f[10] == "1" or IsFeud(c.guild) then
            if not Muted() then
                Print(string.format("%s meldet %s in |cffffd100%s|r%s", sender, Colored(c), f[7] or "?",
                    (f[8] ~= "" and f[8] ~= f[7]) and (" (" .. f[8] .. ")") or ""))
                PlayAlert("kos")
            end
        end
    elseif kind == "A" then
        -- A Name Realm Grund [ID Kills PrämieKupfer Zuteilung Klasse]
        local ct = { by = sender, t = time(), reason = f[4] ~= "" and f[4] or nil }
        if f[5] and f[5] ~= "" then
            ct.id, ct.count, ct.reward = f[5], tonumber(f[6]) or 1, tonumber(f[7]) or 0
            ct.assignee = (f[8] and f[8] ~= "") and f[8] or "alle"
            c.class = (f[9] and f[9] ~= "") and f[9] or c.class
        end
        c.contract = ct
        c.kos = true
        local forMe = ct.assignee and Spy.IsAssigned(ct.assignee, playerName)
        local reward = (ct.reward or 0) > 0 and string.format(" – Prämie %s pro Kill", Spy.Money(ct.reward)) or ""
        if ct.id and not forMe then
            Print(string.format("Auftrag #%s gegen %s wurde an |cffffd100%s|r vergeben.", ct.id, Colored(c), ct.assignee))
        else
            Print(string.format("|cffff2020%s|r von %s: %s%s%s", ct.id and "Dir wurde ein Auftrag erteilt" or "Neuer Gildenauftrag",
                sender, Colored(c), ct.reason and (" – " .. ct.reason) or "", reward))
            if ns.UI then ns.UI.Alert(string.format("Neuer Auftrag: %s%s", Colored(c), reward), true) end
            PlayAlert("order")
        end
    elseif kind == "X" then
        local id = f[4]
        if id and id ~= "" then
            if ns.Kontor then ns.Kontor.OnContractKill(id, sender, f[5]) end
            Print(string.format("%s hat %s erwischt (Auftrag #%s).", sender, Colored(c), id))
        elseif c.contract and not c.contract.done then
            c.contract.done, c.contract.doneBy = time(), sender
            Print(string.format("|cff00ff00Auftrag erfüllt|r durch %s: %s", sender, Colored(c)))
        end
    elseif kind == "Z" then
        -- Z Name Realm ID Status: Kontor-Auftrag abgeschlossen
        if c.contract and c.contract.id == f[4] and not c.contract.done then
            c.contract.done, c.contract.doneBy = time(), f[5] ~= "" and f[5] or "Kontor"
            Print(string.format("|cff00ff00Auftrag #%s abgeschlossen:|r %s", f[4], Colored(c)))
        end
    end
    Spy.dirty = true
end

---------------------------------------------------------------------------
-- Takt: Namensplaketten abfragen, Nachrichten senden, Fenster aktualisieren
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Reichweite: Der Späher sieht so weit wie die Namensplaketten. Deshalb Feind-Plaketten an und
-- die Plakettenreichweite auf das Maximum, das der Client annimmt. Die alten Werte bleiben gemerkt,
-- "/assa plaketten aus" stellt sie wieder her. Im Kampf sperrt das Spiel diese Einstellungen.
---------------------------------------------------------------------------

local PLATE_STEPS = { 41, 40, 35, 30, 25, 20 }
local plateWait

local function ReadCVar(k)
    local ok, v = pcall(GetCVar, k)
    return ok and v or nil
end

local function WriteCVar(k, v)
    return pcall(SetCVar, k, v)
end

local function Yards(y) return string.format("%d Yards (≈ %d m)", y, math.floor(y * 0.9144 + 0.5)) end

function Spy.PlateRange()
    return tonumber(ReadCVar("nameplateMaxDistance")), ReadCVar("nameplateShowEnemies") == "1"
end

function Spy.ApplyPlates(quiet)
    if not GetCVar or not SetCVar then return end
    if InCombatLockdown and InCombatLockdown() then
        if not plateWait then
            plateWait = CreateFrame("Frame")
            plateWait:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                if S.plateBoost then Spy.ApplyPlates(self.quiet) end
            end)
        end
        plateWait.quiet = quiet
        plateWait:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    local show, dist = ReadCVar("nameplateShowEnemies"), ReadCVar("nameplateMaxDistance")
    if not S.plateOrig then S.plateOrig = { show = show, dist = dist } end
    local changed = false
    if show ~= "1" then WriteCVar("nameplateShowEnemies", "1"); changed = true end
    local before = tonumber(dist)
    if before then
        -- Manche Clients lehnen zu große Werte ab statt sie zu kappen: von oben herantasten
        for _, y in ipairs(PLATE_STEPS) do
            if y <= before then break end
            WriteCVar("nameplateMaxDistance", tostring(y))
            local now = tonumber(ReadCVar("nameplateMaxDistance"))
            if now and now > before then break end
        end
    end
    local range = tonumber(ReadCVar("nameplateMaxDistance"))
    if range and before and range ~= before then changed = true end
    if changed or not quiet or (range and S.plateReported ~= range) then
        S.plateReported = range
        Print("Späher-Reichweite: Feind-Plaketten an" .. (range and (", " .. Yards(range)) or "") ..
            ((range and before and range == before and range < PLATE_STEPS[1]) and " – mehr erlaubt das Spiel nicht" or "") ..
            ". Zurückstellen: /assa plaketten aus")
    end
end

function Spy.RestorePlates()
    local o = S.plateOrig
    if not o then return end
    if InCombatLockdown and InCombatLockdown() then Print("Im Kampf lassen sich die Plaketten nicht umstellen – nach dem Kampf nochmal.") return false end
    if o.show then WriteCVar("nameplateShowEnemies", o.show) end
    if o.dist then WriteCVar("nameplateMaxDistance", o.dist) end
    S.plateOrig, S.plateReported = nil, nil
    local range = Spy.PlateRange()
    Print("Plaketten wieder wie vorher" .. (range and (" (" .. Yards(range) .. ")") or "") .. ".")
    return true
end

local tickCount = 0
function Spy.Tick()
    if S.spy then
        for i = 1, 40 do
            -- Ein Fehler bei einer Plakette darf den Rest des Takts (Senden, Fenster) nicht aufhalten
            pcall(Spy.Sight, "nameplate" .. i)
        end
    end
    if tickCount % 5 == 0 and ns.CheckHonorCounter then ns.CheckHonorCounter() end
    if #sendQueue > 0 and GetTime() - lastSend >= 1 then
        lastSend = GetTime()
        pcall(C_ChatInfo.SendAddonMessage, MSG_PREFIX, table.remove(sendQueue, 1), "GUILD")
    end
    tickCount = tickCount + 1
    if ns.UI and (Spy.dirty or tickCount % 3 == 0) then
        Spy.dirty = false
        ns.UI.Refresh()
    end
end

---------------------------------------------------------------------------
-- Slash-Befehle (werden aus /assa weitergereicht)
---------------------------------------------------------------------------

local function NameAndRest(raw)
    local name, rest = (raw or ""):match("^(%S+)%s*(.-)$")
    if name then name = name:sub(1, 1):upper() .. name:sub(2) end
    return name, rest or ""
end

function Spy.Slash(cmd, raw, arg)
    if cmd == "spy" or cmd == "späher" or cmd == "scanner" then
        if ns.UI then ns.UI.ToggleScanner() end
    elseif cmd == "intel" then
        if ns.UI then ns.UI.ToggleIntel() end
    elseif cmd == "akte" then
        local c, key = Spy.Find(raw)
        if not c then Print("Keine Akte zu \"" .. raw .. "\".") elseif ns.UI then ns.UI.OpenIntel(key) end
    elseif cmd == "kos" then
        local name, reason = NameAndRest(raw)
        if not name then Print("Benutzung: /assa kos <Name> [Grund]") return true end
        local c = Spy.Find(name) or GetContact(name, nil, true)
        Spy.SetKos(c, not c.kos, reason)
    elseif cmd == "merken" or cmd == "profil" then
        local name, reason = NameAndRest(raw)
        if not name then Print("Benutzung: /assa merken <Name> [warum er auf der Liste ist]") return true end
        local c, key = Spy.Find(name)
        if not c then c, key = GetContact(name, nil, true) end
        c.saved = true
        if reason and reason ~= "" then c.note = reason end
        Print(string.format("%s gemerkt. Profil: Intel-Zentrale, Reiter »Gemerkt«.", c.name))
        if ns.UI and key then ns.UI.OpenIntel(key) end
    elseif cmd == "teilen" then
        local name, to = NameAndRest(raw)
        local c = name and Spy.Find(name)
        if not c then Print("Benutzung: /assa teilen <Name> [Spieler]  (ohne Spieler: an die Gilde)") return true end
        if to and to ~= "" then Spy.ShareProfile(c, "WHISPER", to)
        else Spy.ShareProfile(c, IsInGuild() and "GUILD" or (ns.Rudel and ns.Rudel.GroupChannel())) end
    elseif cmd == "auftrag" then
        local name, reason = NameAndRest(raw)
        if not name then Print("Benutzung: /assa auftrag <Name> [Grund]") return true end
        Spy.SetContract(Spy.Find(name) or GetContact(name, nil, true), reason)
    elseif cmd == "ruhe" or cmd == "snooze" then
        if arg == "aus" or arg == "off" then
            S.snoozeUntil = nil
            Print("Warnungen wieder aktiv.")
        else
            local min = tonumber(arg) or 15
            S.snoozeUntil = time() + min * 60
            Print(string.format("Warnungen für %d Minuten stumm.", min))
        end
    elseif cmd == "töne" or cmd == "toene" or cmd == "sound" or cmd == "sounds" then
        if arg == "an" or arg == "aus" then
            Print("Töne: " .. ns.OnOff(ns.Toggle("spySound", arg)))
            if ns.Toene then ns.Toene.Refresh() end
        elseif ns.Toene then
            ns.Toene.Toggle()
        end
    elseif cmd == "sync" then
        Print("Gildensync (Sichtungen & Aufträge): " .. ns.OnOff(ns.Toggle("guildSync", arg)))
    elseif cmd == "autokos" then
        Print("Automatisch KOS nach 3 Niederlagen: " .. ns.OnOff(ns.Toggle("autoKos", arg)))
    elseif cmd == "auto" then
        Print("Späher öffnet sich bei neuen Feinden: " .. ns.OnOff(ns.Toggle("spyAuto", arg)))
    elseif cmd == "stadt" then
        Print("Ruhig in Städten (nur KOS/Aufträge): " .. ns.OnOff(ns.Toggle("quietResting", arg)))
    elseif cmd == "neutral" then
        if arg == "hier" then
            local z = GetSubZoneText and GetSubZoneText() or ""
            if z == "" then z = GetRealZoneText and GetRealZoneText() or "" end
            if z == "" then Print("Kein Ortsname gefunden.") return true end
            S.neutralOwn = S.neutralOwn or {}
            local k = z:lower()
            if S.neutralOwn[k] then S.neutralOwn[k] = nil; Print(string.format("„%s“ ist nicht mehr als neutrale Stadt eingetragen.", z))
            else S.neutralOwn[k] = true; Print(string.format("„%s“ zählt jetzt als neutrale Stadt.", z)) end
        else
            Print("Ruhe in neutralen Städten wie Beutebucht oder Gadgetzan (nur KOS/Aufträge/Fehden): "
                .. ns.OnOff(ns.Toggle("neutralQuiet", arg)))
            local here, name = Spy.InNeutralTown()
            Print(here and string.format("Du bist gerade in einer neutralen Stadt%s.", name and (" (" .. name .. ")") or "")
                or "Hier ist keine neutrale Stadt. Fehlt ein Ort? Dort /assa neutral hier eingeben.")
        end
    elseif cmd == "zeilen" then
        local n = tonumber(arg)
        if n and n >= 3 and n <= 25 then S.rows = n end
        Print("Zeilen im Späher: " .. S.rows)
        if ns.UI then ns.UI.Refresh() end
    elseif cmd == "minimap" then
        Print("Minimap-Knopf: " .. ns.OnOff(ns.Toggle("minimap", arg)))
        if ns.UI then ns.UI.UpdateMinimap() end
    elseif cmd == "uebermacht" or cmd == "übermacht" then
        local n = tonumber(arg)
        if arg == "aus" then S.outnumber = 0 elseif arg == "an" then S.outnumber = 3 elseif n and n >= 2 and n <= 15 then S.outnumber = math.floor(n) end
        Print(S.outnumber > 0 and string.format("Übermacht-Warnung ab %d Feinden gleichzeitig. (/assa uebermacht <Zahl>|aus)", S.outnumber)
            or "Übermacht-Warnung aus. (/assa uebermacht an)")
    elseif cmd == "plaketten" or cmd == "reichweite" then
        if arg == "an" or arg == "aus" then
            if arg == "aus" then
                if Spy.RestorePlates() ~= false then S.plateBoost = false end
            else
                S.plateBoost = true
                Spy.ApplyPlates(false)
            end
        else
            local range, show = Spy.PlateRange()
            Print(string.format("Späher-Reichweite: %s, Feind-Plaketten %s. Automatisch aufs Maximum: %s (/assa plaketten an|aus)",
                range and Yards(range) or "unbekannt", show and "an" or "|cffff4040aus|r", ns.OnOff(S.plateBoost)))
        end
    elseif cmd == "erkennung" then
        Print("Feinderkennung: " .. ns.OnOff(ns.Toggle("spy", arg)))
    else
        return (ns.Rudel and ns.Rudel.Slash(cmd, raw, arg)) or (ns.Kontor and ns.Kontor.Slash(cmd, raw, arg)) or false
    end
    return true
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------

function Spy.Init()
    S = ns.settings
    ns.db.intel = ns.db.intel or {}
    intel = ns.db.intel
    intel.contacts = intel.contacts or {}
    contacts = intel.contacts
    playerName = ns.PlayerName()
    ns.WatchSelfName(function(n) playerName = n end)

    -- Alte, unwichtige Kontakte aufräumen
    local cutoff = time() - KEEP_DAYS * 86400
    for key, c in pairs(contacts) do
        if (c.last or 0) < cutoff and not c.kos and not c.note and not c.contract and not c.saved and not c.log and not c.shared
            and (c.wins or 0) == 0 and (c.losses or 0) == 0 then
            contacts[key] = nil
        end
    end

    -- Tarnfähigkeiten (lokalisiert) für den Schatten-Alarm – nur mit Kampflog
    local getName = (C_Spell and C_Spell.GetSpellName) or function(id) return (GetSpellInfo(id)) end
    for _, id in ipairs({ 1784, 1856, 5215, 20580 }) do -- Verstohlenheit, Verschwinden, Schleichen, Schattenmimik
        local ok, n = pcall(getName, id)
        if ok and n then stealthSpells[n] = true end
    end

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(MSG_PREFIX)
    end
    local events = CreateFrame("Frame")
    events:RegisterEvent("CHAT_MSG_ADDON")
    events:SetScript("OnEvent", function(_, _, ...) OnAddonMessage(...) end)

    if ns.UI then ns.UI.Init() end
    if ns.Toene then ns.Toene.Init() end
    if ns.Karte then ns.Karte.Init() end
    if ns.Rudel then ns.Rudel.Init() end
    if ns.Ziele then ns.Ziele.Init() end
    if ns.Jagd then ns.Jagd.Init() end
    if ns.Kontor then ns.Kontor.Init() end
    if ns.Alarm then ns.Alarm.Init() end
    if ns.Bilanz then ns.Bilanz.Init() end
    if ns.Version then ns.Version.Init() end
    if ns.Leiste then ns.Leiste.Init() end
    Spy.InitSharing()
    if S.plateBoost then pcall(Spy.ApplyPlates, true) end
    C_Timer.NewTicker(1, Spy.Tick)
end
