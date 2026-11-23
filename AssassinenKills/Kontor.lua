-- Assassinen Kontor – Aufträge von externen Auftraggebern (Addon "AssassinenAuftrag").
-- Nur beim Gildenleiter (oder wer es mit /assa kontor an einschaltet) aktiv.
--
-- Ablauf:
--   Auftraggeber --REQ--> Kontor: Anfrage (Ziel, Kills, Gold, Grund)
--   Kontor --ACC/DEC--> Auftraggeber: angenommen (mit Empfänger für den Brief) oder abgelehnt
--   Auftraggeber zahlt am Briefkasten (Betreff "Auftrag #ID") --PAID--> Kontor
--   Kontor erkennt den Brief im Posteingang -> "bezahlt (bestätigt)"
--   Gildenleiter vergibt den Auftrag an Mitglieder (Gildennachricht "A" mit ID und Prämie)
--   Mitglied tötet das Ziel -> Gildennachricht "X" -> Kontor zählt, legt Prämienbrief in den Postausgang
--   Alle Kills erledigt -> "Z" an die Gilde, "ST erfuellt" an den Auftraggeber
-- Briefe verschickt WoW nur am Briefkasten: das Kontor füllt sie aus, ein Klick schickt sie ab.

local ADDON_NAME, ns = ...
local K = {}
ns.Kontor = K

local PREFIX = "ASSAK"
local POSTAGE = 30 -- Kupfer pro Brief
local MAX_OPEN_PER_CLIENT = 3

-- Status: Anzeige, r, g, b
K.STATUS = {
    angefragt = { "Neue Anfrage", 1, .82, 0 },
    angenommen = { "Wartet auf Zahlung", 1, .6, .2 },
    bezahlt = { "Zahlung gemeldet", 1, .9, .45 },
    bestaetigt = { "Bezahlt", .45, 1, .45 },
    vergeben = { "Vergeben", 1, .3, .3 },
    erfuellt = { "Erfüllt", .3, 1, .3 },
    abgelehnt = { "Abgelehnt", .55, .55, .55 },
    abgebrochen = { "Abgebrochen", .55, .55, .55 },
    erstattet = { "Erstattet", .55, .55, .55 },
}
local ORDER = { angefragt = 1, bezahlt = 2, bestaetigt = 3, angenommen = 4, vergeben = 5 }

local S, data, playerName
local whisperQueue, lastWhisper, recentWhisper = {}, 0, {}
local mailOpen, sending
local inboxPayments = {}
local frame, mailPanel

local function Print(text) ns.Print("|cffd9b56bKontor:|r " .. text) end
local function Money(c) return ns.Spy.Money(c) end
local function Short(n) return ns.ShortName(n) end

local function Split(msg)
    local out = {}
    for field in (msg .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = field end
    return out
end

function K.Enabled() return S and S.kontor == true end
function K.Payee() return (S.kontorPayee and S.kontorPayee ~= "") and S.kontorPayee or playerName end

---------------------------------------------------------------------------
-- Flüstern (Addon-Nachrichten) an Auftraggeber
---------------------------------------------------------------------------

local function Whisper(to, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[#parts + 1] = (tostring(v == nil and "" or v):gsub("\t", " "))
    end
    table.insert(whisperQueue, { to = to, msg = table.concat(parts, "\t"):sub(1, 250) })
end

local function FlushWhispers()
    if #whisperQueue == 0 or GetTime() - lastWhisper < .3 then return end
    lastWhisper = GetTime()
    local w = table.remove(whisperQueue, 1)
    recentWhisper[w.to:lower()] = GetTime()
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, w.msg, "WHISPER", w.to)
end

-- "Kein Spieler namens X ist online" für unsere eigenen Addon-Nachrichten ausblenden
local function SystemFilter(_, _, msg)
    if not ERR_CHAT_PLAYER_NOT_FOUND_S or type(msg) ~= "string" or not ns.Safe(msg) then return false end
    for name, t in pairs(recentWhisper) do
        if GetTime() - t < 5 and msg:lower() == ERR_CHAT_PLAYER_NOT_FOUND_S:format(name):lower() then return true end
    end
    return false
end

local function Notify(c)
    Whisper(c.client, "ST", c.id, c.status, c.killsDone or 0, c.kills, c.info or "")
end

local function Touch(c, status, info)
    if status then c.status = status end
    if info then c.info = info end
    c.updated = time()
    Notify(c)
    K.Refresh()
end

---------------------------------------------------------------------------
-- Nachrichten vom Auftraggeber-Addon
---------------------------------------------------------------------------

local function OpenCount(client)
    local n = 0
    for _, c in pairs(data.contracts) do
        if c.client == client and (c.status == "angefragt" or c.status == "angenommen") then n = n + 1 end
    end
    return n
end

local function OnWhisper(msg, sender)
    if not K.Enabled() then return end
    sender = Short(sender)
    local f = Split(msg)
    local kind, id = f[1], f[2]
    if data.blocked[sender:lower()] then
        if kind == "REQ" then Whisper(sender, "DEC", id, "Die Assassinen nehmen von dir keine Aufträge an.") end
        return
    end

    if kind == "PING" then
        Whisper(sender, "PONG", playerName, K.Payee(), GetGuildInfo("player") or "")
    elseif kind == "HELLO" then
        for _, c in pairs(data.contracts) do
            if c.client == sender then Notify(c) end
        end
    elseif kind == "REQ" then
        -- REQ ID Ziel Realm Klasse Stufe Kills Gold Grund Anonym
        if not id or not id:match("^%w+$") or #id > 16 then return end
        if data.contracts[id] then Notify(data.contracts[id]) return end
        if OpenCount(sender) >= MAX_OPEN_PER_CLIENT then
            Whisper(sender, "DEC", id, "Zu viele offene Anfragen.")
            return
        end
        local target = strtrim(f[3] or ""):sub(1, 24)
        local kills = math.max(1, math.min(20, math.floor(tonumber(f[7]) or 1)))
        local gold = math.floor(tonumber(f[8]) or 0)
        if target == "" or gold < 1 or gold > 100000 then
            Whisper(sender, "DEC", id, "Ungültige Anfrage.")
            return
        end
        local c = {
            id = id, client = sender, target = target, realm = f[4] ~= "" and f[4] or nil,
            class = f[5] ~= "" and f[5] or nil, level = tonumber(f[6]), kills = kills, gold = gold,
            reason = (f[9] or ""):sub(1, 120), anon = f[10] == "1" or nil,
            status = "angefragt", created = time(), updated = time(), killsDone = 0, killLog = {},
        }
        data.contracts[id] = c
        Print(string.format("Neue Anfrage von |cffffd100%s|r: %s, %d Kill%s für %dg%s",
            sender, target, kills, kills == 1 and "" or "s", gold, c.reason ~= "" and (" – " .. c.reason) or ""))
        if ns.UI then ns.UI.Alert(string.format("Neuer Auftrag: %s (%dg) – /assa kontor", target, gold), true) end
        ns.Sound("order")
        Touch(c)
    elseif kind == "PAID" then
        local c = data.contracts[id or ""]
        if c and c.client == sender and c.status == "angenommen" then
            c.paidClaim = time()
            Print(string.format("%s meldet die Zahlung für Auftrag #%s. Prüfe deinen Briefkasten.", sender, id))
            Touch(c, "bezahlt")
            if mailOpen then K.ScanInbox() end
        end
    elseif kind == "CANCEL" then
        local c = data.contracts[id or ""]
        if c and c.client == sender and (c.status == "angefragt" or c.status == "angenommen") then
            Print(string.format("%s hat Auftrag #%s zurückgezogen.", sender, id))
            Touch(c, "abgebrochen")
        end
    end
end

---------------------------------------------------------------------------
-- Aktionen des Gildenleiters
---------------------------------------------------------------------------

function K.Accept(id)
    local c = data.contracts[id]
    if not c or c.status ~= "angefragt" then return end
    c.accepted = time()
    Whisper(c.client, "ACC", c.id, K.Payee(), c.gold)
    Print(string.format("Auftrag #%s angenommen. %s soll %dg an %s schicken.", id, c.client, c.gold, K.Payee()))
    Touch(c, "angenommen")
end

function K.Decline(id, reason)
    local c = data.contracts[id]
    if not c or not (c.status == "angefragt" or c.status == "angenommen" or c.status == "bezahlt") then return end
    Whisper(c.client, "DEC", c.id, reason or "")
    if c.status == "bezahlt" then
        Print("Achtung: Der Auftraggeber hat bereits eine Zahlung gemeldet. Bei Bedarf erstatten.")
    end
    Touch(c, "abgelehnt", reason)
end

function K.Distribute(id, assignee, rewardGold)
    local c = data.contracts[id]
    if not c or not (c.status == "bestaetigt" or c.status == "bezahlt" or c.status == "vergeben") then return end
    if c.status == "bezahlt" then Print("Hinweis: Die Zahlung ist noch nicht im Briefkasten bestätigt.") end
    assignee = strtrim(assignee or "")
    c.assignee = assignee == "" and "alle" or assignee
    c.reward = math.max(0, math.floor((tonumber(rewardGold) or 0) * 10000))
    c.distributed = time()
    -- Ziel bei allen Assassinen als Auftrag eintragen
    local contact = ns.Spy.ContactFor(c.target, c.realm)
    contact.class = contact.class or c.class
    contact.contract = { by = playerName, t = time(), reason = c.reason ~= "" and c.reason or nil,
        id = c.id, count = c.kills, reward = c.reward, assignee = c.assignee }
    contact.kos = true
    ns.Spy.Send("A", c.target, c.realm or "", c.reason or "", c.id, c.kills, c.reward, c.assignee, c.class or "")
    Print(string.format("Auftrag #%s an |cffffd100%s|r vergeben, Prämie %s pro Kill.", id, c.assignee, Money(c.reward)))
    Touch(c, "vergeben")
end

local function Queue(item)
    table.insert(data.outbox, item)
    K.Refresh()
end

function K.OnContractKill(id, killer, killId)
    local c = data and data.contracts[id]
    if not K.Enabled() or not c or c.status ~= "vergeben" then return end
    for _, k in ipairs(c.killLog) do
        if killId and killId ~= "" then
            if k.kill == killId then return end -- dieselbe Meldung doppelt
        elseif k.by == killer and time() - k.t < 10 then
            return
        end
    end
    c.killsDone = (c.killsDone or 0) + 1
    table.insert(c.killLog, { by = killer, t = time(), kill = killId ~= "" and killId or nil })
    if c.reward and c.reward > 0 then
        if killer == playerName then
            Print("Eigener Kill – keine Prämie an dich selbst.")
        elseif ns.Spy.IsAssigned(c.assignee, killer) then
            Queue({ kind = "payout", id = c.id, to = killer, copper = c.reward,
                subject = "Prämie Auftrag #" .. c.id,
                body = string.format("Für %s. Die Assassinen danken. Ein Rang - ein Ziel.", c.target) })
            Print(string.format("Prämie %s für %s liegt im Postausgang.", Money(c.reward), killer))
        else
            Print(string.format("%s hat getroffen, war aber nicht zugeteilt – keine automatische Prämie.", killer))
        end
    end
    if c.killsDone >= c.kills then
        c.done = time()
        ns.Spy.Send("Z", c.target, c.realm or "", c.id, killer)
        local contact = ns.Spy.ContactFor(c.target, c.realm)
        if contact.contract and contact.contract.id == c.id then contact.contract.done, contact.contract.doneBy = time(), killer end
        Print(string.format("|cff00ff00Auftrag #%s erfüllt!|r %s wurde %d× erledigt.", c.id, c.target, c.killsDone))
        Touch(c, "erfuellt", "Letzter Kill durch " .. killer)
    else
        Touch(c, nil, string.format("Kill %d/%d durch %s", c.killsDone, c.kills, killer))
    end
end

function K.Complete(id)
    local c = data.contracts[id]
    if not c or c.status ~= "vergeben" then return end
    c.done = time()
    ns.Spy.Send("Z", c.target, c.realm or "", c.id, playerName)
    Touch(c, "erfuellt", "Vom Kontor abgeschlossen")
end

function K.Refund(id)
    local c = data.contracts[id]
    if not c or not (c.status == "bestaetigt" or c.status == "bezahlt" or c.status == "vergeben" or c.status == "abgelehnt") then return end
    Queue({ kind = "refund", id = c.id, to = c.client, copper = c.gold * 10000,
        subject = "Erstattung Auftrag #" .. c.id, body = "Euer Auftrag wurde nicht ausgeführt. Hier ist euer Gold zurück." })
    if c.status == "vergeben" then ns.Spy.Send("Z", c.target, c.realm or "", c.id, "Erstattet") end
    Print(string.format("Erstattung von %dg an %s liegt im Postausgang.", c.gold, c.client))
    Touch(c, "erstattet")
end

function K.Block(name)
    data.blocked[name:lower()] = true
    Print(name .. " ist gesperrt und kann keine Aufträge mehr erteilen.")
end

---------------------------------------------------------------------------
-- Briefkasten: Zahlungen prüfen, Briefe verschicken
---------------------------------------------------------------------------

function K.ScanInbox()
    wipe(inboxPayments)
    if not K.Enabled() or not GetInboxNumItems then return end
    for i = 1, GetInboxNumItems() do
        local _, _, sender, subject, money = GetInboxHeaderInfo(i)
        local id = subject and subject:match("#(%w+)")
        local c = id and data.contracts[id]
        if c and sender and Short(sender) == c.client and (money or 0) > 0 then
            table.insert(inboxPayments, { index = i, id = id, money = money })
            if money >= c.gold * 10000 and not c.paidVerified then
                c.paidVerified = time()
                Print(string.format("|cff00ff00Zahlung eingegangen:|r %s von %s für Auftrag #%s.", Money(money), c.client, id))
                if c.status == "angenommen" or c.status == "bezahlt" then Touch(c, "bestaetigt") end
            end
        end
    end
    K.Refresh()
end

-- Muss aus einem Klick heraus aufgerufen werden (Briefkasten offen)
function K.SendNext()
    local item = data.outbox[1]
    if not item or sending then return end
    if not mailOpen then Print("Öffne zuerst einen Briefkasten.") return end
    if GetMoney() < item.copper + POSTAGE then
        Print(string.format("Nicht genug Gold für den Brief an %s (%s).", item.to, Money(item.copper)))
        return
    end
    sending = item
    SetSendMailMoney(item.copper)
    SendMail(item.to, item.subject, item.body)
end

function K.TakeNext()
    local p = inboxPayments[1]
    if p and mailOpen then TakeInboxMoney(p.index) end
end

local function OnMailSent()
    if not sending then return end
    for i, item in ipairs(data.outbox) do
        if item == sending then table.remove(data.outbox, i) break end
    end
    local c = data.contracts[sending.id]
    if c then
        if sending.kind == "payout" then c.paidOut = (c.paidOut or 0) + sending.copper end
        if sending.kind == "refund" then c.refunded = time() end
    end
    Print(string.format("Brief an %s verschickt (%s).", sending.to, Money(sending.copper)))
    sending = nil
    K.Refresh()
end

---------------------------------------------------------------------------
-- Fenster
---------------------------------------------------------------------------

local LIST_ROWS = 16

local function SortedContracts()
    local list = {}
    for _, c in pairs(data.contracts) do list[#list + 1] = c end
    table.sort(list, function(a, b)
        local oa, ob = ORDER[a.status] or 9, ORDER[b.status] or 9
        if oa ~= ob then return oa < ob end
        return (a.updated or 0) > (b.updated or 0)
    end)
    return list
end

local function BuildFrame()
    local UI = ns.UI
    local f = CreateFrame("Frame", "AssassinenKontorFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame = f
    UI.Skin(f, .96)
    f:SetSize(660, 470)
    f:SetFrameStrata("DIALOG")
    UI.MakeMovable(f, "kontorPos")
    UI.RestorePos(f, "kontorPos", "CENTER", UIParent, "CENTER", 0, 40)
    f:Hide()
    table.insert(UISpecialFrames, "AssassinenKontorFrame")
    f.offset = 0

    UI.Decorate(f, UI.Book() and "Kontor" or "Kontor  |cffaaaaaa– Aufträge von Auftraggebern|r")
    UI.TextButton(f, "x", 18, function() f:Hide() end, "Schließen"):SetPoint("TOPRIGHT", UI.Book() and -16 or -8, UI.Book() and -14 or -8)

    local list = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
    UI.Skin(list, .6)
    list:SetPoint("TOPLEFT", 12, -58)
    list:SetSize(290, LIST_ROWS * 22 + 8)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta) f.offset = math.max(0, f.offset - delta * 3); K.Refresh() end)
    f.rows = {}
    for i = 1, LIST_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(282, 22)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 22)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(.8, .1, .2, .25)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(.8, .1, .2, .45)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 4, 0)
        row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.status:SetPoint("RIGHT", -4, 0)
        row:SetScript("OnClick", function(self) f.selected = self.id; K.Refresh() end)
        f.rows[i] = row
    end

    local d = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
    UI.Skin(d, .6)
    d:SetPoint("TOPLEFT", list, "TOPRIGHT", 10, 0)
    d:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 38)
    f.detail = d
    d.emblem = UI.Art(d, "logo", 240)
    d.emblem:SetPoint("CENTER", 0, -6)
    d.emblem:SetAlpha(.75)
    local function Line(font, y, anchor)
        local fs = d:CreateFontString(nil, "OVERLAY", font)
        fs:SetPoint("TOPLEFT", anchor or d, anchor and "BOTTOMLEFT" or "TOPLEFT", anchor and 0 or 10, y)
        fs:SetWidth(320)
        fs:SetJustifyH("LEFT")
        return fs
    end
    d.title = Line("GameFontNormalLarge", -10)
    d.status = Line("GameFontNormal", -4, d.title)
    d.client = Line("GameFontHighlightSmall", -10, d.status)
    d.deal = Line("GameFontHighlight", -4, d.client)
    d.reason = Line("GameFontHighlightSmall", -4, d.deal)
    d.pay = Line("GameFontHighlightSmall", -8, d.reason)
    d.progress = Line("GameFontHighlightSmall", -4, d.pay)
    d.info = Line("GameFontDisableSmall", -4, d.progress)

    -- Vergabe
    d.assignLabel = Line("GameFontDisableSmall", -12, d.info)
    d.assignLabel:SetText("Vergeben an (Namen mit Komma oder \"alle\")      Prämie pro Kill (Gold)")
    d.assignee = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    d.assignee:SetSize(200, 20)
    d.assignee:SetPoint("TOPLEFT", d.assignLabel, "BOTTOMLEFT", 6, -2)
    d.assignee:SetAutoFocus(false)
    d.reward = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    d.reward:SetSize(70, 20)
    d.reward:SetPoint("LEFT", d.assignee, "RIGHT", 16, 0)
    d.reward:SetAutoFocus(false)
    for _, eb in ipairs({ d.assignee, d.reward }) do
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    end

    local function Btn(label, w, fn, tip)
        local b = UI.TextButton(d, label, w, function() if f.selected then fn(f.selected) end end, tip)
        b:SetHeight(22)
        return b
    end
    d.accept = Btn("Annehmen", 80, K.Accept, "Auftrag annehmen. Der Auftraggeber bekommt Empfänger und Betrag für den Brief.")
    d.accept:SetPoint("BOTTOMLEFT", 10, 10)
    d.decline = Btn("Ablehnen", 70, function(id) K.Decline(id, "Abgelehnt vom Kontor") end)
    d.decline:SetPoint("LEFT", d.accept, "RIGHT", 6, 0)
    d.give = Btn("Vergeben", 80, function(id) K.Distribute(id, d.assignee:GetText(), d.reward:GetText()) end,
        "Auftrag an die Mitglieder verteilen. Sie bekommen eine Warnung und das Ziel auf ihre KOS-Liste.")
    d.give:SetPoint("LEFT", d.decline, "RIGHT", 6, 0)
    d.complete = Btn("Erfüllt", 60, K.Complete, "Auftrag von Hand als erfüllt abschließen")
    d.complete:SetPoint("LEFT", d.give, "RIGHT", 6, 0)
    d.refund = Btn("Erstatten", 70, K.Refund, "Gold per Brief an den Auftraggeber zurückschicken (am Briefkasten)")
    d.refund:SetPoint("BOTTOMRIGHT", -10, 10)
    d.block = Btn("Sperren", 60, function(id) K.Block(data.contracts[id].client) end, "Diesen Auftraggeber sperren")
    d.block:SetPoint("BOTTOMRIGHT", d.refund, "TOPRIGHT", 0, 6)

    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.summary:SetPoint("BOTTOMLEFT", 14, 14)
    f:SetScript("OnShow", function() K.Refresh() end)
    UI.Ink(f)
end

local function BuildMailPanel()
    local UI = ns.UI
    local p = CreateFrame("Frame", "AssassinenKontorMail", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    mailPanel = p
    UI.Window(p, .95, { border = 12 })
    p:SetSize(260, 120)
    p:SetFrameStrata("HIGH")
    if MailFrame then p:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 6, -20) else p:SetPoint("CENTER", -300, 0) end
    p:Hide()
    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.title:SetPoint("TOPLEFT", 10, -8)
    p.title:SetText(UI.Book() and (UI.C("title") .. "Assassinen Kontor-Post|r") or "|cffc41e3aAssassinen|r |cffd9b56bKontor-Post|r")
    p.out = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.out:SetPoint("TOPLEFT", 10, -28)
    p.out:SetWidth(240)
    p.out:SetJustifyH("LEFT")
    p.send = UI.TextButton(p, "Brief senden", 110, function() K.SendNext() end, "Schickt den nächsten Brief aus dem Postausgang")
    p.send:SetHeight(22)
    p.send:SetPoint("TOPLEFT", 10, -62)
    p.inbox = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.inbox:SetPoint("TOPLEFT", 10, -92)
    p.take = UI.TextButton(p, "Gold nehmen", 90, function() K.TakeNext() end, "Gold aus dem nächsten Zahlungsbrief entnehmen")
    p.take:SetHeight(20)
    p.take:SetPoint("TOPRIGHT", -10, -88)
    UI.Ink(p)
end

function K.Refresh()
    if mailPanel then
        local show = K.Enabled() and mailOpen and (#data.outbox > 0 or #inboxPayments > 0)
        mailPanel:SetShown(show and true or false)
        if show then
            local item = data.outbox[1]
            local total = 0
            for _, o in ipairs(data.outbox) do total = total + o.copper end
            mailPanel.out:SetText(item and string.format("Postausgang: %d Brief%s (%s)\nNächster: %s an %s",
                #data.outbox, #data.outbox == 1 and "" or "e", Money(total), Money(item.copper), item.to) or "Postausgang leer.")
            mailPanel.send:SetShown(item ~= nil)
            local sum = 0
            for _, pay in ipairs(inboxPayments) do sum = sum + pay.money end
            mailPanel.inbox:SetText(#inboxPayments > 0 and string.format("Zahlungen im Posteingang: %s", Money(sum)) or "")
            mailPanel.take:SetShown(#inboxPayments > 0)
        end
    end

    if not frame or not frame:IsShown() then return end
    local list = SortedContracts()
    frame.offset = math.min(frame.offset, math.max(0, #list - LIST_ROWS))
    for i, row in ipairs(frame.rows) do
        local c = list[i + frame.offset]
        if c then
            local st = K.STATUS[c.status] or { c.status, 1, 1, 1 }
            row.id = c.id
            row.name:SetText(string.format("%s %s(%dg)|r", c.target, ns.UI.C("gray"), c.gold))
            row.status:SetText(st[1])
            row.status:SetTextColor(ns.Design.Ink3(st[2], st[3], st[4]))
            row.sel:SetShown(c.id == frame.selected)
            row:Show()
        else
            row.id = nil
            row:Hide()
        end
    end

    local d, c = frame.detail, data.contracts[frame.selected or ""]
    local function Show(w, on) w:SetShown(on and true or false) end
    Show(d.emblem, not c)
    if not c then
        d.title:SetText(ns.UI.C("gray") .. "Wähle links einen Auftrag.|r")
        for _, fs in ipairs({ d.status, d.client, d.deal, d.reason, d.pay, d.progress, d.info }) do fs:SetText("") end
        for _, w in ipairs({ d.accept, d.decline, d.give, d.complete, d.refund, d.block, d.assignee, d.reward, d.assignLabel }) do Show(w, false) end
    else
        local st = K.STATUS[c.status] or { c.status, 1, 1, 1 }
        local ink = ns.UI.Book()
        d.title:SetText(string.format("Auftrag #%s: |c%s%s|r", c.id, ink and ns.Design.ClassHex(c.class) or ns.ClassColor(c.class), c.target))
        d.status:SetText(st[1])
        d.status:SetTextColor(ns.Design.Ink3(st[2], st[3], st[4]))
        d.client:SetText(string.format("Auftraggeber: %s%s|r%s · %s", ns.UI.C("gold"), c.client, c.anon and " (anonym)" or "", date("%d.%m. %H:%M", c.created)))
        d.deal:SetText(string.format("%d Kill%s für %s%dg|r%s", c.kills, c.kills == 1 and "" or "s", ns.UI.C("gold"), c.gold,
            c.level and (" · Ziel Stufe " .. (c.level > 0 and c.level or "??")) or ""))
        d.reason:SetText(c.reason ~= "" and ("„" .. c.reason .. "“") or "")
        d.pay:SetText(c.paidVerified and (ns.UI.C("good") .. "Zahlung im Briefkasten bestätigt|r " .. date("%d.%m. %H:%M", c.paidVerified))
            or c.paidClaim and (ns.UI.C("gold") .. "Zahlung gemeldet, noch nicht im Briefkasten gesehen|r")
            or (c.status == "angenommen" and string.format("Wartet auf Brief „Auftrag #%s“ an %s", c.id, K.Payee()) or ""))
        d.progress:SetText(c.assignee and string.format("Vergeben an %s · %d/%d Kills · Prämie %s/Kill · ausgezahlt %s",
            c.assignee, c.killsDone or 0, c.kills, Money(c.reward or 0), Money(c.paidOut or 0)) or "")
        d.info:SetText(c.info or "")

        local s = c.status
        Show(d.accept, s == "angefragt")
        Show(d.decline, s == "angefragt" or s == "angenommen" or s == "bezahlt")
        local canGive = s == "bestaetigt" or s == "bezahlt" or s == "vergeben"
        for _, w in ipairs({ d.give, d.assignee, d.reward, d.assignLabel }) do Show(w, canGive) end
        d.give.text:SetText(s == "vergeben" and "Neu vergeben" or "Vergeben")
        Show(d.complete, s == "vergeben")
        Show(d.refund, (s == "bestaetigt" or s == "bezahlt" or s == "vergeben" or s == "abgelehnt") and (c.paidVerified or c.paidClaim))
        Show(d.block, true)
        if canGive and frame.lastDetail ~= c.id then
            d.assignee:SetText(c.assignee or "alle")
            d.reward:SetText(tostring(c.reward and math.floor(c.reward / 10000) or math.floor(c.gold * (S.kontorShare or .8) / c.kills)))
        end
        frame.lastDetail = c.id
    end

    local open, gold = 0, 0
    for _, x in pairs(data.contracts) do
        if ORDER[x.status] then open = open + 1 end
        if x.paidVerified then gold = gold + x.gold end
    end
    frame.summary:SetText(string.format("Offen: %d   ·   eingenommen: %dg   ·   Postausgang: %d Brief%s   ·   Empfänger für Zahlungen: %s",
        open, gold, #data.outbox, #data.outbox == 1 and "" or "e", K.Payee()))
end

---------------------------------------------------------------------------
-- Slash: /assa kontor ...
---------------------------------------------------------------------------

function K.Slash(cmd, raw, arg)
    if cmd ~= "kontor" then return false end
    local sub, rest = (raw or ""):match("^(%S*)%s*(.-)$")
    sub = (sub or ""):lower()
    if sub == "an" or sub == "aus" then
        S.kontor = sub == "an"
        Print(S.kontor and "aktiviert. Auftraggeber können dir jetzt Anfragen schicken." or "deaktiviert.")
    elseif sub == "bank" then
        S.kontorPayee = rest ~= "" and rest or nil
        Print("Zahlungen gehen an: " .. K.Payee())
    elseif sub == "anteil" then
        local v = tonumber(rest)
        if v and v >= 0 and v <= 100 then S.kontorShare = v / 100 end
        Print(string.format("Vorschlag Prämie: %d%% des Auftragswerts", (S.kontorShare or .8) * 100))
    elseif sub == "sperren" and rest ~= "" then
        K.Block(rest)
    elseif sub == "entsperren" and rest ~= "" then
        data.blocked[rest:lower()] = nil
        Print(rest .. " ist entsperrt.")
    elseif not K.Enabled() then
        Print("ist aus. Der Gildenleiter hat es automatisch an; sonst: /assa kontor an")
    else
        if frame:IsShown() then frame:Hide() else frame:Show() end
    end
    return true
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------

local function CheckGuildMaster()
    local _, _, rankIndex = GetGuildInfo("player")
    if rankIndex == 0 and S.kontor == nil then
        S.kontor = true
        Print("aktiviert – du bist Gildenleiter. /assa kontor öffnet die Aufträge.")
    end
end

function K.Init()
    S = ns.settings
    playerName = ns.PlayerName()
    ns.WatchSelfName(function(n) playerName = n end)
    ns.db.kontor = ns.db.kontor or {}
    data = ns.db.kontor
    data.contracts = data.contracts or {}
    data.outbox = data.outbox or {}
    data.blocked = data.blocked or {}

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if addFilter then addFilter("CHAT_MSG_SYSTEM", SystemFilter) end

    BuildFrame()
    BuildMailPanel()

    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "CHAT_MSG_ADDON", "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "MAIL_SEND_SUCCESS",
        "MAIL_FAILED", "PLAYER_GUILD_UPDATE", "GUILD_ROSTER_UPDATE" }) do
        pcall(ev.RegisterEvent, ev, e)
    end
    ev:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_ADDON" then
            local prefix, msg, channel, sender = ...
            if prefix == PREFIX and channel == "WHISPER" then OnWhisper(msg, sender) end
        elseif event == "MAIL_SHOW" then
            mailOpen = true
            if K.Enabled() and CheckInbox then CheckInbox() end
            K.ScanInbox()
        elseif event == "MAIL_CLOSED" then
            mailOpen, sending = false, nil
            K.Refresh()
        elseif event == "MAIL_INBOX_UPDATE" then
            if mailOpen then K.ScanInbox() end
        elseif event == "MAIL_SEND_SUCCESS" then
            OnMailSent()
        elseif event == "MAIL_FAILED" then
            if sending then Print("Brief an " .. sending.to .. " fehlgeschlagen.") end
            sending = nil
        else
            CheckGuildMaster()
        end
    end)
    C_Timer.NewTicker(.3, FlushWhispers)
    CheckGuildMaster()
end
