-- Assassinen Kommando-Leiste – alles, was man im Kampf braucht, mit einem Klick statt per Befehl.
-- Keiner dieser Knöpfe ist eine geschützte Aktion, deshalb funktionieren alle auch mitten im Kampf
-- (nur die Zielliste lässt sich im Kampf nicht öffnen oder schließen, das verbietet das Spiel).

local ADDON_NAME, ns = ...
local Leiste = {}
ns.Leiste = Leiste

local BTN_W, BTN_H, GAP, PER_ROW = 46, 20, 2, 9
local S, UI, Spy, Rudel, Jagd
local frame
local buttons = {}

BINDING_NAME_ASSASSINEN_LEISTE = "Kommando-Leiste ein/aus"
BINDING_NAME_ASSASSINEN_RUDEL = "Rudel in der Nähe einladen"

local function Print(msg) ns.Print(msg) end
local function Safe(v) return ns.Safe(v) end

-- Feindlicher Spieler im Ziel als Akte, sonst nil
local function TargetContact()
    if not Safe(UnitExists("target")) or not Safe(UnitIsPlayer("target")) or not Safe(UnitCanAttack("player", "target")) then
        Print("Kein feindlicher Spieler im Ziel.")
        return
    end
    local name, realm = UnitName("target")
    name, realm = Safe(name), Safe(realm)
    if not name then Print("Das Spiel verbirgt gerade den Namen des Ziels.") return end
    local c = Spy.ContactFor(name, realm ~= "" and realm or nil)
    local _, class = UnitClass("target")
    c.class = Safe(class) or c.class
    local lv = Safe(UnitLevel("target"))
    if lv and lv ~= 0 then c.level = lv end
    return c
end

local function CallerFresh()
    local c = Rudel.Caller()
    return c and GetTime() - (c.t or 0) < 90
end

local function Muted() return S.snoozeUntil and time() < S.snoozeUntil end

-- Jeder Knopf: Beschriftung, Tooltip (Titel, Text), Linksklick, Rechtsklick, Zustand (an/aus/gesperrt)
local DEFS = {
    { id = "hilfe", label = "Hilfe", red = true,
        tip = { "Hilferuf", "Links: Hilferuf an die Gilde (Position + Feind)\nNochmal klicken oder Rechts: »bin sicher«, Ruf beenden" },
        left = function()
            if Rudel.HelpActive() then Rudel.EndHelp("sicher"); Print("Hilferuf beendet.") else Rudel.CallHelp(false) end
        end,
        right = function() if Rudel.HelpActive() then Rudel.EndHelp("sicher"); Print("Hilferuf beendet.") end end,
        state = function() return Rudel.HelpActive() and "on" end },
    { id = "komme", label = "Komme",
        tip = { "Ich komme", "Antwortet auf den letzten Hilferuf: der Rufer sieht, dass du unterwegs bist, und der Pfeil zeigt zu ihm." },
        left = function() Rudel.Respond() end,
        state = function() return CallerFresh() and "on" or "off" end },
    { id = "ziel", label = "Ziel",
        tip = { "Ziel ansagen", "Sagt dein aktuelles Ziel der Gruppe (sonst der Gilde in der Nähe) an – mit Markierung, Karte und Pfeil." },
        left = function() Rudel.CallTarget() end },
    { id = "plan", label = "Plan",
        tip = { "Opener-Plan", "Verteilt Rollen (Stun, Kick, Blind …) an die Gruppe." },
        left = function() Rudel.Plan("") end },
    { id = "los", label = "Los",
        tip = { "Opener-Countdown", "Links: 3 Sekunden · Rechts: 5 Sekunden\nDie ganze Gruppe sieht 3 – 2 – 1 – LOS!" },
        left = function() Jagd.Countdown(3) end,
        right = function() Jagd.Countdown(5) end },
    { id = "sammeln", label = "Sammeln",
        tip = { "Sammelpunkt", "Links: Sammelpunkt hier setzen (Gruppe, sonst Gilde in der Nähe)\nRechts: Sammelpunkt aufheben\nAlt+Klick auf die Weltkarte setzt ihn an jede Stelle." },
        left = function() local me = ns.Karte.me; Jagd.Rally(me.map, me.x, me.y, nil) end,
        right = function() Jagd.EndRally() end,
        state = function() return Jagd.MyRally() and "on" end },
    { id = "wache", label = "Wache",
        tip = { "Wachposten", "Jeder Feind, den du siehst, geht sofort an die Gilde. Nochmal klicken beendet ihn (oder mehr als 90 m weggehen)." },
        left = function() Jagd.ToggleWatch() end,
        state = function() return Jagd.Watching() and "on" end },
    { id = "rudel", label = "Rudel",
        tip = { "Rudel bilden", "Lädt alle Rudelmitglieder in der Nähe (bis ca. 350 m) in deine Gruppe ein, die nächsten zuerst. Ihr Addon nimmt die Einladung von selbst an." },
        left = function() Rudel.FormPack() end },
    { id = "kos", label = "KOS",
        tip = { "KOS", "Links: dein Ziel auf die KOS-Liste setzen oder entfernen\nRechts: Akte deines Ziels öffnen" },
        left = function() local c = TargetContact(); if c then Spy.SetKos(c, not c.kos, "") end end,
        right = function()
            local c = TargetContact()
            if c then local _, key = Spy.Find(c.name); if key then UI.OpenIntel(key) end end
        end },
    { id = "bereit", label = "Bereit",
        tip = { "Bereitschaft", "Links: Bereitschaftscheck in der Gruppe (Gift, Cooldowns, Leben)\nRechts: an die ganze Gilde" },
        left = function() ns.Bereit.Check("") end,
        right = function() ns.Bereit.Check("gilde") end },
    { id = "pfeil", label = "Pfeil",
        tip = { "Pfeil", "Links: Pfeil ausblenden\nRechts: Pfeil ganz ein- oder ausschalten" },
        left = function() Jagd.Clear() end,
        right = function() Jagd.Slash("pfeil", S.arrow == false and "an" or "aus", S.arrow == false and "an" or "aus") end,
        state = function() return S.arrow == false and "off" end },
    { id = "ruhe", label = "Ruhe",
        tip = { "Ruhe", "Links: Warnungen 15 Minuten stumm – nochmal klicken schaltet sie wieder an\nRechts: 60 Minuten stumm" },
        left = function() Spy.Slash("ruhe", "", Muted() and "aus" or "15") end,
        right = function() Spy.Slash("ruhe", "", "60") end,
        state = function() return Muted() and "on" end },
    { id = "radar", label = "Radar",
        tip = { "Jagd-Radar", "" },
        tooltip = function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Jagd-Radar – letzte 30 Minuten", 1, .25, .25)
            local list = Spy.Radar(30)
            for i, z in ipairs(list) do
                if i > 8 then break end
                GameTooltip:AddDoubleLine(z.zone .. (z.hot and ("  |cff999999" .. z.hot .. "|r") or ""),
                    string.format("%d%s", z.n, z.kos > 0 and string.format(" (|cffff4040%d KOS|r)", z.kos) or ""), .9, .9, .9, 1, 1, 1)
            end
            if #list == 0 then GameTooltip:AddLine("Gerade nirgends Feinde gesichtet oder gemeldet.", .6, .6, .6, true) end
            GameTooltip:AddLine("Eigene Sichtungen und Meldungen der Gilde · Klick: im Chat zeigen", .5, .5, .5, true)
            GameTooltip:Show()
        end,
        left = function() Rudel.PrintRadar() end },
    { id = "rang", label = "Rang",
        tip = { "Rangliste", "" },
        tooltip = function(self) ns.Bilanz.Tooltip(self) end,
        left = function() ns.Bilanz.Slash("rang", "", "") end },
    { id = "spaeher", label = "Späher",
        tip = { "Späher", "Feinde in der Nähe ein- oder ausblenden. Klick auf einen Feind nimmt ihn ins Ziel." },
        left = function() UI.ToggleScanner() end },
    { id = "ziele", label = "Ziele",
        tip = { "Zielliste", "Rudel und Feinde mit einem Klick anvisieren. Im Kampf nicht zu öffnen – vorher aufmachen." },
        left = function() ns.Ziele.Toggle() end },
    { id = "intel", label = "Intel",
        tip = { "Intel-Zentrale", "Akten, KOS, Aufträge, Nemesis, Opfer, Fehden." },
        left = function() UI.ToggleIntel() end },
    { id = "toene", label = "Töne",
        tip = { "Töne", "Links: Ton für jede Warnung einzeln auswählen\nRechts: alle Töne an/aus" },
        left = function() ns.Toene.Toggle() end,
        right = function() Spy.Slash("toene", "", S.spySound and "aus" or "an") end,
        state = function() return not S.spySound and "off" end },
}

local function Look(b)
    local st = b.def.state and b.def.state() or nil
    b.st = st or ""
    if b.isSkinned == true then
        ns.Design.SetKind(b, (st == "on" or b.def.red) and "red" or "iron", st == "off")
        return
    end
    if b.SetBackdropColor then
        if st == "on" then b:SetBackdropColor(.55, .05, .08, .95)
        elseif b.def.red then b:SetBackdropColor(.38, .04, .06, .95)
        else b:SetBackdropColor(.09, .08, .09, .95) end
    end
    if st == "off" then b.text:SetTextColor(.45, .42, .42)
    elseif st == "on" or b.def.red then b.text:SetTextColor(1, .85, .85)
    else b.text:SetTextColor(.8, .77, .77) end
end

local function Run(fn)
    if not fn then return end
    local ok, err = pcall(fn)
    if not ok then Print("Fehler: " .. tostring(err)) end
end

local function Build()
    local f = CreateFrame("Frame", "AssassinenLeiste", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame = f
    UI.Window(f, .85, { border = 12, dark = true })
    local rows = math.ceil(#DEFS / PER_ROW)
    f:SetSize(PER_ROW * (BTN_W + GAP) - GAP + 26, rows * (BTN_H + GAP) - GAP + 8 + 16)
    f:SetFrameStrata("MEDIUM")
    UI.MakeMovable(f, "barPos")
    UI.RestorePos(f, "barPos", "BOTTOM", UIParent, "BOTTOM", 0, 150)

    -- Griff links: Flügelschwert, zum Ziehen
    local wings = UI.Art(f, "wings", 16)
    wings:SetPoint("TOPLEFT", 4, -14)

    -- Tagesbilanz unter den Knöpfen
    f.stats = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.stats:SetPoint("BOTTOMLEFT", 24, 5)
    f.stats:SetJustifyH("LEFT")

    for i, def in ipairs(DEFS) do
        local b = UI.TextButton(f, def.label, BTN_W, nil, nil)
        b:SetHeight(BTN_H)
        b.def = def
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local col, row = (i - 1) % PER_ROW, math.floor((i - 1) / PER_ROW)
        b:SetPoint("TOPLEFT", 22 + col * (BTN_W + GAP), -4 - row * (BTN_H + GAP))
        b:SetScript("OnClick", function(self, button)
            if button == "RightButton" then Run(self.def.right or self.def.left) else Run(self.def.left) end
            Look(self)
            Leiste.Refresh()
        end)
        b:SetScript("OnEnter", function(self)
            if self.SetBackdropBorderColor then self:SetBackdropBorderColor(.7, .12, .15) end
            if self.isSkinned == true then ns.Design.Hover(self, true) end
            if self.def.tooltip then pcall(self.def.tooltip, self) return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(self.def.tip[1], 1, .25, .25)
            GameTooltip:AddLine(self.def.tip[2], .85, .85, .85, true)
            if self.st == "on" then GameTooltip:AddLine("Gerade aktiv", 1, .4, .4) end
            if self.def.id == "komme" and self.st == "off" then GameTooltip:AddLine("Gerade ruft niemand um Hilfe.", .5, .5, .5) end
            GameTooltip:AddLine("Leiste verschieben: am Flügelschwert ziehen · Alt+Klick auf den Minimap-Knopf blendet sie aus", .5, .5, .5, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function(self)
            if self.SetBackdropBorderColor then self:SetBackdropBorderColor(.24, .22, .24) end
            if self.isSkinned == true then ns.Design.Hover(self, false) end
            GameTooltip:Hide()
        end)
        buttons[#buttons + 1] = b
        Look(b)
    end
    if S.barShown == false then f:Hide() end
end

local lastStats = -999
function Leiste.Refresh()
    if not frame or not frame:IsShown() then return end
    for _, b in ipairs(buttons) do Look(b) end
    if ns.Bilanz and GetTime() - lastStats >= 2 then
        lastStats = GetTime()
        local ok, line = pcall(ns.Bilanz.Line)
        local okP, place = pcall(ns.Bilanz.MyPlace)
        if not okP then place = nil end
        frame.stats:SetText((ok and line or "") .. (place and string.format("  ·  Woche: Platz %d", place) or ""))
    end
end

function Leiste.Stats() return frame and frame.stats:GetText() end

function Leiste.Toggle()
    if not frame then return end
    frame:SetShown(not frame:IsShown())
    S.barShown = frame:IsShown()
    Print("Kommando-Leiste " .. (S.barShown and "eingeblendet." or "ausgeblendet – zurück mit Alt+Klick auf den Minimap-Knopf oder /assa leiste."))
    Leiste.Refresh()
end

function Leiste.Button(id)
    for _, b in ipairs(buttons) do if b.def.id == id then return b end end
end

function Leiste.Init()
    S, UI, Spy, Rudel, Jagd = ns.settings, ns.UI, ns.Spy, ns.Rudel, ns.Jagd
    Build()
    C_Timer.NewTicker(.5, Leiste.Refresh)
end
