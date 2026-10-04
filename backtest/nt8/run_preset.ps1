# Runs one SMCPresets strategy in the Strategy Analyzer and waits for its log.
#   .\run_preset.ps1 -Preset SMCValH1M5 -Instrument "MNQ 12-26" -From 09/01/2021 -To 10/02/2026 [-Commission]
# The preset is picked from Strategy > Toreda > SMCPresets (alphabetical, 20 px rows), which the
# script finds from the sorted list of preset names in NinjaTrader/Presets/*.cs. Uses the dms-sun-engine
# harness (nt8_helpers.ps1) for window control; Analyzer at 639,3 - 1914,900, hands off while it runs.
param([Parameter(Mandatory = $true)][string]$Preset, [Parameter(Mandatory = $true)][string]$Instrument,
      [string]$From = "09/01/2021", [string]$To = "10/02/2026", [switch]$Commission, [int]$TimeoutMin = 40)
. "C:\Users\chadc\source\repos\dms-sun-engine\backtest\nt8\nt8_helpers.ps1"
$names = Get-ChildItem (Join-Path $PSScriptRoot "..\..\NinjaTrader\Presets\*.cs") | ForEach-Object { Select-String -Path $_.FullName -Pattern "public class (\w+)" -AllMatches } |
  ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -CaseSensitive:$false
$k = [array]::IndexOf(@($names), $Preset); if ($k -lt 0) { throw "preset $Preset not found ($($names -join ','))" }
$logDir = Join-Path $env:USERPROFILE "OneDrive\Documents\NinjaTrader 8\strategyanalyzerlogs"
$rect = Focus-Window "^Strategy Analyzer"
Scroll-Top $rect
Click-NT-Raw $rect 1167 123 | Out-Null; Start-Sleep -Milliseconds 900
Hover-NT-Raw $rect 1150 404; Start-Sleep -Milliseconds 900          # Toreda
Hover-NT-Raw $rect 1010 404; Start-Sleep -Milliseconds 300
Hover-NT-Raw $rect 1010 564; Start-Sleep -Milliseconds 900          # SMCPresets
$y = 564 + 20 * $k
Hover-NT-Raw $rect 900 $y; Start-Sleep -Milliseconds 400
Click-NT-Raw $rect 840 $y | Out-Null; Start-Sleep -Seconds 3
Set-Instrument $rect $Instrument; Start-Sleep 1
Set-Date $rect 0 $From
Set-Date $rect 1 $To
Set-Check $rect 'IncludeComm' ([bool]$Commission)
if ($Commission) {
  $yc = Goto-Label $rect 'IncludeComm'
  Click-NT-Raw $rect 1167 ($yc + 6 + 24) | Out-Null; Start-Sleep -Milliseconds 800; Click-NT-Raw $rect 1170 ($yc + 6 + 24 + 21) | Out-Null; Start-Sleep -Milliseconds 500
}
Shot $rect "preset_$Preset"
$before = @(Get-ChildItem $logDir -Filter "*.xml").Count
Click-NT-Raw $rect ($rect.Right - $rect.Left - 63) ($rect.Bottom - $rect.Top - 52)
$deadline = (Get-Date).AddMinutes($TimeoutMin)
while ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 5; if (@(Get-ChildItem $logDir -Filter "*.xml").Count -gt $before) { break } }
Start-Sleep -Seconds 3
$log = Get-ChildItem $logDir -Filter "*.xml" | Sort-Object LastWriteTime | Select-Object -Last 1
$d = Read-Log $log.FullName
"$($log.Name): strategy params=$($d.params.Count) instrument=$($d.instrument) period=$($d.period) commission=$($d.commission) trades=$($d.stats['TotalNumTrades']) net=$($d.stats['TotalNetProfit']) pf=$($d.stats['ProfitFactor']) dd=$($d.stats['MaxDrawdown'])"
