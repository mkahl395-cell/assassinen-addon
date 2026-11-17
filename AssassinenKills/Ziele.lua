-- Assassinen Zielliste – Rudel und Feinde in der Nähe mit einem Klick oder per Taste anvisieren.
-- Anvisieren ist eine geschützte Aktion: Jede Zeile ist ein sicherer Knopf mit einem /targetexact-Makro.
-- Im Kampf darf das Spiel die Knöpfe nicht umbelegen, dann bleibt die Liste bis zum Kampfende stehen.

local ADDON_NAME, ns = ...
local Ziele = {}
ns.Ziele = Ziele

local ROWS = 5
local WIDTH, ROW_H = 256, 18
local S, UI, Spy, Karte, Rudel
local frame
local friendRows, enemyRows = {}, {}

for i = 1, ROWS do
    _G["BINDING_NAME_CLICK AssassinenZielFreund" .. i .. ":LeftButton"] = "Rudel " .. i .. " anvisieren"
    _G["BINDING_NAME_CLICK AssassinenZielFeind" .. i .. ":LeftButton"] = "Feind " .. i .. " anvisieren"
end
BINDING_NAME_ASSASSINEN_ZIELE = "Zielliste ein/aus"

local function Locked()
    return InCombatLockdown and InCombatLockdown()
end

local function Target(name, realm)
    if realm and realm ~= "" and realm ~= GetRealmName() then return name .. "-" .. realm end
    return name
end

local function NewRow(parent, globalName, label)
    local b = CreateFrame("Button", globalName, parent, "SecureActionButtonTemplate")
    b:SetSize(WIDTH - 10, ROW_H)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type", "macro")
    b:SetAttribute("macrotext", "")
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(.6, .08, .1, .3)
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(.6, .08, .1, .45)
    b.sel:Hide()
    b.key = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.key:SetPoint("LEFT", 2, 0)
    b.key:SetText(label)
    b.sq = b:CreateTexture(nil, "ARTWORK")
    b.sq:SetSize(7, 7)
    b.sq:SetPoint("LEFT", 14, 0)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.name:SetPoint("LEFT", b.sq, "RIGHT", 5, 0)
    b.name:SetJustifyH("LEFT")
    b.info = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.info:SetPoint("RIGHT", -2, 0)
    b.info:SetJustifyH("RIGHT")
    b:SetScript("OnEnter", function(self)
        if not self.entry then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.name:GetText())
        if self.entry.tip then GameTooltip:AddLine(self.entry.tip, .8, .8, .8, true) end
        GameTooltip:AddLine("Klick: ins Ziel nehmen", .5, .5, .5)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function Section(text, y)
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 8, y)
    fs:SetTextColor(.75, .12, .15)
    fs:SetText(text)
    return fs
end

local function Build()
    local f = CreateFrame("Frame", "AssassinenZielliste", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame = f
    UI.Skin(f, .9)
    f:SetSize(WIDTH, 26 + 16 + ROWS * ROW_H + 16 + ROWS * ROW_H + 8)
    f:SetFrameStrata("MEDIUM")
    UI.MakeMovable(f, "targetListPos")
    UI.RestorePos(f, "targetListPos", "CENTER", UIParent, "CENTER", -380, -60)

    local wings = UI.Art(f, "wings", 18)
    wings:SetPoint("TOPLEFT", 4, -2)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("LEFT", wings, "RIGHT", 4, 0)
    f.title:SetText("|cffe6e1e1Ziele|r")
    local close = UI.TextButton(f, "x", 16, function() Ziele.Toggle() end, "Schließen (/assa ziele)")
    close:SetPoint("TOPRIGHT", -4, -4)
    f.help = UI.HelpButton(f)
    f.help:SetPoint("RIGHT", close, "LEFT", -3, 0)
    -- Kampfhinweis rechts in der Rudel-Zeile, damit er die Kopfzeile nicht überdeckt
    f.state = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.state:SetPoint("TOPRIGHT", -8, -27)
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(.5, .07, .09, .9)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 1, -22)
    rule:SetPoint("TOPRIGHT", -1, -22)

    local y = -26
    Section("Rudel", y)
    y = y - 16
    for i = 1, ROWS do
        local row = NewRow(f, "AssassinenZielFreund" .. i, tostring(i))
        row:SetPoint("TOPLEFT", 5, y)
        friendRows[i] = row
        y = y - ROW_H
    end
    Section("Feinde in der Nähe", y)
    y = y - 16
    for i = 1, ROWS do
        local row = NewRow(f, "AssassinenZielFeind" .. i, tostring(i))
        row:SetPoint("TOPLEFT", 5, y)
        enemyRows[i] = row
        y = y - ROW_H
    end
    if not S.targetListShown then f:Hide() end
end

-- Rudel (Mitglieder mit Addon, nach Entfernung) und Gruppenmitglieder ohne Addon
local function Friends()
    local out, seen = {}, {}   -- seen: kleingeschriebener Kurzname oder GUID -> Eintrag
    local me = (ns.ShortName(ns.Safe(UnitName("player"))) or ""):lower()
    local myGuid = ns.Safe(UnitGUID("player"))
    for name, p in pairs(Rudel.pack) do
        local key = (ns.ShortName(name) or name):lower()
        local dup = seen[key] or (p.guid and seen[p.guid])
        if key ~= me and not (p.guid and p.guid == myGuid) and not (dup and dup.t >= p.t) then
            local d = Karte.Offset(p.map, p.x, p.y)
            local where = Karte.Describe(p.map, p.x, p.y)
            local same = Rudel.SameLayer(p.map, p.layer)
            local e = { name = ns.ShortName(name) or name, class = p.class, dist = d, t = p.t,
                info = d and string.format("%d m", math.floor(d * 0.9144 / 10 + 0.5) * 10) or "fern",
                tip = (where or "Entfernung unbekannt") .. (same == false and " · anderer Layer" or "") }
            if dup then -- derselbe Spieler doppelt gemeldet: den neueren behalten
                for k, v in ipairs(out) do if v == dup then out[k] = e end end
            else
                out[#out + 1] = e
            end
            seen[key] = e
            if p.guid then seen[p.guid] = e end
        end
    end
    local raid = IsInRaid and IsInRaid()
    for i = 1, raid and (GetNumGroupMembers and GetNumGroupMembers() or 0) or 4 do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        local name = ns.Safe(UnitExists(unit)) and ns.ShortName(ns.Safe(UnitName(unit)))
        local guid = ns.Safe(UnitGUID(unit))
        local known = name and (seen[name:lower()] or (guid and seen[guid]))
        if known then
            known.tip = known.tip .. " · in deiner Gruppe"
        elseif name and name:lower() ~= me and not (guid and guid == myGuid) then
            local _, class = UnitClass(unit)
            local e = { name = name, class = ns.Safe(class), info = "Gruppe", tip = "In deiner Gruppe (ohne Addon keine Position)" }
            out[#out + 1] = e
            seen[name:lower()] = e
            if guid then seen[guid] = e end
        end
    end
    table.sort(out, function(a, b)
        if (a.dist ~= nil) ~= (b.dist ~= nil) then return a.dist ~= nil end
        if a.dist and b.dist and a.dist ~= b.dist then return a.dist < b.dist end
        return a.name < b.name
    end)
    return out
end

-- Feinde in der Nähe, gefährlichste zuerst
local function Enemies(friends)
    local out, skip = {}, {}
    for _, f in ipairs(friends or {}) do skip[f.name:lower()] = true end
    for _, e in ipairs(Spy.List("nah")) do
        local c = e.c
        if not skip[(c.name or ""):lower()] then -- Lua 5.1 im Spiel: kein goto
            local tier = Spy.Tier(e.score)
            local marks = (c.contract and not c.contract.done) and "Auftrag" or c.kos and "KOS" or nil
            out[#out + 1] = { name = c.name, realm = c.realm, class = c.class, color = { tier[3], tier[4], tier[5] },
                info = (marks and ("|cffff4040" .. marks .. "|r ") or "") .. (c.level and (c.level > 0 and c.level or "??") or "?"),
                tip = string.format("Bedrohung %d (%s)%s", e.score, tier[2], c.guild and (" · <" .. c.guild .. ">") or "") }
        end
    end
    return out
end

local function Fill(rows, list, isEnemy)
    local target = ns.Safe(UnitName("target"))
    for i, row in ipairs(rows) do
        local e = list[i]
        row.entry = e
        if e then
            row:SetAttribute("macrotext", "/targetexact " .. Target(e.name, e.realm))
            row.name:SetText("|c" .. ns.ClassColor(e.class) .. e.name .. "|r")
            row.info:SetText(e.info or "")
            if isEnemy then row.sq:SetColorTexture(e.color[1], e.color[2], e.color[3])
            else
                local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class] or { r = .7, g = .7, b = .7 }
                row.sq:SetColorTexture(c.r, c.g, c.b)
            end
            row.sq:Show()
            row.sel:SetShown(target ~= nil and target == e.name)
        else
            row:SetAttribute("macrotext", "")
            row.name:SetText("|cff5a5555–|r")
            row.info:SetText("")
            row.sq:Hide()
            row.sel:Hide()
        end
    end
end

function Ziele.Refresh()
    if not frame or not frame:IsShown() then return end
    if Locked() then
        frame.state:SetText("eingefroren (Kampf)")
        return
    end
    frame.state:SetText("")
    local friends = Friends()
    Fill(friendRows, friends, false)
    Fill(enemyRows, Enemies(friends), true)
end

function Ziele.Toggle()
    if not frame then return end
    if Locked() then
        ns.Print("Im Kampf lässt sich die Zielliste nicht öffnen oder schließen.")
        return
    end
    frame:SetShown(not frame:IsShown())
    S.targetListShown = frame:IsShown()
    Ziele.Refresh()
end

function Ziele.Init()
    S, UI, Spy, Karte, Rudel = ns.settings, ns.UI, ns.Spy, ns.Karte, ns.Rudel
    Build()
    local f = CreateFrame("Frame")
    for _, e in ipairs({ "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED", "GROUP_ROSTER_UPDATE" }) do pcall(f.RegisterEvent, f, e) end
    f:SetScript("OnEvent", Ziele.Refresh)
    C_Timer.NewTicker(1, Ziele.Refresh)
    Ziele.Refresh()
end
