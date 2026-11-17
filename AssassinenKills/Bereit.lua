-- Assassinen Bereitschaft – Bereitschaftscheck fürs Rudel und Giftwächter.
-- Liest nur den eigenen Charakter aus. Schurken: Gifte, Pulver, Verschwinden/Sprinten.
-- Druiden: Mana, Samen für Wiedergeburt, Wiedergeburt/Anregen.

local ADDON_NAME, ns = ...
local Bereit = {}
ns.Bereit = Bereit

local S, Rudel, UI
local playerName
local current          -- laufender Check: { id, t, channel, replies }
local lastWarn = {}

local ITEM_FLASH, ITEM_BLIND, ITEM_TEA = 5140, 5530, 7676 -- Blitzstrahlpulver, Blendungspulver, Distelfusstee
local SPELL_VANISH, SPELL_SPRINT, SPELL_EVASION = 1856, 2983, 5277
local SPELL_REBIRTH, SPELL_INNERVATE = 20484, 29166
local SEEDS = { 17034, 17035, 17036, 17037, 17038 } -- Ahornsamen bis Eisenholzsamen (je Rang von Wiedergeburt)

-- Mana in Prozent, nil wenn das Spiel den Wert verbirgt
local function ManaPct()
    if not (UnitPower and UnitPowerMax) then return nil end
    local cur, max = ns.Safe(UnitPower("player", 0)), ns.Safe(UnitPowerMax("player", 0))
    if not cur or not max or max <= 0 then return nil end
    return math.floor(cur / max * 100 + 0.5)
end

local function Print(text) ns.Print(text) end

-- Restliche Abklingzeit in Sekunden: 0 = bereit, -1 = Zauber nicht bekannt
local function SpellCD(id)
    local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or (GetSpellInfo and GetSpellInfo(id))
    if not name then return -1 end
    local ok, start, duration
    if C_Spell and C_Spell.GetSpellCooldown then
        local info
        ok, info = pcall(C_Spell.GetSpellCooldown, name)
        if ok and type(info) == "table" then start, duration = info.startTime, info.duration end
    elseif GetSpellCooldown then
        ok, start, duration = pcall(GetSpellCooldown, name)
    end
    start, duration = ns.Safe(start), ns.Safe(duration)
    if not ok or start == nil then return -1 end
    if start == 0 or (duration or 0) <= 1.5 then return 0 end
    return math.max(0, math.ceil(start + duration - GetTime()))
end

local function Count(item)
    local get = (C_Item and C_Item.GetItemCount) or GetItemCount
    return get and ns.Safe(get(item)) or 0
end

function Bereit.Status()
    local _, class = UnitClass("player")
    local s = { class = class, hp = Rudel.HealthPct("player") }
    local hasMH, mhExp, _, _, hasOH, ohExp
    if GetWeaponEnchantInfo then hasMH, mhExp, _, _, hasOH, ohExp = GetWeaponEnchantInfo() end
    s.mh = hasMH and math.floor((mhExp or 0) / 60000) or -1
    s.oh = hasOH and math.floor((ohExp or 0) / 60000) or -1
    s.ohWeapon = GetInventoryItemLink and GetInventoryItemLink("player", 17) ~= nil or false
    s.flash, s.blind, s.tea = Count(ITEM_FLASH), Count(ITEM_BLIND), Count(ITEM_TEA)
    s.vanish, s.sprint, s.evasion = SpellCD(SPELL_VANISH), SpellCD(SPELL_SPRINT), SpellCD(SPELL_EVASION)
    s.mana, s.rebirth, s.innervate, s.seeds = ManaPct(), SpellCD(SPELL_REBIRTH), SpellCD(SPELL_INNERVATE), 0
    for _, id in ipairs(SEEDS) do s.seeds = s.seeds + Count(id) end
    return s
end

local function Mins(sec)
    return sec >= 60 and string.format("%d:%02d", math.floor(sec / 60), sec % 60) or (sec .. " s")
end

-- Was fehlt? Leere Liste = bereit
function Bereit.Problems(s)
    local out = {}
    if s.class == "ROGUE" then
        if s.mh < 0 then out[#out + 1] = "kein Gift (Haupthand)" elseif s.mh < 5 then out[#out + 1] = "Gift Haupthand " .. s.mh .. " Min." end
        if s.ohWeapon then
            if s.oh < 0 then out[#out + 1] = "kein Gift (Schildhand)" elseif s.oh < 5 then out[#out + 1] = "Gift Schildhand " .. s.oh .. " Min." end
        end
        if s.vanish >= 0 and s.flash == 0 then out[#out + 1] = "kein Blitzstrahlpulver" end
        if s.vanish > 0 then out[#out + 1] = "Verschwinden " .. Mins(s.vanish) end
        if s.sprint > 0 then out[#out + 1] = "Sprinten " .. Mins(s.sprint) end
    end
    if s.class == "DRUID" then
        if s.mana and s.mana >= 0 and s.mana < 70 then out[#out + 1] = "Mana " .. s.mana .. "%" end
        if s.rebirth >= 0 and s.seeds == 0 then out[#out + 1] = "keine Samen für Wiedergeburt" end
        if s.innervate > 0 then out[#out + 1] = "Anregen " .. Mins(s.innervate) end
    end
    if s.hp and s.hp >= 0 and s.hp < 70 then out[#out + 1] = "Leben " .. s.hp .. "%" end
    return out
end

function Bereit.Line(name, s)
    local problems = Bereit.Problems(s)
    local state = #problems == 0 and "|cff00ff00bereit|r" or ("|cffff4040" .. table.concat(problems, ", ") .. "|r")
    local info = {}
    if s.class == "ROGUE" then
        info[#info + 1] = string.format("Gift %s/%s", s.mh >= 0 and s.mh or "–", s.ohWeapon and (s.oh >= 0 and s.oh or "–") or "·")
        info[#info + 1] = "Pulver " .. s.flash
        info[#info + 1] = "Blenden " .. s.blind
        if s.tea > 0 then info[#info + 1] = "Tee " .. s.tea end
        if s.evasion > 0 then info[#info + 1] = "Entrinnen " .. Mins(s.evasion) end
    elseif s.class == "DRUID" then
        if s.mana and s.mana >= 0 then info[#info + 1] = "Mana " .. s.mana .. "%" end
        if s.rebirth >= 0 then
            info[#info + 1] = "Samen " .. s.seeds
            info[#info + 1] = "Wiedergeburt " .. (s.rebirth == 0 and "bereit" or Mins(s.rebirth))
        end
    end
    return string.format("|c%s%s|r: %s%s", ns.ClassColor(s.class), name, state,
        #info > 0 and ("  |cffaaaaaa" .. table.concat(info, " · ") .. "|r") or ""), #problems == 0
end

local function Encode(s)
    return s.class or "", s.hp or -1, s.mh, s.oh, s.ohWeapon and 1 or 0, s.flash, s.blind, s.tea, s.vanish, s.sprint, s.evasion,
        s.mana or -1, s.rebirth, s.innervate, s.seeds
end

local function Decode(f)
    local n = function(i) return tonumber(f[i]) or -1 end
    return {
        class = f[3] ~= "" and f[3] or nil, hp = n(4), mh = n(5), oh = n(6), ohWeapon = f[7] == "1",
        flash = math.max(0, n(8)), blind = math.max(0, n(9)), tea = math.max(0, n(10)), vanish = n(11), sprint = n(12), evasion = n(13),
        mana = f[14] and tonumber(f[14]) or 100, rebirth = n(15), innervate = n(16), seeds = math.max(0, n(17)),
    }
end

---------------------------------------------------------------------------
-- Bereitschaftscheck
---------------------------------------------------------------------------

function Bereit.Check(scope)
    local channel = scope == "gilde" and (IsInGuild() and "GUILD") or Rudel.GroupChannel()
    if not channel then
        Print("Bereitschaft (nur du – für das Rudel in eine Gruppe gehen oder /assa bereit gilde):")
        Print("  " .. Bereit.Line(playerName, Bereit.Status()))
        return
    end
    current = { id = string.format("%x", math.random(0x1000, 0xffff)), t = GetTime(), channel = channel, replies = {} }
    current.replies[playerName] = Bereit.Status()
    Rudel.Send(channel, { urgent = true }, "RQ", current.id)
    Print(string.format("Bereitschaftscheck an %s gesendet – Ergebnis in 6 Sekunden.", channel == "GUILD" and "die Gilde" or "die Gruppe"))
    local id = current.id
    C_Timer.After(6, function() if current and current.id == id then Bereit.Report() end end)
end

function Bereit.Report()
    local c = current
    if not c then return end
    current = nil
    local names, ready = {}, 0
    for name in pairs(c.replies) do names[#names + 1] = name end
    table.sort(names)
    Print(string.format("|cffffd100Bereitschaft|r (%d Antworten):", #names))
    for _, name in ipairs(names) do
        local line, ok = Bereit.Line(name, c.replies[name])
        if ok then ready = ready + 1 end
        Print("  " .. line)
    end
    if c.channel ~= "GUILD" then
        local missing = {}
        for i = 1, 40 do
            local unit = (IsInRaid and IsInRaid()) and ("raid" .. i) or (i <= 4 and ("party" .. i))
            local n = unit and ns.Safe(UnitExists(unit)) and ns.Safe(UnitName(unit))
            if n and not c.replies[n] then missing[#missing + 1] = n end
        end
        if #missing > 0 then Print("  |cffaaaaaaOhne Antwort (kein Addon?):|r " .. table.concat(missing, ", ")) end
    end
    UI.Alert(string.format("Bereit: %d von %d", ready, #names), false)
end

Bereit.HandleRequest = function(f, sender)
    local id = f[2]
    if not id or id == "" then return end
    Rudel.Send("WHISPER", { urgent = true, target = sender }, "RA", id, Encode(Bereit.Status()))
    local problems = Bereit.Problems(Bereit.Status())
    Print(string.format("Bereitschaftscheck von %s – du bist %s", sender,
        #problems == 0 and "|cff00ff00bereit|r." or ("|cffff4040nicht bereit:|r " .. table.concat(problems, ", "))))
    Rudel.Sound("ready")
end

Bereit.HandleAnswer = function(f, sender)
    if not current or f[2] ~= current.id then return end
    current.replies[sender] = Decode(f)
end

---------------------------------------------------------------------------
-- Giftwächter
---------------------------------------------------------------------------

local function Warn(key, text, every)
    if lastWarn[key] and GetTime() - lastWarn[key] < (every or 300) then return end
    lastWarn[key] = GetTime()
    Print("|cffff8020" .. text .. "|r")
    UI.Alert(text, false)
end

function Bereit.Watch()
    if not S.poisonWarn or UnitLevel("player") < 20 then return end
    local _, class = UnitClass("player")
    if class ~= "ROGUE" then return end
    if UnitAffectingCombat("player") or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) or IsResting() then return end
    local s = Bereit.Status()
    if s.mh < 0 then Warn("mh", "Kein Gift auf der Haupthand!")
    elseif s.mh < 3 then Warn("mh", string.format("Gift auf der Haupthand läuft ab (%d Min.)", s.mh)) end
    if s.ohWeapon then
        if s.oh < 0 then Warn("oh", "Kein Gift auf der Schildhand!")
        elseif s.oh < 3 then Warn("oh", string.format("Gift auf der Schildhand läuft ab (%d Min.)", s.oh)) end
    end
    if s.vanish >= 0 and s.flash == 0 then Warn("flash", "Kein Blitzstrahlpulver – Verschwinden geht nicht!", 600) end
end

---------------------------------------------------------------------------

function Bereit.Slash(cmd, raw, arg)
    if cmd == "bereit" or cmd == "ready" then
        Bereit.Check(arg)
    elseif cmd == "gift" then
        Print("Giftwächter: " .. ns.OnOff(ns.Toggle("poisonWarn", arg)))
    else
        return false
    end
    return true
end

function Bereit.Init()
    S, Rudel, UI = ns.settings, ns.Rudel, ns.UI
    playerName = ns.PlayerName()
    ns.WatchSelfName(function(n) playerName = n end)
    Rudel.On("RQ", Bereit.HandleRequest)
    Rudel.On("RA", Bereit.HandleAnswer)
    C_Timer.NewTicker(15, Bereit.Watch)
end
