# Neue Version veröffentlichen: Version in AssassinenKills.toc erhöhen, dann
#   pwsh tools/veroeffentlichen.ps1 -Notes "Was neu ist"
# Packt die Zip, schreibt version.txt, committet, pusht und legt das GitHub-Release an.
# Der Updater der Gildenmitglieder holt sich danach automatisch die neue Version.
param([string]$Notes = "")
$ErrorActionPreference = 'Stop'
$repo = 'mkahl395-cell/assassinen-addon'
$root = Split-Path -Parent $PSScriptRoot
$addon = Join-Path $root 'AssassinenKills'
$ver = (Select-String -LiteralPath (Join-Path $addon 'AssassinenKills.toc') -Pattern '^## Version:\s*(\S+)').Matches[0].Groups[1].Value
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = 'C:\Program Files\GitHub CLI\gh.exe' }

$out = Join-Path $root 'release'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null
Compress-Archive -Path $addon -DestinationPath (Join-Path $out 'AssassinenKills.zip')
[IO.File]::WriteAllText((Join-Path $out 'version.txt'), $ver)
Copy-Item (Join-Path $addon 'Assassinen-Update.bat') $out

git -C $root add -A
git -C $root commit -m "Version $ver" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C $root push origin HEAD
& $gh release create "v$ver" (Join-Path $out 'AssassinenKills.zip') (Join-Path $out 'version.txt') (Join-Path $out 'Assassinen-Update.bat') --repo $repo --title "Version $ver" --notes $(if ($Notes) { $Notes } else { "Version $ver" })
Write-Host "Veröffentlicht: Version $ver" -ForegroundColor Green
