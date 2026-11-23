-- Assassinen Design – "Blutbuch": Pergament im roten Lederrahmen, Buch für die Intel-Zentrale, Wachssiegel,
-- Blutspritzer und Knöpfe aus Leder, Pergament und Eisen. Die Grafiken liegen in Media\skin.
-- Mit /assa design dunkel gibt es das alte dunkle Aussehen zurück.

local ADDON_NAME, ns = ...
local D = {}
ns.Design = D

local SKIN = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\skin\\"
local TITLE_FONT = "Fonts\\MORPHEUS.TTF"

-- Tinte auf Pergament
D.INK = { .12, .06, .02 }
D.INK2 = { .26, .16, .08 }
D.BLOOD = { .5, .06, .06 }
D.GOLD = { .93, .84, .66 }

-- Maße aus den Texturen (siehe make-skin.py)
local FRAME_B = .122     -- Randstärke des Lederrahmens (Anteil der Textur)
local FRAME_C = .19      -- Ecke mit Eisenbeschlag
local BOOK_TC = .7363    -- genutzte Höhe der Buchtextur
D.BOOK_RATIO = 1.3576
local BANNER_TC, BANNER_RATIO = .6719, 2.98
local DIVIDER_TC, DIVIDER_RATIO = .7813, 5.1
local SEAL_RATIO = .896
local NOTE_TC, NOTE_RATIO = .7031, .703
local BUTTONS = { red = { 0, .3184 }, parchment = { .3262, .6406 }, iron = { .6484, .9648 } }
local BLOOD = {
    { .015, .352, .069, .466 }, { .359, .69, .04, .488 }, { .722, .93, .041, .523 },
    { .402, .63, .479, .961 }, { .03, .352, .554, .912 }, { .654, .973, .563, .923 },
}
-- Seitenbereiche im Buch (Anteile von Breite/Höhe des Fensters)
D.PAGES = { left = { .1, .47, .12, .9 }, right = { .53, .9, .12, .9 } }

function D.On()
    return not (ns.settings and ns.settings.design == "dunkel")
end

local function Hex(r, g, b) return string.format("ff%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)) end

-- Farbcodes für Texte in den Fenstern: auf Pergament dunkler, sonst wie bisher
local CODES = {
    good = { "|cff1f6b12", "|cff00ff00" },
    bad = { "|cff8a0c0c", "|cffff4040" },
    gray = { "|cff4a3a28", "|cffaaaaaa" },
    gold = { "|cff7a4e06", "|cffffd100" },
    title = { "|cff5a0c0c", "|cffe6e1e1" },
    dim = { "|cff4a3a28", "|cff8f8a8a" },
}
function D.C(kind)
    local c = CODES[kind]
    return c and c[D.On() and 1 or 2] or ""
end

-- Klassenfarbe als Tinte (auf Pergament sind die hellen Klassenfarben kaum lesbar)
function D.ClassHex(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    -- Priester (weiß) wäre auf Pergament grau und blass: dunkle Tinte
    if not c or class == "PRIEST" then return Hex(D.INK[1], D.INK[2], D.INK[3]) end
    local k = ({ ROGUE = .36, WARRIOR = .45, PALADIN = .5, HUNTER = .4, DRUID = .45 })[class] or .45
    return Hex(c.r * k, c.g * k, c.b * k)
end

function D.InkHex() return Hex(D.INK[1], D.INK[2], D.INK[3]) end

-- Helle Warnfarben (Bedrohungsstufen u. Ä.) für Pergament abdunkeln
function D.Ink3(r, g, b)
    if not D.On() then return r, g, b end
    return r * .6, g * .5, b * .45
end

local function Tex(parent, file, layer, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    t:SetTexture(SKIN .. file)
    return t
end

function D.TitleFont(fs, size)
    if not fs then return end
    local ok = pcall(fs.SetFont, fs, TITLE_FONT, size or 16, "")
    if not ok then fs:SetFontObject("GameFontNormalLarge") end
end

---------------------------------------------------------------------------
-- Fenster: Pergament (oder dunkel) im Lederrahmen
---------------------------------------------------------------------------

-- opts: border (Randbreite in Pixeln, Standard 14), dark (dunkler Grund statt Pergament),
--       seal ("BOTTOMRIGHT" u. a.), sealSize, blood (Nummer 1–6 eines Blutflecks, blass im Hintergrund)
function D.Window(f, opts)
    opts = opts or {}
    if f.SetBackdrop then f:SetBackdrop(nil) end
    local b = opts.border or 14
    local inset = 0 -- der Rahmen liegt außen um das Fenster, der Inhalt behält seinen Platz
    if opts.dark then
        local bg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
        bg:SetColorTexture(.06, .045, .045, .94)
        bg:SetPoint("TOPLEFT", inset, -inset)
        bg:SetPoint("BOTTOMRIGHT", -inset, inset)
    else
        local bg = Tex(f, "parchment", "BACKGROUND", -8)
        bg:SetPoint("TOPLEFT", inset, -inset)
        bg:SetPoint("BOTTOMRIGHT", -inset, inset)
    end
    if opts.blood then D.Splat(f, opts.blood, opts.bloodSize or 90, .22, "BOTTOMRIGHT", -b, b) end
    -- Rahmen in 8 Teilen: Ecken fest, Kanten gestreckt; er liegt außen um das Fenster (2 Pixel überlappend)
    local out = b - 2
    local c = math.floor(b * FRAME_C / FRAME_B + .5)
    local function Piece(l, r, t, btm)
        local p = Tex(f, "frame", "BORDER", 7)
        p:SetTexCoord(l, r, t, btm)
        return p
    end
    local tl = Piece(0, FRAME_C, 0, FRAME_C); tl:SetSize(c, c); tl:SetPoint("TOPLEFT", -out, out)
    local tr = Piece(1 - FRAME_C, 1, 0, FRAME_C); tr:SetSize(c, c); tr:SetPoint("TOPRIGHT", out, out)
    local bl = Piece(0, FRAME_C, 1 - FRAME_C, 1); bl:SetSize(c, c); bl:SetPoint("BOTTOMLEFT", -out, -out)
    local br = Piece(1 - FRAME_C, 1, 1 - FRAME_C, 1); br:SetSize(c, c); br:SetPoint("BOTTOMRIGHT", out, -out)
    local top = Piece(FRAME_C, 1 - FRAME_C, 0, FRAME_B); top:SetHeight(b)
    top:SetPoint("TOPLEFT", tl, "TOPRIGHT"); top:SetPoint("TOPRIGHT", tr, "TOPLEFT")
    local bot = Piece(FRAME_C, 1 - FRAME_C, 1 - FRAME_B, 1); bot:SetHeight(b)
    bot:SetPoint("BOTTOMLEFT", bl, "BOTTOMRIGHT"); bot:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
    local left = Piece(0, FRAME_B, FRAME_C, 1 - FRAME_C); left:SetWidth(b)
    left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT"); left:SetPoint("BOTTOMLEFT", bl, "TOPLEFT")
    local right = Piece(1 - FRAME_B, 1, FRAME_C, 1 - FRAME_C); right:SetWidth(b)
    right:SetPoint("TOPRIGHT", tr, "BOTTOMRIGHT"); right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
    if opts.seal then D.Seal(f, opts.sealSize or 34, opts.seal, opts.sealX or 10, opts.sealY or -10) end
    f.isParchment = not opts.dark
    f.isDark = opts.dark
end

-- Buch als ganzes Fenster (Intel-Zentrale); das Seitenverhältnis gibt das Bild vor
function D.Book(f)
    if f.SetBackdrop then f:SetBackdrop(nil) end
    local bg = Tex(f, "book", "BACKGROUND", -8)
    bg:SetTexCoord(0, 1, 0, BOOK_TC)
    bg:SetAllPoints()
    f.isParchment = true
end

-- Ein Rahmen über einer Buchseite, an den man Inhalte hängen kann
function D.Page(f, side, w, h)
    local p = CreateFrame("Frame", nil, f)
    local r = D.PAGES[side]
    p:SetPoint("TOPLEFT", f, "TOPLEFT", r[1] * w, -r[3] * h)
    p:SetSize((r[2] - r[1]) * w, (r[4] - r[3]) * h)
    return p
end

-- Titelschild (Eisen mit rotem Leder) mittig über der Oberkante, Text in Gold
function D.Banner(f, text, width, yOff)
    width = width or 180
    local h = math.floor(width / BANNER_RATIO + .5)
    local holder = CreateFrame("Frame", nil, f)
    holder:SetSize(width, h)
    holder:SetPoint("TOP", f, "TOP", 0, yOff or math.floor(h * .45))
    holder:SetFrameLevel((f:GetFrameLevel() or 1) + 20)
    local t = Tex(holder, "banner", "ARTWORK")
    t:SetTexCoord(0, 1, 0, BANNER_TC)
    t:SetAllPoints()
    local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("CENTER", 0, 1)
    D.TitleFont(fs, math.floor(h * .42))
    fs:SetTextColor(D.GOLD[1], D.GOLD[2], D.GOLD[3])
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    fs:SetText(text or "")
    fs.noInk = true
    holder.text = fs
    return holder, fs
end

-- Kleines Kopfschild links oben (für schmale Fenster wie Späher und Ziele)
function D.Plate(f, width, height)
    local holder = CreateFrame("Frame", nil, f)
    holder:SetSize(width, height)
    holder:SetPoint("TOPLEFT", 6, -5)
    local t = Tex(holder, "banner", "ARTWORK")
    t:SetTexCoord(0, 1, 0, BANNER_TC)
    t:SetAllPoints()
    return holder
end

function D.Divider(parent, width, layer)
    local t = Tex(parent, "divider", layer or "ARTWORK")
    t:SetTexCoord(0, 1, 0, DIVIDER_TC)
    t:SetSize(width, width / DIVIDER_RATIO)
    t:SetVertexColor(1, 1, 1, .85)
    return t
end

function D.Seal(parent, size, point, x, y)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size * SEAL_RATIO, size)
    holder:SetPoint(point or "BOTTOMRIGHT", x or 0, y or 0)
    holder:SetFrameLevel((parent:GetFrameLevel() or 1) + 25)
    local t = Tex(holder, "seal", "ARTWORK")
    t:SetTexCoord(0, 1, 0, 1)
    t:SetAllPoints()
    holder:EnableMouse(false)
    return holder
end

function D.Splat(parent, i, size, alpha, point, x, y)
    local r = BLOOD[((i or 1) - 1) % #BLOOD + 1]
    local t = Tex(parent, "blood", "BORDER", 1)
    t:SetTexCoord(r[1], r[2], r[3], r[4])
    local ratio = (r[2] - r[1]) / (r[4] - r[3])
    t:SetSize(size * math.min(ratio, 1), size * math.min(1 / ratio, 1))
    t:SetPoint(point or "CENTER", x or 0, y or 0)
    t:SetAlpha(alpha or .25)
    return t
end

---------------------------------------------------------------------------
-- Knöpfe: Leder (rot), Pergament, Eisen – Enden fest, Mitte gestreckt
---------------------------------------------------------------------------

local TEXT = { red = { .97, .88, .8 }, parchment = D.INK, iron = { .86, .82, .78 } }

function D.SetKind(b, kind, dimmed)
    kind = BUTTONS[kind] and kind or "parchment"
    b.kind, b.dimmed = kind, dimmed
    local y0, y1 = BUTTONS[kind][1], BUTTONS[kind][2]
    local capTc = (y1 - y0) * .55 -- Endkappe = 0,55 × Knopfhöhe; der Atlas ist quadratisch, der Knopf füllt die Breite
    b.skinL:SetTexCoord(0, capTc, y0, y1)
    b.skinM:SetTexCoord(capTc, 1 - capTc, y0, y1)
    b.skinR:SetTexCoord(1 - capTc, 1, y0, y1)
    local c = TEXT[kind]
    local k = dimmed and .55 or 1
    if b.text then b.text:SetTextColor(c[1] * k + (dimmed and .2 or 0), c[2] * k + (dimmed and .18 or 0), c[3] * k + (dimmed and .16 or 0)) end
    D.Hover(b, false)
end

function D.Hover(b, on)
    local v = on and 1 or (b.dimmed and .62 or .86)
    for _, t in ipairs({ b.skinL, b.skinM, b.skinR }) do t:SetVertexColor(v, v, v) end
end

function D.Button(b, kind)
    b.skinL = Tex(b, "buttons", "BACKGROUND")
    b.skinM = Tex(b, "buttons", "BACKGROUND")
    b.skinR = Tex(b, "buttons", "BACKGROUND")
    local function Layout()
        local h = b:GetHeight() or 16
        local cap = math.max(4, math.floor(h * .55))
        b.skinL:ClearAllPoints(); b.skinL:SetPoint("TOPLEFT"); b.skinL:SetPoint("BOTTOMLEFT"); b.skinL:SetWidth(cap)
        b.skinR:ClearAllPoints(); b.skinR:SetPoint("TOPRIGHT"); b.skinR:SetPoint("BOTTOMRIGHT"); b.skinR:SetWidth(cap)
        b.skinM:ClearAllPoints(); b.skinM:SetPoint("TOPLEFT", b.skinL, "TOPRIGHT"); b.skinM:SetPoint("BOTTOMRIGHT", b.skinR, "BOTTOMLEFT")
    end
    Layout()
    b:HookScript("OnSizeChanged", Layout)
    b.isSkinned = true
    D.SetKind(b, kind or "parchment")
end

---------------------------------------------------------------------------
-- Tinte: alle Schriften eines Fensters auf Pergament dunkel färben
---------------------------------------------------------------------------

local function InkFor(fs)
    local fo = fs.GetFontObject and fs:GetFontObject()
    local name = fo and fo.GetName and fo:GetName() or ""
    if name:find("Disable") then return D.INK2 end
    if name:find("Normal") and not name:find("Highlight") then return D.BLOOD end
    return D.INK
end

function D.Ink(frame)
    if not D.On() or not frame then return end
    local function Visit(obj)
        if obj.isSkinned == true or obj.noInk == true then return end -- Knöpfe färben sich selbst
        for _, r in ipairs({ obj:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "FontString" and r.noInk ~= true then
                local c = InkFor(r)
                r:SetTextColor(c[1], c[2], c[3])
                r:SetShadowColor(0, 0, 0, 0)
                -- kleine Schrift ist auf Pergament schwer zu lesen: zwei Punkte größer
                local okF, file, size, flags = pcall(r.GetFont, r)
                if okF and type(file) == "string" and type(size) == "number" and size < 12 then
                    pcall(r.SetFont, r, file, size + 2, flags or "")
                end
            end
        end
        for _, child in ipairs({ obj:GetChildren() }) do
            if child.GetObjectType and child:GetObjectType() ~= "EditBox" then Visit(child) end
        end
    end
    Visit(frame)
end

---------------------------------------------------------------------------
-- Steckbrief bei einem Kill: angenagelter Zettel mit Blut, ein paar Sekunden in der Bildschirmmitte
---------------------------------------------------------------------------

local card
local function BuildCard()
    local f = CreateFrame("Frame", "AssassinenSteckbrief", UIParent)
    card = f
    f:SetSize(200, 200 / NOTE_RATIO)
    f:SetPoint("TOP", UIParent, "TOP", 0, -120)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(false)
    local t = Tex(f, "note", "BACKGROUND")
    t:SetTexCoord(0, NOTE_TC, 0, 1)
    t:SetAllPoints()
    f.head = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.head:SetPoint("TOP", 0, -62)
    D.TitleFont(f.head, 22)
    f.head:SetTextColor(D.BLOOD[1], D.BLOOD[2], D.BLOOD[3])
    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.name:SetPoint("TOP", f.head, "BOTTOM", 0, -8)
    D.TitleFont(f.name, 20)
    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.info:SetPoint("TOP", f.name, "BOTTOM", 0, -6)
    f.info:SetWidth(150)
    f.info:SetTextColor(D.INK[1], D.INK[2], D.INK[3])
    f.info:SetShadowColor(0, 0, 0, 0)
    f.extra = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.extra:SetPoint("TOP", f.info, "BOTTOM", 0, -6)
    f.extra:SetWidth(150)
    f.extra:SetTextColor(D.BLOOD[1], D.BLOOD[2], D.BLOOD[3])
    f.extra:SetShadowColor(0, 0, 0, 0)
    f:Hide()
    f:SetScript("OnUpdate", function(self, el)
        self.t = (self.t or 0) + el
        local a = self.t < .25 and self.t / .25 or (self.t > 4 and math.max(0, 1 - (self.t - 4) / .8) or 1)
        self:SetAlpha(a)
        if self.t > 4.8 then self:Hide() end
    end)
end

function D.KillCard(rec, total)
    if not D.On() or not (ns.settings and ns.settings.killCard ~= false) then return end
    if not card then BuildCard() end
    card.head:SetText("Ausgeschaltet")
    card.name:SetText("|c" .. D.ClassHex(rec.class) .. (rec.victim or "?") .. "|r")
    local lvl = rec.level and (rec.level > 0 and rec.level or "??") or "?"
    card.info:SetText(string.format("Stufe %s · %s\nKill #%d", lvl, rec.zone or "?", total or 0))
    local extra = {}
    if (rec.streak or 0) >= 3 then extra[#extra + 1] = rec.streak .. " in Folge" end
    if rec.giant then extra[#extra + 1] = "Riesentöter" end
    if rec.revenge or rec.avenged then extra[#extra + 1] = "Rache" end
    card.extra:SetText(table.concat(extra, " · "))
    card.t = 0
    card:SetAlpha(0)
    card:Show()
end
