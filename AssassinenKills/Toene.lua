-- Assassinen Töne – jede Warnung bekommt ihren eigenen, frei wählbaren Ton.
-- Auswahl: Töne aus dem Spiel, "Aus" oder eigene Dateien (Sounds\eigen1.ogg … eigen5.ogg im Addon-Ordner).
-- Fenster: /assa toene, Knopf "Töne" auf der Kommando-Leiste oder Optionen → AddOns → Assassinen.

local ADDON_NAME, ns = ...
local Toene = {}
ns.Toene = Toene

local S, UI
local frame, list
local rows = {}

local SOUND_DIR = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Sounds\\"

-- Auswahlmöglichkeiten: id, Anzeigename, SOUNDKIT-Name, Ersatz-ID
Toene.CHOICES = {
    { "off", "|cff888888Aus|r" },
    { "RAID_WARNING", "Schlachtzugswarnung", "RAID_WARNING", 8959 },
    { "READY_CHECK", "Bereitschaftscheck", "READY_CHECK", 8960 },
    { "TELL_MESSAGE", "Flüstern", "TELL_MESSAGE", 3081 },
    { "ALARM3", "Wecker (lang)", "ALARM_CLOCK_WARNING_3", 12889 },
    { "ALARM2", "Wecker (kurz)", "ALARM_CLOCK_WARNING_2", 12867 },
    { "PVP_QUEUE", "Schlachtfeld bereit", "PVP_THROUGH_QUEUE", 8459 },
    { "LEVEL_UP", "Stufenaufstieg", "LEVEL_UP", 888 },
    { "MAP_PING", "Kartenpinger", "MAP_PING", 3175 },
    { "INVITE", "Gruppeneinladung", "IG_PLAYER_INVITE", 880 },
    { "QUEST_FAILED", "Quest fehlgeschlagen", "IG_QUEST_FAILED", 847 },
    { "AGGRO", "Aggro", "IG_CREATURE_AGGRO_SELECT", 873 },
    { "AUCTION", "Auktionshaus", "AUCTION_WINDOW_OPEN", 5274 },
    { "eigen1", "Eigene Datei 1", nil, nil, "eigen1" },
    { "eigen2", "Eigene Datei 2", nil, nil, "eigen2" },
    { "eigen3", "Eigene Datei 3", nil, nil, "eigen3" },
    { "eigen4", "Eigene Datei 4", nil, nil, "eigen4" },
    { "eigen5", "Eigene Datei 5", nil, nil, "eigen5" },
}
local byId = {}
for _, c in ipairs(Toene.CHOICES) do byId[c[1]] = c end

-- Ereignisse: Schlüssel, Name im Fenster, Standardton
Toene.EVENTS = {
    { "aim", "Du bist im Ziel", "RAID_WARNING" },
    { "stealth", "Feind ist in die Tarnung gegangen", "ALARM3" },
    { "kos", "KOS / Auftrag / Fehde in Sicht", "RAID_WARNING" },
    { "new", "Neuer Feind in der Nähe", "TELL_MESSAGE" },
    { "outnumber", "Übermacht / Aufmarsch", "RAID_WARNING" },
    { "help", "Hilferuf eines Mitglieds", "RAID_WARNING" },
    { "coming", "Jemand kommt dir zu Hilfe", "TELL_MESSAGE" },
    { "target", "Ziel angesagt", "RAID_WARNING" },
    { "plan", "Opener-Plan erhalten", "TELL_MESSAGE" },
    { "tick", "Countdown: 3 – 2 – 1", "TELL_MESSAGE" },
    { "go", "Countdown: LOS!", "RAID_WARNING" },
    { "rally", "Sammelpunkt gesetzt", "TELL_MESSAGE" },
    { "watch", "Wachmeldung", "TELL_MESSAGE" },
    { "ready", "Bereitschaftscheck", "READY_CHECK" },
    { "order", "Neuer Auftrag", "RAID_WARNING" },
    { "feud", "Fehde erklärt / Rache", "RAID_WARNING" },
}
local eventIndex = {}
for _, e in ipairs(Toene.EVENTS) do eventIndex[e[1]] = e end

function Toene.Choice(key)
    local e = eventIndex[key]
    local id = S and S.sounds and S.sounds[key] or (e and e[3]) or "TELL_MESSAGE"
    return byId[id] or byId[e and e[3] or "TELL_MESSAGE"]
end

-- Einen Ton aus der Auswahl abspielen (ohne Prüfung, ob Töne an sind: für die Vorschau)
function Toene.PlayChoice(id)
    local c = byId[id]
    if not c or c[1] == "off" then return false end
    if c[5] then
        for _, ext in ipairs({ ".ogg", ".mp3" }) do
            local ok, willPlay = pcall(PlaySoundFile, SOUND_DIR .. c[5] .. ext, "Master")
            if ok and willPlay then return true end
        end
        return false
    end
    local kit = SOUNDKIT and SOUNDKIT[c[3]] or c[4]
    local ok = pcall(PlaySound, kit, "Master")
    return ok
end

-- Ton für ein Ereignis. respectMute: bei "/assa ruhe" still bleiben
function ns.Sound(key, respectMute)
    if not S or not S.spySound then return end
    if respectMute and ns.Spy and ns.Spy.Muted and ns.Spy.Muted() then return end
    local c = Toene.Choice(key)
    if c then Toene.PlayChoice(c[1]) end
end

---------------------------------------------------------------------------
-- Fenster
---------------------------------------------------------------------------

local ROW_H, WIDTH = 22, 420

local function HideList()
    if list then list:Hide() end
end

local function BuildList()
    list = CreateFrame("Frame", "AssassinenToeneListe", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    UI.Window(list, .97, { border = 8 })
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetSize(170, #Toene.CHOICES * 16 + 8)
    list:EnableMouse(true)
    list.items = {}
    for i, c in ipairs(Toene.CHOICES) do
        local b = CreateFrame("Button", nil, list)
        b:SetSize(162, 16)
        b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 16)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(.6, .08, .1, .45)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", 4, 0)
        b.text:SetText(c[2])
        b:SetScript("OnClick", function()
            if list.row then
                S.sounds = S.sounds or {}
                S.sounds[list.row.key] = c[1]
                Toene.PlayChoice(c[1])
                Toene.Refresh()
            end
            HideList()
        end)
        list.items[i] = b
    end
    UI.Ink(list)
    list:Hide()
end

local function OpenList(row)
    if not list then BuildList() end
    if list:IsShown() and list.row == row then HideList() return end
    list.row = row
    list:ClearAllPoints()
    list:SetPoint("TOPLEFT", row.drop, "BOTTOMLEFT", 0, -2)
    list:Show()
end

local function Build()
    local f = CreateFrame("Frame", "AssassinenToene", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame = f
    UI.Window(f, .95, { border = 14, seal = "BOTTOMRIGHT", sealSize = 40, sealX = 16, sealY = -16, blood = 2, bloodSize = 110 })
    f:SetSize(WIDTH, 92 + #Toene.EVENTS * ROW_H)
    f:SetFrameStrata("DIALOG")
    UI.MakeMovable(f, "soundsPos")
    UI.RestorePos(f, "soundsPos", "CENTER", UIParent, "CENTER", 0, 40)
    table.insert(UISpecialFrames, "AssassinenToene") -- Escape schließt
    f:SetScript("OnHide", HideList)

    f.title = UI.Header(f, UI.C("title") .. "Töne|r")
    local close = UI.TextButton(f, "x", 16, function() f:Hide() end, "Schließen")
    close:SetPoint("TOPRIGHT", -4, -4)

    f.master = UI.TextButton(f, "", 120, function()
        S.spySound = not S.spySound
        Toene.Refresh()
    end, "Alle Töne des Addons ein- oder ausschalten")
    f.master:SetHeight(18)
    f.master:SetPoint("TOPLEFT", 10, -28)
    f.reset = UI.TextButton(f, "Standard", 70, function()
        S.sounds = {}
        Toene.Refresh()
    end, "Alle Töne auf die Voreinstellung zurücksetzen")
    f.reset:SetHeight(18)
    f.reset:SetPoint("LEFT", f.master, "RIGHT", 6, 0)

    local y = -52
    for i, e in ipairs(Toene.EVENTS) do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(WIDTH - 20, ROW_H)
        row:SetPoint("TOPLEFT", 10, y - (i - 1) * ROW_H)
        row.key = e[1]
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.label:SetPoint("LEFT", 0, 0)
        row.label:SetText(e[2])
        row.play = UI.TextButton(row, ">", 22, function()
            local c = Toene.Choice(e[1])
            if c then Toene.PlayChoice(c[1]) end
        end, "Probehören")
        row.play:SetHeight(18)
        row.play:SetPoint("RIGHT", 0, 0)
        row.drop = UI.TextButton(row, "", 170, function() OpenList(row) end, "Ton auswählen")
        row.drop:SetHeight(18)
        row.drop:SetPoint("RIGHT", row.play, "LEFT", -4, 0)
        rows[i] = row
    end

    local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 10, 8)
    note:SetPoint("BOTTOMRIGHT", -10, 8)
    note:SetJustifyH("LEFT")
    note:SetText("Eigene Töne: Dateien als eigen1.ogg bis eigen5.ogg (oder .mp3) in den Ordner\n" ..
        "Interface\\AddOns\\AssassinenKills\\Sounds legen und das Spiel neu starten.")
    UI.Ink(f)
    f:Hide()
end

function Toene.Refresh()
    if not frame then return end
    frame.master.text:SetText(S.spySound and ("Töne: " .. UI.C("good") .. "an|r") or ("Töne: " .. UI.C("bad") .. "aus|r"))
    for _, row in ipairs(rows) do
        local c = Toene.Choice(row.key)
        row.drop.text:SetText((c and c[2] or "?") .. "  |cff888888v|r")
        row:SetAlpha(S.spySound and 1 or .5)
    end
end

function Toene.Toggle()
    if not frame then return end
    frame:SetShown(not frame:IsShown())
    Toene.Refresh()
end

-- In den Spieloptionen (AddOns) einen Eintrag mit Knopf zum Fenster
local function RegisterOptions()
    local panel = CreateFrame("Frame")
    panel.name = "Assassinen"
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cffc41e3aAssassinen|r Kill-Tracker")
    local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    text:SetText("Töne für jede Warnung einzeln wählen. Alle Befehle: /assa")
    local b = UI.TextButton(panel, "Ton-Einstellungen öffnen", 180, function()
        if not frame:IsShown() then Toene.Toggle() end
    end)
    b:SetHeight(22)
    b:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -12)
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local cat = Settings.RegisterCanvasLayoutCategory(panel, "Assassinen")
        Settings.RegisterAddOnCategory(cat)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

function Toene.Init()
    S, UI = ns.settings, ns.UI
    S.sounds = S.sounds or {}
    Build()
    pcall(RegisterOptions)
end
