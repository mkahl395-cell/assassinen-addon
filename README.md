# Assassinen – Addon für WoW Forever

Kill-Tracker, Späher, Alarme, Rangliste und Gruppen-Werkzeuge für die Gilde **Assassinen**.

## Installieren und aktuell halten

1. **[Assassinen-Update.bat herunterladen](https://github.com/mkahl395-cell/assassinen-addon/releases/latest/download/Assassinen-Update.bat)**
2. Doppelklicken. Beim ersten Mal fragt Windows evtl. nach („Windows hat den PC geschützt“ → *Weitere Informationen* → *Trotzdem ausführen*).
3. Der Updater sucht den WoW-Forever-Ordner (findet er ihn nicht, wählst du den Ordner `_forever_` aus), installiert die neueste Version und legt auf dem Desktop die Verknüpfung **Assassinen-Update** an.
4. Ab jetzt: **vor dem Spielen einfach die Verknüpfung „Assassinen-Update“ starten.** Sie holt neue Versionen automatisch und startet danach Battle.net.

Im Spiel sagt das Addon außerdem Bescheid, wenn jemand aus der Gilde schon eine neuere Version hat.
`/assa versionen` zeigt, wer welche Version nutzt.

## Ohne Updater

[Neueste Version](https://github.com/mkahl395-cell/assassinen-addon/releases/latest) → `AssassinenKills.zip` herunterladen und den Ordner `AssassinenKills` nach
`…\World of Warcraft\_forever_\Interface\AddOns\` entpacken. Danach WoW neu starten.

## Aussehen

Die Fenster sind im **Blutbuch**-Design: Pergament im roten Lederrahmen, die Intel-Zentrale als aufgeschlagenes Buch, Wachssiegel und Blutspritzer. Bei jedem Kill erscheint kurz ein Steckbrief.
`/assa design dunkel` schaltet auf das alte dunkle Aussehen zurück (`/assa design buch` wieder auf das Buch, danach `/reload`). `/assa steckbrief aus` schaltet den Steckbrief ab.

## Profile

In der Intel-Zentrale (Rechtsklick auf den Minimap-Knopf) einen Feind auswählen und **Merken** klicken. Unter „Warum auf der Liste“ den Grund eintippen, darunter Erlebnisse – jeweils mit Enter speichern. Alle gemerkten Feinde stehen im Reiter **Gemerkt**. Per Befehl: `/assa merken <Name> [Grund]`.
**Teilen** schickt den Grund und deine letzten 5 Erlebnisse: Klick an die Gilde, Shift+Klick an die Gruppe, Strg+Klick an den Spieler im Ziel (oder `/assa teilen <Name> [Spieler]`).

## Neutrale Städte

In Beutebucht, Gadgetzan, Ratschet, Ewige Warte und anderen neutralen Orten warnen nur noch KOS, Aufträge und Fehden. `/assa neutral aus` schaltet das ab, `/assa neutral hier` trägt einen fehlenden Ort ein.

## Befehle

`/assa` zeigt alle Befehle. Fast alles geht auch per Klick über die Kommando-Leiste (`/assa leiste`).
