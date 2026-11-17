-- Assassinen Bilanz – Tagesbilanz (Kills, Tode, Serie, bester Kill) und die Wochen-Rangliste der Gilde.
-- Die Rangliste entsteht ohne Webseite: Jedes Mitglied mit Addon sagt der Gilde seine Kills der Woche an
-- (beim Einloggen, nach jedem Kill und auf Nachfrage). Wer offline ist, steht mit seinem letzten Stand drin.

local ADDON_NAME, ns = ...
local Bilanz = {}
ns.Bilanz = Bilanz

local S, Rudel
local playerName
local lastAnswer = -999

local function Print(msg) ns.Print(msg) end

-- Beginn des heutigen Tages und der aktuellen Woche (Montag 0 Uhr), Ortszeit
local function DayStart(now)
    local d = date("*t", now)
    return now - (d.hour * 3600 + d.min * 60 + d.sec)
end

local function WeekStart(now)
    local d = date("*t", now)
    local sinceMonday = (d.wday + 5) % 7 -- wday: 1 = Sonntag
    return DayStart(now) - sinceMonday * 86400
end

function Bilanz.WeekId(now)
    return date("%Y-%m-%d", WeekStart(now or time()))
end

-- Heute: Kills, Tode, aktuelle Serie, bester Kill (höchste Stufe, Riesentöter zuerst)
function Bilanz.Today()
    local char = ns.char
    local from = DayStart(time())
    local kills, deaths, best = 0, 0, nil
    for _, k in ipairs(char and char.kills or {}) do
        if (k.t or 0) >= from and k.kb then -- nur echte Todesstöße (ab 1.9.5 markiert)
            kills = kills + 1
            local lv = (k.level and k.level < 0) and 99 or (k.level or 0)
            local score = lv + (k.giant and 100 or 0)
            if not best or score > best.score then best = { k = k, score = score } end
        end
    end
    for _, d in ipairs(char and char.deaths or {}) do
        if (d.t or 0) >= from then deaths = deaths + 1 end
    end
    return { kills = kills, deaths = deaths, streak = char and char.streak or 0, best = best and best.k }
end

function Bilanz.Line()
    local t = Bilanz.Today()
    local parts = { string.format("Heute |cff40ff40%d|r : |cffff4040%d|r", t.kills, t.deaths) }
    if t.streak > 0 then parts[#parts + 1] = "Serie " .. t.streak end
    if t.best then
        local lv = t.best.level and (t.best.level > 0 and t.best.level or "??") or "?"
        parts[#parts + 1] = string.format("Bester: |c%s%s|r (%s)", ns.ClassColor(t.best.class), t.best.victim or "?", lv)
    end
    return table.concat(parts, "  ·  ")
end

---------------------------------------------------------------------------
-- Wochen-Rangliste
---------------------------------------------------------------------------

-- Schlachtfelder und Arena zählen nicht für die Rangliste: nur Open-World-PvP.
-- Neue Kills tragen den Instanztyp, ältere erkennen wir am Zonennamen.
local BG_ZONES = {
    ["Kriegshymnenschlucht"] = true, ["Warsong Gulch"] = true, ["Arathibecken"] = true, ["Arathi Basin"] = true,
    ["Alteractal"] = true, ["Alterac Valley"] = true, ["Auge des Sturms"] = true, ["Eye of the Storm"] = true,
}
function Bilanz.IsBattleground(k)
    return k.instance == "pvp" or k.instance == "arena" or k.bg == true or (k.zone ~= nil and BG_ZONES[k.zone] == true)
end

local function MyWeekKills()
    local from = WeekStart(time())
    local n = 0
    for _, k in ipairs(ns.char and ns.char.kills or {}) do
        -- nur echte Todesstöße in der offenen Welt
        if (k.t or 0) >= from and k.kb and not Bilanz.IsBattleground(k) then n = n + 1 end
    end
    return n
end

local function Board()
    local week = Bilanz.WeekId()
    -- neue Woche oder neue Zählweise (ab 1.9.5 nur Todesstöße, ab 1.10.4 ohne Schlachtfelder): Liste neu beginnen
    if S.rankWeek ~= week or S.rankRules ~= 3 then S.rankWeek, S.rankList, S.rankRules = week, {}, 3 end
    S.rankList = S.rankList or {}
    -- alte Einträge "Name-Realm" mit "Name" zusammenführen (höherer Stand gewinnt)
    local merge = {}
    for name in pairs(S.rankList) do
        local short = ns.ShortName(name)
        -- der eigene Eintrag nur einmal: Vorname allein und voller Name sind dieselbe Figur
        if ns.IsMe(name) then short = ns.PlayerName() end
        if short and short ~= name then merge[#merge + 1] = { name, short } end
    end
    for _, m in ipairs(merge) do
        local e, o = S.rankList[m[1]], S.rankList[m[2]]
        if not o or (e.n or 0) > (o.n or 0) then S.rankList[m[2]] = e end
        S.rankList[m[1]] = nil
    end
    return S.rankList
end

local function Store(name, n)
    local b = Board()
    name = ns.ShortName(name) or name
    b[name] = { n = n, t = time() }
    if ns.Leiste then ns.Leiste.Refresh() end
end

function Bilanz.Announce()
    local n = MyWeekKills()
    Store(playerName, n)
    -- "WK3": ältere Versionen schickten "WK"/"WK2" und zählten jede Ehre bzw. Schlachtfeld-Kills mit
    if IsInGuild() then Rudel.Send("GUILD", nil, "WK3", Bilanz.WeekId(), n) end
end

-- { { name, n }, ... } absteigend
function Bilanz.Ranking()
    Store(playerName, MyWeekKills())
    local out = {}
    for name, e in pairs(Board()) do out[#out + 1] = { name = name, n = e.n or 0, t = e.t } end
    table.sort(out, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    return out
end

function Bilanz.MyPlace()
    for i, e in ipairs(Bilanz.Ranking()) do if e.name == playerName then return i, e.n end end
end

-- Neuesten Stand von allen anfordern
function Bilanz.Request()
    if IsInGuild() then Rudel.Send("GUILD", nil, "WQ", Bilanz.WeekId()) end
end

function Bilanz.PrintRanking()
    local list = Bilanz.Ranking()
    Print(string.format("|cffffd100Rangliste der Woche|r (ab Montag, nur offene Welt, %d mit Addon gemeldet):", #list))
    for i, e in ipairs(list) do
        if i > 10 and e.name ~= playerName then break end
        Print(string.format("  %d. %s%s – %d Kill%s", i, e.name == playerName and "|cffffd100" or "", e.name .. (e.name == playerName and "|r" or ""),
            e.n, e.n == 1 and "" or "s"))
    end
end

function Bilanz.Tooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine("Rangliste der Woche (ohne Schlachtfelder)", 1, .82, 0)
    local list = Bilanz.Ranking()
    for i, e in ipairs(list) do
        if i > 10 then break end
        local me = e.name == playerName
        GameTooltip:AddDoubleLine(string.format("%d. %s", i, e.name), tostring(e.n), me and 1 or .9, me and .82 or .9, me and 0 or .9, 1, 1, 1)
    end
    if #list <= 1 then GameTooltip:AddLine("Noch keine anderen Meldungen – Klick fragt alle Mitglieder online.", .6, .6, .6, true) end
    GameTooltip:AddLine("Klick: neuesten Stand holen und im Chat zeigen", .5, .5, .5)
    GameTooltip:Show()
end

function Bilanz.OnKill()
    Bilanz.Announce()
end

function Bilanz.Slash(cmd, raw, arg)
    if cmd == "rang" or cmd == "rangliste" then
        Bilanz.Request()
        C_Timer.After(3, Bilanz.PrintRanking)
        Print("Frage die Gilde nach dem Stand …")
    elseif cmd == "bilanz" or cmd == "heute" then
        Print(Bilanz.Line())
    else
        return false
    end
    return true
end

function Bilanz.Init()
    S, Rudel = ns.settings, ns.Rudel
    playerName = ns.PlayerName()
    ns.WatchSelfName(function(n) playerName = n end)
    Rudel.On("WK3", function(f, sender)
        if f[2] ~= Bilanz.WeekId() then return end
        Store(sender, tonumber(f[3]) or 0)
    end)
    Rudel.On("WQ", function(f, sender)
        if sender == playerName or GetTime() - lastAnswer < 20 then return end
        lastAnswer = GetTime()
        -- leicht versetzt antworten, damit nicht alle gleichzeitig senden
        C_Timer.After(math.random() * 2, Bilanz.Announce)
    end)
    C_Timer.After(10, Bilanz.Announce)
end
