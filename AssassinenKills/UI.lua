-- Assassinen Späher – Fenster: Späher-Liste, Intel-Zentrale, Minimap-Knopf, Warnrand.

local ADDON_NAME, ns = ...
local UI = {}
ns.UI = UI

local Spy
local S
local BT = BackdropTemplateMixin and "BackdropTemplate" or nil
local RED = { .5, .07, .09 }     -- Blutrot aus dem Logo
local EDGE = { .24, .22, .24 }   -- dezenter Rand für Knöpfe und Felder
local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
-- Gilden-Grafiken: Datei, Seitenverhältnis, genutzter Bereich der Textur
local ART = {
    wordmark = { file = "wordmark", ratio = 2.876, t0 = .1523, t1 = .8477 },
    wings = { file = "wings", ratio = 1.219, t0 = .0859, t1 = .9062 },
    logo = { file = "logo", ratio = 1, t0 = 0, t1 = 1 },
}
local BACKDROP = { bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 }
local SKULL = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12|t"
local CROSS = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:12|t"
local ROW_H = 16

local scanner, intelFrame, minimapButton, flash
local scannerRows = {}
local scannerModes = { { "nah", "Nah" }, { "kos", "KOS" }, { "verlauf", "Verlauf" } }

local D = ns.Design
local function Book() return D and D.On() end

-- Dunkler Grund mit feinem Rand. Im Blutbuch-Design: zarter Tintenrahmen auf dem Pergament
local function Skin(f, alpha)
    if not f.SetBackdrop then return end
    f:SetBackdrop(BACKDROP)
    if Book() then
        f:SetBackdropColor(.35, .22, .1, .07)
        f:SetBackdropBorderColor(.35, .22, .12, .45)
        return
    end
    f:SetBackdropColor(.03, .025, .03, alpha or .9)
    f:SetBackdropBorderColor(EDGE[1], EDGE[2], EDGE[3])
end

-- Gilden-Grafik als Textur; height ist die Höhe auf dem Bildschirm
local function Art(parent, kind, height, layer)
    local a = ART[kind]
    local tex = parent:CreateTexture(nil, layer or "ARTWORK")
    tex:SetTexture(MEDIA .. a.file)
    tex:SetTexCoord(0, 1, a.t0, a.t1)
    tex:SetSize(height * a.ratio, height)
    return tex
end

-- Hauptfenster: Banner als Hintergrund, zweite Rahmenlinie, Kopf mit Flügelschwert und Schriftzug.
-- Im Blutbuch-Design: Pergament im Lederrahmen, Titelschild, Siegel und ein Blutfleck
local function Decorate(f, subtitle)
    if Book() then
        D.Window(f, { border = 18, seal = "BOTTOMRIGHT", sealSize = 52, sealX = 18, sealY = -18, blood = 6, bloodSize = 140 })
        local wings = Art(f, "wings", 40)
        wings:SetPoint("TOPLEFT", 16, -10)
        local _, title = D.Banner(f, subtitle, 260)
        return title
    end
    if f.SetBackdropBorderColor then f:SetBackdropBorderColor(RED[1], RED[2], RED[3]) end
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetTexture(MEDIA .. "bg")
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    bg:SetVertexColor(1, 1, 1, .6)
    local line = CreateFrame("Frame", nil, f, BT)
    line:SetPoint("TOPLEFT", 3, -3)
    line:SetPoint("BOTTOMRIGHT", -3, 3)
    if line.SetBackdrop then
        line:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        line:SetBackdropBorderColor(.42, .4, .42, .35)
    end
    line:EnableMouse(false)
    local wings = Art(f, "wings", 42)
    wings:SetPoint("TOPLEFT", 10, -5)
    local word = Art(f, "wordmark", 42)
    word:SetPoint("LEFT", wings, "RIGHT", 2, 0)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", word, "RIGHT", 12, 0)
    title:SetTextColor(.86, .83, .83)
    title:SetText(subtitle)
    return title
end

-- Knopf im Blutbuch-Design: Leder, Pergament oder Eisen ("x" zum Schließen ist immer Eisen)
local function BookButton(parent, label, width, onClick, tip, kind)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 18, 16)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER", 0, 0)
    b.text:SetText(label)
    b.text:SetShadowColor(0, 0, 0, 0)
    D.Button(b, kind or (label == "x" and "iron" or "parchment"))
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        D.Hover(self, true)
        if tip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self) D.Hover(self, false); GameTooltip:Hide() end)
    return b
end

local function TextButton(parent, label, width, onClick, tip)
    if Book() then return BookButton(parent, label, width, onClick, tip) end
    local b = CreateFrame("Button", nil, parent, BT)
    b:SetSize(width or 18, 16)
    Skin(b, .9)
    if b.SetBackdropColor then b:SetBackdropColor(.09, .08, .09, .95) end
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    b.text:SetTextColor(.8, .77, .77)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        if self.SetBackdropBorderColor then self:SetBackdropBorderColor(.7, .12, .15) end
        self.text:SetTextColor(1, 1, 1)
        if tip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        if self.SetBackdropBorderColor then self:SetBackdropBorderColor(EDGE[1], EDGE[2], EDGE[3]) end
        self.text:SetTextColor(.8, .77, .77)
        GameTooltip:Hide()
    end)
    return b
end

local function MakeMovable(f, posKey)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        S[posKey] = { p, rp, x, y }
    end)
end

local function RestorePos(f, posKey, ...)
    f:ClearAllPoints()
    local pos = S[posKey]
    if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint(...) end
end

-- Roter Hilferuf-Knopf: ein normaler Knopf, der Hilferuf ist keine geschützte Aktion und geht auch im Kampf
local helpButtons = {}
local function HelpLook(b, hover)
    if b.SetBackdropColor then b:SetBackdropColor(hover and .55 or .38, .04, .06, .95) end
    if b.SetBackdropBorderColor then b:SetBackdropBorderColor(hover and .95 or .7, .15, .18) end
end
local function HelpButton(parent)
    local b = TextButton(parent, "Hilfe", 40, function(self)
        if not (ns.Rudel and ns.Rudel.CallHelp(false)) then return end
        for _, hb in ipairs(helpButtons) do
            hb.text:SetText("Gesendet")
            hb.resetAt = GetTime() + 4
        end
    end)
    b:SetWidth(52)
    if Book() then D.SetKind(b, "red") else b.text:SetTextColor(1, .85, .85) end
    HelpLook(b, false)
    b:SetScript("OnEnter", function(self)
        HelpLook(self, true)
        if self.isSkinned == true then D.Hover(self, true) end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Hilferuf an die Gilde", 1, .25, .25)
        GameTooltip:AddLine("Schickt deine Position und den Feind an alle Mitglieder mit Addon. Geht auch im Kampf.", .85, .85, .85, true)
        GameTooltip:AddLine("Eigene Taste: Tastaturbelegung → AddOns → Assassinen", .5, .5, .5, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self) HelpLook(self, false); if self.isSkinned == true then D.Hover(self, false) end; GameTooltip:Hide() end)
    b:SetScript("OnUpdate", function(self)
        if self.resetAt and GetTime() >= self.resetAt then self.resetAt = nil; self.text:SetText("Hilfe") end
    end)
    helpButtons[#helpButtons + 1] = b
    return b
end

-- Kopfzeile schmaler Fenster: Flügelschwert, Titel, Trennlinie bei y = -22
local function Header(f, text)
    local wings = Art(f, "wings", 18)
    wings:SetPoint("TOPLEFT", 4, -2)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", wings, "RIGHT", 4, 0)
    title:SetText(text or "")
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(RED[1], RED[2], RED[3], .9)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 1, -22)
    rule:SetPoint("TOPRIGHT", -1, -22)
    if Book() then
        wings:ClearAllPoints()
        wings:SetPoint("TOPLEFT", 6, -3)
        D.TitleFont(title, 15)
        title.noInk = true
        title:SetTextColor(D.BLOOD[1], D.BLOOD[2], D.BLOOD[3])
        title:SetShadowColor(0, 0, 0, 0)
        rule:SetColorTexture(D.BLOOD[1], D.BLOOD[2], D.BLOOD[3], .55)
        rule:SetPoint("TOPLEFT", 8, -23)
        rule:SetPoint("TOPRIGHT", -8, -23)
    end
    return title, wings, rule
end

-- Schmales Fenster (Späher, Ziele, Töne …): Pergament im Lederrahmen, sonst dunkel
local function Window(f, alpha, opts)
    if Book() then D.Window(f, opts or { border = 12 }) else Skin(f, alpha) end
end

UI.Skin, UI.TextButton, UI.MakeMovable, UI.RestorePos, UI.Art, UI.Decorate = Skin, TextButton, MakeMovable, RestorePos, Art, Decorate
UI.Header, UI.Window, UI.Book = Header, Window, Book
function UI.Ink(f) if Book() then D.Ink(f) end end
function UI.C(kind) return D and D.C(kind) or "" end
function UI.Name(c) return Spy.Colored(c, true) end
UI.HelpButton = HelpButton

local function ClassName(token)
    return token and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token] or token) or "?"
end

local function LevelText(c)
    return c.level and (c.level > 0 and tostring(c.level) or "??") or "?"
end

local function Marks(c)
    return (c.contract and not c.contract.done and CROSS or "") .. (c.kos and SKULL or "")
end

-- Tooltip mit allem, was wir über einen Feind wissen
function UI.ContactTooltip(owner, key, c, hint)
    local score = Spy.Threat(key, c)
    local tier = Spy.Tier(score)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(Marks(c) .. Spy.Colored(c) .. (c.guild and ("  |cffaaaaaa<" .. c.guild .. ">|r") or ""))
    GameTooltip:AddLine(string.format("Stufe %s %s %s", LevelText(c), c.race or "", ClassName(c.class)), .8, .8, .8)
    GameTooltip:AddLine(string.format("Bedrohung: %d (%s)", score, tier[2]), tier[3], tier[4], tier[5])
    GameTooltip:AddLine(string.format("Bilanz: |cff00ff00%d Siege|r / |cffff4040%d Niederlagen|r", c.wins or 0, c.losses or 0))
    GameTooltip:AddLine(string.format("Zuletzt: %s, %s", c.sub ~= "" and c.sub or c.zone or "?", Spy.Ago(c.last)), .8, .8, .8)
    GameTooltip:AddLine(string.format("Gesichtet: %d×", c.seen or 0), .6, .6, .6)
    if c.reported then GameTooltip:AddLine(string.format("Gemeldet von %s %s", c.reportBy or "?", Spy.Ago(c.reported)), .6, .6, .6) end
    if c.kos then GameTooltip:AddLine("KOS" .. (c.kosReason and (": " .. c.kosReason) or ""), 1, .2, .2) end
    if c.contract then
        local ct = c.contract
        GameTooltip:AddLine(ct.done and ("Auftrag erfüllt von " .. (ct.doneBy or "?")) or
            ("Gildenauftrag von " .. (ct.by or "?") .. (ct.reason and (": " .. ct.reason) or "")), 1, .82, 0, true)
    end
    if c.saved then GameTooltip:AddLine("Gemerkt (eigenes Profil)", 1, .82, 0) end
    if c.note then GameTooltip:AddLine("Warum auf der Liste: " .. c.note, 1, 1, 1, true) end
    for who, s in pairs(c.shared or {}) do
        if s.reason then GameTooltip:AddLine(who .. ": " .. s.reason, .85, .75, .55, true) end
    end
    if c.log and #c.log > 0 then
        local e = c.log[#c.log]
        GameTooltip:AddLine(string.format("Zuletzt erlebt (%s): %s", date("%d.%m.", e.t), e.text), .9, .8, .6, true)
    end
    GameTooltip:AddLine(hint or "Links: Akte öffnen · Rechts: KOS umschalten", .5, .5, .5)
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Späher-Fenster
---------------------------------------------------------------------------

local function ScannerMode()
    for _, m in ipairs(scannerModes) do
        if m[1] == S.scannerMode then return m end
    end
    return scannerModes[1]
end

-- Anvisieren ist eine geschützte Aktion: Über jeder Späher-Zeile liegt ein sicherer Knopf mit /targetexact.
-- Die Knöpfe hängen bewusst nicht am Späher, sonst dürfte sich der Späher im Kampf nicht mehr verändern.
-- Im Kampf blendet das Spiel sie selbst aus (die Liste sortiert sich dann um), dann gilt der normale Zeilenklick.
local targetHolder, targetButtons = nil, {}
local lastCombatHint = 0

local function Locked()
    return InCombatLockdown and InCombatLockdown()
end

local function TargetName(c)
    if c.realm and c.realm ~= "" and c.realm ~= GetRealmName() then return c.name .. "-" .. c.realm end
    return c.name
end

local function RowHint()
    if targetHolder then return "Links: anvisieren · Shift+Links: Akte · Rechts: KOS" end
    return "Links: Akte öffnen · Rechts: KOS umschalten"
end

-- secure: Klick kam über den sicheren Knopf, das Anvisieren hat das Spiel schon erledigt
local function RowClick(row, button, secure)
    if not row.key then return end
    if button == "RightButton" then
        Spy.SetKos(row.c, not row.c.kos, "")
    elseif (IsShiftKeyDown and IsShiftKeyDown()) or not targetHolder then
        UI.OpenIntel(row.key)
    elseif not secure and GetTime() - lastCombatHint > 8 then
        lastCombatHint = GetTime()
        ns.Print("Im Kampf erlaubt das Spiel kein Anvisieren per Klick im Späher. Nutze die Zielliste-Tasten (Tastaturbelegung → AddOns → Assassinen). Shift+Klick öffnet die Akte.")
    end
end

local function HideTargetButtons()
    if Locked() then return end
    for _, b in ipairs(targetButtons) do
        b.row = nil
        b:SetAttribute("macrotext", "")
        b:Hide()
    end
end

local function BuildTargetButtons()
    if not RegisterStateDriver then return end
    local ok, holder = pcall(CreateFrame, "Frame", "AssassinenSpaeherZiele", UIParent)
    if not ok or not holder then return end
    holder:SetAllPoints(UIParent)
    holder:SetFrameStrata("MEDIUM")
    for i = 1, #scannerRows do
        local okB, b = pcall(CreateFrame, "Button", "AssassinenSpaeherZiel" .. i, holder, "SecureActionButtonTemplate")
        if not okB or not b then return end
        b:RegisterForClicks("AnyUp", "AnyDown")
        b:SetAttribute("type1", "macro")
        b:SetAttribute("macrotext", "")
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(.8, .1, .2, .25)
        b:SetScript("OnEnter", function(self) if type(self.row) == "table" and self.row.key then UI.ContactTooltip(self, self.row.key, self.row.c, RowHint()) end end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- Je nach Client kommt der Klick beim Drücken und Loslassen: Akte und KOS nur einmal, beim Loslassen
        b:SetScript("PostClick", function(self, button, down)
            if down or type(self.row) ~= "table" then return end
            RowClick(self.row, button, true)
        end)
        b:Hide()
        targetButtons[i] = b
    end
    RegisterStateDriver(holder, "visibility", "[combat] hide; show")
    targetHolder = holder
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:SetScript("OnEvent", function() UI.Refresh() end)
end

-- Legt die sicheren Knöpfe genau über die sichtbaren Zeilen (nur außerhalb des Kampfes erlaubt)
local function PlaceTargetButtons()
    if not targetHolder or Locked() then return end
    local hs = targetHolder:GetEffectiveScale()
    for i, b in ipairs(targetButtons) do
        local row = scannerRows[i]
        local left, top = row:GetLeft(), row:GetTop()
        if type(row.c) == "table" and row.c.name and scanner:IsShown() and row:IsShown() and left and top then
            local s = row:GetEffectiveScale() / hs
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * s, top * s)
            b:SetSize(row:GetWidth() * s, row:GetHeight() * s)
            b:SetFrameLevel(scanner:GetFrameLevel() + 10)
            b:SetAttribute("macrotext", "/targetexact " .. TargetName(row.c))
            b.row = row
            b:Show()
        else
            b.row = nil
            b:SetAttribute("macrotext", "")
            b:Hide()
        end
    end
end

local function BuildScanner()
    local f = CreateFrame("Frame", "AssassinenScanner", UIParent, BT)
    scanner = f
    Window(f, .85, { border = 12, seal = "BOTTOMRIGHT", sealSize = 30, sealX = 14, sealY = -14 })
    f:SetSize(256, 40)
    f:SetFrameStrata("MEDIUM")
    MakeMovable(f, "scannerPos")
    RestorePos(f, "scannerPos", "CENTER", UIParent, "CENTER", -380, 160)

    -- Der Schriftzug wäre hier zu klein zum Lesen: Flügelschwert und klarer Titel, darunter eine Blutlinie
    f.title = Header(f)
    f.close = TextButton(f, "x", 16, function() f:Hide(); S.scannerShown = false end, "Schließen (/assa spy)")
    f.close:SetPoint("TOPRIGHT", -4, -4)
    f.intel = TextButton(f, "Intel", 34, function() UI.ToggleIntel() end, "Intel-Zentrale öffnen")
    f.intel:SetPoint("RIGHT", f.close, "LEFT", -3, 0)
    f.mode = TextButton(f, "Nah", 50, function()
        local cur = ScannerMode()
        for i, m in ipairs(scannerModes) do
            if m == cur then S.scannerMode = scannerModes[i % #scannerModes + 1][1] end
        end
        UI.Refresh()
    end, "Liste wechseln: Nah · KOS · Verlauf")
    f.mode:SetPoint("RIGHT", f.intel, "LEFT", -3, 0)
    f.help = HelpButton(f)
    f.help:SetPoint("RIGHT", f.mode, "LEFT", -3, 0)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.empty:SetPoint("TOPLEFT", 8, -26)
    f.empty:SetText("Keine Feinde in Sicht.")

    for i = 1, 25 do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(246, ROW_H)
        row:SetPoint("TOPLEFT", 5, -22 - (i - 1) * ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(.8, .1, .2, .25)
        row.sq = row:CreateTexture(nil, "ARTWORK")
        row.sq:SetSize(8, 8)
        row.sq:SetPoint("LEFT", 2, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.sq, "RIGHT", 5, 0)
        row.name:SetJustifyH("LEFT")
        row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.info:SetPoint("RIGHT", -2, 0)
        row.info:SetJustifyH("RIGHT")
        row:SetScript("OnEnter", function(self) if self.key then UI.ContactTooltip(self, self.key, self.c, RowHint()) end end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self, button) RowClick(self, button, false) end)
        row:Hide()
        scannerRows[i] = row
    end

    UI.Ink(f)
    if S.scannerShown == false then f:Hide() end
    BuildTargetButtons()
    f:HookScript("OnDragStart", HideTargetButtons)
    f:HookScript("OnHide", HideTargetButtons)
    f:HookScript("OnDragStop", function() UI.Refresh() end)
end

local function RefreshScanner()
    if not scanner then return end
    local mode = ScannerMode()
    local list = Spy.List(mode[1])
    local n = math.min(#list, S.rows or 10)
    for i, row in ipairs(scannerRows) do
        local e = list[i]
        if i <= n and e then
            local tier = Spy.Tier(e.score)
            row.key, row.c = e.key, e.c
            row.sq:SetColorTexture(tier[3], tier[4], tier[5])
            row.name:SetText(Marks(e.c) .. UI.Name(e.c))
            local cls = ClassName(e.c.class)
            if Book() then cls = "|c" .. D.ClassHex(e.c.class) .. cls .. "|r" end
            row.info:SetText(LevelText(e.c) .. " " .. cls)
            row:SetAlpha((mode[1] == "nah" and e.age and e.age > 20) and (Book() and .8 or .55) or 1)
            row:Show()
        else
            row.key, row.c = nil, nil
            row:Hide()
        end
    end
    scanner.mode.text:SetText(mode[2])
    scanner.title:SetText(string.format("%sSpäher|r  %s%d|r%s", UI.C("title"), UI.C("dim"), #list,
        (ns.Jagd and ns.Jagd.Watching()) and ("  " .. UI.C("bad") .. "Wache|r") or ""))
    scanner.empty:SetShown(n == 0)
    scanner.empty:SetText(mode[1] == "nah" and "Keine Feinde in Sicht." or "Liste ist leer.")
    scanner:SetHeight(26 + math.max(n, 1) * ROW_H + 2)
    PlaceTargetButtons()
end

function UI.ToggleScanner()
    if scanner:IsShown() then scanner:Hide() else scanner:Show() end
    S.scannerShown = scanner:IsShown()
    UI.Refresh()
end

function UI.OnContact(key, c, score)
    if scanner and S.spyAuto and not scanner:IsShown() and not Spy.Muted() and not Spy.Calm() then
        scanner:Show()
    end
end

---------------------------------------------------------------------------
-- Intel-Zentrale
---------------------------------------------------------------------------

local intelTabs = {
    { "akten", "Akten" }, { "kos", "KOS" }, { "auftraege", "Aufträge" }, { "nemesis", "Nemesis" }, { "opfer", "Opfer" },
    { "fehde", "Fehden" }, { "gemerkt", "Gemerkt" },
}
local LOG_ROWS = 3
local INTEL_ROWS = 18 -- im Buch: 15 (siehe BuildIntel)

local function SelectContact(key)
    intelFrame.selected = key
    UI.Refresh()
end

local function BuildIntel()
    local f = CreateFrame("Frame", "AssassinenIntelFrame", UIParent, BT)
    intelFrame = f
    local book = Book()
    local W, H = 640, 464
    if book then
        W, H = 660, math.floor(660 / D.BOOK_RATIO)
        INTEL_ROWS = 15
        D.Book(f)
    else
        Skin(f, .96)
    end
    f:SetSize(W, H)
    f:SetFrameStrata("DIALOG")
    MakeMovable(f, "intelPos")
    RestorePos(f, "intelPos", "CENTER", UIParent, "CENTER", 0, 40)
    f:Hide()
    table.insert(UISpecialFrames, "AssassinenIntelFrame") -- Escape schließt
    f.tab, f.offset = "akten", 0

    local leftPage, rightPage
    if book then
        D.Banner(f, "Intel-Zentrale", 230)
        leftPage, rightPage = D.Page(f, "left", W, H), D.Page(f, "right", W, H)
        D.Seal(f, 48, "BOTTOMRIGHT", -6, 12)
    else
        Decorate(f, "Intel-Zentrale")
    end
    local close = TextButton(f, "x", 18, function() f:Hide() end, "Schließen")
    close:SetPoint("TOPRIGHT", book and -18 or -8, book and -14 or -8)

    f.tabButtons = {}
    local prev
    for i, t in ipairs(intelTabs) do
        local b = TextButton(f, t[2], book and 59 or 58, function() f.tab, f.offset = t[1], 0; UI.Refresh() end)
        b:SetHeight(book and 19 or 20)
        if book then
            -- im Buch zwei Reihen zu vier Reitern oben auf der linken Seite
            b:SetPoint("TOPLEFT", leftPage, "TOPLEFT", ((i - 1) % 4) * 62, -math.floor((i - 1) / 4) * 22)
        elseif prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 12, -56) end
        b.id = t[1]
        f.tabButtons[#f.tabButtons + 1] = b
        prev = b
    end

    f.search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.search:SetSize(book and 180 or 150, 20)
    if book then f.search:SetPoint("TOPRIGHT", leftPage, "TOPRIGHT", -4, -46) else f.search:SetPoint("TOPRIGHT", -14, -56) end
    f.search:SetAutoFocus(false)
    f.search:SetScript("OnTextChanged", function() f.offset = 0; UI.Refresh() end)
    f.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("RIGHT", f.search, "LEFT", -8, 0)
    hint:SetText("Suche")

    -- Liste links
    local list = CreateFrame("Frame", nil, f, BT)
    Skin(list, .6)
    if book then list:SetPoint("TOPLEFT", leftPage, "TOPLEFT", 0, -72) else list:SetPoint("TOPLEFT", 12, -84) end
    local rowW = book and 236 or 292
    list:SetSize(rowW + 8, INTEL_ROWS * 18 + 8)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        f.offset = math.max(0, f.offset - delta * 3)
        UI.Refresh()
    end)
    f.rows = {}
    for i = 1, INTEL_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(rowW, 18)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 18)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(.8, .1, .2, .25)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        if book then row.sel:SetColorTexture(.55, .08, .04, .22) else row.sel:SetColorTexture(.8, .1, .2, .45) end
        row.sq = row:CreateTexture(nil, "ARTWORK")
        row.sq:SetSize(8, 8)
        row.sq:SetPoint("LEFT", 3, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.sq, "RIGHT", 6, 0)
        row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.info:SetPoint("RIGHT", -4, 0)
        row:SetScript("OnClick", function(self) if self.key then SelectContact(self.key) end end)
        row:SetScript("OnEnter", function(self) if self.key then UI.ContactTooltip(self, self.key, self.c) end end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.rows[i] = row
    end

    -- Akte rechts
    local d = CreateFrame("Frame", nil, f, BT)
    if book then
        d:SetAllPoints(rightPage)
    else
        Skin(d, .6)
        d:SetPoint("TOPLEFT", list, "TOPRIGHT", 10, 0)
        d:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 38)
    end
    f.detail = d
    d.emblem = Art(d, "logo", book and 190 or 240)
    d.emblem:SetPoint("CENTER", 0, -6)
    d.emblem:SetAlpha(book and .4 or .75)
    local function Line(font, y, anchor)
        local fs = d:CreateFontString(nil, "OVERLAY", font)
        fs:SetPoint("TOPLEFT", anchor or d, anchor and "BOTTOMLEFT" or "TOPLEFT", anchor and 0 or (book and 2 or 10), y)
        fs:SetWidth(book and 232 or 280)
        fs:SetJustifyH("LEFT")
        return fs
    end
    d.name = Line("GameFontNormalLarge", book and -2 or -10)
    if book then D.TitleFont(d.name, 20) end
    d.sub = Line("GameFontHighlightSmall", -4, d.name)
    d.threat = Line("GameFontNormalSmall", -5, d.sub)
    d.where = Line("GameFontHighlightSmall", -3, d.threat)
    d.report = Line("GameFontDisableSmall", -2, d.where)
    d.contract = Line("GameFontNormalSmall", -2, d.report)

    -- Eigenes Profil: warum auf der Liste, Erlebnisse mit Datum
    local function Box(anchor, w)
        local e = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        e:SetSize(w, 20)
        e:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 6, -2)
        e:SetAutoFocus(false)
        e:SetMaxLetters(200)
        e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        return e
    end
    local boxW = book and 222 or 270
    d.noteLabel = Line("GameFontNormalSmall", -10, d.contract)
    d.noteLabel:SetText("Warum auf der Liste")
    d.note = Box(d.noteLabel, boxW)
    d.note:SetScript("OnEnterPressed", function(self)
        local c = Spy.Get(intelFrame.selected)
        if c then c.note = self:GetText() ~= "" and self:GetText() or nil; c.saved = true end
        self:ClearFocus()
        UI.Refresh()
    end)
    d.note:SetScript("OnEditFocusLost", function(self)
        local c = Spy.Get(intelFrame.selected)
        if c and (self:GetText() or "") ~= (c.note or "") then c.note = self:GetText() ~= "" and self:GetText() or nil end
    end)
    -- Was andere über ihn geteilt haben
    d.shared = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    d.shared:SetPoint("TOPLEFT", d.note, "BOTTOMLEFT", -6, -3)
    d.shared:SetWidth(book and 232 or 280)
    d.shared:SetJustifyH("LEFT")
    if d.shared.SetWordWrap then d.shared:SetWordWrap(false) end
    d.logLabel = Line("GameFontNormalSmall", -6, d.note)
    d.logLabel:ClearAllPoints()
    d.logLabel:SetPoint("TOPLEFT", d.shared, "BOTTOMLEFT", 0, -5)
    d.share = TextButton(d, "Teilen", 56, function()
        local c = Spy.Get(intelFrame.selected)
        if not c then return end
        if IsShiftKeyDown and IsShiftKeyDown() then
            Spy.ShareProfile(c, ns.Rudel and ns.Rudel.GroupChannel())
        elseif IsControlKeyDown and IsControlKeyDown() then
            local who = ns.Safe(UnitName("target"))
            if who and ns.Safe(UnitIsPlayer("target")) and not ns.Safe(UnitIsEnemy("player", "target")) then
                Spy.ShareProfile(c, "WHISPER", who)
            else
                ns.Print("Strg+Klick teilt mit dem Spieler im Ziel – nimm zuerst ein Gildenmitglied oder einen Freund ins Ziel.")
            end
        else
            Spy.ShareProfile(c, IsInGuild() and "GUILD" or (ns.Rudel and ns.Rudel.GroupChannel()))
        end
    end, "Profil teilen (Grund und deine letzten 5 Erlebnisse)\nKlick: mit der Gilde\nShift+Klick: mit der Gruppe\nStrg+Klick: mit dem Spieler im Ziel")
    d.share:SetHeight(18)
    d.share:SetPoint("BOTTOMRIGHT", d.note, "TOPRIGHT", 0, 3)
    d.logLabel:SetText("Erlebnisse")
    d.logInput = Box(d.logLabel, boxW)
    d.logInput:SetScript("OnEnterPressed", function(self)
        local c = Spy.Get(intelFrame.selected)
        if c then Spy.AddLog(c, self:GetText()) end
        self:SetText("")
        self:ClearFocus()
    end)
    d.logHint = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    d.logHint:SetPoint("LEFT", d.logInput, "LEFT", 2, 0)
    d.logHint:SetText("Neues Erlebnis eintippen, Enter speichert")
    d.logInput:SetScript("OnEditFocusGained", function() d.logHint:Hide() end)
    d.logInput:SetScript("OnEditFocusLost", function(self) d.logHint:SetShown((self:GetText() or "") == "") end)
    d.logRows = {}
    local prevRow = d.logInput
    for i = 1, LOG_ROWS do
        local r = CreateFrame("Button", nil, d)
        r:SetSize(book and 232 or 280, 26)
        r:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", i == 1 and -6 or 0, i == 1 and -4 or 0)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetAllPoints()
        r.text:SetJustifyH("LEFT")
        r.text:SetJustifyV("TOP")
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r:SetScript("OnClick", function(self, button)
            local c = Spy.Get(intelFrame.selected)
            if c and self.index and button == "RightButton" and IsShiftKeyDown and IsShiftKeyDown() then Spy.DelLog(c, self.index) end
        end)
        r:SetScript("OnEnter", function(self)
            local c = Spy.Get(intelFrame.selected)
            local e = c and c.log and self.index and c.log[self.index]
            if not e then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(date("%d.%m.%Y %H:%M", e.t) .. (e.zone and ("  ·  " .. e.zone) or ""), 1, .82, 0)
            GameTooltip:AddLine(e.text, 1, 1, 1, true)
            GameTooltip:AddLine("Shift+Rechtsklick: Eintrag löschen", .5, .5, .5)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        d.logRows[i] = r
        prevRow = r
    end
    d.logMore = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    d.logMore:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, 0)

    local bw = book and { 44, 60, 60, 66 } or { 50, 70, 70, 74 }
    d.kos = TextButton(d, "KOS", bw[1], function()
        local c = Spy.Get(intelFrame.selected)
        if c then Spy.SetKos(c, not c.kos, "") end
    end, "Auf die KOS-Liste setzen oder entfernen")
    d.kos:SetHeight(22)
    d.kos:SetPoint("BOTTOMLEFT", book and 0 or 10, book and 4 or 10)
    d.save = TextButton(d, "Merken", bw[2], function()
        local c = Spy.Get(intelFrame.selected)
        if c then Spy.SetSaved(c, not c.saved) end
    end, "Im eigenen Profil merken (Reiter »Gemerkt«). Nur für dich, wird nicht geteilt.")
    d.save:SetHeight(22)
    d.save:SetPoint("LEFT", d.kos, "RIGHT", 3, 0)
    d.contractBtn = TextButton(d, "Auftrag", bw[3], function()
        local c = Spy.Get(intelFrame.selected)
        if c then Spy.SetContract(c, d.note:GetText() or "") end
    end, "Gildenauftrag: alle Assassinen mit dem Addon bekommen das Ziel auf ihre KOS-Liste. »Warum auf der Liste« wird als Grund mitgeschickt.")
    d.contractBtn:SetHeight(22)
    d.contractBtn:SetPoint("LEFT", d.save, "RIGHT", 3, 0)
    d.forget = TextButton(d, "Vergessen", bw[4], function()
        if intelFrame.selected then Spy.Forget(intelFrame.selected); intelFrame.selected = nil end
    end, "Akte mit Profil und Erlebnissen löschen")
    d.forget:SetHeight(22)
    d.forget:SetPoint("LEFT", d.contractBtn, "RIGHT", 3, 0)

    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    if book then
        f.summary:SetPoint("BOTTOMLEFT", leftPage, "BOTTOMLEFT", 0, 0)
        f.summary:SetWidth(240)
    else
        f.summary:SetPoint("BOTTOMLEFT", 14, 14)
    end
    f.summary:SetJustifyH("LEFT")

    f:SetScript("OnShow", function() UI.Refresh() end)
    UI.Ink(f)
end

local function RefreshIntel()
    if not intelFrame or not intelFrame:IsShown() then return end
    local f = intelFrame
    for _, b in ipairs(f.tabButtons) do
        if b.isSkinned == true then D.SetKind(b, b.id == f.tab and "red" or "parchment") end
        if b.isSkinned ~= true then b.text:SetTextColor(b.id == f.tab and 1 or .7, b.id == f.tab and 1 or .67, b.id == f.tab and 1 or .67) end
        if b.SetBackdropColor then
            if b.id == f.tab then b:SetBackdropColor(RED[1], RED[2], RED[3], .9) else b:SetBackdropColor(.09, .08, .09, .95) end
        end
    end

    local list = Spy.List(f.tab, f.search:GetText())
    f.offset = math.min(f.offset, math.max(0, #list - INTEL_ROWS))
    for i, row in ipairs(f.rows) do
        local e = list[i + f.offset]
        if e then
            local tier = Spy.Tier(e.score)
            row.key, row.c = e.key, e.c
            row.sq:SetColorTexture(tier[3], tier[4], tier[5])
            row.name:SetText(Marks(e.c) .. UI.Name(e.c))
            local info
            if f.tab == "nemesis" then info = string.format("%d× gefallen", e.c.losses or 0)
            elseif f.tab == "opfer" then info = string.format("%d× getötet", e.c.wins or 0)
            elseif f.tab == "auftraege" then info = e.c.contract.done and "erfüllt" or ("von " .. (e.c.contract.by or "?"))
            elseif f.tab == "fehde" then info = "<" .. (e.c.guild or "?") .. ">"
            elseif f.tab == "gemerkt" then
                info = (e.c.log and #e.c.log > 0) and string.format("%d Erlebnis%s", #e.c.log, #e.c.log == 1 and "" or "se")
                    or (e.c.shared and "geteilt") or LevelText(e.c)
            else info = string.format("%s · %d", LevelText(e.c), e.score) end
            row.info:SetText(info)
            row.sel:SetShown(e.key == f.selected)
            row:Show()
        else
            row.key, row.c = nil, nil
            row:Hide()
        end
    end

    local d, c = f.detail, Spy.Get(f.selected)
    for _, w in ipairs({ d.kos, d.save, d.contractBtn, d.forget, d.note, d.noteLabel, d.logLabel, d.logInput, d.share, d.shared }) do w:SetShown(c ~= nil) end
    local others = {}
    for who, s in pairs(c and c.shared or {}) do
        others[#others + 1] = who .. (s.reason and (": " .. s.reason) or (s.kos and ": KOS" or ""))
    end
    table.sort(others)
    d.shared:SetText(#others > 0 and ("Andere: " .. table.concat(others, "  ·  ")) or "")
    d.logHint:SetShown(c ~= nil and not d.logInput:HasFocus() and (d.logInput:GetText() or "") == "")
    d.emblem:SetShown(c == nil)
    local entries = c and c.log or {}
    for i, r in ipairs(d.logRows) do
        local idx = #entries - i + 1
        local e = entries[idx]
        r.index = e and idx or nil
        r.text:SetText(e and string.format("%s%s|r  %s%s", UI.C("gray"), date("%d.%m.", e.t), e.text,
            e.by and string.format("  %s(%s)|r", UI.C("gray"), e.by) or "") or "")
        r:SetShown(e ~= nil)
    end
    d.logMore:SetText(#entries > LOG_ROWS and string.format("… und %d ältere (Tooltip zeigt alles)", #entries - LOG_ROWS) or "")
    if not c then
        d.name:SetText(UI.C("gray") .. "Wähle links einen Feind.|r")
        for _, fs in ipairs({ d.sub, d.threat, d.where, d.report, d.contract }) do fs:SetText("") end
    else
        local score = Spy.Threat(f.selected, c)
        local tier = Spy.Tier(score)
        d.name:SetText(Marks(c) .. UI.Name(c))
        d.sub:SetText(string.format("Stufe %s %s %s%s", LevelText(c), c.race or "", ClassName(c.class), c.guild and ("  ·  <" .. c.guild .. ">") or ""))
        d.threat:SetText(string.format("Bedrohung %d (%s)  ·  Bilanz %s%d|r : %s%d|r", score, tier[2], UI.C("good"), c.wins or 0, UI.C("bad"), c.losses or 0))
        d.threat:SetTextColor(D.Ink3(tier[3], tier[4], tier[5]))
        d.where:SetText(string.format("Zuletzt: %s%s, %s  ·  %d× gesehen", c.zone or "?", (c.sub and c.sub ~= "") and (" – " .. c.sub) or "", Spy.Ago(c.last), c.seen or 0))
        d.report:SetText(c.reported and string.format("Gemeldet von %s %s", c.reportBy or "?", Spy.Ago(c.reported)) or "")
        local ct = c.contract
        d.contract:SetText(ct and (ct.done and string.format("%sAuftrag erfüllt|r von %s", UI.C("good"), ct.doneBy or "?")
            or string.format("%sOffener Auftrag|r von %s%s", UI.C("bad"), ct.by or "?", ct.reason and (": " .. ct.reason) or "")) or "")
        d.kos.text:SetText(c.kos and "KOS weg" or "KOS")
        d.save.text:SetText(c.saved and "Gemerkt" or "Merken")
        if d.save.isSkinned == true then D.SetKind(d.save, c.saved and "red" or "parchment") end
        if d.kos.isSkinned == true then D.SetKind(d.kos, c.kos and "red" or "parchment") end
        if not d.note:HasFocus() then d.note:SetText(c.note or "") end
    end

    local total, kos, open, w, l = 0, 0, 0, 0, 0
    for _, e in ipairs(Spy.List("akten")) do
        total = total + 1
        if e.c.kos then kos = kos + 1 end
        if e.c.contract and not e.c.contract.done then open = open + 1 end
        w, l = w + (e.c.wins or 0), l + (e.c.losses or 0)
    end
    if Book() then
        f.summary:SetText(string.format("Akten %d  ·  KOS %d  ·  Aufträge %d\nBilanz %s%d|r : %s%d|r", total, kos, open, UI.C("good"), w, UI.C("bad"), l))
    else
        f.summary:SetText(string.format("Akten: %d   ·   KOS: %d   ·   offene Aufträge: %d   ·   Gesamtbilanz: %s%d|r : %s%d|r",
            total, kos, open, UI.C("good"), w, UI.C("bad"), l))
    end
end

function UI.ToggleIntel()
    if intelFrame:IsShown() then intelFrame:Hide() else intelFrame:Show() end
end

function UI.OpenIntel(key)
    intelFrame.selected = key
    intelFrame:Show()
    UI.Refresh()
end

---------------------------------------------------------------------------
-- Minimap-Knopf
---------------------------------------------------------------------------

local atan2 = math.atan2 or atan2 or function(y, x) return math.atan(y, x) end

-- Abstand aus der echten Kartengröße: Der Knopf sitzt auf dem Rand, nicht auf der Karte
local function MinimapButtonRadius()
    return (Minimap:GetWidth() or 140) / 2 + 8
end

local function PlaceMinimapButton()
    local a, r = math.rad(S.minimapAngle or 205), MinimapButtonRadius()
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
    minimapButton.radius = r
end

local function BuildMinimapButton()
    local b = CreateFrame("Button", "AssassinenMinimapButton", Minimap)
    minimapButton = b
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture(MEDIA .. "minimap")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 7, -5)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -3, 4)

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then UI.ToggleIntel()
        elseif IsShiftKeyDown and IsShiftKeyDown() and ns.Ziele then ns.Ziele.Toggle()
        elseif IsAltKeyDown and IsAltKeyDown() and ns.Leiste then ns.Leiste.Toggle()
        else UI.ToggleScanner() end
    end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            S.minimapAngle = math.deg(atan2(cy / s - my, cx / s - mx))
            PlaceMinimapButton()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self)
        local n, top = Spy.NearbyCount()
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cffc41e3aAssassinen|r Späher")
        GameTooltip:AddLine(string.format("%d Feind%s in der Nähe", n, n == 1 and "" or "e"), 1, 1, 1)
        if n > 0 then
            local t = Spy.Tier(top)
            GameTooltip:AddLine("Höchste Bedrohung: " .. t[2], t[3], t[4], t[5])
        end
        if Spy.Muted() then GameTooltip:AddLine("Warnungen stumm (/assa ruhe aus)", 1, .6, .2) end
        GameTooltip:AddLine("Links: Späher · Shift+Links: Ziele · Alt+Links: Leiste · Rechts: Intel · Ziehen: verschieben", .6, .6, .6)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PlaceMinimapButton()
end

function UI.UpdateMinimap()
    if not minimapButton then return end
    -- Die Karte kann ihre Größe nach dem Einloggen noch ändern
    if minimapButton.radius ~= MinimapButtonRadius() then PlaceMinimapButton() end
    minimapButton:SetShown(S.minimap)
    local n, top = Spy.NearbyCount()
    minimapButton.count:SetText(n > 0 and n or "")
    if n > 0 then
        local t = Spy.Tier(top)
        minimapButton.count:SetTextColor(t[3], t[4], t[5])
    end
end

---------------------------------------------------------------------------
-- Warnungen: Text in der Bildschirmmitte + roter Rand
---------------------------------------------------------------------------

local function BuildFlash()
    flash = CreateFrame("Frame", nil, UIParent)
    flash:SetAllPoints(UIParent)
    flash:SetFrameStrata("FULLSCREEN")
    local tex = flash:CreateTexture(nil, "BACKGROUND")
    tex:SetTexture("Interface\\FullScreenTextures\\LowHealth")
    tex:SetAllPoints()
    tex:SetBlendMode("ADD")
    flash:Hide()
    flash:SetScript("OnUpdate", function(self, elapsed)
        self.t = (self.t or 0) + elapsed
        if self.t > 1.8 then self:Hide() return end
        self:SetAlpha(math.abs(math.sin(self.t * 4)) * (1 - self.t / 1.8))
    end)
end

function UI.Alert(text, important)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = .2, b = .2 })
    end
    if important and flash then
        flash.t = 0
        flash:Show()
    end
end

---------------------------------------------------------------------------

function UI.Refresh()
    RefreshScanner()
    RefreshIntel()
    UI.UpdateMinimap()
end

function UI.Init()
    Spy, S = ns.Spy, ns.settings
    BuildScanner()
    BuildIntel()
    BuildMinimapButton()
    BuildFlash()
    UI.Refresh()
end
