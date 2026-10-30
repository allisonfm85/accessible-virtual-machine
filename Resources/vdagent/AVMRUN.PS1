# AVM: run one installer with a time limit (2026-10-30).
# Usage: AVMRUN.PS1 <minutes> <program> ["<arguments>"]
# Windows 11 24H2 (26100) left the SPICE agent's msiexec waiting forever in
# the specialize pass, and Setup waits for every step there, so the install
# never got past it (found by the install test from Microsoft's own download,
# 2026-10-30). When the time runs out this stops the program and any
# msiexec it left, so the next installer isn't blocked behind it; the first
# sign-in then tries again (autounattend.xml, FirstLogonCommands).
# On that build every msiexec froze in turn, 5 minutes each, so the first
# freeze leaves FROZE.TXT and later msiexec runs skip straight away. The
# first sign-in deletes it before its own catch-up.
param([int]$Minutes, [string]$Program, [string]$Arguments = '')
$froze = Join-Path $PSScriptRoot 'FROZE.TXT'
if ($Program -eq 'msiexec' -and (Test-Path $froze)) { exit 1460 }
if ($Arguments) {
    $p = Start-Process -FilePath $Program -ArgumentList $Arguments -PassThru
} else {
    $p = Start-Process -FilePath $Program -PassThru
}
if (-not $p.WaitForExit($Minutes * 60000)) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Get-Process msiexec -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Set-Content -Path $froze -Value $Program
    exit 1460
}
exit $p.ExitCode
