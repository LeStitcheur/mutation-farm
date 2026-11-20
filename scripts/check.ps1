# Vérification complète : sourcemap, formatage, lint, typage strict, tests, build.
# Usage : pwsh scripts/check.ps1 [-Fix]   (-Fix : applique StyLua au lieu de seulement vérifier)
param([switch]$Fix)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Get-Tool([string]$name) {
	$local = Join-Path $root "tools/bin/$name.exe"
	if (Test-Path $local) { return $local }
	$global = Get-Command $name -ErrorAction SilentlyContinue
	if ($global) { return $global.Source }
	throw "Outil introuvable : $name. Lancez scripts/setup-tools.ps1 ou 'rokit install'."
}

$failures = @()
function Invoke-Step([string]$label, [scriptblock]$action) {
	Write-Host "`n=== $label ===" -ForegroundColor Cyan
	& $action
	if ($LASTEXITCODE -ne 0) {
		Write-Host "ÉCHEC : $label (code $LASTEXITCODE)" -ForegroundColor Red
		$script:failures += $label
	} else {
		Write-Host "OK : $label" -ForegroundColor Green
	}
}

$rojo = Get-Tool "rojo"
$stylua = Get-Tool "stylua"
$selene = Get-Tool "selene"
$luauLsp = Get-Tool "luau-lsp"
$lune = Get-Tool "lune"
$defs = Join-Path $root "tools/defs/globalTypes.d.luau"
if (-not (Test-Path $defs)) { throw "Définitions Roblox absentes : $defs (lancez scripts/setup-tools.ps1)." }

Invoke-Step "Sourcemap Rojo" { & $rojo sourcemap default.project.json --output sourcemap.json }
if ($Fix) {
	Invoke-Step "StyLua (formatage)" { & $stylua src tests }
} else {
	Invoke-Step "StyLua (vérification)" { & $stylua --check src tests }
}
Invoke-Step "Selene (lint)" { & $selene src tests }
Invoke-Step "luau-lsp (typage strict)" {
	& $luauLsp analyze --sourcemap=sourcemap.json "--definitions=@roblox=$defs" --base-luaurc=.luaurc --no-strict-dm-types src
}
Invoke-Step "Tests unitaires (Lune)" { & $lune run tests/run.luau }
New-Item -ItemType Directory -Force build | Out-Null
Invoke-Step "Build Rojo" { & $rojo build default.project.json --output build/MutationFarm.rbxlx }

if ($failures.Count -gt 0) {
	Write-Host "`nÉtapes en échec : $($failures -join ', ')" -ForegroundColor Red
	exit 1
}
Write-Host "`nToutes les vérifications sont passées." -ForegroundColor Green
exit 0
