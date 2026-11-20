# Télécharge la chaîne d'outils épinglée (voir rokit.toml) dans tools/bin, sans modifier le PATH.
# Sources : releases GitHub officielles. Usage : pwsh scripts/setup-tools.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root "tools/bin"
$dl = Join-Path $root "tools/dl"
$defsDir = Join-Path $root "tools/defs"
New-Item -ItemType Directory -Force $bin, $dl, $defsDir | Out-Null

$tools = @(
	@{ Name = "rojo"; Url = "https://github.com/rojo-rbx/rojo/releases/download/v7.7.1/rojo-7.7.1-windows-x86_64.zip" },
	@{ Name = "stylua"; Url = "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.6.0/stylua-windows-x86_64.zip" },
	@{ Name = "selene"; Url = "https://github.com/Kampfkarren/selene/releases/download/0.32.0/selene-0.32.0-windows.zip" },
	@{ Name = "lune"; Url = "https://github.com/lune-org/lune/releases/download/v0.11.1/lune-0.11.1-windows-x86_64.zip" },
	@{ Name = "luau-lsp"; Url = "https://github.com/JohnnyMorganz/luau-lsp/releases/download/1.70.1/luau-lsp-win64.zip" }
)

foreach ($tool in $tools) {
	$dir = Join-Path $dl $tool.Name
	New-Item -ItemType Directory -Force $dir | Out-Null
	$zip = Join-Path $dir "$($tool.Name).zip"
	Write-Host "Téléchargement de $($tool.Name)..."
	Invoke-WebRequest -Uri $tool.Url -OutFile $zip
	Expand-Archive -Force $zip (Join-Path $dir "x")
	Get-ChildItem (Join-Path $dir "x") -Recurse -Filter *.exe | ForEach-Object { Copy-Item $_.FullName $bin -Force }
}

Write-Host "Téléchargement des définitions de types Roblox (luau-lsp 1.70.1)..."
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.70.1/scripts/globalTypes.d.luau" -OutFile (Join-Path $defsDir "globalTypes.d.luau")

foreach ($name in "rojo", "stylua", "selene", "lune", "luau-lsp") { & (Join-Path $bin "$name.exe") --version }
