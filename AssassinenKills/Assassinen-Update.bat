<# : Assassinen-Update – Batch-Teil (startet nur PowerShell, der Rest der Datei ist das PowerShell-Skript)
@echo off & setlocal & set "AU_SELF=%~f0" & powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:AU_SELF, [Text.Encoding]::UTF8))" & exit /b
#>
# Assassinen-Update: holt die neueste Version des Addons AssassinenKills von GitHub
# und installiert sie in den AddOns-Ordner von WoW Forever. Einfach doppelklicken.

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Assassinen-Update'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = 'mkahl395-cell/assassinen-addon'
$base = "https://github.com/$repo/releases/latest/download"
$cfgDir = Join-Path $env:APPDATA 'AssassinenUpdate'
$cfgFile = Join-Path $cfgDir 'wow-pfad.txt'

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

function Fix-WowDir($d) {
    if (-not $d) { return $null }
    $d = $d.TrimEnd('\')
    if (Test-Path -LiteralPath (Join-Path $d '_forever_')) { $d = Join-Path $d '_forever_' }
    if ((Test-Path -LiteralPath (Join-Path $d 'Wow.exe')) -or (Test-Path -LiteralPath (Join-Path $d 'Interface\AddOns'))) { return $d }
    return $null
}

function Find-WowDir {
    # 1. Liegt das Skript im WoW-Ordner (z. B. Interface\AddOns\AssassinenKills)?
    $p = Split-Path -Parent $env:AU_SELF
    while ($p) {
        $hit = Fix-WowDir $p
        if ($hit) { return $hit }
        $parent = Split-Path -Parent $p
        if ($parent -eq $p) { break }
        $p = $parent
    }
    # 2. Beim letzten Mal gemerkt
    if (Test-Path -LiteralPath $cfgFile) {
        $hit = Fix-WowDir ((Get-Content -LiteralPath $cfgFile -Raw).Trim())
        if ($hit) { return $hit }
    }
    # 3. Installationsort laut Windows
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft') {
        try {
            $loc = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).InstallLocation
            $hit = Fix-WowDir $loc
            if ($hit) { return $hit }
        } catch {}
    }
    # 4. Übliche Orte auf allen Laufwerken
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })) {
        foreach ($sub in 'World of Warcraft', 'Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft',
                         'Games\World of Warcraft', 'Spiele\World of Warcraft', 'Blizzard\World of Warcraft') {
            $hit = Fix-WowDir (Join-Path $drive $sub)
            if ($hit) { return $hit }
        }
    }
    # 5. Selbst auswählen lassen
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Bitte den WoW-Forever-Ordner wählen (der Ordner _forever_ mit Wow.exe darin)'
    if ($dlg.ShowDialog() -eq 'OK') { return Fix-WowDir $dlg.SelectedPath }
    return $null
}

function Get-InstalledVersion($addonDir) {
    $toc = Join-Path $addonDir 'AssassinenKills.toc'
    if (-not (Test-Path -LiteralPath $toc)) { return $null }
    $m = Select-String -LiteralPath $toc -Pattern '^## Version:\s*(\S+)' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

function Is-Newer($a, $b) {
    if (-not $b) { return $true }
    try { return ([version]$a) -gt ([version]$b) } catch { return $a -ne $b }
}

try {
    Say ''
    Say '  ASSASSINEN – Addon-Update' 'Red'
    Say ''
    $wow = Find-WowDir
    if (-not $wow) { throw 'WoW-Forever-Ordner nicht gefunden.' }
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    Set-Content -LiteralPath $cfgFile -Value $wow -Encoding UTF8
    $addonDir = Join-Path $wow 'Interface\AddOns\AssassinenKills'
    Say "  WoW-Ordner: $wow"

    $installed = Get-InstalledVersion $addonDir
    $latest = (Invoke-WebRequest -UseBasicParsing -Uri "$base/version.txt").Content
    if ($latest -is [byte[]]) { $latest = [Text.Encoding]::UTF8.GetString($latest) }
    $latest = $latest.Trim()
    Say ("  Installiert: " + ($(if ($installed) { $installed } else { 'noch nicht' })) + "   Neueste: $latest")

    if (Is-Newer $latest $installed) {
        Say "  Lade Version $latest herunter ..." 'Yellow'
        $tmp = Join-Path $env:TEMP ('AssassinenUpdate-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'AssassinenKills.zip'
        Invoke-WebRequest -UseBasicParsing -Uri "$base/AssassinenKills.zip" -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x') -Force
        $src = Join-Path $tmp 'x\AssassinenKills'
        if (-not (Test-Path -LiteralPath (Join-Path $src 'AssassinenKills.toc'))) { throw 'Download ist unvollständig.' }
        New-Item -ItemType Directory -Force -Path $addonDir | Out-Null
        # Drüberkopieren: eigene Töne (Sounds\eigen1.ogg usw.) bleiben erhalten
        Copy-Item -Path (Join-Path $src '*') -Destination $addonDir -Recurse -Force
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Say "  Fertig: Version $latest ist installiert." 'Green'
        if (Get-Process -Name 'Wow' -ErrorAction SilentlyContinue) {
            Say '  WoW läuft gerade: bitte WoW ganz beenden und neu starten, damit die neue Version lädt.' 'Yellow'
        }
    } else {
        Say '  Du hast schon die neueste Version.' 'Green'
    }

    # Verknüpfung auf dem Desktop, die immer auf den Updater im Addon-Ordner zeigt (der wird mit aktualisiert)
    $installedBat = Join-Path $addonDir 'Assassinen-Update.bat'
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Assassinen-Update.lnk'
    if ((Test-Path -LiteralPath $installedBat) -and -not (Test-Path -LiteralPath $lnk) -and -not $env:AU_TEST) {
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = $installedBat
        $s.WorkingDirectory = $addonDir
        $wowExe = Join-Path $wow 'Wow.exe'
        if (Test-Path -LiteralPath $wowExe) { $s.IconLocation = "$wowExe,0" }
        $s.Save()
        Say '  Verknüpfung "Assassinen-Update" auf dem Desktop angelegt.' 'Green'
    }

    if (-not $env:AU_TEST -and -not (Get-Process -Name 'Wow' -ErrorAction SilentlyContinue)) {
        $bnet = Join-Path ${env:ProgramFiles(x86)} 'Battle.net\Battle.net Launcher.exe'
        if (Test-Path -LiteralPath $bnet) { Say '  Starte Battle.net ...'; Start-Process -FilePath $bnet }
    }
    Say ''
    Say '  Fenster schließt gleich von selbst.'
    if (-not $env:AU_TEST) { Start-Sleep -Seconds 6 }
} catch {
    Say ''
    Say ("  FEHLER: " + $_.Exception.Message) 'Red'
    Say "  Manuell: https://github.com/$repo/releases/latest" 'Yellow'
    Say ''
    if (-not $env:AU_TEST) { Read-Host '  Enter zum Schließen' }
}
