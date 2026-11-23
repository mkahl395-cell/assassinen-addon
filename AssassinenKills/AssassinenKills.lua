-- Assassinen Kill-Tracker – Kern
-- Nur PvP: Zeichnet Kills an Spielern, Tode durch Spieler und einen Screenshot pro Kill auf.
-- Die Daten landen in den SavedVariables (WTF\Account\<KONTO>\SavedVariables\AssassinenKills.lua)
-- und werden vom Uploader auf der Gilden-Webseite hochgeladen.
--
-- Kill-Erkennung:
--   1. Kampflog (PARTY_KILL = eigener Todesstoß) – sofern der Client es Addons erlaubt
--   2. Chatmeldung "ehrenhafter Sieg" – funktioniert auch in WoW Forever, wo das Kampflog gesperrt ist

local ADDON_NAME, ns = ...
local DB_VERSION = 1
local PREFIX = "|cffc41e3a[Assassinen]|r "

local defaults = {
    screenshots = true,  -- Screenshot bei jedem Spieler-Kill
    delay = 0.4,         -- Sekunden nach dem Kill, bevor der Screenshot gemacht wird
    announce = false,    -- Kill im Gildenchat ansagen
    chat = true,         -- Kill im eigenen Chatfenster anzeigen
    -- Späher
    spy = true,          -- Gegnererkennung an
    spyAuto = true,      -- Späher-Fenster öffnet sich bei neuen Feinden
    spySound = true,     -- Töne bei Feinden
    quietResting = true, -- in Städten/Gasthäusern nur bei KOS/Aufträgen warnen
    neutralQuiet = true, -- in neutralen Städten (Beutebucht, Gadgetzan …) nur bei KOS/Aufträgen/Fehden warnen
    guildSync = true,    -- Sichtungen und Aufträge mit der Gilde teilen
    autoKos = false,     -- nach 3 Niederlagen gegen jemanden automatisch KOS
    rows = 10,           -- Zeilen im Späher-Fenster
    minimap = true,      -- Minimap-Knopf anzeigen
    -- Rudel
    huntMap = true,      -- Jagdkarte: eigene Position teilen, Rudel + Feinde auf der Karte
    sightShare = true,   -- jede Feindsichtung (nicht nur KOS) an die Gilde melden
    helpAlerts = true,   -- Hilferufe anderer anzeigen
    autoHelp = true,     -- automatisch um Hilfe rufen (unter 50 % Leben, Feind im Nacken)
    feed = true,         -- Kills und Tode der Gilde im Chat
    poisonWarn = true,   -- Giftwächter
    layerHop = true,     -- Layerwechsel: Helfer automatisch in die Gruppe holen bzw. Einladung annehmen
    arrow = true,        -- Pfeil zu Hilferuf, Sammelpunkt und angesagtem Ziel
    aimAlarm = true,     -- Warnung, wenn ein Feind dich ins Ziel nimmt
    stealthAlarm = true, -- feindlicher Schurke/Druide verschwindet neben dir
    outnumber = 3,       -- Übermacht-Warnung ab so vielen Feinden gleichzeitig (0 = aus)
    autoJoin = true,     -- Rudel-Einladungen von Mitgliedern automatisch annehmen
    plateBoost = true,   -- Feind-Plaketten an und Reichweite aufs Maximum (größere Späher-Reichweite)
    design = "buch",     -- Aussehen der Fenster: "buch" (Pergament und Leder) oder "dunkel"
    killCard = true,     -- Steckbrief in der Bildschirmmitte bei jedem Kill
}

local band = bit.band
local TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x00000400
local CONTROL_PLAYER = COMBATLOG_OBJECT_CONTROL_PLAYER or 0x00000100

local frame = CreateFrame("Frame")
local db, settings, char
local playerGUID

local unitCache = {}     -- guid -> { name, level, guild, class, race, t }  (zuletzt gesehene Spieler)
local nameToGuid = {}    -- Name -> guid (für Kills, die nur per Chatmeldung erkannt werden)
local lastHit = {}       -- guid -> { spell, t }  (letzter eigener Treffer auf ein Ziel)
local lastHitOnMe        -- { name, guid, flags, spell, env, t }  (letzter Treffer auf mich)
local recentKills = {}   -- Kurzname -> GetTime() (verhindert Doppelzählung Kampflog + Ehrenmeldung)
local cacheWrites = 0
local lastEnemyTarget    -- { guid, name, t }  (letztes feindliches Ziel, für die Zähler-Erkennung)
local honorBase          -- Stand des Ehrenzählers beim Einloggen
local honorCredited = 0  -- seither schon erfasste Kills
local honorCheckPending = false

local pendingShot        -- Kill-Einträge, die auf den nächsten Screenshot warten
local lastShotAt, lastShotStamp = 0, nil

local function Print(text)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

local function ClassColor(classToken)
    local c = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if not c then return "ffffffff" end
    if c.colorStr then return c.colorStr end
    return string.format("ff%02x%02x%02x", math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255))
end

local function Round(v, digits)
    local m = 10 ^ (digits or 0)
    return math.floor(v * m + 0.5) / m
end

local function ShortName(name)
    return name and (name:match("^([^%-]+)") or name)
end

ns.Print, ns.ClassColor, ns.ShortName = Print, ClassColor, ShortName
ns.Sound = function() end -- wird von Toene.lua ersetzt (Ton-Zentrale)

-- Eigener Name. In WoW Forever haben Figuren Vor- und Nachnamen: UnitName("player") liefert nur den Vornamen,
-- Addon-Nachrichten kommen aber mit vollem Namen an ("Vorname Nachname"). Den vollen Namen lernt das Addon,
-- indem es sich selbst eine Nachricht schickt und schaut, unter welchem Namen sie ankommt.
-- Ohne Angleichen stünde man doppelt in der Rangliste und hielte die eigenen Nachrichten für fremde.
local selfFull
local selfWatchers = {}

local function BaseName()
    local ok, name = pcall(UnitName, "player")
    return ShortName(ok and type(name) == "string" and name or nil) or "?"
end

function ns.PlayerName()
    return selfFull or BaseName()
end

function ns.IsMe(name)
    if type(name) ~= "string" then return false end
    local n = (ShortName(name) or name):lower()
    return n == BaseName():lower() or (selfFull ~= nil and n == selfFull:lower())
end

-- Module, die sich den eigenen Namen merken, bekommen den vollen Namen nachgereicht
function ns.WatchSelfName(fn)
    selfWatchers[#selfWatchers + 1] = fn
end

function ns.LearnSelfName(name)
    name = ShortName(name)
    if not name or name == selfFull then return end
    local base = BaseName():lower()
    local low = name:lower()
    if low ~= base and low:sub(1, #base + 1) ~= base .. " " then return end -- muss mit dem eigenen Vornamen beginnen
    selfFull = name
    if ns.char then ns.char.fullName = name end
    for _, fn in ipairs(selfWatchers) do pcall(fn, name) end
end

-- WoW Forever verbirgt manche Werte ("Secret Values"): Rechnen, Vergleichen oder Anhängen
-- löst einen Lua-Fehler aus. Safe liefert stattdessen nil.
local function Safe(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end
ns.Safe = Safe

---------------------------------------------------------------------------
-- Datenbank
---------------------------------------------------------------------------

local function InitDB()
    AssassinenKillsDB = AssassinenKillsDB or {}
    db = AssassinenKillsDB
    db.version = DB_VERSION
    db.chars = db.chars or {}
    db.settings = db.settings or {}
    settings = db.settings
    for k, v in pairs(defaults) do
        if settings[k] == nil then settings[k] = v end
    end

    local name, realm = UnitName("player"), GetRealmName()
    local key = name .. "-" .. realm
    db.chars[key] = db.chars[key] or { kills = {}, deaths = {} }
    -- Ältere Versionen haben auch NPC-Kills und Tode ohne Spielerbeteiligung gespeichert
    for _, c in pairs(db.chars) do
        c.npc, c.npcKills = nil, nil
        local pvp = {}
        for _, d in ipairs(c.deaths or {}) do
            if d.pvp then pvp[#pvp + 1] = d end
        end
        c.deaths = pvp
    end
    char = db.chars[key]
    char.name, char.realm = name, realm
    ns.db, ns.settings, ns.char = db, settings, char
end

local function UpdateProfile()
    if not char then return end
    local _, classToken = UnitClass("player")
    local raceName, raceToken = UnitRace("player")
    char.class = classToken
    char.race, char.raceToken = raceName, raceToken
    char.level = UnitLevel("player")
    char.faction = UnitFactionGroup("player")
    char.sex = UnitSex("player")
    local guild, rank = GetGuildInfo("player")
    if guild then char.guild, char.guildRank = guild, rank end
    if GetPVPLifetimeStats then
        local ok, hk, dk, highestRank = pcall(GetPVPLifetimeStats)
        if ok and hk then
            char.honorKills, char.dishonorKills, char.highestRank = hk, dk, highestRank
        end
    end
    char.updated = time()
    char.addonVersion = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
end

---------------------------------------------------------------------------
-- Spieler-Cache (Level & Gilde stehen nicht im Kampflog)
---------------------------------------------------------------------------

local function CacheUnit(unit)
    if not unit or not Safe(UnitExists(unit)) or not Safe(UnitIsPlayer(unit)) then return end
    local guid = Safe(UnitGUID(unit))
    if guid == playerGUID and guid then return end
    local name = Safe(UnitName(unit))
    if unit == "target" and name and (Safe(UnitIsEnemy("player", unit)) or Safe(UnitCanAttack("player", unit))) then
        lastEnemyTarget = { guid = guid, name = name, t = GetTime() }
    end
    if guid then
        local _, classToken = UnitClass(unit)
        unitCache[guid] = {
            name = name,
            level = Safe(UnitLevel(unit)),
            guild = Safe(GetGuildInfo(unit)),
            class = Safe(classToken),
            race = Safe(UnitRace(unit)),
            t = GetTime(),
        }
        if name then nameToGuid[name] = guid end
    end
    if ns.Spy then ns.Spy.Sight(unit) end

    cacheWrites = cacheWrites + 1
    if cacheWrites > 300 then
        cacheWrites = 0
        local now = GetTime()
        for g, info in pairs(unitCache) do
            if now - info.t > 900 then
                unitCache[g] = nil
                if info.name and nameToGuid[info.name] == g then nameToGuid[info.name] = nil end
            end
        end
        for g, info in pairs(lastHit) do
            if now - info.t > 60 then lastHit[g] = nil end
        end
    end
end
ns.CacheUnit = CacheUnit

local function LookupUnit(guid)
    if not guid then return nil end
    for _, unit in ipairs({ "target", "mouseover", "focus", "targettarget" }) do
        if Safe(UnitExists(unit)) and Safe(UnitGUID(unit)) == guid then CacheUnit(unit) end
    end
    return unitCache[guid]
end

---------------------------------------------------------------------------
-- Screenshots
---------------------------------------------------------------------------

-- Merkt sich den Zeitstempel (MMDDYY_HHMMSS) des Screenshots. Daraus findet der
-- Uploader die Datei "WoWScrnShot_MMDDYY_HHMMSS.jpg" im Screenshots-Ordner.
local function QueueScreenshot(rec)
    if pendingShot then
        table.insert(pendingShot, rec)
        return
    end
    if lastShotStamp and GetTime() - lastShotAt < 1.5 then
        rec.shot = lastShotStamp
        return
    end
    pendingShot = { rec }
    C_Timer.After(settings.delay or 0.4, function()
        local stamp = date("%m%d%y_%H%M%S")
        Screenshot()
        lastShotAt, lastShotStamp = GetTime(), stamp
        for _, r in ipairs(pendingShot) do r.shot = stamp end
        pendingShot = nil
    end)
end

---------------------------------------------------------------------------
-- Kills & Tode
---------------------------------------------------------------------------

local function CurrentPosition()
    if not (C_Map and C_Map.GetBestMapForUnit) then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    x, y = Safe(x), Safe(y)
    if not x or not y then return end
    return Round(x * 100, 1), Round(y * 100, 1)
end

-- Wann habe ich einen feindlichen Spieler zuletzt angegriffen? (Fähigkeit oder laufender Nahkampf)
-- Damit entscheidet die Gruppe ohne Kampflog, wer den Todesstoß hatte.
local lastAttack, autoAttacking = {}, false -- Schlüssel: GUID oder Vorname klein -> GetTime()
local lastAny, anonAttack                     -- letzter Angriff überhaupt / auf einen Feind mit verborgenem Namen
local attacked = {}                           -- GUID oder Vorname -> { guid, name, t }: wen ich zuletzt angegriffen habe
local credited = {}                           -- GUID oder Vorname -> GetTime(): Opfer, die schon gezählt wurden
local KB_WINDOW = 8 -- Sekunden: so kurz vor dem Tod muss der eigene Angriff liegen, sonst nur Ehre (8 s, damit Blutung und Gift reichen)
local kbLog = {}    -- die letzten Entscheidungen (für /assa todesstoss)

-- Vorname klein: WoW Forever schreibt Namen mal mit, mal ohne Nachnamen ("Vorname" / "Vorname Nachname")
local function NameKey(n)
    if type(n) ~= "string" or n == "" or n == "?" then return nil end
    local first = (ShortName(n) or n):match("^(%S+)")
    return first and first:lower() or nil
end

-- Wahr/falsch, oder nil wenn das Spiel den Wert verbirgt
local function Known(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v and true or false
end

-- Heilung, Segen usw. sind kein Angriff. Was das Spiel als hilfreich meldet, fällt raus.
-- "Nicht schädlich" (Reittier, Sprinten …) gilt erst, wenn die Abfrage schon einmal "schädlich" gesagt hat –
-- sonst könnte eine kaputte Abfrage alle Angriffe verschlucken. Im Zweifel zählt der Zauber als Angriff.
local harmfulWorks = false
local function IsHarmful(spellID)
    if spellID == nil or Known(spellID) == nil then return nil end
    if C_Spell and C_Spell.IsSpellHelpful then
        local ok, help = pcall(C_Spell.IsSpellHelpful, spellID)
        if ok and Known(help) then return false end
    end
    if C_Spell and C_Spell.IsSpellHarmful then
        local ok, h = pcall(C_Spell.IsSpellHarmful, spellID)
        if ok and Known(h) == true then harmfulWorks = true return true end
        if ok and harmfulWorks and Known(h) == false then return false end
    end
    local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)) or (GetSpellInfo and GetSpellInfo(spellID))
    name = Safe(name)
    if type(name) == "string" then
        if IsHelpfulSpell then
            local ok, help = pcall(IsHelpfulSpell, name)
            if ok and Known(help) then return false end
        end
        if IsHarmfulSpell then
            local ok, h = pcall(IsHarmfulSpell, name)
            if ok and Known(h) == true then harmfulWorks = true return true end
            if ok and harmfulWorks and Known(h) == false then return false end
        end
    end
    return nil
end

local function NoteAttack()
    if Known(UnitExists("target")) ~= true and Known(UnitExists("target")) ~= nil then return end
    if Known(UnitIsPlayer("target")) == false then return end
    if Known(UnitIsUnit("target", "player")) then return end
    local canAtk, enemy = Known(UnitCanAttack("player", "target")), Known(UnitIsEnemy("player", "target"))
    if canAtk == false and enemy == false then return end
    local now = GetTime()
    local key, guid = NameKey(Safe(UnitName("target"))), Safe(UnitGUID("target"))
    if type(guid) ~= "string" then guid = nil end
    if key then lastAttack[key] = now end
    if guid then lastAttack[guid] = now end
    if not key then anonAttack = now end -- Name verborgen: später nicht zuzuordnen, also gilt der Angriff für jedes Opfer
    lastAny = now
    -- Für den Ehrenzähler (Meldung ohne Namen): wen habe ich angegriffen?
    local id = guid or key
    if id then
        local name = Safe(UnitName("target"))
        local e = attacked[id] or {}
        e.guid, e.t = guid or e.guid, now
        if type(name) == "string" and name ~= "" then e.name = name end
        attacked[id] = e
    end
    for k, e in pairs(attacked) do if now - e.t > 60 then attacked[k] = nil end end
end

-- Sekunden seit meinem letzten Angriff auf das Opfer (99 = keiner) und woran es erkannt wurde
function ns.AttackAge(victim, guid)
    if autoAttacking then NoteAttack() end
    local t, how = guid and lastAttack[guid], "Ziel"
    if not t then t = lastAttack[NameKey(victim) or ""] end
    if not t then
        if NameKey(victim) then
            t, how = anonAttack, "Ziel mit verborgenem Namen"
        else
            t, how = lastAny, "letzter Angriff (Opfer unbekannt)"
        end
    end
    local age = t and math.min(99, GetTime() - t) or 99
    return tonumber(string.format("%.1f", age)), how
end

local function LogKb(victim, age, how, result)
    table.insert(kbLog, 1, { t = time(), victim = victim, age = age, how = how, result = result })
    kbLog[9] = nil
    if settings.kbDebug then
        Print(string.format("Todesstoß-Prüfung %s: %s", victim or "?", result))
    end
end

function ns.KbReport(arg)
    if arg == "an" or arg == "aus" then
        settings.kbDebug = arg == "an"
        Print("Todesstoß-Prüfung im Chat anzeigen: " .. (settings.kbDebug and "an" or "aus"))
        return
    end
    if #kbLog == 0 then Print("Seit dem Einloggen noch keine Ehrenmeldung geprüft.") end
    for _, e in ipairs(kbLog) do
        Print(string.format("%s %s: %s (eigener Angriff vor %s – %s)", date("%H:%M", e.t), e.victim or "?", e.result,
            e.age >= 99 and "–" or string.format("%.1f s", e.age), e.how or "?"))
    end
    local last = lastAny and string.format("vor %.0f s", GetTime() - lastAny) or "keiner"
    Print(string.format("Letzter erkannter Angriff: %s. Fenster: %d s. Live mitlesen: /assa todesstoss an|aus", last, KB_WINDOW))
end

local StoreKill

-- via: "log" (Todesstoß laut Kampflog), "honor" (Ehrenmeldung) oder "count" (Ehrenzähler ist gestiegen)
local function OnPlayerKill(guid, destName, byPet, via)
    local short = ShortName(destName)
    if short == "?" then short = nil end -- unbekannte Opfer nie als Doppelmeldung verwerfen
    if short and recentKills[short] and GetTime() - recentKills[short] < 5 then return end
    if short then recentKills[short] = GetTime() end
    honorCredited = honorCredited + 1
    if guid then credited[guid] = GetTime() end
    if NameKey(destName) then credited[NameKey(destName)] = GetTime() end

    local _, classToken, raceName, raceToken, sex, name, realm
    if guid and GetPlayerInfoByGUID then
        _, classToken, raceName, raceToken, sex, name, realm = GetPlayerInfoByGUID(guid)
    end
    classToken, raceName, raceToken, sex = Safe(classToken), Safe(raceName), Safe(raceToken), Safe(sex)
    name, realm = Safe(name), Safe(realm)
    local cached = LookupUnit(guid) or {}
    local _, instanceType = IsInInstance()
    local x, y = CurrentPosition()
    local hit = guid and lastHit[guid]

    local rec = {
        id = time() .. "-" .. (guid or short or "?") .. "-" .. (#char.kills + 1),
        t = time(),
        victim = Safe(name) or short or cached.name or "?",
        victimRealm = (realm and realm ~= "") and realm or (destName and destName:match("%-(.+)$")) or nil,
        class = classToken or cached.class,
        race = raceName or cached.race,
        raceToken = raceToken,
        sex = sex,
        level = cached.level,
        guild = cached.guild,
        zone = GetRealZoneText(),
        subzone = GetSubZoneText(),
        x = x, y = y,
        myLevel = UnitLevel("player"),
        spell = (hit and GetTime() - hit.t < 10) and hit.spell or nil,
        pet = byPet or nil,
        instance = (instanceType and instanceType ~= "none") and instanceType or nil,
        bg = (UnitInBattleground and Safe(UnitInBattleground("player")) and true) or nil,
        via = via,
    }
    -- Ohne Kampflog meldet das Spiel jeden ehrenhaften Sieg, an dem man irgendwie beteiligt war (Gruppe,
    -- Schlachtzug, Schlachtfeld). Gezählt wird nur der Todesstoß:
    --  1. Ich muss das Opfer selbst kurz vor seinem Tod angegriffen haben (schädlicher Zauber oder Nahkampf).
    --     Sonst ist es nur Ehre: kein Kill, kein Screenshot, keine Meldung.
    --  2. In der Gruppe stimmen die Addons ab: wer zuletzt zugeschlagen hat, bekommt den Kill.
    if via ~= "log" then
        local age, how = ns.AttackAge(rec.victim, guid)
        if age > KB_WINDOW then
            char.assists = (char.assists or 0) + 1
            LogKb(rec.victim, age, how, "nur Ehre (kein eigener Angriff kurz davor)")
            return
        end
        if not (ns.Rudel and ns.Rudel.ClaimKill and ns.Rudel.GroupChannel()) then
            LogKb(rec.victim, age, how, "Kill")
            StoreKill(rec, guid)
            return
        end
        ns.Rudel.ClaimKill(rec.victim, age,
            function() rec.blow = true; LogKb(rec.victim, age, how, "Kill (Gruppe: du warst zuletzt dran)"); StoreKill(rec, guid) end,
            function(winner)
                char.assists = (char.assists or 0) + 1
                LogKb(rec.victim, age, how, "Beteiligung – Todesstoß hatte " .. (winner or "?"))
                if settings.chat then
                    Print(string.format("Beteiligt am Kill an |c%s%s|r – den Todesstoß hatte %s.", ClassColor(rec.class), rec.victim, winner or "?"))
                end
            end)
        return
    end
    StoreKill(rec, guid)
end

-- Kill speichern, Serie zählen, Screenshot, Meldungen
StoreKill = function(rec, guid)
    rec.kb = true -- Todesstoß nach den Regeln ab 1.9.5 (ältere Einträge zählen nicht für Bilanz und Rangliste)
    -- Serie (Kills ohne zu sterben) und Riesentöter (Opfer 3+ Stufen höher oder Totenkopf)
    char.streak = (char.streak or 0) + 1
    char.bestStreak = math.max(char.bestStreak or 0, char.streak)
    rec.streak = char.streak
    if rec.level and (rec.level < 0 or (rec.myLevel and rec.level - rec.myLevel >= 3)) then rec.giant = true end

    table.insert(char.kills, rec)
    if guid then lastHit[guid] = nil end
    if ns.Spy then ns.Spy.OnKill(rec) end
    if ns.Rudel then ns.Rudel.OnKill(rec) end

    if settings.screenshots then QueueScreenshot(rec) end
    if ns.Design then pcall(ns.Design.KillCard, rec, #char.kills) end

    local total = #char.kills
    if settings.chat then
        local lvl = rec.level and (rec.level > 0 and rec.level or "??") or "?"
        Print(string.format("Kill #%d: |c%s%s|r (Stufe %s) in %s%s", total, ClassColor(rec.class),
            rec.victim, lvl, rec.zone or "?", settings.screenshots and " – Screenshot!" or ""))
    end
    if settings.announce and IsInGuild() then
        local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
        if send then
            pcall(send, string.format("[Assassinen] %s wurde in %s ausgeschaltet. Kill #%d",
                rec.victim, rec.zone or "?", total), "GUILD")
        end
    end
end

-- Nur Tode durch Spieler zählen: Monster, Stürze usw. werden nicht erfasst und beenden keine Serie
local function OnPlayerDead()
    local x, y = CurrentPosition()
    local rec = {
        t = time(),
        zone = GetRealZoneText(),
        subzone = GetSubZoneText(),
        x = x, y = y,
        myLevel = UnitLevel("player"),
    }
    local h = lastHitOnMe
    if h and GetTime() - h.t < 20 then
        if band(h.flags or 0, CONTROL_PLAYER) > 0 then
            rec.killer = h.name
            rec.spell = h.spell
            rec.pvp = true
            if h.guid and h.guid:find("^Player") and GetPlayerInfoByGUID then
                local _, classToken = GetPlayerInfoByGUID(h.guid)
                rec.class = classToken
                local cached = unitCache[h.guid]
                if cached then rec.level, rec.guild = cached.level, cached.guild end
            end
        end
    elseif ns.Spy then
        -- Ohne Kampflog: feindlichen Spieler nehmen, der mich gerade im Ziel hatte
        local g = ns.Spy.GuessKiller()
        if g then
            rec.killer, rec.class, rec.level, rec.guild = g.name, g.class, g.level, g.guild
            rec.pvp, rec.guess = true, true
        end
    end
    if rec.pvp then
        table.insert(char.deaths, rec)
        char.streak = 0
    end
    lastHitOnMe = nil
    if ns.Spy then ns.Spy.OnDeath(rec) end
    if ns.Rudel then ns.Rudel.OnDeath(rec) end
end

local function OnCombatLog()
    if not CombatLogGetCurrentEventInfo then return end
    local _, sub, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags, _, a12, a13 =
        CombatLogGetCurrentEventInfo()

    if ns.Spy then ns.Spy.OnCombatLog(sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, a13) end

    if sub == "PARTY_KILL" then
        local byPet = srcGUID ~= playerGUID and srcGUID == UnitGUID("pet")
        if srcGUID == playerGUID or byPet then
            if band(dstFlags or 0, TYPE_PLAYER) > 0 then
                OnPlayerKill(dstGUID, dstName, byPet, "log")
            end
        end
        return
    end

    local isDamage = sub == "SWING_DAMAGE" or sub == "RANGE_DAMAGE" or sub == "SPELL_DAMAGE"
        or sub == "SPELL_PERIODIC_DAMAGE" or sub == "DAMAGE_SHIELD" or sub == "DAMAGE_SPLIT"
    if isDamage then
        local spell = sub == "SWING_DAMAGE" and "Nahkampf" or a13
        if srcGUID == playerGUID and dstGUID ~= playerGUID then
            lastHit[dstGUID] = { spell = spell, t = GetTime() }
        elseif dstGUID == playerGUID then
            lastHitOnMe = { name = srcName, guid = srcGUID, flags = srcFlags, spell = spell, t = GetTime() }
        end
    end
end

---------------------------------------------------------------------------
-- Ehrenmeldungen ("X stirbt, ehrenhafter Sieg ...") – Kill-Erkennung ohne Kampflog
---------------------------------------------------------------------------

-- Wandelt einen Formatstring wie "%s dies, honorable kill Rank: %s (...%d)" in ein Lua-Muster um.
local function ToPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("%%%d?%$?s", "\1"):gsub("%%%d?%$?d", "\2")
    p = p:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
    p = p:gsub("\1", "(.-)"):gsub("\2", "%%d+")
    return "^" .. p .. "$"
end

local honorPatterns = {}
for _, fmt in ipairs({ COMBATLOG_HONORGAIN, COMBATLOG_HONORGAIN_NO_RANK, COMBATLOG_HONORGAIN_EXHAUSTION1 }) do
    local p = ToPattern(fmt)
    if p then table.insert(honorPatterns, p) end
end
table.insert(honorPatterns, "^(.-) stirbt, ehrenhafter Sieg")
table.insert(honorPatterns, "^(.-) dies, honorable kill")

local function OnHonorMessage(msg)
    if type(msg) ~= "string" or not Safe(msg) then return end
    for _, p in ipairs(honorPatterns) do
        local ok, name = pcall(string.match, msg, p)
        name = ok and Safe(name)
        if name and name ~= "" then
            OnPlayerKill(nameToGuid[name] or nameToGuid[ShortName(name)], name, false, "honor")
            return
        end
    end
end
ns.ToPattern = ToPattern

---------------------------------------------------------------------------
-- Ehrenzähler: falls die Chatmeldung für Addons unlesbar ist, zählt der Anstieg der
-- ehrenhaften Siege. Das Opfer ist dann das tote Ziel, eine tote Namensplakette
-- oder das letzte feindliche Ziel.
---------------------------------------------------------------------------

local function ReadHonorKills()
    if not GetPVPLifetimeStats then return end
    local ok, hk = pcall(GetPVPLifetimeStats)
    hk = ok and Safe(hk)
    return type(hk) == "number" and hk or nil
end

-- Schon gezählt? (Ein totes Ziel bleibt tot, wenn man gleich den nächsten Gegner umhaut)
local function WasCredited(guid, name)
    local now = GetTime()
    local a, b = guid and credited[guid], NameKey(name) and credited[NameKey(name)]
    return (a and now - a < 60) or (b and now - b < 60) or false
end

local function DeadEnemy(unit)
    if not Safe(UnitExists(unit)) or not Safe(UnitIsPlayer(unit)) or not Safe(UnitIsDeadOrGhost(unit)) then return end
    if Known(UnitIsEnemy("player", unit)) == false and Known(UnitCanAttack("player", unit)) == false then return end
    local name, guid = Safe(UnitName(unit)), Safe(UnitGUID(unit))
    if type(guid) ~= "string" then guid = nil end
    if (name or guid) and not WasCredited(guid, name) then return guid, name end
end

-- Lebt dieser Gegner noch sichtbar (Ziel oder Namensplakette)? Dann war er es nicht.
local function AliveNow(e)
    local key = NameKey(e.name)
    for i = 0, 40 do
        local unit = i == 0 and "target" or ("nameplate" .. i)
        if Safe(UnitExists(unit)) then
            local g, n = Safe(UnitGUID(unit)), NameKey(Safe(UnitName(unit)))
            if (e.guid and g == e.guid) or (key and n == key) then
                if Known(UnitIsDeadOrGhost(unit)) == false then return true end
            end
        end
    end
    return false
end

-- Opfer, wenn die Ehrenmeldung keinen Namen nennt ("Ihr werdet mit 9 Ehre belohnt"):
-- totes Ziel, tote Plakette, sonst der zuletzt von mir angegriffene Gegner, der nicht mehr lebend zu sehen ist.
-- Schon gezählte Opfer werden übersprungen, damit zwei schnelle Kills zwei verschiedene Namen bekommen.
local function FindVictim()
    local guid, name = DeadEnemy("target")
    if guid or name then return guid, name end
    for i = 1, 40 do
        guid, name = DeadEnemy("nameplate" .. i)
        if guid or name then return guid, name end
    end
    local now, best = GetTime()
    for _, e in pairs(attacked) do
        if now - e.t < 20 and (not best or e.t > best.t) and not WasCredited(e.guid, e.name) and not AliveNow(e) then best = e end
    end
    if best then return best.guid, best.name end
    local l = lastEnemyTarget
    if l and now - l.t < 20 and not WasCredited(l.guid, l.name) then return l.guid, l.name end
end

local function CheckHonorCounter()
    local hk = ReadHonorKills()
    if not hk or not char then return end
    if not honorBase or hk < honorBase or hk - honorBase - honorCredited > 5 then
        -- Erster Wert nach dem Einloggen (oder ein Sprung): nur merken, nicht als Kills zählen
        honorBase, honorCredited = hk, 0
        return
    end
    if hk - honorBase <= honorCredited or honorCheckPending then return end
    -- Kurz warten: Die Ehrenmeldung kann nach dem Zähler ankommen
    honorCheckPending = true
    C_Timer.After(0.7, function()
        honorCheckPending = false
        local now = ReadHonorKills()
        while now and honorBase and now - honorBase > honorCredited do
            local before = honorCredited
            local guid, name = FindVictim()
            OnPlayerKill(guid, name or "?", false, "count")
            if honorCredited == before then honorCredited = before + 1 end -- als Doppelmeldung verworfen
        end
    end)
end
ns.CheckHonorCounter = CheckHonorCounter

---------------------------------------------------------------------------
-- Slash-Befehle
---------------------------------------------------------------------------

local function PrintStats()
    local pvp, deaths = #char.kills, #char.deaths
    local kd = deaths > 0 and string.format("%.2f", pvp / deaths) or tostring(pvp)
    Print(string.format("%s: |cffffd100%d|r Kills, |cffffd100%d|r Tode durch Spieler (K/D %s)",
        char.name, pvp, deaths, kd))
end

local function OnOff(value) return value and "|cff00ff00an|r" or "|cffff4040aus|r" end
ns.OnOff = OnOff

-- "an"/"aus" auswerten, sonst umschalten
local function Toggle(key, arg)
    if arg == "on" or arg == "an" then settings[key] = true
    elseif arg == "off" or arg == "aus" then settings[key] = false
    else settings[key] = not settings[key] end
    return settings[key]
end
ns.Toggle = Toggle

SLASH_ASSASSINEN1 = "/assa"
SLASH_ASSASSINEN2 = "/assassinen"
SlashCmdList.ASSASSINEN = function(input)
    local cmd, rawArg = strtrim(input or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    local arg = rawArg:lower()
    if cmd == "stats" then
        PrintStats()
    elseif cmd == "shots" or cmd == "screenshots" then
        Print("Screenshots bei Kills: " .. OnOff(Toggle("screenshots", arg)))
    elseif cmd == "ansage" or cmd == "announce" then
        Print("Kill-Ansage im Gildenchat: " .. OnOff(Toggle("announce", arg)))
    elseif cmd == "delay" then
        local v = tonumber(arg)
        if v and v >= 0 and v <= 5 then settings.delay = v end
        Print(string.format("Screenshot-Verzögerung: %.1f s", settings.delay))
    elseif cmd == "design" then
        if arg == "buch" or arg == "dunkel" then
            settings.design = arg
            Print("Design: " .. arg .. " – wird nach /reload übernommen.")
        else
            Print("Design: " .. (settings.design or "buch") .. ". Umschalten: /assa design buch | dunkel (danach /reload)")
        end
    elseif cmd == "steckbrief" then
        Print("Steckbrief bei Kills: " .. OnOff(Toggle("killCard", arg)))
    elseif cmd == "todesstoss" or cmd == "todesstoß" or cmd == "kb" then
        ns.KbReport(arg)
    elseif cmd == "letzte" or cmd == "last" then
        local n = #char.kills
        if n == 0 then Print("Noch keine Kills.") end
        for i = n, math.max(1, n - 4), -1 do
            local k = char.kills[i]
            Print(string.format("#%d |c%s%s|r – %s, %s", i, ClassColor(k.class), k.victim, k.zone or "?",
                date("%d.%m. %H:%M", k.t)))
        end
    elseif ns.Spy and ns.Spy.Slash(cmd, rawArg, arg) then
        -- vom Späher erledigt
    else
        PrintStats()
        Print("Kills: /assa stats | letzte | todesstoss [an|aus] | shots [an|aus] | ansage [an|aus] | delay <sek>")
        Print("Addon: /assa versionen (wer hat welche Version) | update (wie aktualisieren) | design buch|dunkel | steckbrief [an|aus]")
        Print("Späher: /assa spy | intel | kos <Name> [Grund] | auftrag <Name> [Grund] | akte <Name> | merken <Name> [Grund] | teilen <Name> [Spieler]")
        Print("        /assa töne  (Fenster: Ton für jede Warnung wählen)  ·  /assa töne an|aus")
        Print("        /assa ruhe [Minuten|aus] | töne [an|aus] | sync [an|aus] | autokos [an|aus] | zeilen <n> | minimap")
        Print("        /assa plaketten [an|aus]  (Späher-Reichweite: Feind-Plaketten an, Reichweite aufs Maximum)")
        Print("Rudel: /assa hilfe [aus] | komme | ziel | plan [Namen] | bereit [gilde] | fehde <Gilde> | fehden")
        Print("       /assa rudel (Rudel in der Nähe einladen) | autorudel [an|aus] | radar | rang | bilanz")
        Print("       /assa imziel [an|aus] | tarnalarm [an|aus] | uebermacht [Zahl|aus]  (Warnungen)")
        Print("       /assa neutral [an|aus|hier]  (Ruhe in Beutebucht, Gadgetzan & Co.)")
        Print("       /assa leiste  (Kommando-Leiste: Hilfe, Ziel, Plan, Los, Sammeln, Wache, KOS … alles per Klick)")
        Print("       /assa ziele  (Zielliste: Rudel und Feinde per Klick oder Taste anvisieren)")
        Print("       /assa sammeln [Text|aus]  (Sammelpunkt hier; Alt+Klick auf die Weltkarte setzt ihn dort)")
        Print("       /assa los [Sekunden]  (Opener-Countdown für die Gruppe)  ·  /assa wache  (Wachposten an/aus)")
        Print("       /assa pfeil [Name|an|aus]  (Pfeil auf ein Mitglied, ausblenden oder ganz abschalten)")
        Print("       /assa layer [Name] | layerwechsel [an|aus]  (Layer anzeigen bzw. auf den Layer eines Mitglieds wechseln)")
        Print("       /assa gruppentest  (zeigt, was das Addon über deine Gruppe weiß – bei Problemen mit Kartenpunkten)")
        Print("       /assa karte | sichtungen | autohilfe | hilferufe | feed | gift  [an|aus]")
        Print("Tasten: Tastaturbelegung → AddOns → Assassinen (Hilferuf, Ziel ansagen, Ziel anvisieren, Plan, Bereit)")
        Print("Daten werden beim Ausloggen oder per /reload gespeichert – danach auf der Webseite hochladen.")
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if char then OnCombatLog() end
    elseif event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
        if char then OnHonorMessage((...)) end
    elseif event == "PLAYER_TARGET_CHANGED" then
        CacheUnit("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        CacheUnit("mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        CacheUnit((...))
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" and IsHarmful(spellID) ~= false then pcall(NoteAttack) end
    elseif event == "PLAYER_ENTER_COMBAT" then
        autoAttacking = true
        NoteAttack()
    elseif event == "PLAYER_LEAVE_COMBAT" then
        autoAttacking = false
    elseif event == "PLAYER_DEAD" then
        if char then OnPlayerDead() end
    elseif event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        InitDB()
        UpdateProfile()
        -- TGA kann der Browser nicht anzeigen, also auf JPEG umstellen.
        if GetCVar("screenshotFormat") == "tga" then
            SetCVar("screenshotFormat", "jpeg")
            Print("Screenshot-Format auf JPEG umgestellt.")
        end
        C_Timer.NewTicker(0.25, function() if autoAttacking then pcall(NoteAttack) end end)
        if char.fullName then ns.LearnSelfName(char.fullName) end
        if ns.Spy then ns.Spy.Init() end
        Print(string.format("geladen – %d Kills bisher. /assa für Befehle.", #char.kills))
    elseif event == "PLAYER_LEVEL_UP" then
        if char then char.level = (...) end
    elseif event == "PLAYER_PVP_KILLS_CHANGED" then
        if char then UpdateProfile(); CheckHonorCounter() end
    elseif char then
        UpdateProfile() -- PLAYER_ENTERING_WORLD, PLAYER_GUILD_UPDATE, PLAYER_PVP_KILLS_CHANGED, PLAYER_LOGOUT
    end
end)

for _, event in ipairs({
    "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "PLAYER_LEVEL_UP", "PLAYER_GUILD_UPDATE",
    "PLAYER_PVP_KILLS_CHANGED", "PLAYER_DEAD", "CHAT_MSG_COMBAT_HONOR_GAIN",
    "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED",
    "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_ENTER_COMBAT", "PLAYER_LEAVE_COMBAT",
}) do
    pcall(frame.RegisterEvent, frame, event)
end
-- In WoW Forever gibt es das Kampflog für Addons nicht, schon das Anmelden löst dort einen Fehler aus
if CombatLogGetCurrentEventInfo then pcall(frame.RegisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED") end
