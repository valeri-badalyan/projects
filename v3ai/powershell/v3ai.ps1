#Requires -Version 5.1
<#
.SYNOPSIS
  V3AI для PowerShell — консольная версия ИИ-помощника V3AI.

.DESCRIPTION
  Чат с Claude прямо в терминале: режимы (Помощник, Учёба, Писатель, Переводчик, Код, Весельчак),
  Художник (SVG-картинки), WattAI (браузерные игры), Dr. Agents (агенты с памятью и делами),
  подключение GitHub-репозитория по ссылке, шесть моделей V3AI, EngineSecure и история чатов.

  Ключ API берётся из переменной среды ANTHROPIC_API_KEY (или вводится при запуске).
  Без ключа V3AI работает в небольшом офлайн-режиме.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\v3ai.ps1
  pwsh ./v3ai.ps1 -Model ortl55 -Mode code
#>
[CmdletBinding()]
param(
  [string]$Model,
  [string]$Mode,
  [switch]$NoColor
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ── Подготовка окружения ───────────────────────────────────────────────────────────────────────
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:IsWinPS = $PSVersionTable.PSVersion.Major -lt 6
if ($script:IsWinPS) {
  Add-Type -AssemblyName System.Net.Http
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  # В Windows PowerShell 5.1 без этого массивы иногда превращаются в {"value":[...],"Count":n}.
  Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
}

$script:Version = '1.3'
$script:Root = Join-Path $HOME '.v3ai'
$script:Paths = @{
  Config = Join-Path $script:Root 'config.json'
  Chats  = Join-Path $script:Root 'chats'
  Agents = Join-Path $script:Root 'agents.json'
  Memory = Join-Path $script:Root 'agent-memory'
  Games  = Join-Path $script:Root 'games'
  Art    = Join-Path $script:Root 'art'
  Export = Join-Path $script:Root 'export'
  Video  = Join-Path $script:Root 'video'
  Gif    = Join-Path $script:Root 'gif'
  Design = Join-Path $script:Root 'design'
}
$script:VT = (-not $NoColor) -and ($Host.UI.SupportsVirtualTerminal -eq $true)
$script:ESC = [char]27
$script:Http = [System.Net.Http.HttpClient]::new()
$script:Http.Timeout = [TimeSpan]::FromMinutes(20)
$script:ApiKey = $env:ANTHROPIC_API_KEY
# Откуда берётся ИИ: ключ API (если задан) → Claude Code (вход через аккаунт Claude, без ключа) → офлайн.
$script:CcCmd = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
$script:CcPartial = $true
function Get-V3Backend { if ($script:ApiKey) { return 'api' } elseif ($script:CcCmd) { return 'claude-code' } else { return 'offline' } }
$script:Backend = Get-V3Backend
$script:GhToken = $env:GITHUB_TOKEN

# ── JSON и файлы ───────────────────────────────────────────────────────────────────────────────
function ConvertTo-V3Json($Object) { ConvertTo-Json -InputObject $Object -Depth 64 -Compress }

# PSCustomObject из ConvertFrom-Json → изменяемые hashtable/List (рекурсивно)
function ConvertTo-V3Hash($Object) {
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Management.Automation.PSCustomObject]) {
    $h = [ordered]@{}
    foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-V3Hash $p.Value }
    return $h
  }
  if ($Object -is [System.Collections.IDictionary]) {
    $h = [ordered]@{}
    foreach ($k in @($Object.Keys)) { $h[$k] = ConvertTo-V3Hash $Object[$k] }
    return $h
  }
  if (($Object -is [System.Collections.IList]) -and ($Object -isnot [string])) {
    $l = [System.Collections.Generic.List[object]]::new()
    foreach ($x in $Object) { $l.Add((ConvertTo-V3Hash $x)) }
    return , $l
  }
  return $Object
}

function Read-V3Json([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { $v = ConvertTo-V3Hash ((Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json); return , $v } catch { return $null }
}

function Save-V3Json([string]$Path, $Object) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [IO.File]::WriteAllText($Path, (ConvertTo-V3Json $Object), [Text.UTF8Encoding]::new($false))
}

function New-V3List { return , ([System.Collections.Generic.List[object]]::new()) }

function Get-V3Prop($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } else { return $Default } }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# ── Внешний вид: темы «Sunset» (по умолчанию) и «Neon» ──
$script:Themes = @{
  studio = @{ g1 = @(232, 161, 91); g2 = @(232, 161, 91); frame = 'DarkGray'; head = 'Cyan'; acc = 'DarkYellow'; acc2 = 'Gray'; code = 'DarkYellow'; bullet = '•'; gutter = '  '; box = 'panel'; prompt = 'studio'
              map = @{ Cyan = 'DarkYellow'; Green = 'Cyan'; Magenta = 'Magenta' } }
  sunset = @{ g1 = @(255, 79, 216); g2 = @(255, 181, 71); frame = 'DarkMagenta'; head = 'Magenta'; acc = 'Magenta'; acc2 = 'Yellow'; code = 'DarkYellow'; bullet = '›'; gutter = '  ▏ '; box = 'heavy'; prompt = 'double'
              map = @{ Cyan = 'Magenta'; Green = 'Yellow'; Magenta = 'DarkYellow' } }
  neon   = @{ g1 = @(0, 180, 255); g2 = @(125, 255, 207); frame = 'DarkCyan'; head = 'Cyan'; acc = 'Cyan'; acc2 = 'Green'; code = 'DarkYellow'; bullet = '•'; gutter = '  '; box = 'round'; prompt = 'single'
              map = @{} }
}
$script:T = $script:Themes.studio
# Тема Studio рисует настоящими цветами (truecolor), если терминал умеет; иначе — 16 цветами консоли.
$script:SH = @{ text = 'c9ced6'; dim = '8a92a0'; orange = 'e8a15b'; teal = '4fd1c5'; blue = '7aa2f7'; purple = 'bb9af7'; white = 'f2f4f8'; code = 'e5c07b'; band = '252a33' }
$script:SHFall = @{ text = 'Gray'; dim = 'DarkGray'; orange = 'DarkYellow'; teal = 'Cyan'; blue = 'Blue'; purple = 'Magenta'; white = 'White'; code = 'Yellow'; band = 'Gray' }
$script:InPanel = $false; $script:Ln = 0
function Get-V3Width { $w = 80; try { $w = [Console]::WindowWidth } catch { }; return [Math]::Max(40, [Math]::Min(110, $w - 2)) }
function Write-V3X([string]$Text, [string]$Tone = 'text', [switch]$NoNewline, [switch]$Bold, [string]$Bg = '') {
  if ($script:VT) {
    $h = $script:SH[$Tone]; $pre = "$($script:ESC)[38;2;$([Convert]::ToInt32($h.Substring(0, 2), 16));$([Convert]::ToInt32($h.Substring(2, 2), 16));$([Convert]::ToInt32($h.Substring(4, 2), 16))m"
    if ($Bold) { $pre += "$($script:ESC)[1m" }
    if ($Bg) { $bh = $script:SH[$Bg]; $pre += "$($script:ESC)[48;2;$([Convert]::ToInt32($bh.Substring(0, 2), 16));$([Convert]::ToInt32($bh.Substring(2, 2), 16));$([Convert]::ToInt32($bh.Substring(4, 2), 16))m" }
    Write-Host ($pre + $Text + "$($script:ESC)[0m") -NoNewline:$NoNewline
  } else { Write-Host $Text -ForegroundColor $script:SHFall[$Tone] -NoNewline:$NoNewline }
}
# Заголовок посередине рамки: ──── title ────
function Write-V3Frame([string]$Title, [string]$Tone = 'orange') {
  $w = Get-V3Width; $side = [Math]::Max(3, [int](($w - $Title.Length - 4) / 2))
  Write-V3X ('  ' + ('─' * $side) + ' ') dim -NoNewline; Write-V3X $Title $Tone -NoNewline; Write-V3X (' ' + ('─' * $side)) dim
}
function Write-V3Band([string]$Text) {   # вопрос пользователя на серой плашке
  $w = Get-V3Width
  if (-not $script:VT) { Write-V3X ('  ❯ ' + $Text) white; return }
  $pad = ' ' * $w
  Write-V3X $pad white -Bg band
  foreach ($l in ($Text -split "`n")) { $t = '  ❯ ' + $l; if ($t.Length -lt $w) { $t += ' ' * ($w - $t.Length) }; Write-V3X $t white -Bg band }
  Write-V3X $pad white -Bg band
}
function Write-V3Hints {
  $M = Get-V3Model $script:Cfg.model
  $parts = @(@('Enter', 'отправить'), @('/help', 'команды'), @('/model', 'модель'), @('/theme', 'тема'), @('Esc', 'стоп'))
  Write-Host '  ' -NoNewline
  for ($i = 0; $i -lt $parts.Count; $i++) { if ($i) { Write-V3X ' │ ' dim -NoNewline }; Write-V3X $parts[$i][0] text -NoNewline; Write-V3X (' ' + $parts[$i][1]) dim -NoNewline }
  Write-V3X ('   ' + $M.n) dim
}
function Get-V3Tone([string]$Color) { $m = $script:T.map; if ($m.ContainsKey($Color)) { return $m[$Color] } else { return $Color } }

# ── Внешний вид: «V3AI Terminal» ──────────────────────────────────────────────────────────────
function Get-V3Rgb([int]$r, [int]$g, [int]$b, [string]$text) {
  if ($script:VT) { return "$($script:ESC)[38;2;$r;$g;${b}m$text$($script:ESC)[0m" }
  return $text
}

function Write-V3Gradient([string]$Text, [int[]]$From = $null, [int[]]$To = $null) {
  if (-not $From) { $From = $script:T.g1 }; if (-not $To) { $To = $script:T.g2 }
  if (-not $script:VT) { Write-Host $Text -ForegroundColor $script:T.acc; return }
  $sb = [Text.StringBuilder]::new()
  $n = [Math]::Max(1, $Text.Length - 1)
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $t = $i / $n
    $r = [int]($From[0] + ($To[0] - $From[0]) * $t); $g = [int]($From[1] + ($To[1] - $From[1]) * $t); $b = [int]($From[2] + ($To[2] - $From[2]) * $t)
    [void]$sb.Append("$($script:ESC)[38;2;$r;$g;${b}m").Append($Text[$i])
  }
  [void]$sb.Append("$($script:ESC)[0m")
  Write-Host $sb.ToString()
}

function Write-V3Banner {
  Write-Host ''
  if ($script:T.box -eq 'panel') {
    Write-V3X '  ◆ ' orange -NoNewline; Write-V3X 'V3AI Studio' white -Bold -NoNewline; Write-V3X "   v$($script:Version) · PowerShell $($PSVersionTable.PSVersion)" dim
    Write-V3X '  v3ai/' text -NoNewline; Write-V3X ([string]$script:Cfg.mode) teal -NoNewline; Write-V3X ('  ' + (Get-Location).Path) dim
    Write-Host ''
    Write-V3Hints
    Write-Host ''
    return
  }
  if ($script:T.box -eq 'round') {
    $logo = @(
      '  ██╗   ██╗██████╗  █████╗ ██╗',
      '  ██║   ██║╚════██╗██╔══██╗██║',
      '  ██║   ██║ █████╔╝███████║██║',
      '  ╚██╗ ██╔╝ ╚═══██╗██╔══██║██║',
      '   ╚████╔╝ ██████╔╝██║  ██║██║',
      '    ╚═══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝'
    )
    foreach ($line in $logo) { Write-V3Gradient $line }
    Write-Host ('  ' + (Get-V3Rgb 125 255 207 'Terminal') + "  v$($script:Version) · ИИ-помощник от команды V3 · PowerShell $($PSVersionTable.PSVersion)") -ForegroundColor DarkGray
  } else {
    $logo = @(
      '   █   █  ▀▀▀█   ▄▀▄   █',
      '    █ █    ▀▀█  █▄▄▄█  █',
      '     █    ▄▄▄█  █   █  █'
    )
    foreach ($line in $logo) { Write-V3Gradient $line }
    Write-V3Gradient '  ━━━━━━━━━━━━━━━━━━━━━━━━━━'
    Write-V3Gradient '     ━━━━━━━━━━━━━━━━━━━━'
    Write-V3Gradient '        ━━━━━━━━━━━━━━'
    Write-Host ('  ' + (Get-V3Rgb 255 181 71 'SUNSET') + "  V3AI Terminal v$($script:Version) · PowerShell $($PSVersionTable.PSVersion) · /theme — сменить тему") -ForegroundColor DarkGray
  }
  Write-Host ''
}

function Write-V3Rule([string]$Title = '') {
  $w = 60; try { $w = [Math]::Min(78, [Console]::WindowWidth - 2) } catch { }
  if ($script:T.box -eq 'panel') { Write-V3Frame $Title; return }
  $ch = $(if ($script:T.box -eq 'heavy') { '━' } else { '─' })
  if ($Title) {
    $rest = [Math]::Max(3, $w - $Title.Length - 4)
    if ($script:T.box -eq 'heavy') { Write-V3Gradient ("$ch$ch $Title " + ($ch * $rest)) } else { Write-V3Gradient ("──╴$Title╶" + ('─' * $rest)) }
  } else { Write-V3Gradient ($ch * $w) }
}

function Write-V3Box([string]$Title, [string[]]$Lines, [ConsoleColor]$Color = 'Cyan') {
  $c = Get-V3Tone ([string]$Color)
  if ($script:T.box -eq 'panel') {
    $tone = @{ DarkYellow = 'orange'; Cyan = 'teal'; Magenta = 'purple'; Yellow = 'orange'; Green = 'teal' }[$c]; if (-not $tone) { $tone = 'orange' }
    Write-V3Frame $Title $tone
    foreach ($l in $Lines) { Write-V3X '  │ ' dim -NoNewline; Write-V3X $l text }
    Write-V3X ('  ╰' + ('─' * ((Get-V3Width) - 3))) dim
    return
  }
  if ($script:T.box -eq 'heavy') {
    Write-Host "  ┏━ " -NoNewline -ForegroundColor $c; Write-Host $Title -ForegroundColor $c
    foreach ($l in $Lines) { Write-Host "  ┃ " -ForegroundColor $c -NoNewline; Write-Host $l }
    Write-Host ('  ┗' + ('━' * 28)) -ForegroundColor $c
  } else {
    Write-Host "  ╭─ $Title" -ForegroundColor $c
    foreach ($l in $Lines) { Write-Host "  │ " -ForegroundColor $c -NoNewline; Write-Host $l }
    Write-Host '  ╰─' -ForegroundColor $c
  }
}

function Write-V3Note([string]$Text, [ConsoleColor]$Color = 'DarkGray') { Write-Host "  $Text" -ForegroundColor $Color }

# Рендер ответа: построчно, с подсветкой **жирного**, `кода`, блоков ```, заголовков и списков.
$script:R = @{ Buf = ''; InCode = $false; Started = $false; Spinner = $false }

function Start-V3Render([string]$Waiting = 'думает…') {
  $script:R = @{ Buf = ''; InCode = $false; Started = $false; Spinner = $true }
  if ($script:T.box -eq 'panel') { Write-V3X '  ◆ ' orange -NoNewline; Write-V3X $Waiting dim -NoNewline; return }
  Write-Host ($script:T.gutter + "◌ $Waiting") -NoNewline -ForegroundColor DarkGray
}

function Clear-V3Spinner {
  if ($script:R.Spinner) { Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline; $script:R.Spinner = $false }
}

function Add-V3Render([string]$Text) {
  if (-not $script:R.Started) { Clear-V3Spinner; $script:R.Started = $true }
  $script:R.Buf += $Text
  while (($i = $script:R.Buf.IndexOf("`n")) -ge 0) {
    $line = $script:R.Buf.Substring(0, $i).TrimEnd("`r")
    $script:R.Buf = $script:R.Buf.Substring($i + 1)
    Write-V3Line $line
  }
}

function Stop-V3Render {
  Clear-V3Spinner
  if ($script:R.Buf.Length) { Write-V3Line $script:R.Buf; $script:R.Buf = '' }
  if ($script:R.InCode) { $script:R.InCode = $false }
}

function Write-V3Inline([string]$Line, [ConsoleColor]$Base = 'Gray', [switch]$Strong) {
  $parts = [regex]::Split($Line, '(\*\*[^*]+\*\*|`[^`]+`)')
  if ($script:T.box -eq 'panel') {
    foreach ($p in $parts) {
      if (-not $p) { continue }
      if ($p.StartsWith('**') -and $p.EndsWith('**') -and $p.Length -gt 4) { Write-V3X $p.Substring(2, $p.Length - 4) white -Bold -NoNewline }
      elseif ($p.StartsWith('`') -and $p.EndsWith('`') -and $p.Length -gt 2) { Write-V3X $p.Substring(1, $p.Length - 2) teal -NoNewline }
      elseif ($Strong) { Write-V3X $p white -Bold -NoNewline }
      else { Write-V3X $p text -NoNewline }
    }
    Write-Host ''
    return
  }
  foreach ($p in $parts) {
    if (-not $p) { continue }
    if ($p.StartsWith('**') -and $p.EndsWith('**') -and $p.Length -gt 4) { Write-Host $p.Substring(2, $p.Length - 4) -NoNewline -ForegroundColor White }
    elseif ($p.StartsWith('`') -and $p.EndsWith('`') -and $p.Length -gt 2) { Write-Host $p.Substring(1, $p.Length - 2) -NoNewline -ForegroundColor Yellow }
    else { Write-Host $p -NoNewline -ForegroundColor $Base }
  }
  Write-Host ''
}

function Write-V3Line([string]$Line) {
  $T = $script:T; $g = $T.gutter
  if ($T.box -eq 'panel') {
    $t = $Line.Trim()
    if ($script:InPanel) { $script:Ln++; Write-V3X ('  ' + $script:Ln.ToString().PadLeft(3) + ' ') dim -NoNewline } else { Write-Host '  ' -NoNewline }
    if ($t.StartsWith('```')) { $script:R.InCode = -not $script:R.InCode; $lang = $t.Substring(3).Trim(); Write-V3X $(if ($script:R.InCode) { '┌ ' + $(if ($lang) { $lang } else { 'код' }) } else { '└' }) dim; return }
    if ($script:R.InCode) { Write-V3X ('│ ' + $Line) code; return }
    if ($t -match '^(#{1,4})\s+(.*)$') { $tone = @('teal', 'blue', 'purple', 'purple')[$Matches[1].Length - 1]; Write-V3X $Matches[2] $tone -Bold; return }
    if ($t -match '^[-*•]\s+(.*)$') { Write-V3X '  • ' dim -NoNewline; Write-V3Inline $Matches[1]; return }
    if ($t -match '^(\d+)[.)]\s+(.*)$') { Write-V3X ($Matches[1] + '. ') white -Bold -NoNewline; Write-V3Inline $Matches[2] -Strong; return }
    Write-V3Inline $Line
    return
  }
  $t = $Line.Trim()
  if ($t.StartsWith('```')) {
    $script:R.InCode = -not $script:R.InCode
    $lang = $t.Substring(3).Trim(); if (-not $lang) { $lang = 'код' }
    if ($T.box -eq 'heavy') {
      Write-Host $g -NoNewline -ForegroundColor DarkGray
      if ($script:R.InCode) { Write-Host ("▌ $lang " + ('─' * 20)) -ForegroundColor $T.code } else { Write-Host '▌' -ForegroundColor $T.code }
    } elseif ($script:R.InCode) { Write-Host ('  ┌─ ' + $lang) -ForegroundColor $T.code } else { Write-Host '  └─' -ForegroundColor $T.code }
    return
  }
  if ($script:R.InCode) {
    if ($T.box -eq 'heavy') { Write-Host $g -NoNewline -ForegroundColor DarkGray; Write-Host '▌ ' -NoNewline -ForegroundColor $T.code } else { Write-Host '  │ ' -NoNewline -ForegroundColor $T.code }
    Write-Host $Line -ForegroundColor Yellow; return
  }
  Write-Host $g -NoNewline -ForegroundColor DarkGray
  if ($t -match '^#{1,4}\s+(.*)$') { Write-Host $Matches[1] -ForegroundColor $T.head; return }
  if ($t -match '^[-*•]\s+(.*)$') { Write-Host " $($T.bullet) " -NoNewline -ForegroundColor $T.acc2; Write-V3Inline $Matches[1]; return }
  if ($t -match '^(\d+)[.)]\s+(.*)$') { Write-Host (' ' + $Matches[1] + '. ') -NoNewline -ForegroundColor $T.acc2; Write-V3Inline $Matches[2]; return }
  Write-V3Inline $Line
}

# ── Настройки, модели, режимы ─────────────────────────────────────────────────────────────────
$script:Models = @(
  @{ id = 'lai13';   n = 'LAI 1.3';       tag = 'Лёгкая';    api = 'claude-haiku-5-5';  effort = 'low';    len = 60;  d = 'Самая простая: отвечает мгновенно и очень коротко.' },
  @{ id = 'fuhi28';  n = 'FUHI 2.8';      tag = 'Быстрая';   api = 'claude-haiku-5-5';  effort = 'medium'; len = 120; d = 'Быстрая и весёлая для обычных вопросов и идей.' },
  @{ id = 'ards31';  n = 'ARDSONNET 3.1'; tag = 'Умная';     api = 'claude-sonnet-5-5'; effort = 'low';    len = 150; d = 'Точнее объясняет, лучше пишет код.' },
  @{ id = 'flash39'; n = 'FLASH 3.9';     tag = 'Скорость+'; api = 'claude-opus-5-5';   effort = 'low';    len = 220; speed = 'fast'; d = 'Флагман в быстром режиме: молниеносно, но дороже.' },
  @{ id = 'ards45';  n = 'ARDSONNET 4.5'; tag = 'Сильная';   api = 'claude-sonnet-5-5'; effort = 'high';   len = 300; d = 'Развёрнутые ответы, учёба шаг за шагом, игры.' },
  @{ id = 'ortl55';  n = 'V3 ORTL 5.5';   tag = 'Флагман';   api = 'claude-opus-5-5';   effort = 'high';   len = 400; d = 'Самая мощная: сложные задачи, большой код, лучшие игры.' }
)

$script:Modes = @(
  @{ id = 'help';   ico = '✨'; n = 'Помощник';   p = 'Режим «Помощник»: отвечай понятно и по делу, давай практичные советы.' },
  @{ id = 'school'; ico = '📚'; n = 'Учёба';      p = 'Режим «Учёба»: ты терпеливый учитель. Объясняй шаг за шагом, простыми словами и с примерами. С домашним заданием не давай просто готовый ответ — покажи ход решения.' },
  @{ id = 'write';  ico = '✍'; n = 'Писатель';   p = 'Режим «Писатель»: пиши живые истории, стихи с рифмой, поздравления, придумывай названия и идеи.' },
  @{ id = 'lang';   ico = '🌍'; n = 'Переводчик'; p = 'Режим «Переводчик»: переводи текст. Если язык не указан: с русского — на английский, с других — на русский. Ниже — произношение русскими буквами или полезный нюанс.' },
  @{ id = 'code';   ico = '💻'; n = 'Код';        p = 'Режим «Код»: ты опытный программист и наставник. Давай рабочий код в блоках ``` с языком и кратко объясняй, как он работает.' },
  @{ id = 'fun';    ico = '😂'; n = 'Весельчак';  p = 'Режим «Весельчак»: шутки, загадки (ответ не говори сразу), викторины, игры в слова. Только добрый юмор.' },
  @{ id = 'art';    ico = '🎨'; n = 'Художник';   p = '' },
  @{ id = 'game';   ico = '🕹'; n = 'WattAI';     p = '' },
  @{ id = 'video';  ico = '🎬'; n = 'Видео';      p = '' },
  @{ id = 'design'; ico = '✒'; n = 'Design';     p = '' },
  @{ id = 'agents'; ico = '🩺'; n = 'Dr. Agents'; p = '' }
)

function Get-V3Model([string]$Id) { foreach ($m in $script:Models) { if ($m.id -eq $Id) { return $m } }; return $script:Models[5] }
function Get-V3Mode([string]$Id) { foreach ($m in $script:Modes) { if ($m.id -eq $Id) { return $m } }; return $script:Modes[0] }

$script:Cfg = Read-V3Json $script:Paths.Config
if (-not $script:Cfg) { $script:Cfg = [ordered]@{} }
foreach ($kv in @(@('model', 'ortl55'), @('mode', 'help'), @('secureOn', $true), @('asked', 0), @('theme', 'studio'))) { if (-not $script:Cfg.Contains($kv[0])) { $script:Cfg[$kv[0]] = $kv[1] } }
if (-not $script:Cfg.Contains('secure') -or -not ($script:Cfg['secure'] -is [System.Collections.IDictionary])) { $script:Cfg['secure'] = [ordered]@{} }
if ($Model) { $script:Cfg.model = (Get-V3Model $Model).id }
if ($Mode) { $script:Cfg.mode = (Get-V3Mode $Mode).id }
function Save-V3Config { Save-V3Json $script:Paths.Config $script:Cfg }
if (-not $script:Cfg.Contains('themeSet')) { $script:Cfg.theme = 'studio' }   # пока тему не выбрали сами — новая Studio
if ($script:Themes.ContainsKey([string]$script:Cfg.theme)) { $script:T = $script:Themes[[string]$script:Cfg.theme] }

# ── EngineSecure ──────────────────────────────────────────────────────────────────────────────
$script:SecureActs = [ordered]@{
  open   = @{ ico = '🕹'; n = 'Открытие файлов'; d = 'Игры WattAI и картинки откроются в браузере. Игра — это программа, которую написал ИИ.' }
  save   = @{ ico = '💾'; n = 'Сохранение файлов'; d = 'Игры, картинки и экспорт чатов сохраняются в папку ~/.v3ai.' }
  github = @{ ico = '🐙'; n = 'Доступ к GitHub'; d = 'V3AI читает репозиторий (только чтение). С токеном — и закрытые репозитории твоего аккаунта.' }
  photo  = @{ ico = '📷'; n = 'Отправка фото ИИ'; d = 'Фото будет отправлено ИИ, чтобы он ответил на вопрос о нём.' }
  key    = @{ ico = '🔑'; n = 'Сохранение ключей'; d = 'Ключ сохранится в переменную среды твоей учётной записи, чтобы не вводить его каждый раз.' }
}

function Request-V3Permission([string]$Act, [string]$Detail = '') {
  if (-not $script:Cfg.secureOn) { return $true }
  $A = $script:SecureActs[$Act]
  $st = Get-V3Prop $script:Cfg.secure $Act 'ask'
  if ($st -eq 'allow') { return $true }
  if ($st -eq 'deny') { Write-V3Note "🛡 EngineSecure: «$($A.n)» запрещено. Изменить: /secure" Yellow; return $false }
  Write-Host ''
  $lines = @("V3AI просит разрешение: «$($A.n)» $($A.ico)", $A.d)
  if ($Detail) { $lines += $Detail }
  $lines += '[Д] да, один раз   [В] всегда   [Н] нет   [З] запретить навсегда'
  Write-V3Box '🛡 EngineSecure' $lines Cyan
  while ($true) {
    $a = (Read-Host '  Выбор').Trim().ToLower()
    switch -Regex ($a) {
      '^(д|да|y|yes)$'          { Write-V3Note '🛡 разрешено'; return $true }
      '^(в|всегда|a|always)$'   { $script:Cfg.secure[$Act] = 'allow'; Save-V3Config; Write-V3Note '🛡 разрешено навсегда (изменить: /secure)'; return $true }
      '^(н|нет|n|no|)$'         { Write-V3Note '🛡 отменено'; return $false }
      '^(з|запретить|x|never)$' { $script:Cfg.secure[$Act] = 'deny'; Save-V3Config; Write-V3Note '🛡 запрещено навсегда (изменить: /secure)'; return $false }
    }
    Write-V3Note 'Введи Д, В, Н или З.'
  }
}

function Show-V3Secure {
  Write-V3Rule '🛡 EngineSecure'
  Write-V3Note ("Защита: " + $(if ($script:Cfg.secureOn) { 'включена' } else { 'ВЫКЛЮЧЕНА' })) White
  $i = 0
  foreach ($k in $script:SecureActs.Keys) {
    $i++; $A = $script:SecureActs[$k]; $st = Get-V3Prop $script:Cfg.secure $k 'ask'
    $label = @{ ask = 'спрашивать'; allow = 'разрешено'; deny = 'запрещено' }[$st]
    Write-Host ("   $i. $($A.ico) $($A.n)".PadRight(34)) -NoNewline; Write-Host $label -ForegroundColor $(if ($st -eq 'allow') { 'Green' } elseif ($st -eq 'deny') { 'Red' } else { 'Yellow' })
  }
  Write-V3Note 'Изменить: /secure <номер> ask|allow|deny   ·   /secure on|off'
}

function Set-V3Secure([string[]]$Words) {
  if ($Words.Count -ge 1 -and $Words[0] -in @('on', 'off')) {
    if ($Words[0] -eq 'off') {
      $a = Read-Host '  ⚠ Выключить EngineSecure? V3AI перестанет спрашивать разрешения (да/нет)'
      if ($a.Trim().ToLower() -notin @('да', 'д', 'y', 'yes')) { Write-V3Note 'Оставил защиту включённой.'; return }
    }
    $script:Cfg.secureOn = ($Words[0] -eq 'on'); Save-V3Config; Show-V3Secure; return
  }
  if ($Words.Count -ge 2) {
    $keys = @($script:SecureActs.Keys); $n = 0
    if ([int]::TryParse($Words[0], [ref]$n) -and $n -ge 1 -and $n -le $keys.Count -and $Words[1] -in @('ask', 'allow', 'deny')) {
      $script:Cfg.secure[$keys[$n - 1]] = $Words[1]; Save-V3Config
    }
  }
  Show-V3Secure
}

# ── Ключ API ──────────────────────────────────────────────────────────────────────────────────
function ConvertFrom-V3Secure([Security.SecureString]$S) {
  $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($S)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

function Request-V3ApiKey {
  Write-V3Box '🔑 Ключ Claude API' @(
    'Ключ не найден в переменной ANTHROPIC_API_KEY.',
    'Получить ключ: https://platform.claude.com → API Keys.',
    'Вставь ключ ниже (он не отобразится) или нажми Enter для офлайн-режима.'
  ) Cyan
  $s = Read-Host '  Ключ' -AsSecureString
  $k = (ConvertFrom-V3Secure $s).Trim()
  if (-not $k) { Write-V3Note '📴 Офлайн-режим. Ключ можно добавить позже: /key'; return }
  $script:ApiKey = $k; $script:Backend = Get-V3Backend
  Write-V3Note '✓ Ключ принят на эту сессию.' Green
  if ((Read-Host '  Сохранить ключ, чтобы не вводить каждый раз? (да/нет)').Trim().ToLower() -in @('да', 'д', 'y', 'yes')) {
    if (Request-V3Permission 'key' 'Переменная: ANTHROPIC_API_KEY (уровень пользователя).') {
      if ($IsLinux -or $IsMacOS) { Write-V3Note 'На Linux/macOS добавь в ~/.bashrc или ~/.zshrc строку: export ANTHROPIC_API_KEY=...' Yellow }
      else { [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $k, 'User'); Write-V3Note '✓ Сохранено. Новые окна PowerShell увидят ключ.' Green }
    }
  }
}

# ── Claude API: потоковый запрос ──────────────────────────────────────────────────────────────
function New-V3ApiError([int]$Status, [string]$Type, [string]$Message, [int]$RetryAfter = 0) {
  $e = [System.Exception]::new($Message)
  $e.Data['v3'] = $true; $e.Data['status'] = $Status; $e.Data['type'] = $Type; $e.Data['retry'] = $RetryAfter
  return $e
}

function New-V3HttpRequest([string]$Json, [string]$Beta) {
  $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://api.anthropic.com/v1/messages')
  [void]$req.Headers.TryAddWithoutValidation('x-api-key', $script:ApiKey)
  [void]$req.Headers.TryAddWithoutValidation('anthropic-version', '2026-10-21')
  if ($Beta) { [void]$req.Headers.TryAddWithoutValidation('anthropic-beta', $Beta) }
  $req.Content = [System.Net.Http.StringContent]::new($Json, [Text.Encoding]::UTF8, 'application/json')
  return $req
}

# Один потоковый запрос. Возвращает @{ Blocks; Stop; Model; Stopped }.
# OnText получает куски текста, OnTool — имя инструмента, когда модель начинает его вызывать.
function Invoke-V3Stream($Body, [string]$Beta, [scriptblock]$OnText, [scriptblock]$OnTool) {
  $json = ConvertTo-V3Json $Body
  $attempt = 0
  while ($true) {
    $attempt++
    $req = New-V3HttpRequest $json $Beta
    try { $resp = $script:Http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult() }
    catch { throw (New-V3ApiError 0 'network' "Нет связи с API: $($_.Exception.Message)") }
    $code = [int]$resp.StatusCode
    if ($resp.IsSuccessStatusCode) { break }
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $type = 'api_error'; $msg = "HTTP $code"
    try { $ej = $text | ConvertFrom-Json; $type = [string]$ej.error.type; $msg = [string]$ej.error.message } catch { }
    $ra = 0; try { $ra = [int]($resp.Headers.GetValues('retry-after') | Select-Object -First 1) } catch { }
    $resp.Dispose()
    if (($code -eq 429 -or $code -eq 529 -or $code -ge 500) -and $attempt -le 2) {
      $wait = $(if ($ra -gt 0) { [Math]::Min(30, $ra) } else { 2 * $attempt })
      Write-Host ("`r  ⏳ сервер занят, повторяю через $wait с…".PadRight(40)) -NoNewline -ForegroundColor DarkGray
      Start-Sleep -Seconds $wait
      continue
    }
    throw (New-V3ApiError $code $type $msg $ra)
  }

  $blocks = @{}; $order = [System.Collections.Generic.List[int]]::new()
  $stop = $null; $model = $null; $stopped = $false
  $canKeys = $false
  try { $canKeys = -not [Console]::IsInputRedirected } catch { }
  $oldCtrlC = $false
  if ($canKeys) { try { $oldCtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { $canKeys = $false } }
  $reader = [IO.StreamReader]::new($resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult(), [Text.Encoding]::UTF8)
  try {
    while ($null -ne ($line = $reader.ReadLine())) {
      if ($canKeys) {
        try {
          while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Escape' -or (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'C')) { $stopped = $true }
          }
        } catch { }
        if ($stopped) { break }
      }
      if (-not $line.StartsWith('data:')) { continue }
      $data = $line.Substring(5).Trim()
      if (-not $data) { continue }
      $ev = $data | ConvertFrom-Json
      switch ([string]$ev.type) {
        'message_start' { $model = [string]$ev.message.model }
        'content_block_start' {
          $b = ConvertTo-V3Hash $ev.content_block
          $blocks[[int]$ev.index] = @{ Block = $b; Json = [Text.StringBuilder]::new(); Bad = $null }
          $order.Add([int]$ev.index)
          if ($b.type -eq 'tool_use' -and $OnTool) { & $OnTool ([string]$b.name) }
          if ($b.type -eq 'text' -and $b.text -and $OnText) { & $OnText ([string]$b.text) }
        }
        'content_block_delta' {
          $st = $blocks[[int]$ev.index]; if (-not $st) { break }
          $d = $ev.delta
          switch ([string]$d.type) {
            'text_delta'       { $st.Block['text'] = [string]$st.Block['text'] + $d.text; if ($OnText) { & $OnText ([string]$d.text) } }
            'thinking_delta'   { $st.Block['thinking'] = [string]$st.Block['thinking'] + $d.thinking }
            'signature_delta'  { $st.Block['signature'] = [string]$st.Block['signature'] + $d.signature }
            'input_json_delta' { [void]$st.Json.Append([string]$d.partial_json) }
          }
        }
        'content_block_stop' {
          $st = $blocks[[int]$ev.index]
          if ($st -and $st.Block.type -eq 'tool_use') {
            $raw = $st.Json.ToString()
            if ($raw.Trim()) {
              try { $st.Block['input'] = ConvertTo-V3Hash ($raw | ConvertFrom-Json); if (-not ($st.Block['input'] -is [System.Collections.IDictionary])) { throw 'not an object' } }
              catch { $st.Bad = $raw; $st.Block['input'] = [ordered]@{} }
            } elseif ($null -eq $st.Block['input']) { $st.Block['input'] = [ordered]@{} }
          }
        }
        'message_delta' { if ($ev.delta.stop_reason) { $stop = [string]$ev.delta.stop_reason } }
        'error' { throw (New-V3ApiError 0 ([string]$ev.error.type) ([string]$ev.error.message)) }
      }
    }
  } finally {
    $reader.Dispose(); $resp.Dispose()
    if ($canKeys) { try { [Console]::TreatControlCAsInput = $oldCtrlC } catch { } }
  }
  $list = New-V3List; $bad = @{}
  foreach ($i in $order) { $st = $blocks[$i]; $list.Add($st.Block); if ($st.Bad) { $bad[[string]$st.Block.id] = $st.Bad } }
  return @{ Blocks = $list; Stop = $stop; Model = $model; Stopped = $stopped; Bad = $bad }
}

# После смены модели посреди ответа: блоки размышлений и вызовы инструментов до последней метки
# fallback не возвращаются в историю, а сама метка остаётся на месте.
function Get-V3Echo($Blocks) {
  $last = -1
  for ($i = 0; $i -lt $Blocks.Count; $i++) { if ($Blocks[$i].type -eq 'fallback') { $last = $i } }
  if ($last -lt 0) { return , $Blocks }
  $out = New-V3List
  for ($i = 0; $i -lt $Blocks.Count; $i++) {
    $t = [string]$Blocks[$i].type
    if ($i -lt $last -and $t -notin @('text', 'fallback')) { continue }
    $out.Add($Blocks[$i])
  }
  return , $out
}

function Get-V3RequestParts($M) {
  $beta = ''
  $extra = [ordered]@{ output_config = [ordered]@{ effort = $M.effort } }
  if ($M.speed) { $extra['speed'] = $M.speed }
  elseif ($M.api -in @('claude-opus-5-5', 'claude-sonnet-5-5')) { $extra['fallbacks'] = 'default'; $beta = 'server-side-fallback-2026-07-01' }
  return @{ Extra = $extra; Beta = $beta }
}

# ── Claude Code: тот же ИИ через программу Claude для терминала — без ключа API ────────────────
# История разговора одним текстом (у Claude Code каждый вызов отдельный).
function ConvertTo-V3Transcript($Messages) {
  $flat = @()
  foreach ($m in $Messages) {
    $c = $m.content; $t = ''
    if ($c -is [string]) { $t = $c }
    else { $t = (@($c) | ForEach-Object { if ($_.type -eq 'text') { $_.text } elseif ($_.type -eq 'image') { '[фото]' } }) -join "`n" }
    if ($t.Trim()) { $flat += @{ role = [string]$m.role; text = $t } }
  }
  if (-not $flat.Count) { return '' }
  if ($flat.Count -eq 1) { return $flat[0].text }
  $hist = ($flat[0..($flat.Count - 2)] | Select-Object -Last 16 | ForEach-Object { $(if ($_.role -eq 'user') { 'Пользователь: ' } else { 'V3AI: ' }) + $_.text }) -join "`n`n"
  return "История разговора (для контекста):`n$hist`n`n---`nНовое сообщение пользователя:`n" + $flat[$flat.Count - 1].text
}

function Invoke-V3ClaudeCode([string]$System, [string]$Prompt, [scriptblock]$OnText) {
  $ErrorActionPreference = 'Continue'   # Claude Code пишет служебное в stderr — это не ошибка
  $M = Get-V3Model $script:Cfg.model
  $alias = $(if ($M.api -like '*haiku*') { 'haiku' } elseif ($M.api -like '*sonnet*') { 'sonnet' } else { 'opus' })
  $input2 = "<instructions>`n$System`n</instructions>`n`n$Prompt"
  for ($try = 1; $try -le 2; $try++) {
    $ccArgs = @('-p', '--output-format', 'stream-json', '--verbose', '--model', $alias,
      '--system-prompt', 'Ты V3AI, дружелюбный ИИ-помощник. Следуй инструкциям в сообщении пользователя и отвечай только текстом.',
      '--disallowedTools', 'Bash,Edit,Write,MultiEdit,NotebookEdit,Read,Glob,Grep,LS,WebFetch,WebSearch,Task,TodoWrite')
    if ($script:CcPartial) { $ccArgs += '--include-partial-messages' }
    $sb = [Text.StringBuilder]::new(); $final = ''; $errText = [Text.StringBuilder]::new(); $isErr = $false
    $input2 | & $script:CcCmd @ccArgs 2>&1 | ForEach-Object {
      $l = [string]$_
      if (-not $l.StartsWith('{')) { [void]$errText.AppendLine($l); return }
      $j = $null; try { $j = $l | ConvertFrom-Json } catch { return }
      switch ([string]$j.type) {
        'stream_event' { $e = $j.event; if ($e.type -eq 'content_block_delta' -and $e.delta.type -eq 'text_delta') { [void]$sb.Append([string]$e.delta.text); if ($OnText) { & $OnText ([string]$e.delta.text) } } }
        'assistant' { if (-not $script:CcPartial) { foreach ($b in @($j.message.content)) { if ($b.type -eq 'text') { [void]$sb.Append([string]$b.text); if ($OnText) { & $OnText ([string]$b.text) } } } } }
        'result' { $final = [string]$j.result; if ($j.is_error) { $isErr = $true } }
      }
    }
    $err = $errText.ToString()
    if ($script:CcPartial -and $err -match 'unknown option' -and $sb.Length -eq 0) { $script:CcPartial = $false; continue }   # старая версия Claude Code
    if ($isErr -or ($sb.Length -eq 0 -and -not $final)) {
      $msg = $(if ($final) { $final } elseif ($err.Trim()) { $err.Trim() } else { 'нет ответа' })
      if ($msg -match 'login|log in|auth|API key|credential') { $msg = 'Claude Code не вошёл в аккаунт. Запусти в терминале команду claude и войди, потом попробуй снова.' }
      throw (New-V3ApiError 0 'claude-code' $msg)
    }
    if ($sb.Length -eq 0 -and $final) { if ($OnText) { & $OnText $final }; return $final }
    return $sb.ToString()
  }
}

# Разговор с инструментами: стримит текст, сам выполняет вызовы инструментов, повторяет до конца.
# $Messages — List, в него дописываются ответы (только добавление, без правок прошлого).
function Invoke-V3Turn {
  param($Messages, [string]$System, $Tools, [scriptblock]$Handler, [switch]$Quiet, [int]$MaxTokens = 64000, [string]$Waiting = 'думает…')
  if ($script:Backend -eq 'claude-code') {
    $script:QuietCount = 0
    if ($Quiet) { Write-Host "  ◌ $Waiting" -NoNewline -ForegroundColor DarkGray } else { Start-V3Render $Waiting }
    $cb = if ($Quiet) { { param($t) $script:QuietCount += $t.Length; Write-Host ("`r  ◌ $Waiting " + [Math]::Round($script:QuietCount / 1000, 1) + ' тыс. символов   ') -NoNewline -ForegroundColor DarkGray } } else { { param($t) Add-V3Render $t } }
    try { $text = Invoke-V3ClaudeCode $System (ConvertTo-V3Transcript $Messages) $cb }
    finally { if ($Quiet) { Write-Host '' } else { Stop-V3Render } }
    if ($text) { $Messages.Add([ordered]@{ role = 'assistant'; content = $text }) }
    return @{ Text = [string]$text; Used = [System.Collections.Generic.List[string]]::new() }
  }
  $M = Get-V3Model $script:Cfg.model
  $parts = Get-V3RequestParts $M
  $final = [Text.StringBuilder]::new(); $used = [System.Collections.Generic.List[string]]::new()
  $script:QuietCount = 0
  for ($round = 1; $round -le 14; $round++) {
    $body = [ordered]@{ model = $M.api; max_tokens = $MaxTokens; stream = $true; system = $System; messages = $Messages; cache_control = [ordered]@{ type = 'ephemeral' } }
    foreach ($k in $parts.Extra.Keys) { $body[$k] = $parts.Extra[$k] }
    if ($Tools -and $Tools.Count) { $body['tools'] = $Tools }
    if ($Quiet) { Write-Host "  ◌ $Waiting" -NoNewline -ForegroundColor DarkGray } else { Start-V3Render $Waiting }
    $onText = if ($Quiet) { { param($t) $script:QuietCount += $t.Length; Write-Host ("`r  ◌ $Waiting " + [Math]::Round($script:QuietCount / 1000, 1) + ' тыс. символов   ') -NoNewline -ForegroundColor DarkGray } } else { { param($t) Add-V3Render $t } }
    $onTool = { param($n) if (-not $Quiet) { Stop-V3Render; if ($script:T.box -eq 'panel') { Write-V3X '  ◆ ' orange -NoNewline; Write-V3X $n dim } else { Write-Host "  🧰 $n…" -ForegroundColor DarkCyan }; Start-V3Render 'работает…' } }
    try { $res = Invoke-V3Stream $body $parts.Beta $onText $onTool }
    catch {
      if ($Quiet) { Write-Host '' } else { Stop-V3Render }
      $ex = $_.Exception
      if ($ex.Data['v3'] -and $ex.Data['status'] -eq 429 -and $M.speed -and $body.Contains('speed')) {
        Write-V3Note '⚡ Быстрый режим сейчас занят — продолжаю в обычном.'; $parts.Extra.Remove('speed'); $round--; continue
      }
      throw
    }
    if ($Quiet) { Write-Host '' } else { Stop-V3Render }
    if ($res.Model -and $res.Model -ne $M.api) { Write-V3Note "↪ ответ продолжила запасная модель ($($res.Model))" }
    $echo = Get-V3Echo $res.Blocks
    if ($res.Stopped -or $res.Stop -eq 'refusal') {
      $only = New-V3List; foreach ($b in $echo) { if ($b.type -eq 'text' -and ([string]$b.text).Trim()) { $only.Add($b) } }; $echo = $only
    }
    foreach ($b in $echo) { if ($b.type -eq 'text') { [void]$final.Append([string]$b.text) } }
    if ($echo.Count) { $Messages.Add([ordered]@{ role = 'assistant'; content = $echo }) }
    if ($res.Stopped) { Write-V3Note '■ остановлено'; break }
    if ($res.Stop -eq 'refusal') { Write-V3Note '🚫 Модель не стала отвечать на это. Давай о чём-нибудь другом?' Yellow; break }
    $calls = @($echo | Where-Object { $_.type -eq 'tool_use' })
    if ($res.Stop -eq 'max_tokens') { if ($calls.Count) { Write-V3Note 'Ответ оборвался посреди вызова инструмента — попробуй модель посильнее или вопрос попроще.' Yellow } else { Write-V3Note '(ответ обрезан — напиши «продолжи»)' } ; break }
    if ($res.Stop -ne 'tool_use' -or -not $calls.Count -or -not $Handler) { break }
    $results = New-V3List
    foreach ($c in $calls) {
      $id = [string]$c.id
      if ($res.Bad.ContainsKey($id)) { $results.Add([ordered]@{ type = 'tool_result'; tool_use_id = $id; is_error = $true; content = (ConvertTo-V3Json @{ INVALID_JSON = $res.Bad[$id] }) }); continue }
      try {
        $out = & $Handler ([string]$c.name) $c.input
        if (-not $used.Contains([string]$c.name)) { $used.Add([string]$c.name) }
        $txt = if ($out -is [string]) { $out } else { ConvertTo-V3Json $out }
        $results.Add([ordered]@{ type = 'tool_result'; tool_use_id = $id; content = $txt })
      } catch {
        $results.Add([ordered]@{ type = 'tool_result'; tool_use_id = $id; is_error = $true; content = [string]$_.Exception.Message })
      }
    }
    $Messages.Add([ordered]@{ role = 'user'; content = $results })
  }
  return @{ Text = $final.ToString(); Used = $used }
}

function Get-V3ErrorText($Ex) {
  if (-not $Ex.Data['v3']) { return "Что-то пошло не так: $($Ex.Message)" }
  switch ([int]$Ex.Data['status']) {
    0   { if ($Ex.Data['type'] -eq 'claude-code') { return "Claude Code: $($Ex.Message)" }; if ($Ex.Data['type'] -eq 'network') { return 'Нет связи с Claude. Проверь интернет.' } else { return "Сервер прервал ответ ($($Ex.Data['type'])). Попробуй ещё раз." } }
    401 { return 'Ключ API не подходит. Введи новый: /key' }
    403 { return 'У ключа нет доступа к этой модели. Выбери другую: /model' }
    429 { return 'Слишком много запросов подряд — подожди немного.' }
    400 { return "Запрос не принят: $($Ex.Message)" }
    529 { return 'Claude сейчас перегружен — попробуй через минуту.' }
    default { return "Ошибка API ($($Ex.Data['status'])): $($Ex.Message)" }
  }
}

# ── Офлайн-режим ──────────────────────────────────────────────────────────────────────────────
function Get-V3Offline([string]$Text) {
  $q = $Text.ToLower().Replace('ё', 'е')
  $expr = ($q -replace ',', '.' -replace '[x×]', '*' -replace '[÷:]', '/' -replace 'сколько будет|посчитай|реши|=|\?', '').Trim()
  if ($expr -match '^[\d\s.+\-*/()%^]+$' -and $expr -match '\d' -and $expr -match '[+\-*/%^]') {
    try { $v = Invoke-V3Calc $expr; return "**$expr = $v**" } catch { }
  }
  $pick = { param([string[]]$a) $a[(Get-Random -Maximum $a.Count)] }
  if ($q -match 'привет|здравств|хай|салам|хелло') { return (& $pick @('Привет! Я V3AI. Чем помочь?', 'Хай! Рад тебя видеть ✨', 'Привет-привет! Спрашивай.')) }
  if ($q -match 'кто ты|как тебя зовут') { return 'Я **V3AI** — ИИ-помощник от команды V3, версия для PowerShell.' }
  if ($q -match 'время|который час') { return 'Сейчас **' + (Get-Date -Format 'HH:mm') + '**.' }
  if ($q -match 'дата|число|какой (сегодня )?день') { return 'Сегодня **' + (Get-Date).ToString('dddd, d MMMM yyyy', [Globalization.CultureInfo]::GetCultureInfo('ru-RU')) + '**.' }
  if ($q -match 'шутк|анекдот|смешн') { return (& $pick @('Почему программисты путают Хэллоуин и Рождество? Потому что 31 OCT = 25 DEC 🎃🎄', 'Учитель: «Почему опоздал?» Ученик: «Знак „Школа, сбавь скорость“ увидел!» 🚸', 'PowerShell зашёл в бар и сказал: Get-Drink | Where-Object { $_.Cold } 🍹')) }
  if ($q -match 'загадк') { return (& $pick @('Зимой и летом одним цветом. Что это? (Ответ: ёлка 🎄)', 'Не лает, не кусает, а в дом не пускает. (Ответ: замок 🔒)')) }
  if ($q -match 'спасиб') { return 'Всегда пожалуйста! 💙' }
  return 'Сейчас я в офлайн-режиме 📴: умею считать примеры («12*7+3»), подсказать время и дату, пошутить и загадать загадку. Установи **Claude Code** (claude.ai/code) и войди в аккаунт — и я отвечу на что угодно, без ключа.'
}

function Invoke-V3Calc([string]$Expr) {
  $e = ($Expr -replace ',', '.' -replace '[x×]', '*' -replace '[÷:]', '/').Trim()
  if ($e -notmatch '^[\d\s.+\-*/()%^]+$') { throw 'можно только числа и + - * / ^ % ( )' }
  if ($e.Contains('^')) { throw 'степень (^) не поддерживается — распиши через умножение' }
  $dt = [Data.DataTable]::new()
  $v = [double]$dt.Compute($e, $null)
  if ([double]::IsInfinity($v) -or [double]::IsNaN($v)) { throw 'не число' }
  return [Math]::Round($v, 10)
}

# ── Системная инструкция ──────────────────────────────────────────────────────────────────────
function Get-V3Rules($ModeObj) {
  $M = Get-V3Model $script:Cfg.model
  $d = (Get-Date).ToString('dddd, d MMMM yyyy', [Globalization.CultureInfo]::GetCultureInfo('ru-RU'))
  return @(
    'Тебя зовут V3AI (читается «Ви-три-ай») — дружелюбный ИИ-ассистент от команды V3, версия для PowerShell (ответы показываются в терминале). Ты бодрый, технологичный, говоришь уверенно и с лёгким юмором, эмодзи — в меру.',
    "Сейчас ты работаешь на модели $($M.n) (линейка V3AI: LAI 1.3, FUHI 2.8, ARDSONNET 3.1, FLASH 3.9, ARDSONNET 4.5, V3 ORTL 5.5). Если спросят, на какой ты модели, — назови её.",
    $ModeObj.p,
    "Отвечай на языке пользователя (по умолчанию по-русски). Пиши до $($M.len) слов, если не попросили подробнее. Можно **жирный**, `код`, списки и блоки ``` — без таблиц и без HTML.",
    'Приложение могут открывать дети: никаких взрослых, опасных, жестоких или грубых тем — мягко откажи и предложи другое. Не проси и не храни личные данные.',
    'Не выдумывай факты: если не уверен — так и скажи.',
    "Сегодня $d."
  ) -join "`n"
}

# ── Чаты ──────────────────────────────────────────────────────────────────────────────────────
function New-V3Chat([string]$ModeId, [string]$AgentId = '') {
  return [ordered]@{ id = ('c' + (Get-Date -Format 'yyyyMMddHHmmss') + (Get-Random -Maximum 999)); title = ''; mode = $ModeId; agent = $AgentId; repo = $null; lastGame = ''; messages = (New-V3List); at = (Get-Date).ToString('o') }
}

function Save-V3Chat($Chat) {
  if (-not $Chat.messages.Count) { return }
  $Chat.at = (Get-Date).ToString('o')
  Save-V3Json (Join-Path $script:Paths.Chats ($Chat.id + '.json')) $Chat
}

function Get-V3Chats {
  if (-not (Test-Path -LiteralPath $script:Paths.Chats)) { return @() }
  $files = Get-ChildItem -LiteralPath $script:Paths.Chats -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 20
  return @($files)
}

function Open-V3Chat([string]$Path) {
  $c = Read-V3Json $Path
  if (-not $c) { return $null }
  if (-not ($c.messages -is [System.Collections.Generic.List[object]])) { $l = New-V3List; foreach ($m in @($c.messages)) { if ($null -ne $m) { $l.Add($m) } }; $c.messages = $l }
  foreach ($k in @('agent', 'lastGame', 'title')) { if (-not $c.Contains($k) -or $null -eq $c[$k]) { $c[$k] = '' } }
  if (-not $c.Contains('repo')) { $c['repo'] = $null }
  return $c
}

# Убрать последний вопрос без ответа (ошибка сети и т. п.), чтобы роли в истории чередовались.
function Undo-V3LastUser($Chat) {
  $n = $Chat.messages.Count
  if (-not $n -or $Chat.messages[$n - 1].role -ne 'user') { return }
  $c = $Chat.messages[$n - 1].content
  if ($c -is [string] -or -not (@($c) | Where-Object { $_.type -eq 'tool_result' })) { $Chat.messages.RemoveAt($n - 1) }
}

# ── GitHub ────────────────────────────────────────────────────────────────────────────────────
function ConvertFrom-V3RepoUrl([string]$Text) {
  $m = [regex]::Match($Text, '(?:https?://)?(?:www\.)?github\.com/([A-Za-z0-9-]{1,39})/([A-Za-z0-9._-]{1,100})(?:/(tree|blob)/([^\s/?#]+))?[^\s]*', 'IgnoreCase')
  if (-not $m.Success) { return $null }
  $owner = $m.Groups[1].Value
  if ($owner.ToLower() -in @('orgs', 'settings', 'marketplace', 'features', 'topics', 'collections', 'sponsors', 'login', 'about', 'pricing', 'explore', 'notifications', 'search', 'apps', 'enterprise')) { return $null }
  $repo = $m.Groups[2].Value -replace '\.git$', ''
  if (-not $repo -or $repo -in @('.', '..')) { return $null }
  return [ordered]@{ url = $m.Value; owner = $owner; repo = $repo; ref = $(if ($m.Groups[4].Success) { [Uri]::UnescapeDataString($m.Groups[4].Value) } else { '' }) }
}

function Invoke-V3GitHub([string]$Path) {
  $h = @{ 'User-Agent' = 'V3AI-PowerShell'; 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
  if ($script:GhToken) { $h['Authorization'] = "Bearer $($script:GhToken)" }
  try { return Invoke-RestMethod -Uri ('https://api.github.com' + $Path) -Headers $h -TimeoutSec 30 -UseBasicParsing }
  catch {
    $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    switch ($code) {
      404 { throw 'Не найдено: репозиторий закрытый или ссылка с опечаткой. Для закрытых войди: /github login' }
      401 { throw 'Токен GitHub не подходит. Войди заново: /github login' }
      403 { throw 'GitHub ограничил запросы (лимит без входа — 60 в час). Войди: /github login — лимит станет 5000.' }
      0   { throw 'Нет связи с GitHub. Проверь интернет.' }
      default { throw "GitHub ответил ошибкой $code." }
    }
  }
}

function Get-V3RepoQuery($Repo) { if ($Repo.ref) { return '?ref=' + [Uri]::EscapeDataString($Repo.ref) } else { return '' } }

function Get-V3RepoPath([string]$P) { return (($P.Trim('/') -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/' }

function Get-V3RepoDir($Repo, [string]$Path) {
  $r = @(Invoke-V3GitHub ("/repos/$($Repo.owner)/$($Repo.repo)/contents/" + (Get-V3RepoPath $Path) + (Get-V3RepoQuery $Repo)))
  return @($r | ForEach-Object { [ordered]@{ name = [string]$_.name; type = [string]$_.type; path = [string]$_.path; size = [int]$_.size } } | Sort-Object @{ e = { $_.type -ne 'dir' } }, @{ e = { $_.name } })
}

function Get-V3RepoFile($Repo, [string]$Path) {
  $f = Invoke-V3GitHub ("/repos/$($Repo.owner)/$($Repo.repo)/contents/" + (Get-V3RepoPath $Path) + (Get-V3RepoQuery $Repo))
  if ($f -is [array]) { throw "«$Path» — это папка, а не файл." }
  if ($f.content) {
    $bytes = [Convert]::FromBase64String(([string]$f.content) -replace '\s', '')
    if ($bytes -contains 0) { return $null }
    return [Text.Encoding]::UTF8.GetString($bytes)
  }
  if ($f.download_url) {
    $h = @{ 'User-Agent' = 'V3AI-PowerShell' }; if ($script:GhToken) { $h['Authorization'] = "Bearer $($script:GhToken)" }
    $w = Invoke-WebRequest -Uri $f.download_url -Headers $h -TimeoutSec 60 -UseBasicParsing
    $raw = $w.RawContentStream.ToArray()
    if ($raw -contains 0) { return $null }
    return [Text.Encoding]::UTF8.GetString($raw)
  }
  return ''
}

function Format-V3Size([long]$n) { if ($n -gt 1048576) { return ('{0:N1} МБ' -f ($n / 1048576)) } elseif ($n -gt 1024) { return ('{0:N0} КБ' -f ($n / 1024)) } else { return "$n Б" } }

function Connect-V3Repo($Chat, $R) {
  if (-not (Request-V3Permission 'github' "Репозиторий: $($R.owner)/$($R.repo)")) { return $false }
  Write-Host "  ◌ подключаю $($R.owner)/$($R.repo)…" -ForegroundColor DarkGray
  try {
    $info = Invoke-V3GitHub "/repos/$($R.owner)/$($R.repo)"
    $repo = [ordered]@{ owner = [string]$info.owner.login; repo = [string]$info.name; ref = $(if ($R.ref) { $R.ref } else { [string]$info.default_branch }) }
    $files = @(Get-V3RepoDir $repo '')
    $readme = ''
    $rd = $files | Where-Object { $_.type -eq 'file' -and $_.name -match '^readme(\.(md|markdown|txt|rst))?$' } | Select-Object -First 1
    if ($rd) { try { $readme = [string](Get-V3RepoFile $repo $rd.path) } catch { } }
    $commits = @(); try { $commits = @(Invoke-V3GitHub ("/repos/$($repo.owner)/$($repo.repo)/commits?per_page=5&sha=" + [Uri]::EscapeDataString($repo.ref))) } catch { }
  } catch { Write-V3Note "🐙 $($_.Exception.Message)" Yellow; return $false }
  $Chat.repo = $repo
  if (-not $Chat.title) { $Chat.title = "🐙 $($repo.owner)/$($repo.repo)" }
  $lines = @()
  if ($info.description) { $lines += [string]$info.description }
  $lines += ("★ $($info.stargazers_count)  ⑂ $($info.forks_count)  язык: $(if ($info.language) { $info.language } else { '—' })  ветка: $($repo.ref)  " + $(if ($info.private) { '🔒 закрытый' } else { '🌐 публичный' }))
  $names = @($files | Select-Object -First 24 | ForEach-Object { if ($_.type -eq 'dir') { "📁 $($_.name)/" } else { "📄 $($_.name) ($(Format-V3Size $_.size))" } })
  for ($i = 0; $i -lt $names.Count; $i += 3) { $lines += (($names[$i..([Math]::Min($i + 2, $names.Count - 1))] | ForEach-Object { $_.PadRight(26) }) -join '') }
  if ($files.Count -gt 24) { $lines += "… и ещё $($files.Count - 24)" }
  if ($readme) {
    $lines += '📖 README:'
    $lines += @(($readme -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 6) | ForEach-Object { '   ' + $(if ($_.Length -gt 90) { $_.Substring(0, 90) + '…' } else { $_ }) })
  }
  if ($commits.Count) {
    $lines += '🕒 Последние коммиты:'
    foreach ($c in $commits) { $msg = ([string]$c.commit.message -split "`n")[0]; if ($msg.Length -gt 70) { $msg = $msg.Substring(0, 70) + '…' }; $lines += ('   • ' + $msg + '  ' + ([datetime]$c.commit.author.date).ToString('dd.MM.yyyy')) }
  }
  Write-V3Box "🐙 $($repo.owner)/$($repo.repo) — подключён к чату (только чтение)" $lines Green
  Write-V3Note 'Спрашивай что угодно о проекте. /repo — карточка, /disconnect — отключить.'
  $Chat.messages.Add([ordered]@{ role = 'user'; content = "Подключаю GitHub-репозиторий $($repo.owner)/$($repo.repo)." })
  $Chat.messages.Add([ordered]@{ role = 'assistant'; content = "Репозиторий $($repo.owner)/$($repo.repo) подключён (ветка $($repo.ref)). Корень: " + (($files | ForEach-Object { if ($_.type -eq 'dir') { $_.name + '/' } else { $_.name } }) -join ', ') })
  Save-V3Chat $Chat
  return $true
}

function Get-V3RepoTools {
  $e = $true
  return @(
    [ordered]@{ name = 'list_dir'; description = 'Список файлов и папок в подключённом репозитории. path — путь к папке, пустой — корень.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ path = @{ type = 'string' } } } },
    [ordered]@{ name = 'read_file'; description = 'Прочитать текстовый файл репозитория. Длинный — частями: offset (с какого символа, по 30000).'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ path = @{ type = 'string' }; offset = @{ type = 'integer' } }; required = @('path') } },
    [ordered]@{ name = 'list_commits'; description = 'Последние коммиты (можно по одному файлу через path).'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ path = @{ type = 'string' }; count = @{ type = 'integer' } } } },
    [ordered]@{ name = 'list_branches'; description = 'Ветки репозитория.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{} } },
    [ordered]@{ name = 'list_issues'; description = 'Issues репозитория. state: open, closed или all.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ state = @{ type = 'string'; enum = @('open', 'closed', 'all') } } } },
    [ordered]@{ name = 'list_pull_requests'; description = 'Pull requests. state: open, closed или all.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ state = @{ type = 'string'; enum = @('open', 'closed', 'all') } } } }
  )
}

function Invoke-V3RepoTool($Repo, [string]$Name, $In) {
  $base = "/repos/$($Repo.owner)/$($Repo.repo)"
  switch ($Name) {
    'list_dir' { return @{ entries = @(Get-V3RepoDir $Repo ([string](Get-V3Prop $In 'path' ''))) } }
    'read_file' {
      $p = [string](Get-V3Prop $In 'path' ''); if (-not $p) { throw 'нужен path' }
      $t = Get-V3RepoFile $Repo $p
      if ($null -eq $t) { return @{ path = $p; binary = $true } }
      $o = [Math]::Max(0, [int](Get-V3Prop $In 'offset' 0)); if ($o -gt $t.Length) { $o = $t.Length }
      $len = [Math]::Min(30000, $t.Length - $o)
      return @{ path = $p; total_chars = $t.Length; offset = $o; text = $t.Substring($o, $len); more = ($o + $len -lt $t.Length) }
    }
    'list_commits' {
      $n = [Math]::Min(30, [Math]::Max(1, [int](Get-V3Prop $In 'count' 10)))
      $q = "?per_page=$n&sha=" + [Uri]::EscapeDataString($Repo.ref); $p = [string](Get-V3Prop $In 'path' ''); if ($p) { $q += '&path=' + [Uri]::EscapeDataString($p) }
      return @{ commits = @(@(Invoke-V3GitHub "$base/commits$q") | ForEach-Object { @{ sha = ([string]$_.sha).Substring(0, 7); message = ([string]$_.commit.message -split "`n")[0]; date = [string]$_.commit.author.date; author = [string]$_.commit.author.name } }) }
    }
    'list_branches' { return @{ branches = @(@(Invoke-V3GitHub "$base/branches?per_page=50") | ForEach-Object { [string]$_.name }) } }
    'list_issues' {
      $s = [string](Get-V3Prop $In 'state' 'open')
      return @{ issues = @(@(Invoke-V3GitHub "$base/issues?per_page=20&state=$s") | Where-Object { -not $_.pull_request } | ForEach-Object { @{ number = $_.number; title = [string]$_.title; state = [string]$_.state } }) }
    }
    'list_pull_requests' {
      $s = [string](Get-V3Prop $In 'state' 'open')
      return @{ pulls = @(@(Invoke-V3GitHub "$base/pulls?per_page=20&state=$s") | ForEach-Object { @{ number = $_.number; title = [string]$_.title; state = [string]$_.state; merged = [bool]$_.merged_at } }) }
    }
  }
  throw "Неизвестный инструмент $Name"
}

function Get-V3RepoRules($Chat) {
  $r = $Chat.repo
  return "`nК чату подключён GitHub-репозиторий $($r.owner)/$($r.repo) (ветка $($r.ref)) — только чтение. Прежде чем отвечать о проекте, смотри его сам инструментами: list_dir, read_file (большие файлы — частями через offset), list_commits, list_branches, list_issues, list_pull_requests. Называй пути файлов, цитируй короткие куски кода, не выдумывай то, чего не читал. Изменять репозиторий ты не можешь — если просят, предложи готовый код."
}

function Invoke-V3GitHubLogin {
  if (-not (Request-V3Permission 'github' 'Вход: токен GitHub (из gh CLI или вставленный вручную).')) { return }
  $tok = ''
  if (Get-Command gh -ErrorAction SilentlyContinue) {
    try { $tok = (& gh auth token 2>$null | Select-Object -First 1); if ($tok) { $tok = $tok.Trim() } } catch { }
    if ($tok) { Write-V3Note '✓ Взял токен из GitHub CLI (gh).' Green }
  }
  if (-not $tok) {
    Write-V3Box '🐙 Вход в GitHub' @('Создай токен: https://github.com/settings/tokens → Fine-grained token,', 'доступ: Contents — Read-only (и Issues/Pull requests — Read-only, по желанию).', 'Вставь токен ниже (он не отобразится) или Enter — отмена.') Cyan
    $tok = (ConvertFrom-V3Secure (Read-Host '  Токен' -AsSecureString)).Trim()
  }
  if (-not $tok) { Write-V3Note 'Отменено.'; return }
  $script:GhToken = $tok
  try { $me = Invoke-V3GitHub '/user'; Write-V3Note "✓ Вошёл в GitHub как $($me.login). Теперь открываются и закрытые репозитории." Green }
  catch { $script:GhToken = $null; Write-V3Note "🐙 $($_.Exception.Message)" Yellow; return }
  if ((Read-Host '  Запомнить токен для следующих запусков? (да/нет)').Trim().ToLower() -in @('да', 'д', 'y', 'yes')) {
    if (Request-V3Permission 'key' 'Переменная: GITHUB_TOKEN (уровень пользователя).') {
      if ($IsLinux -or $IsMacOS) { Write-V3Note 'На Linux/macOS добавь в ~/.bashrc или ~/.zshrc: export GITHUB_TOKEN=...' Yellow }
      else { [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $tok, 'User'); Write-V3Note '✓ Сохранено.' Green }
    }
  }
}

# ── Файлы: картинки и игры ────────────────────────────────────────────────────────────────────
function Get-V3SafeName([string]$Text) {
  $n = ($Text -replace '[^\p{L}\p{N}]+', '-').Trim('-')
  if ($n.Length -gt 40) { $n = $n.Substring(0, 40).Trim('-') }
  if (-not $n) { $n = 'v3ai' }
  return $n + '-' + (Get-Date -Format 'HHmmss')
}

function Save-V3File([string]$Dir, [string]$Name, [string]$Content) {
  if (-not (Request-V3Permission 'save' "Файл: $(Join-Path $Dir $Name)")) { return $null }
  if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
  $path = Join-Path $Dir $Name
  [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
  return $path
}

function Open-V3File([string]$Path) {
  if (-not (Request-V3Permission 'open' "Файл: $Path")) { return }
  try {
    if ($IsMacOS) { & open $Path } elseif ($IsLinux) { & xdg-open $Path 2>$null | Out-Null } else { Invoke-Item -LiteralPath $Path }
  } catch { Write-V3Note "Не получилось открыть автоматически. Открой вручную: $Path" Yellow }
}

function Get-V3Block([string]$Text, [string]$Lang) {
  $m = [regex]::Match($Text, '```' + $Lang + '\s*([\s\S]*?)(```|$)', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ''
}

# SVG открывается в браузере — убираем всё, что может выполнять код или ходить в сеть.
function Clear-V3Svg([string]$Svg) {
  $m = [regex]::Match($Svg, '<svg[\s\S]*</svg>', 'IgnoreCase'); if (-not $m.Success) { return '' }
  $s = $m.Value
  $s = [regex]::Replace($s, '<(script|foreignObject|iframe|image|audio|video)[\s\S]*?(</\1>|/>)', '', 'IgnoreCase')
  $s = [regex]::Replace($s, '\son\w+\s*=\s*("[^"]*"|''[^'']*'')', '', 'IgnoreCase')
  $s = [regex]::Replace($s, '(xlink:)?href\s*=\s*("(?!#)[^"]*"|''(?!#)[^'']*'')', '', 'IgnoreCase')
  $s = [regex]::Replace($s, 'url\(\s*[''"]?(?!#)[^)]*\)', 'none', 'IgnoreCase')
  $s = [regex]::Replace($s, '@import[^;]*;', '', 'IgnoreCase')
  return $s
}

function Invoke-V3Art($Chat, [string]$Q) {
  $prev = Get-V3Prop $Chat 'lastArt' ''
  $prompt = @(
    'Ты — V3AI, ИИ-художник. Нарисуй картинку по описанию пользователя как ОДНО SVG-изображение.',
    'Формат: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">. Яркая, детальная композиция на весь холст: фон, средний и передний план, главный объект крупно, свет, тени, градиенты, плавные кривые path.',
    'Запрещено: script, foreignObject, image, ссылки, внешние шрифты, анимация, обработчики событий. Текст на картинке — только если его явно попросили.',
    'Юмор приветствуется, в том числе мультяшный туалетный: какашка-смайлик 💩, пуки, лужи — смешно и без натурализма. Нельзя: кровь, жестокость, взрослые темы и насмешки или унижение конкретных людей по имени (это может обидеть настоящего человека). Если в просьбе есть такое — сделай смешную безопасную версию (например, вместо человека забавный персонаж) и ОБЯЗАТЕЛЬНО коротко и честно скажи в ответной фразе, что изменил и почему. Никогда не меняй просьбу молча.',
    $(if ($prev) { "Предыдущая картинка в этом чате была по запросу «$prev». Если новый запрос — правка, нарисуй ту же сцену с изменением." } else { '' }),
    'Ответ: сначала SVG в блоке ```svg, затем одна короткая весёлая фраза по-русски о том, что нарисовано. Если что-то в просьбе пришлось изменить — прямо скажи об этом в этой фразе.',
    "Описание картинки: $Q"
  ) -join "`n"
  $msgs = New-V3List; $msgs.Add([ordered]@{ role = 'user'; content = $prompt })
  $r = Invoke-V3Turn -Messages $msgs -System 'Ты — V3AI, ИИ-художник в терминальной версии V3AI.' -Quiet -Waiting '🎨 рисую…'
  $svg = Clear-V3Svg $r.Text
  if (-not $svg) { Write-V3Note 'Не получилось нарисовать — попробуй ещё раз или опиши иначе.' Yellow; return }
  $cap = ([regex]::Replace($r.Text, '```[\s\S]*?(```|$)', '')).Trim()
  $path = Save-V3File $script:Paths.Art ((Get-V3SafeName $Q) + '.svg') $svg
  if ($cap) { Write-V3Line $cap }
  if ($path) { Write-V3Note "🎨 Сохранено: $path" Green; Open-V3File $path }
  $Chat['lastArt'] = $Q
  $Chat.messages.Add([ordered]@{ role = 'user'; content = $Q })
  $Chat.messages.Add([ordered]@{ role = 'assistant'; content = "(Нарисовал картинку по запросу «$Q».) $cap" })
}

# Показывает ошибку прямо в игре и подсказывает, как попросить WattAI её исправить.
$script:GameGuard = '<script data-v3ai-guard>(function(){var n=0;function s(m){if(n++)return;var d=document.createElement("div");d.style.cssText="position:fixed;left:8px;right:8px;bottom:8px;z-index:2147483647;padding:10px 12px;border-radius:10px;background:#3a0d14;color:#fff;font:14px system-ui,sans-serif";d.textContent="⚠ Ошибка в игре: "+m+" — напиши в V3AI: /watt исправь ошибку: "+m;(document.body||document.documentElement).appendChild(d)}window.addEventListener("error",function(e){s((e.message||"ошибка")+(e.lineno?" (строка "+e.lineno+")":""))});window.addEventListener("unhandledrejection",function(e){s(String(e.reason&&e.reason.message||e.reason))})})();</script>'
function Remove-V3GameGuard([string]$Html) { return [regex]::Replace($Html, '<script data-v3ai-guard>[\s\S]*?</script>', '') }

function Invoke-V3Game($Chat, [string]$Q, [switch]$Fresh) {
  $prevCode = ''
  if (-not $Fresh -and $Chat.lastGame -and (Test-Path -LiteralPath $Chat.lastGame)) { $prevCode = Remove-V3GameGuard (Get-Content -LiteralPath $Chat.lastGame -Raw -Encoding UTF8) }
  $prompt = @(
    'Ты — WattAI, создатель игр внутри V3AI. Напиши по запросу пользователя готовую браузерную игру — ОДИН полный HTML-документ.',
    'Требования:',
    '- Всё в одном файле: HTML, CSS и JavaScript внутри. Никаких внешних файлов, библиотек, шрифтов, картинок по ссылкам и сетевых запросов. Графика — canvas 2D (фигуры, градиенты, эмодзи) или DOM/CSS; звук — только Web Audio API, после первого нажатия.',
    '- Игра занимает всё окно и подстраивается под размер. Стартовый экран с названием, правилом и «Нажми, чтобы начать»; потом игра; в конце «Игра окончена» со счётом, рекордом (localStorage) и перезапуском.',
    '- Управление и мышью/касанием, и с клавиатуры. Без alert/prompt/confirm, без открытия окон и ссылок.',
    '- Живая и красивая игра: анимации, частицы, нарастающая сложность, понятная цель. Тексты в игре по-русски.',
    '- Аккуратный рабочий код: requestAnimationFrame с dt, без ошибок в консоли. Размер — до ~25 000 символов.',
    '- Юмор приветствуется, в том числе мультяшный туалетный: какашка-смайлик 💩, пуки, лужи — смешно и без натурализма. Нельзя: кровь, жестокость, взрослые темы и насмешки или унижение конкретных людей по имени (это может обидеть настоящего человека). Если в просьбе есть такое — сделай смешную безопасную версию (например, вместо человека забавный персонаж) и ОБЯЗАТЕЛЬНО коротко и честно скажи в ответной фразе, что изменил и почему. Никогда не меняй просьбу молча.',
    $(if ($prevCode) { "`nВ этом чате уже есть игра. Её код ниже. Если запрос — правка этой игры, верни ВЕСЬ исправленный документ; если просят другую игру — сделай новую.`n``````html`n$prevCode`n``````" } else { '' }),
    "`nОтвет: строка «Название: …», затем весь код в блоке ``````html, затем одна-две короткие фразы по-русски: как играть. Если что-то в просьбе пришлось изменить — прямо скажи об этом в этой фразе.",
    "Запрос: $Q"
  ) -join "`n"
  $msgs = New-V3List; $msgs.Add([ordered]@{ role = 'user'; content = $prompt })
  $r = Invoke-V3Turn -Messages $msgs -System 'Ты — WattAI, создатель браузерных игр в V3AI.' -Quiet -Waiting '🕹 WattAI пишет игру…'
  $html = Get-V3Block $r.Text 'html'
  if (-not $html) { $mm = [regex]::Match($r.Text, '<!doctype html[\s\S]*</html>', 'IgnoreCase'); if ($mm.Success) { $html = $mm.Value } }
  if (-not $html -or $html -notmatch '<script') { Write-V3Note 'Игра не получилась — попробуй ещё раз или модель посильнее (/model).' Yellow; return }
  $title = ''; $tm = [regex]::Match($r.Text, 'Название:\s*([^\r\n]+)'); if ($tm.Success) { $title = $tm.Groups[1].Value.Trim(' *«»"') }
  $how = ([regex]::Replace(([regex]::Replace($r.Text, '```[\s\S]*?(```|$)', '')), 'Название:[^\r\n]*', '')).Trim()
  $html = Remove-V3GameGuard $html
  $hm = [regex]::Match($html, '<head[^>]*>', 'IgnoreCase')
  $html = $(if ($hm.Success) { $html.Insert($hm.Index + $hm.Length, $script:GameGuard) } else { $script:GameGuard + $html })
  $path = Save-V3File $script:Paths.Games ((Get-V3SafeName $(if ($title) { $title } else { $Q })) + '.html') $html
  Write-V3Box ('🕹 ' + $(if ($title) { $title } else { 'Игра готова' })) @($(if ($how) { $how } else { 'Играй!' }), $(if ($path) { "Файл: $path" } else { 'Файл не сохранён (EngineSecure).' })) Magenta
  if ($path) { $Chat.lastGame = $path; Open-V3File $path }
  $Chat.messages.Add([ordered]@{ role = 'user'; content = $Q })
  $Chat.messages.Add([ordered]@{ role = 'assistant'; content = "(WattAI сделал игру «$title» по запросу «$Q».) $how" })
}

# ── Видео: сценарий → все сцены сразу → HTML-плеер на движке веб-версии V3AI ─────────────────
# Несколько независимых запросов одновременно. Возвращает текст каждого ответа ($null — не вышло).
function Invoke-V3Many([string[]]$Prompts, [string]$System, [string]$Label) {
  if ($script:Backend -eq 'claude-code') {   # через Claude Code — по очереди
    $out = New-Object 'object[]' $Prompts.Count
    for ($i = 0; $i -lt $Prompts.Count; $i++) {
      Write-Host ("`r  ◌ $Label готово $i из $($Prompts.Count)   ") -NoNewline -ForegroundColor DarkGray
      try { $out[$i] = Invoke-V3ClaudeCode $System $Prompts[$i] $null } catch { $out[$i] = $null }
    }
    Write-Host ("`r  ◌ $Label готово $($Prompts.Count) из $($Prompts.Count)   ") -ForegroundColor DarkGray
    return , $out
  }
  $M = Get-V3Model $script:Cfg.model; $parts = Get-V3RequestParts $M
  $n = $Prompts.Count; $texts = New-Object 'object[]' $n
  if ($n -lt 1) { return , $texts }
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    $todo = @(0..($n - 1) | Where-Object { $null -eq $texts[$_] })
    if (-not $todo.Count) { break }
    if ($attempt -gt 1) { Start-Sleep -Seconds 3; if ($parts.Extra.Contains('speed')) { $parts.Extra.Remove('speed') } }
    $tasks = @{}
    foreach ($i in $todo) {
      $body = [ordered]@{ model = $M.api; max_tokens = 16000; system = $System; messages = @([ordered]@{ role = 'user'; content = $Prompts[$i] }) }
      foreach ($k in $parts.Extra.Keys) { $body[$k] = $parts.Extra[$k] }
      $tasks[$i] = $script:Http.SendAsync((New-V3HttpRequest (ConvertTo-V3Json $body) $parts.Beta))
    }
    $all = [System.Threading.Tasks.Task[]]@($tasks.Values)
    while ($true) {
      $done = @($all | Where-Object { $_.IsCompleted }).Count
      Write-Host ("`r  ◌ $Label готово $done из $n   ") -NoNewline -ForegroundColor DarkGray
      if ($done -ge $all.Count) { break }
      [void][System.Threading.Tasks.Task]::WaitAny($all, 400)
    }
    foreach ($i in $todo) {
      $t = $tasks[$i]
      if ($t.IsFaulted -or $t.IsCanceled) { continue }
      $resp = $t.Result
      try {
        if (-not $resp.IsSuccessStatusCode) { continue }
        $j = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if ($j.stop_reason -eq 'refusal') { $texts[$i] = ''; continue }
        $texts[$i] = (@($j.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ''
      } catch { } finally { $resp.Dispose() }
    }
  }
  Write-Host ''
  return , $texts
}

function Invoke-V3Video($Chat, [string]$Q, [bool]$Three = $true) {
  $safe = 'Юмор приветствуется, в том числе мультяшный туалетный: какашка-смайлик 💩, пуки, лужи — смешно и без натурализма. Нельзя: кровь, жестокость, взрослые темы и насмешки или унижение конкретных людей по имени (это может обидеть настоящего человека). Если в просьбе есть такое — сделай смешную безопасную версию (например, вместо человека забавный персонаж) и ОБЯЗАТЕЛЬНО коротко и честно скажи в ответной фразе, что изменил и почему. Никогда не меняй просьбу молча.'
  $planPrompt = @(
    'Ты — V3AI, ИИ-режиссёр мультфильмов. Придумай по запросу пользователя короткое видео из 3 сцен (максимум 4), которые вместе рассказывают маленькую историю: начало, развитие, финал.',
    $safe,
    'Ответь ТОЛЬКО JSON: {"title":"название ролика до 40 символов","music":"happy|calm|epic","hero":"как выглядит главный герой: цвета, форма, одежда — одной фразой","style":"общий стиль и палитра одной фразой","scenes":[{"picture":"что в сцене и что в ней двигается","caption":"субтитр по-русски до 60 символов","dur":4}],"comment":"одна короткая весёлая фраза по-русски о ролике; если что-то в просьбе изменил — скажи здесь, что и почему"}',
    'dur — от 3 до 6 секунд.',
    "Запрос: $Q"
  ) -join "`n"
  $msgs = New-V3List; $msgs.Add([ordered]@{ role = 'user'; content = $planPrompt })
  $r = Invoke-V3Turn -Messages $msgs -System 'Ты — V3AI, ИИ-режиссёр мультфильмов.' -Quiet -Waiting '🎬 пишу сценарий…' -MaxTokens 8000
  $plan = $null; $m = [regex]::Match($r.Text, '\{[\s\S]*\}'); if ($m.Success) { try { $plan = $m.Value | ConvertFrom-Json } catch { } }
  $list = @(); if ($plan -and $plan.scenes) { $list = @(@($plan.scenes) | Select-Object -First 4) }
  if (-not $list.Count) { Write-V3Note 'Сценарий не получился — попробуй описать сюжет иначе.' Yellow; return }

  $prompts = @()
  for ($i = 0; $i -lt $list.Count; $i++) {
    $sc = $list[$i]; $what = $(if ($sc.picture) { [string]$sc.picture } elseif ($sc.caption) { [string]$sc.caption } else { $Q })
    $head = @("Сюжет фильма: $Q", $(if ($plan.hero) { "Главный герой (во всех сценах выглядит одинаково): $($plan.hero)" } else { '' }), $(if ($plan.style) { "Стиль: $($plan.style)" } else { '' }), "Эта сцена: $what")
    if ($Three) {
      $prompts += (@(
        "Ты — V3AI, 3D-аниматор. Опиши сцену $($i + 1) из $($list.Count) 3D-мультфильма как JSON. Ответ — только JSON в блоке ``````json."
      ) + $head + @(
        'Мир: ось Y вверх, земля на y=0, 1 единица ≈ 1 метр, герой ростом 1–2, всё действие в пределах ±6 от центра.',
        'Формат: {"sky":"#87ceeb","ground":"grass|sand|snow|water|space|none","groundColor":"#5cb85c","light":"day|sunset|night","particles":"none|stars|snow|rain|confetti|bubbles|sparkles","camera":{"from":[0,2.5,8],"to":[1,2,6],"look":[0,1,0],"fov":50,"orbit":20},"objects":[...],"anim":[...]}',
        'objects — по порядку, родитель раньше детей: {"id":"cat","shape":"group","pos":[0,0,0]}, {"id":"head","parent":"cat","shape":"sphere","size":0.5,"pos":[0,1.4,0],"rot":[0,0,0],"scale":[1,0.9,1],"color":"#ff9a3c","rough":0.6,"metal":0,"emissive":"#000000"}. pos и rot (градусы) — относительно родителя.',
        'Формы и size: box [w,h,d]; sphere r; cylinder [rTop,rBottom,h]; cone [r,h]; capsule [r,h]; torus [R,tube]; plane [w,h]; ring [rIn,rOut]; star [r,толщина]; dodecahedron/icosahedron/octahedron/tetrahedron r; group — без формы, для частей.',
        'Героев собирай из 10–25 частей (голова, глаза с белками и зрачками, бликами, нос, уши, лапы, хвост, одежда) — милые, узнаваемые, яркие. Добавь окружение (деревья из конуса и цилиндра, дома, камни, облака из сфер, планеты, цветы) — всего до 70 объектов. Светящиеся вещи — через emissive.',
        'anim: [{"id":"cat","loop":1.2,"linear":false,"keys":[{"t":0,"y":0},{"t":0.5,"y":0.6},{"t":1,"y":0}]}] — смещения от исходного положения: x, y, z; поворот rx, ry, rz в градусах; s — множитель масштаба. t от 0 до 1 внутри периода loop (секунды). Первый и последний ключ одинаковые; для непрерывного вращения — "linear":true и ry от 0 до 360. Двигай 3–8 вещей: шаги, прыжки, махи, вращение, полёт, моргание.',
        'camera: from→to — плавный полёт камеры за сцену, orbit — облёт вокруг look в градусах. Снимай кинематографично, герой хорошо виден.',
        $safe
      ) | Where-Object { $_ }) -join "`n"
    } else {
      $prompts += (@(
        "Ты — V3AI, ИИ-аниматор. Нарисуй сцену $($i + 1) из $($list.Count) короткого мультфильма."
      ) + $head + @(
        'Шаг 1 — ОДНО SVG <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"> в блоке ```svg: яркое и детальное, на весь холст (фон, герой крупно, градиенты, тени), до ~5000 символов. Каждую часть, которая двигается, оберни в <g id="..."> с латинским id.',
        'Запрещено в SVG: script, foreignObject, image, ссылки, внешние шрифты, теги animate/set, CSS-анимация, обработчики событий, текст на картинке.',
        'Шаг 2 — блок ```json: {"loop":2,"anim":[{"id":"hero","origin":[256,300],"keys":[{"t":0,"y":0},{"t":0.5,"y":-30},{"t":1,"y":0}]}]}. loop — период движения в секундах. Ключи: t от 0 до 1; x, y — сдвиг в пикселях; r — поворот в градусах вокруг origin; s — масштаб (или sx, sy); o — прозрачность 0..1. Первый и последний ключ одинаковые. Двигай 2–6 частей заметно и живо.',
        $safe,
        'Ответ — только эти два блока.'
      ) | Where-Object { $_ }) -join "`n"
    }
  }
  $texts = Invoke-V3Many $prompts 'Ты — V3AI, ИИ-аниматор мультфильмов.' $(if ($Three) { "🧊 строю $($list.Count) 3D-сцены сразу:" } else { "🎬 рисую $($list.Count) сцены сразу:" })

  $scenes = New-V3List
  for ($i = 0; $i -lt $list.Count; $i++) {
    $t = [string]$texts[$i]; if (-not $t) { continue }
    $sc = $list[$i]; $dur = 4.0; try { if ($sc.dur) { $dur = [double]$sc.dur } } catch { }
    $cap = [string]$sc.caption
    if ($Three) {
      $js = Get-V3Block $t 'json'; if (-not $js) { $mm = [regex]::Match($t, '\{[\s\S]*\}'); if ($mm.Success) { $js = $mm.Value } }
      $spec = $null; try { $spec = $js | ConvertFrom-Json } catch { }
      if (-not $spec -or -not $spec.objects) { continue }
      $scenes.Add([ordered]@{ three = $spec; dur = $dur; caption = $cap })
    } else {
      $mm = [regex]::Match($t, '<svg[\s\S]*?</svg>', 'IgnoreCase'); if (-not $mm.Success) { continue }
      $anim = @(); $loop = 2.0
      $js = Get-V3Block $t 'json'
      if ($js) { try { $a = $js | ConvertFrom-Json; if ($a.anim) { $anim = @($a.anim) }; if ($a.loop) { $loop = [double]$a.loop } } catch { } }
      $scenes.Add([ordered]@{ svg = $mm.Value; anim = $anim; loop = $loop; dur = $dur; caption = $cap })
    }
  }
  if (-not $scenes.Count) { Write-V3Note 'Сцены не получились — попробуй ещё раз или модель посильнее (/model).' Yellow; return }

  $title = $(if ($plan.title) { ([string]$plan.title).Trim() } else { $Q })
  if ($title.Length -gt 40) { $title = $title.Substring(0, 40) }
  $film = [ordered]@{ title = $title; music = [string]$plan.music; scenes = $scenes }
  $html = $script:PlayerTemplate.Replace('/*V3AI_FILM*/null', (ConvertTo-V3Json $film).Replace('</', '<\/'))
  $path = Save-V3File $script:Paths.Video ((Get-V3SafeName $title) + '.html') $html
  $lines = @()
  if ($plan.comment) { $lines += [string]$plan.comment }
  $lines += ("Сцен: $($scenes.Count)" + $(if ($scenes.Count -lt $list.Count) { " из $($list.Count)" } else { '' }) + ' · ' + $(if ($Three) { '3D' } else { 'рисованный 2D' }) + ' · субтитры и музыка')
  $lines += $(if ($path) { "Файл: $path" } else { 'Файл не сохранён (EngineSecure).' })
  $lines += 'В плеере: ▶ Смотреть и 💾 Скачать видео (MP4). Для 3D нужен интернет.'
  Write-V3Box "🎬 $title" $lines Magenta
  if ($path) { Open-V3File $path }
  $Chat.messages.Add([ordered]@{ role = 'user'; content = $Q })
  $Chat.messages.Add([ordered]@{ role = 'assistant'; content = "(Снял $(if ($Three) { '3D-' } else { '' })видео «$title» по запросу «$Q».)" })
}

# Плеер: страница, которая показывает фильм и собирает из него MP4 (движок — из веб-версии V3AI).
$script:PlayerTemplate = @'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>V3AI · Видео</title>
<style>
:root { --bg: #0b1020; --panel: #121a30; --line: #263049; --fg: #eef2ff; --muted: #9aa6c4; --a1: #00b4ff; --a2: #7dffcf; }
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body { margin: 0; min-height: 100vh; background: var(--bg); color: var(--fg); font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; display: flex; justify-content: center; }
main { width: min(760px, 100%); padding: 24px 16px 40px; display: flex; flex-direction: column; gap: 14px; }
header { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; }
.logo { font: 900 22px/1 "Segoe UI", system-ui, sans-serif; letter-spacing: 1px; background: linear-gradient(90deg, var(--a1), var(--a2)); -webkit-background-clip: text; background-clip: text; color: transparent; }
h1 { margin: 0; font-size: 18px; font-weight: 700; }
.screen { position: relative; width: 100%; aspect-ratio: 1; border-radius: 16px; overflow: hidden; background: #000; border: 1px solid var(--line); }
.screen canvas, .screen img { display: block; width: 100%; height: 100%; object-fit: contain; }
.screen .msg { position: absolute; inset: 0; display: grid; place-items: center; padding: 24px; text-align: center; color: var(--muted); }
.bar { height: 6px; border-radius: 3px; background: var(--panel); overflow: hidden; }
.bar i { display: block; height: 100%; width: 0; background: linear-gradient(90deg, var(--a1), var(--a2)); }
.row { display: flex; gap: 10px; flex-wrap: wrap; }
button { min-height: 44px; padding: 10px 18px; border-radius: 999px; border: 1px solid var(--line); background: var(--panel); color: var(--fg); font: inherit; font-weight: 700; cursor: pointer; }
button.main { border: 0; background: linear-gradient(135deg, #0a84ff, #00c2a8); color: #fff; }
button:disabled { opacity: .55; cursor: default; }
button:focus-visible { outline: 3px solid var(--a2); outline-offset: 2px; }
#status { margin: 0; color: var(--muted); min-height: 1.5em; }
ol { margin: 0; padding-left: 22px; color: var(--muted); }
ol b { color: var(--fg); font-weight: 600; }
</style>
</head>
<body>
<main>
  <header><span class="logo">V3AI</span><h1 id="title">Видео</h1></header>
  <div class="screen"><canvas id="view" width="720" height="720" aria-label="Видео"></canvas><div class="msg" id="msg">Готовлю сцены…</div></div>
  <div class="bar" aria-hidden="true"><i id="prog"></i></div>
  <div class="row">
    <button type="button" class="main" id="play" disabled>▶ Смотреть</button>
    <button type="button" id="save" disabled>💾 Скачать видео</button>
  </div>
  <p id="status" aria-live="polite"></p>
  <ol id="scenes"></ol>
</main>
<script>
const FILM = /*V3AI_FILM*/null;
(() => {
  "use strict";
  const $ = (s) => document.querySelector(s);
function cleanSvg(src) {
  const m = String(src).match(/<svg[\s\S]*<\/svg>/i);
  if (!m) return "";
  let doc;
  try { doc = new DOMParser().parseFromString(m[0], "image/svg+xml"); } catch (e) { return ""; }
  const root = doc.documentElement;
  if (!root || root.nodeName.toLowerCase() !== "svg" || doc.getElementsByTagName("parsererror").length) return "";
  const BAD = ["script", "foreignobject", "iframe", "a", "audio", "video", "animate", "set", "animatetransform", "animatemotion", "image"];
  Array.from(root.getElementsByTagName("*")).forEach((n) => {
    if (BAD.includes(n.nodeName.toLowerCase())) { n.remove(); return; }
    Array.from(n.attributes).forEach((a) => {
      const k = a.name.toLowerCase(), v = a.value;
      if (k.startsWith("on") || /javascript:|data:text|@import/i.test(v) || ((k === "href" || k === "xlink:href") && !v.startsWith("#")) || /url\(\s*['"]?(?!#)/i.test(v)) n.removeAttribute(a.name);
    });
    if (n.nodeName.toLowerCase() === "style" && /@import|url\(\s*['"]?(?!#)/i.test(n.textContent)) n.remove();
  });
  Array.from(root.attributes).forEach((a) => { if (a.name.toLowerCase().startsWith("on")) root.removeAttribute(a.name); });
  root.setAttribute("xmlns", "http://www.w3.org/2000/svg");
  if (!root.getAttribute("viewBox")) root.setAttribute("viewBox", `0 0 ${parseFloat(root.getAttribute("width")) || 512} ${parseFloat(root.getAttribute("height")) || 512}`);
  root.setAttribute("width", "1024"); root.setAttribute("height", "1024");
  const out = new XMLSerializer().serializeToString(root);
  return root.getElementsByTagName("*").length >= 3 ? out : "";
}
const svgUrl = (svg) => "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
const OFF_ANIM = { frames: 20, fps: 12, anim: [
  { id: "hero", origin: [256, 400], keys: [{ t: 0, y: 0, sx: 1.06, sy: .94 }, { t: .15, y: 0, sx: 1, sy: 1 }, { t: .5, y: -70, sx: .97, sy: 1.04 }, { t: .85, y: 0, sx: 1, sy: 1 }, { t: 1, y: 0, sx: 1.06, sy: .94 }] },
  { id: "shadow", origin: [256, 410], keys: [{ t: 0, s: 1, o: 1 }, { t: .5, s: .7, o: .5 }, { t: 1, s: 1, o: 1 }] },
  { id: "sun", origin: [410, 100], keys: [{ t: 0, s: 1 }, { t: .5, s: 1.08 }, { t: 1, s: 1 }] },
  { id: "fx", origin: [256, 256], keys: [{ t: 0, o: 1 }, { t: .5, o: .45, y: 6 }, { t: 1, o: 1 }] },
] };
function jsonBlock(text, key) {
  const m = String(text).match(/```json\s*([\s\S]*?)```/i) || String(text).match(new RegExp('(\\{[\\s\\S]*"' + key + '"[\\s\\S]*\\})'));
  if (!m) return null;
  try { return JSON.parse(m[1]); } catch (e) { return null; }
}
const parseAnim = (text) => normAnim(jsonBlock(text, "anim"));
function normAnim(a) {
  try {
    if (!a || !Array.isArray(a.anim)) return null;
    const num = (v, d) => (typeof v === "number" && isFinite(v) ? v : d);
    const anim = a.anim.slice(0, 16).filter((x) => x && typeof x.id === "string" && Array.isArray(x.keys) && x.keys.length).map((x) => ({
      id: x.id.slice(0, 40), origin: Array.isArray(x.origin) ? [num(x.origin[0], 256), num(x.origin[1], 256)] : [256, 256],
      keys: x.keys.slice(0, 12).map((k) => ({ t: Math.min(1, Math.max(0, num(k.t, 0))), x: num(k.x, 0), y: num(k.y, 0), r: num(k.r, 0), s: num(k.s, 1), sx: num(k.sx, NaN), sy: num(k.sy, NaN), o: Math.min(1, Math.max(0, num(k.o, 1))) })).sort((p, q) => p.t - q.t),
    }));
    return anim.length ? { frames: Math.round(Math.min(36, Math.max(8, num(a.frames, 24)))), fps: Math.min(20, Math.max(4, num(a.fps, 12))), anim } : null;
  } catch (e) { return null; }
}
const offAnim = () => normAnim(OFF_ANIM);
// the value of every animated property at time t (0..1), eased between keys
function at(keys, t) {
  let i = 0; while (i < keys.length - 1 && keys[i + 1].t < t) i++;
  const a = keys[i], b = keys[Math.min(i + 1, keys.length - 1)];
  const span = b.t - a.t, u = span > 0 ? Math.min(1, Math.max(0, (t - a.t) / span)) : 0, e = u * u * (3 - 2 * u);
  const mix = (p, q) => p + (q - p) * e;
  const sx = (k) => (isNaN(k.sx) ? k.s : k.sx), sy = (k) => (isNaN(k.sy) ? k.s : k.sy);
  return { x: mix(a.x, b.x), y: mix(a.y, b.y), r: mix(a.r, b.r), sx: mix(sx(a), sx(b)), sy: mix(sy(a), sy(b)), o: mix(a.o, b.o) };
}
function frameSvgs(svg, spec) { const rig = makeRig(svg, spec.anim), out = []; for (let f = 0; f < spec.frames; f++) out.push(rig(f / spec.frames)); return out; }
// a "rig": the picture with its moving parts wrapped; rig(t) gives the SVG at loop time t (0..1)
function makeRig(svg, anims) {
  const doc = new DOMParser().parseFromString(svg, "image/svg+xml"), root = doc.documentElement, NS = "http://www.w3.org/2000/svg";
  // wrap each moving part, so its own transform stays and ours goes on top
  const parts = (anims || []).map((a) => {
    let el = null; try { el = root.querySelector("#" + CSS.escape(a.id)); } catch (e) { el = null; }
    if (!el || el === root) return null;
    const g = doc.createElementNS(NS, "g"); el.parentNode.insertBefore(g, el); g.appendChild(el);
    return { a, g };
  }).filter(Boolean);
  if (!parts.length) { // nothing matched: gently sway the whole picture
    const g = doc.createElementNS(NS, "g"); while (root.firstChild) g.appendChild(root.firstChild); root.appendChild(g);
    parts.push({ g, a: { origin: [256, 256], keys: [{ t: 0, x: 0, y: 0, r: -2, s: 1.04, sx: NaN, sy: NaN, o: 1 }, { t: .5, x: 0, y: -8, r: 2, s: 1.07, sx: NaN, sy: NaN, o: 1 }, { t: 1, x: 0, y: 0, r: -2, s: 1.04, sx: NaN, sy: NaN, o: 1 }] } });
  }
  const ser = new XMLSerializer();
  return (t) => {
    parts.forEach(({ a, g }) => {
      const v = at(a.keys, t), [ox, oy] = a.origin, n = (z) => Math.round(z * 1000) / 1000;
      g.setAttribute("transform", `translate(${n(ox + v.x)} ${n(oy + v.y)}) rotate(${n(v.r)}) scale(${n(v.sx)} ${n(v.sy)}) translate(${-ox} ${-oy})`);
      if (v.o < .999) g.setAttribute("opacity", n(v.o)); else g.removeAttribute("opacity");
    });
    return ser.serializeToString(root);
  };
}
const loadImg = (src) => new Promise((res, rej) => { const im = new Image(); im.onload = () => res(im); im.onerror = rej; im.src = src; });
let actx = null;
function wakeAudio() { // must run inside the tap that asked for the video
  try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); if (actx.state === "suspended") actx.resume(); } catch (e) { actx = null; }
}
function music(a, dest, total, mood) {
  const t0 = a.currentTime + .05;
  const M = { happy: { bpm: 120, wave: "triangle", root: 60, prog: [0, 7, 9, 5] }, calm: { bpm: 80, wave: "sine", root: 57, prog: [0, 5, 3, 7] }, epic: { bpm: 100, wave: "sawtooth", root: 50, prog: [0, 8, 3, 10] } }[mood] || null;
  if (!M) return;
  const out = a.createGain(); out.gain.setValueAtTime(0, t0); out.gain.linearRampToValueAtTime(.5, t0 + .4); out.gain.setValueAtTime(.5, t0 + total - 1.2); out.gain.linearRampToValueAtTime(0, t0 + total); out.connect(dest);
  const hz = (n) => 440 * Math.pow(2, (n - 69) / 12), beat = 60 / M.bpm, minor = mood !== "happy";
  const note = (n, at, len, wave, vol) => { const o = a.createOscillator(), g = a.createGain(); o.type = wave; o.frequency.value = hz(n); g.gain.setValueAtTime(0, at); g.gain.linearRampToValueAtTime(vol, at + .02); g.gain.exponentialRampToValueAtTime(.001, at + len); o.connect(g); g.connect(out); o.start(at); o.stop(at + len + .05); };
  for (let b = 0, t = t0; t < t0 + total; b++, t += beat) {
    const ch = M.root + M.prog[Math.floor(b / 4) % 4], tri = [0, minor && b % 8 < 4 ? 3 : 4, 7, 12];
    note(ch - 12, t, beat * .9, "sine", .35);
    note(ch + tri[b % 4], t, beat * .8, M.wave, mood === "epic" ? .07 : .16);
    if (mood === "happy") note(ch + tri[(b + 2) % 4] + 12, t + beat / 2, beat * .4, "triangle", .08);
  }
}
function wrapLines(g, text, max) {
  const words = String(text).split(/\s+/), lines = []; let cur = "";
  words.forEach((w) => { const t = cur ? cur + " " + w : w; if (g.measureText(t).width > max && cur) { lines.push(cur); cur = w; } else cur = t; });
  if (cur) lines.push(cur); return lines.slice(0, 2);
}
async function makeFrames(m, S) {
  const cv = document.createElement("canvas"); cv.width = cv.height = S;
  const g = cv.getContext("2d"), scenes = m.scenes, FADE = .5, k = S / 720;
  const stage = scenes.some((sc) => sc.three) ? stage3d(await loadThree(), S) : null;
  const views = scenes.map((sc) => (sc.three ? stage.build(sc) : makeRig(sc.svg, sc.anim))), starts = []; let total = 0;
  scenes.forEach((sc) => { starts.push(total); total += sc.dur; });
  const paint = async (i, local, alpha) => {
    const sc = scenes[i];
    let src;
    if (sc.three) { stage.render(views[i], local); src = stage.canvas; } else src = await loadImg(svgUrl(views[i]((local % sc.loop) / sc.loop)));
    g.globalAlpha = alpha; g.drawImage(src, 0, 0, S, S); g.globalAlpha = 1;
  };
  const frame = async (sec) => {
    let i = 0; while (i < scenes.length - 1 && sec >= starts[i + 1]) i++;
    const local = sec - starts[i], sc = scenes[i], left = sc.dur - local;
    g.fillStyle = "#000"; g.fillRect(0, 0, S, S);
    await paint(i, local, 1);
    if (i < scenes.length - 1 && left < FADE) await paint(i + 1, 0, 1 - left / FADE); // crossfade into the next scene
    if (sec < FADE) { g.fillStyle = `rgba(0,0,0,${1 - sec / FADE})`; g.fillRect(0, 0, S, S); }
    if (total - sec < FADE) { g.fillStyle = `rgba(0,0,0,${Math.min(1, 1 - (total - sec) / FADE)})`; g.fillRect(0, 0, S, S); }
    if (sc.caption) {
      g.font = `800 ${34 * k}px Manrope, system-ui, sans-serif`; g.textAlign = "center"; g.textBaseline = "middle";
      const lines = wrapLines(g, sc.caption, S - 120 * k), a = Math.min(1, local / .3, left / .3);
      if (a > 0) {
        g.globalAlpha = a; const hh = (lines.length * 44 + 24) * k, y0 = S - 40 * k - hh;
        g.fillStyle = "rgba(0,0,0,.55)"; g.beginPath(); (g.roundRect ? g.roundRect(40 * k, y0, S - 80 * k, hh, 18 * k) : g.rect(40 * k, y0, S - 80 * k, hh)); g.fill();
        g.fillStyle = "#fff"; lines.forEach((l, n) => g.fillText(l, S / 2, y0 + (34 + n * 44) * k)); g.globalAlpha = 1;
      }
    }
    g.font = `900 ${20 * k}px Manrope, system-ui, sans-serif`; g.textAlign = "right"; g.textBaseline = "middle"; g.fillStyle = "rgba(255,255,255,.75)"; g.fillText("V3AI", S - 18 * k, 30 * k);
  };
  return { cv, frame, total, dispose: () => { if (stage) stage.dispose(); } };
}
let threeLib = null;
function loadThree() {
  if (window.THREE) return Promise.resolve(window.THREE);
  return threeLib || (threeLib = new Promise((res, rej) => {
    const sc = document.createElement("script"); sc.src = "https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"; sc.async = true;
    sc.onload = () => (window.THREE ? res(window.THREE) : rej(new Error("no3d")));
    sc.onerror = () => { threeLib = null; sc.remove(); rej(new Error("no3d")); };
    document.head.appendChild(sc);
  }));
}
const clampN = (v, d, lo, hi) => Math.min(hi, Math.max(lo, typeof v === "number" && isFinite(v) ? v : d));
const vec3 = (v, d, lo, hi) => (Array.isArray(v) ? [0, 1, 2].map((i) => clampN(v[i], d[i], lo, hi)) : typeof v === "number" ? [clampN(v, d[0], lo, hi), clampN(v, d[1], lo, hi), clampN(v, d[2], lo, hi)] : d.slice());
const colr = (c, d) => (typeof c === "string" && /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(c) ? c : d);
const SHAPES = ["group", "box", "sphere", "cylinder", "cone", "capsule", "torus", "plane", "ring", "star", "dodecahedron", "icosahedron", "octahedron", "tetrahedron"];
// Turn whatever came back into a safe, bounded scene description.
function norm3d(j) {
  if (!j || !Array.isArray(j.objects)) return null;
  const ids = new Set(), objects = [];
  j.objects.slice(0, 90).forEach((o) => {
    if (!o || typeof o !== "object") return;
    const shape = SHAPES.includes(String(o.shape).toLowerCase()) ? String(o.shape).toLowerCase() : "box";
    const id = typeof o.id === "string" ? o.id.slice(0, 40) : "";
    const size = Array.isArray(o.size) ? o.size.slice(0, 3).map((v) => clampN(v, 1, .01, 60)) : typeof o.size === "number" ? [clampN(o.size, 1, .01, 60)] : [];
    objects.push({ id, shape, size, parent: typeof o.parent === "string" && ids.has(o.parent) ? o.parent : "",
      pos: vec3(o.pos, [0, 0, 0], -120, 120), rot: vec3(o.rot, [0, 0, 0], -720, 720), scale: vec3(o.scale, [1, 1, 1], .01, 40),
      color: colr(o.color, "#cccccc"), emissive: colr(o.emissive, "#000000"), rough: clampN(o.rough, .55, 0, 1), metal: clampN(o.metal, 0, 0, 1), opacity: clampN(o.opacity, 1, .05, 1) });
    if (id) ids.add(id);
  });
  if (!objects.length) return null;
  const anim = (Array.isArray(j.anim) ? j.anim : []).slice(0, 24).filter((x) => x && ids.has(x.id) && Array.isArray(x.keys) && x.keys.length).map((x) => ({
    id: x.id, loop: clampN(x.loop, 2, .2, 12), linear: !!x.linear,
    keys: x.keys.slice(0, 12).map((k) => ({ t: clampN(k.t, 0, 0, 1), x: clampN(k.x, 0, -60, 60), y: clampN(k.y, 0, -60, 60), z: clampN(k.z, 0, -60, 60), rx: clampN(k.rx, 0, -1080, 1080), ry: clampN(k.ry, 0, -1080, 1080), rz: clampN(k.rz, 0, -1080, 1080), s: clampN(k.s, 1, .01, 20) })).sort((p, q) => p.t - q.t),
  }));
  const cam = j.camera && typeof j.camera === "object" ? j.camera : {};
  const from = vec3(cam.from, [0, 2.5, 8], -80, 80);
  return {
    sky: colr(j.sky, "#8fd3ff"), ground: ["grass", "sand", "snow", "water", "space", "none"].includes(j.ground) ? j.ground : "grass", groundColor: colr(j.groundColor, ""),
    light: ["day", "sunset", "night"].includes(j.light) ? j.light : "day", particles: ["none", "stars", "snow", "rain", "confetti", "bubbles", "sparkles"].includes(j.particles) ? j.particles : "none",
    camera: { from, to: vec3(cam.to, from, -80, 80), look: vec3(cam.look, [0, 1, 0], -80, 80), fov: clampN(cam.fov, 50, 20, 100), orbit: clampN(cam.orbit, 0, -360, 360) },
    objects, anim,
  };
}
function stage3d(T, S) {
  const canvas = document.createElement("canvas"); canvas.width = canvas.height = S;
  const rd = new T.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true });
  rd.setPixelRatio(1); rd.setSize(S, S, false); rd.shadowMap.enabled = true; rd.shadowMap.type = T.PCFSoftShadowMap; rd.outputEncoding = T.sRGBEncoding;
  return { canvas, build: (sc) => build3d(T, sc.three, sc.dur), render: (v, local) => { v.update(local); rd.render(v.scene, v.cam); }, dispose: () => { rd.dispose(); try { rd.forceContextLoss(); } catch (e) { /* fine */ } } };
}
function geom(T, shape, sz) {
  const a = (i, d) => (sz[i] != null ? sz[i] : d);
  switch (shape) {
    case "sphere": return new T.SphereGeometry(a(0, .5), 32, 20);
    case "cylinder": return sz.length >= 3 ? new T.CylinderGeometry(a(0, .5), a(1, .5), a(2, 1), 32) : new T.CylinderGeometry(a(0, .5), a(0, .5), a(1, 1), 32);
    case "cone": return new T.ConeGeometry(a(0, .5), a(1, 1), 32);
    case "torus": return new T.TorusGeometry(a(0, .5), a(1, .15), 16, 48);
    case "plane": return new T.PlaneGeometry(a(0, 1), a(1, 1));
    case "ring": return new T.RingGeometry(a(0, .3), a(1, .5), 48);
    case "dodecahedron": return new T.DodecahedronGeometry(a(0, .5));
    case "icosahedron": return new T.IcosahedronGeometry(a(0, .5));
    case "octahedron": return new T.OctahedronGeometry(a(0, .5));
    case "tetrahedron": return new T.TetrahedronGeometry(a(0, .5));
    case "star": {
      const r = a(0, .5), sh = new T.Shape();
      for (let i = 0; i < 10; i++) { const ang = Math.PI / 2 + i * Math.PI / 5, rr = i % 2 ? r * .45 : r; const x = Math.cos(ang) * rr, y = Math.sin(ang) * rr; if (i) sh.lineTo(x, y); else sh.moveTo(x, y); }
      const gm = new T.ExtrudeGeometry(sh, { depth: a(1, .15), bevelEnabled: true, bevelSize: r * .05, bevelThickness: r * .05, bevelSegments: 2 }); gm.center(); return gm;
    }
    default: return new T.BoxGeometry(a(0, 1), a(1, 1), a(2, 1));
  }
}
function build3d(T, spec, dur) {
  const scene = new T.Scene(), d2r = Math.PI / 180;
  const lc = (hex) => new T.Color(hex).convertSRGBToLinear(); // colours as people pick them, shown true on screen
  const LIGHT = { day: [1, .75, "#ffffff"], sunset: [.8, .55, "#ffb27a"], night: [.35, .35, "#9fb4ff"] }[spec.light];
  const space = spec.ground === "space";
  scene.background = new T.Color(space ? "#02030c" : spec.sky);
  if (!space) scene.fog = new T.Fog(lc(spec.sky), 30, 90);
  scene.add(new T.HemisphereLight(lc(space ? "#8899ff" : spec.sky), lc("#555555"), LIGHT[1]));
  const sun = new T.DirectionalLight(lc(LIGHT[2]), LIGHT[0] * 1.1); sun.position.set(6, 12, 7); sun.castShadow = true;
  sun.shadow.mapSize.set(1024, 1024); Object.assign(sun.shadow.camera, { left: -14, right: 14, top: 14, bottom: -14, near: 1, far: 50 }); sun.shadow.bias = -.0008;
  scene.add(sun);
  if (!["space", "none"].includes(spec.ground)) {
    const GC = { grass: "#5cb85c", sand: "#e8d29b", snow: "#f4f8ff", water: "#2a7fd4" }[spec.ground];
    const gnd = new T.Mesh(new T.CircleGeometry(90, 64), new T.MeshStandardMaterial({ color: lc(spec.groundColor || GC), roughness: spec.ground === "water" ? .15 : .95, metalness: spec.ground === "water" ? .25 : 0 }));
    gnd.rotation.x = -Math.PI / 2; gnd.receiveShadow = true; scene.add(gnd);
  }
  // the objects; a part's position is relative to its parent
  const byId = {};
  spec.objects.forEach((o) => {
    let node;
    if (o.shape === "group") node = new T.Group();
    else {
      const mat = new T.MeshStandardMaterial({ color: lc(o.color), roughness: Math.max(.2, o.rough), metalness: o.metal * .45, emissive: lc(o.emissive), transparent: o.opacity < 1, opacity: o.opacity, side: o.shape === "plane" || o.shape === "ring" ? T.DoubleSide : T.FrontSide });
      if (o.shape === "capsule") { // r128 has no capsule: a cylinder with two half-spheres
        const r = o.size[0] != null ? o.size[0] : .3, h = o.size[1] != null ? o.size[1] : .8;
        node = new T.Group();
        const body = new T.Mesh(new T.CylinderGeometry(r, r, h, 32), mat), top = new T.Mesh(new T.SphereGeometry(r, 32, 16), mat), bot = top.clone();
        top.position.y = h / 2; bot.position.y = -h / 2;
        [body, top, bot].forEach((x) => { x.castShadow = x.receiveShadow = true; node.add(x); });
      } else { node = new T.Mesh(geom(T, o.shape, o.size), mat); node.castShadow = node.receiveShadow = true; }
    }
    node.position.set(...o.pos); node.rotation.set(o.rot[0] * d2r, o.rot[1] * d2r, o.rot[2] * d2r); node.scale.set(...o.scale);
    (o.parent && byId[o.parent] ? byId[o.parent] : scene).add(node);
    if (o.id) byId[o.id] = node;
    node.userData.base = { p: node.position.clone(), r: node.rotation.clone(), s: node.scale.clone() };
  });
  // particles
  let pts = null, base = null, speed = 0;
  if (spec.particles !== "none") {
    const N = spec.particles === "stars" ? 700 : 450, pos = new Float32Array(N * 3), col = new Float32Array(N * 3), c = new T.Color();
    base = new Float32Array(N * 3);
    for (let i = 0; i < N; i++) {
      if (spec.particles === "stars") { const u = Math.random() * 2 - 1, th = Math.random() * Math.PI * 2, rr = 60; base.set([Math.sqrt(1 - u * u) * Math.cos(th) * rr, Math.abs(u) * rr * .9 + 2, Math.sqrt(1 - u * u) * Math.sin(th) * rr], i * 3); }
      else base.set([(Math.random() - .5) * 24, Math.random() * 14, -14 + Math.random() * 16], i * 3); // in front of the camera, never on its lens
      c.set(spec.particles === "confetti" ? ["#ff4d6d", "#ffd84d", "#4dd2ff", "#7dffcf", "#b48cff"][i % 5] : spec.particles === "bubbles" ? "#bfefff" : spec.particles === "sparkles" ? "#fff3a0" : "#ffffff");
      c.convertSRGBToLinear(); col.set([c.r, c.g, c.b], i * 3);
    }
    pos.set(base);
    const gm = new T.BufferGeometry(); gm.setAttribute("position", new T.BufferAttribute(pos, 3)); gm.setAttribute("color", new T.BufferAttribute(col, 3));
    const size = { stars: .35, snow: .12, rain: .06, confetti: .14, bubbles: .18, sparkles: .12 }[spec.particles];
    pts = new T.Points(gm, new T.PointsMaterial({ size, vertexColors: true, transparent: true, opacity: spec.particles === "bubbles" ? .7 : .95, sizeAttenuation: true }));
    scene.add(pts);
    speed = { stars: 0, snow: -1.2, rain: -9, confetti: -1.6, bubbles: 1.1, sparkles: .4 }[spec.particles];
  }
  const cam = new T.PerspectiveCamera(spec.camera.fov, 1, .1, 400);
  const look = new T.Vector3(...spec.camera.look), from = new T.Vector3(...spec.camera.from), to = new T.Vector3(...spec.camera.to);
  const ease = (u) => u * u * (3 - 2 * u);
  const value = (keys, t, lin) => {
    let i = 0; while (i < keys.length - 1 && keys[i + 1].t < t) i++;
    const a = keys[i], b = keys[Math.min(i + 1, keys.length - 1)], span = b.t - a.t;
    const u = span > 0 ? Math.min(1, Math.max(0, (t - a.t) / span)) : 0, e = lin ? u : ease(u), mix = (p, q) => p + (q - p) * e;
    return { x: mix(a.x, b.x), y: mix(a.y, b.y), z: mix(a.z, b.z), rx: mix(a.rx, b.rx), ry: mix(a.ry, b.ry), rz: mix(a.rz, b.rz), s: mix(a.s, b.s) };
  };
  const update = (local) => {
    spec.anim.forEach((an) => {
      const node = byId[an.id]; if (!node) return;
      const v = value(an.keys, (local % an.loop) / an.loop, an.linear), B = node.userData.base;
      node.position.set(B.p.x + v.x, B.p.y + v.y, B.p.z + v.z);
      node.rotation.set(B.r.x + v.rx * d2r, B.r.y + v.ry * d2r, B.r.z + v.rz * d2r);
      node.scale.set(B.s.x * v.s, B.s.y * v.s, B.s.z * v.s);
    });
    if (pts) {
      const arr = pts.geometry.attributes.position.array;
      for (let i = 0; i < arr.length; i += 3) {
        if (speed) { let y = base[i + 1] + speed * local; y = ((y % 14) + 14) % 14; arr[i + 1] = y; arr[i] = base[i] + Math.sin(local * 1.3 + i) * (spec.particles === "rain" ? 0 : .25); }
      }
      if (speed) pts.geometry.attributes.position.needsUpdate = true;
      if (spec.particles === "stars" || spec.particles === "sparkles") pts.material.opacity = .75 + .25 * Math.sin(local * 4);
    }
    const e = ease(Math.min(1, local / Math.max(.1, dur)));
    cam.position.lerpVectors(from, to, e);
    if (spec.camera.orbit) { const off = cam.position.clone().sub(look); off.applyAxisAngle(new T.Vector3(0, 1, 0), spec.camera.orbit * d2r * e); cam.position.copy(look).add(off); }
    cam.lookAt(look);
  };
  return { scene, cam, update };
}
// Fast path: WebCodecs encodes the frames as quickly as they can be drawn, mp4-muxer packs them into an MP4.
let muxLib = null;
function loadMuxer() {
  if (window.Mp4Muxer) return Promise.resolve(window.Mp4Muxer);
  return muxLib || (muxLib = new Promise((res, rej) => {
    const sc = document.createElement("script"); sc.src = "https://cdn.jsdelivr.net/npm/mp4-muxer@5.1.3/build/mp4-muxer.js"; sc.async = true;
    sc.onload = () => (window.Mp4Muxer ? res(window.Mp4Muxer) : rej(new Error("nomux")));
    sc.onerror = () => { muxLib = null; sc.remove(); rej(new Error("nomux")); };
    document.head.appendChild(sc);
  }));
}
async function pickVideo(S, fps) {
  for (const [codec, mux] of [["avc1.4d401f", "avc"], ["avc1.42e01f", "avc"], ["vp09.00.31.08", "vp9"]]) {
    const cfg = { codec, width: S, height: S, bitrate: 2500000, framerate: fps, latencyMode: "quality" };
    if (mux === "avc") cfg.avc = { format: "avc" };
    try { const r = await VideoEncoder.isConfigSupported(cfg); if (r && r.supported) return { cfg, mux }; } catch (e) { /* try the next */ }
  }
  return null;
}
async function pickAudio() {
  if (!window.AudioEncoder || !window.AudioData || !window.OfflineAudioContext) return null;
  for (const [codec, mux] of [["mp4a.40.2", "aac"], ["opus", "opus"]]) {
    const cfg = { codec, sampleRate: 48000, numberOfChannels: 2, bitrate: 128000 };
    try { const r = await AudioEncoder.isConfigSupported(cfg); if (r && r.supported) return { cfg, mux }; } catch (e) { /* try the next */ }
  }
  return null;
}
async function fastVideo(m, onProg) {
  if (!window.VideoEncoder || !window.VideoFrame) throw new Error("nowc");
  const S = 720, FPS = 24, wantMusic = m.music && m.music !== "none";
  const [M, v, a] = await Promise.all([loadMuxer(), pickVideo(S, FPS), wantMusic ? pickAudio() : null]);
  if (!v) throw new Error("nowc");
  const R = await makeFrames(m, S), n = Math.round(R.total * FPS);
  const muxer = new M.Muxer({ target: new M.ArrayBufferTarget(), video: { codec: v.mux, width: S, height: S, frameRate: FPS }, audio: a ? { codec: a.mux, numberOfChannels: 2, sampleRate: 48000 } : undefined, fastStart: "in-memory", firstTimestampBehavior: "offset" });
  let err = null;
  const ve = new VideoEncoder({ output: (c, meta) => muxer.addVideoChunk(c, meta), error: (e) => { err = e; } });
  ve.configure(v.cfg);
  // music renders in parallel with the pictures
  const song = a ? (() => { const oc = new OfflineAudioContext(2, Math.ceil(R.total * 48000), 48000); music(oc, oc.destination, R.total, m.music); return oc.startRendering(); })() : null;
  for (let i = 0; i < n; i++) {
    if (err) throw err;
    await R.frame(i / FPS);
    const vf = new VideoFrame(R.cv, { timestamp: Math.round(i * 1e6 / FPS), duration: Math.round(1e6 / FPS) });
    ve.encode(vf, { keyFrame: i % (FPS * 2) === 0 }); vf.close();
    while (ve.encodeQueueSize > 6) await new Promise((r) => setTimeout(r, 4));
    if (i % 4 === 0) onProg(i / n * .97);
  }
  await ve.flush(); ve.close(); if (err) throw err;
  if (song) {
    const buf = await song, len = buf.length, L = buf.getChannelData(0), Rr = buf.getChannelData(1), CH = 4800;
    const ae = new AudioEncoder({ output: (c, meta) => muxer.addAudioChunk(c, meta), error: (e) => { err = e; } });
    ae.configure(a.cfg);
    for (let off = 0; off < len; off += CH) {
      const k = Math.min(CH, len - off), data = new Float32Array(k * 2);
      data.set(L.subarray(off, off + k), 0); data.set(Rr.subarray(off, off + k), k);
      const ad = new AudioData({ format: "f32-planar", sampleRate: 48000, numberOfFrames: k, numberOfChannels: 2, timestamp: Math.round(off * 1e6 / 48000), data });
      ae.encode(ad); ad.close();
    }
    await ae.flush(); ae.close(); if (err) throw err;
  }
  R.dispose(); muxer.finalize(); onProg(1);
  const blob = new Blob([muxer.target.buffer], { type: "video/mp4" });
  if (!blob.size) throw new Error("empty");
  return { blob, url: URL.createObjectURL(blob) };
}

// Fallback: play the film on a canvas and record it in real time.
async function recordVideo(m, onProg) {
  if (!window.MediaRecorder || !HTMLCanvasElement.prototype.captureStream) throw new Error("norec");
  const mime = ['video/mp4;codecs="avc1.42E01E,mp4a.40.2"', "video/mp4", "video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm"].find((t) => { try { return MediaRecorder.isTypeSupported(t); } catch (e) { return false; } });
  if (!mime) throw new Error("norec");
  const R = await makeFrames(m, 720), total = R.total;
  await R.frame(0);
  const stream = R.cv.captureStream(30);
  if (actx && m.music && m.music !== "none") {
    try { if (actx.state === "suspended") await actx.resume(); const dest = actx.createMediaStreamDestination(); music(actx, dest, total, m.music); dest.stream.getAudioTracks().forEach((t) => stream.addTrack(t)); } catch (e) { /* silent video then */ }
  }
  const rec = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: 3e6 }), chunks = [];
  rec.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
  const stopped = new Promise((res) => { rec.onstop = res; });
  rec.start(250);
  const t0 = performance.now();
  for (;;) {
    const sec = (performance.now() - t0) / 1000;
    if (sec >= total) break;
    await R.frame(sec); onProg(sec / total);
    const wait = 33 - ((performance.now() - t0) % 33); await new Promise((r) => setTimeout(r, wait));
  }
  await R.frame(total - .001);
  rec.stop(); await stopped; stream.getTracks().forEach((t) => t.stop()); R.dispose();
  const blob = new Blob(chunks, { type: mime.split(";")[0] });
  if (!blob.size) throw new Error("empty");
  return { blob, url: URL.createObjectURL(blob) };
}
// Median-cut palette (256 colours) over all frames, then LZW: a complete GIF89a encoder.
function palette(frames) {
  const hist = new Uint32Array(32768);
  frames.forEach((d) => { for (let i = 0; i < d.length; i += 8) hist[((d[i] >> 3) << 10) | ((d[i + 1] >> 3) << 5) | (d[i + 2] >> 3)]++; });
  const bins = []; for (let i = 0; i < 32768; i++) if (hist[i]) bins.push(i);
  const ch = (b, c) => (c === 0 ? b >> 10 : c === 1 ? (b >> 5) & 31 : b & 31);
  const boxes = [bins];
  while (boxes.length < 256) {
    let best = -1, bestScore = 0, bestC = 0;
    boxes.forEach((bx, i) => {
      if (bx.length < 2) return;
      let cnt = 0; const lo = [31, 31, 31], hi = [0, 0, 0];
      bx.forEach((b) => { cnt += hist[b]; for (let c = 0; c < 3; c++) { const v = ch(b, c); if (v < lo[c]) lo[c] = v; if (v > hi[c]) hi[c] = v; } });
      for (let c = 0; c < 3; c++) { const sc = (hi[c] - lo[c]) * Math.sqrt(cnt); if (sc > bestScore) { bestScore = sc; best = i; bestC = c; } }
    });
    if (best < 0) break;
    const bx = boxes[best].sort((p, q) => ch(p, bestC) - ch(q, bestC));
    let total = 0; bx.forEach((b) => { total += hist[b]; });
    let acc = 0, cut = 1; for (let i = 0; i < bx.length - 1; i++) { acc += hist[bx[i]]; if (acc >= total / 2) { cut = i + 1; break; } }
    boxes.splice(best, 1, bx.slice(0, cut), bx.slice(cut));
  }
  const pal = boxes.map((bx) => { let n = 0, r = 0, g = 0, b = 0; bx.forEach((v) => { const w = hist[v]; n += w; r += ch(v, 0) * w; g += ch(v, 1) * w; b += ch(v, 2) * w; }); return n ? [r / n * 8.226 | 0, g / n * 8.226 | 0, b / n * 8.226 | 0] : [0, 0, 0]; });
  while (pal.length < 256) pal.push([0, 0, 0]);
  return pal;
}
function encodeGif(frames, w, h, fps) {
  const pal = palette(frames), look = new Int16Array(32768).fill(-1);
  const nearest = (key) => {
    const r = (key >> 10) * 8.226, g = ((key >> 5) & 31) * 8.226, b = (key & 31) * 8.226;
    let bi = 0, bd = Infinity;
    for (let i = 0; i < 256; i++) { const p = pal[i], d = (p[0] - r) ** 2 * 2 + (p[1] - g) ** 2 * 4 + (p[2] - b) ** 2 * 3; if (d < bd) { bd = d; bi = i; } }
    return (look[key] = bi);
  };
  const out = []; const put = (...b) => { for (const x of b) out.push(x & 255); }; const word = (v) => put(v, v >> 8); const str = (t) => { for (const c of t) put(c.charCodeAt(0)); };
  str("GIF89a"); word(w); word(h); put(0xF7, 0, 0); pal.forEach((p) => put(p[0], p[1], p[2]));
  put(0x21, 0xFF, 11); str("NETSCAPE2.0"); put(3, 1, 0, 0, 0); // loop forever
  const delay = Math.round(100 / fps), BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
  const idx = new Uint8Array(w * h);
  frames.forEach((d) => {
    for (let y = 0, p = 0; y < h; y++) for (let x = 0; x < w; x++, p++) {
      const o = (BAYER[(y & 3) * 4 + (x & 3)] - 7.5) * .5, q = (v) => Math.min(255, Math.max(0, d[p * 4 + v] + o)) >> 3;
      const key = (q(0) << 10) | (q(1) << 5) | q(2), v = look[key];
      idx[p] = v >= 0 ? v : nearest(key);
    }
    put(0x21, 0xF9, 4, 0x04); word(delay); put(0, 0);
    put(0x2C); word(0); word(0); word(w); word(h); put(0);
    put(8); lzw(idx, out);
  });
  put(0x3B);
  return new Blob([new Uint8Array(out)], { type: "image/gif" });
}
function lzw(idx, out) {
  const CLEAR = 256, EOI = 257; let size = 9, next = 258, table = new Map(), cur = 0, bits = 0, block = [];
  const flush = () => { out.push(block.length); for (const b of block) out.push(b); block = []; };
  const emit = (c) => { cur |= c << bits; bits += size; while (bits >= 8) { block.push(cur & 255); cur >>>= 8; bits -= 8; if (block.length === 255) flush(); } };
  emit(CLEAR);
  let code = idx[0];
  for (let i = 1; i < idx.length; i++) {
    const k = idx[i], key = (code << 8) | k, e = table.get(key);
    if (e !== undefined) { code = e; continue; }
    emit(code);
    if (next === 4096) { emit(CLEAR); next = 258; size = 9; table = new Map(); }
    else { if (next >= 1 << size) size++; table.set(key, next++); }
    code = k;
  }
  emit(code); emit(EOI);
  if (bits > 0) { block.push(cur & 255); if (block.length === 255) flush(); }
  if (block.length) flush();
  out.push(0);
}
const gifCache = new WeakMap();
function gifOf(m) {
  if (!gifCache.has(m)) gifCache.set(m, (async () => {
    const spec = m.anim || offAnim(), S = 360, svgs = frameSvgs(m.svg, spec);
    const cv = document.createElement("canvas"); cv.width = cv.height = S; const g = cv.getContext("2d", { willReadFrequently: true });
    const frames = [];
    for (const sv of svgs) { const im = await loadImg(svgUrl(sv)); g.fillStyle = "#fff"; g.fillRect(0, 0, S, S); g.drawImage(im, 0, 0, S, S); frames.push(g.getImageData(0, 0, S, S).data); }
    await new Promise((r) => setTimeout(r, 0));
    const blob = encodeGif(frames, S, S, spec.fps);
    return { blob, url: URL.createObjectURL(blob) };
  })());
  const p = gifCache.get(m); p.catch(() => gifCache.delete(m)); return p;
}

  const status = (t) => { $("#status").textContent = t; };
  const fileName = (t, ext) => "V3AI-" + String(t).replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "").slice(0, 40) + ext;
  // A GIF: one picture with its motion, encoded here with the web version's GIF encoder.
  if (FILM && FILM.kind === "gif") {
    const gt = (typeof FILM.title === "string" && FILM.title) || "GIF V3AI";
    document.title = "V3AI · " + gt; $("#title").textContent = gt;
    $("#play").hidden = true; $("#scenes").hidden = true; document.querySelector(".bar").hidden = true;
    const save = $("#save"), msg = $("#msg"); save.textContent = "💾 Скачать GIF"; msg.textContent = "Собираю GIF…";
    const svg = cleanSvg(String(FILM.svg || ""));
    if (!svg) { msg.textContent = "В этом GIF нет картинки — сделай его в V3AI ещё раз."; return; }
    const spec = normAnim({ anim: Array.isArray(FILM.anim) ? FILM.anim : [], frames: FILM.frames, fps: FILM.fps });
    gifOf({ svg, anim: spec }).then((g) => {
      const im = document.createElement("img"); im.src = g.url; im.alt = gt; $("#view").replaceWith(im);
      msg.hidden = true; save.disabled = false;
      status("GIF · " + Math.round(g.blob.size / 1024) + " КБ · крутится по кругу");
      save.addEventListener("click", () => { const a = document.createElement("a"); a.href = g.url; a.download = fileName(gt, ".gif"); document.body.appendChild(a); a.click(); a.remove(); });
    }, () => { msg.textContent = "Не получилось собрать GIF — сделай его ещё раз."; });
    return;
  }
  // the film as V3AI wrote it → safe, bounded scenes for the engine
  const raw = (FILM && Array.isArray(FILM.scenes)) ? FILM.scenes : [];
  const scenes = raw.map((sc) => {
    if (!sc || typeof sc !== "object") return null;
    const dur = clampN(sc.dur, 4, 2, 8), caption = typeof sc.caption === "string" ? sc.caption.slice(0, 80) : "";
    if (sc.three) { const t = norm3d(sc.three); return t ? { three: t, dur, caption } : null; }
    const svg = cleanSvg(String(sc.svg || "")); if (!svg) return null;
    const an = normAnim({ anim: Array.isArray(sc.anim) ? sc.anim : [] });
    return { svg, anim: an ? an.anim : [], dur, loop: clampN(sc.loop, 2, .5, 6), caption };
  }).filter(Boolean);
  const film = { scenes, music: ["happy", "calm", "epic", "none"].includes(FILM && FILM.music) ? FILM.music : "happy" };
  const title = (FILM && typeof FILM.title === "string" && FILM.title) || "Видео V3AI";
  document.title = "V3AI · " + title; $("#title").textContent = title;
  scenes.forEach((sc, i) => { const li = document.createElement("li"); const b = document.createElement("b"); b.textContent = sc.caption || "Сцена " + (i + 1); li.append(b, " · " + sc.dur + " с" + (sc.three ? " · 3D" : "")); $("#scenes").appendChild(li); });

  const view = $("#view"), vg = view.getContext("2d"), msg = $("#msg"), playBtn = $("#play"), saveBtn = $("#save"), prog = $("#prog");
  let R = null, playing = false, out = null, t0 = 0;
  if (!scenes.length) { msg.textContent = "В этом видео нет сцен — сними его в V3AI ещё раз."; return; }

  (async () => {
    try {
      R = await makeFrames(film, 720);
      await R.frame(Math.min(1.2, R.total / 2)); vg.drawImage(R.cv, 0, 0, 720, 720);
      msg.hidden = true; playBtn.disabled = false; saveBtn.disabled = false;
      status("Длительность: " + Math.round(R.total) + " с · сцен: " + scenes.length);
    } catch (e) {
      msg.textContent = e && e.message === "no3d" ? "3D-движок не загрузился. Проверь интернет и обнови страницу." : "Не получилось подготовить видео.";
    }
  })();

  function stop() {
    playing = false; playBtn.textContent = "▶ Смотреть";
    if (out) { try { out.disconnect(); } catch (e) { /* fine */ } out = null; }
  }
  async function tick() {
    if (!playing) return;
    const t = (performance.now() - t0) / 1000;
    if (t >= R.total) { stop(); prog.style.width = "100%"; return; }
    await R.frame(t); vg.drawImage(R.cv, 0, 0, 720, 720);
    prog.style.width = Math.min(100, t / R.total * 100) + "%";
    requestAnimationFrame(tick);
  }
  playBtn.addEventListener("click", () => {
    if (playing) { stop(); return; }
    wakeAudio();
    if (actx && film.music !== "none") { out = actx.createGain(); out.connect(actx.destination); music(actx, out, R.total, film.music); }
    playing = true; t0 = performance.now(); playBtn.textContent = "⏹ Стоп"; tick();
  });
  saveBtn.addEventListener("click", async () => {
    wakeAudio(); stop(); saveBtn.disabled = true; playBtn.disabled = true;
    const p = (k) => { prog.style.width = Math.round(k * 100) + "%"; status("Собираю видео… " + Math.round(k * 100) + "%"); };
    try {
      const v = await fastVideo(film, p).catch(() => recordVideo(film, p));
      const a = document.createElement("a"); a.href = v.url; a.download = fileName(title, /mp4/.test(v.blob.type) ? ".mp4" : ".webm");
      document.body.appendChild(a); a.click(); a.remove();
      status("Готово: видео скачивается (" + Math.round(v.blob.size / 1024) + " КБ).");
    } catch (e) {
      status(e && e.message === "norec" ? "Этот браузер не умеет записывать видео — открой файл в Chrome или Edge." : "Не получилось собрать видео — попробуй ещё раз.");
    }
    saveBtn.disabled = false; playBtn.disabled = false;
  });
})();
</script>
</body>
</html>

'@

# ── GIF: картинка с движением → страница, которая собирает GIF (кодировщик — из веб-версии) ──
function Invoke-V3Gif($Chat, [string]$Q) {
  $prev = Get-V3Prop $Chat 'lastGif' ''
  $prompt = @(
    'Ты — V3AI, ИИ-аниматор. Сделай по описанию пользователя короткую зацикленную анимацию для GIF.',
    'Шаг 1 — картинка: ОДНО SVG <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">, яркое и детальное, на весь холст (фон, главный объект крупно, градиенты, тени). Каждую часть, которая будет двигаться, оберни в <g id="..."> с латинским id (например "cat", "paw", "tail", "eyes", "star1").',
    'Запрещено в SVG: script, foreignObject, image, ссылки, внешние шрифты, теги animate/set, CSS-анимация, обработчики событий. Текст — только если его явно попросили.',
    'Шаг 2 — движение: блок ```json вида {"frames":24,"fps":12,"anim":[{"id":"paw","origin":[300,260],"keys":[{"t":0,"r":0},{"t":0.5,"r":-30},{"t":1,"r":0}]}]}.',
    'Поля ключа: t — время от 0 до 1; x, y — сдвиг в пикселях; r — поворот в градусах вокруг origin (шарнир в координатах viewBox); s — масштаб (или sx и sy отдельно); o — прозрачность 0..1. Не указанное поле = покой.',
    'Первый и последний ключ каждой части одинаковые, чтобы GIF шёл по кругу без рывка. Двигай 2–8 частей заметно и живо: махание, прыжки, полёт, вращение, моргание (sy до 0.1), мерцание. frames 16–32, fps 8–15.',
    'Юмор приветствуется, в том числе мультяшный туалетный: какашка-смайлик 💩, пуки, лужи — смешно и без натурализма. Нельзя: кровь, жестокость, взрослые темы и насмешки или унижение конкретных людей по имени (это может обидеть настоящего человека). Если в просьбе есть такое — сделай смешную безопасную версию (например, вместо человека забавный персонаж) и ОБЯЗАТЕЛЬНО коротко и честно скажи в ответной фразе, что изменил и почему. Никогда не меняй просьбу молча.',
    $(if ($prev) { "Предыдущая работа в этом чате была по запросу «$prev». Если новый запрос — правка («быстрее», «пусть ещё и прыгает»), сделай ту же сцену с изменением." } else { '' }),
    'Ответ: блок ```svg, затем блок ```json, затем одна короткая весёлая фраза по-русски о том, что получилось. Если что-то в просьбе пришлось изменить — прямо скажи об этом в этой фразе.',
    "Описание анимации: $Q"
  ) -join "`n"
  $msgs = New-V3List; $msgs.Add([ordered]@{ role = 'user'; content = $prompt })
  $r = Invoke-V3Turn -Messages $msgs -System 'Ты — V3AI, ИИ-аниматор.' -Quiet -Waiting '🎞 рисую GIF…'
  $sm = [regex]::Match($r.Text, '<svg[\s\S]*?</svg>', 'IgnoreCase')
  if (-not $sm.Success) { Write-V3Note 'GIF не получился — попробуй ещё раз или опиши иначе.' Yellow; return }
  $anim = @(); $frames = 24; $fps = 12
  $js = Get-V3Block $r.Text 'json'
  if ($js) { try { $a = $js | ConvertFrom-Json; if ($a.anim) { $anim = @($a.anim) }; if ($a.frames) { $frames = [int]$a.frames }; if ($a.fps) { $fps = [double]$a.fps } } catch { } }
  $cap = ([regex]::Replace($r.Text, '```[\s\S]*?(```|$)', '')).Trim()
  $title = $(if ($Q.Length -gt 40) { $Q.Substring(0, 40) } else { $Q })
  $film = [ordered]@{ kind = 'gif'; title = $title; svg = $sm.Value; anim = $anim; frames = $frames; fps = $fps }
  $html = $script:PlayerTemplate.Replace('/*V3AI_FILM*/null', (ConvertTo-V3Json $film).Replace('</', '<\/'))
  $path = Save-V3File $script:Paths.Gif ((Get-V3SafeName $title) + '.html') $html
  Write-V3Box "🎞 $title" @($(if ($cap) { $cap } else { 'GIF готов!' }), "Движущихся частей: $($anim.Count) · кадров: $frames", $(if ($path) { "Файл: $path" } else { 'Файл не сохранён (EngineSecure).' }), 'На странице: анимация и 💾 Скачать GIF.') Magenta
  if ($path) { Open-V3File $path }
  $Chat['lastGif'] = $Q
  $Chat.messages.Add([ordered]@{ role = 'user'; content = $Q })
  $Chat.messages.Add([ordered]@{ role = 'assistant'; content = "(Сделал GIF-анимацию по запросу «$Q».) $cap" })
}

# ── V3AI Design: три варианта логотипа → страница-доска (PNG с прозрачным фоном и SVG) ────────
function Invoke-V3Logo($Chat, [string]$Q) {
  $prev = Get-V3Prop $Chat 'lastLogos' $null
  $prompt = @(
    'Ты — V3AI Design, дизайнер логотипов. Сделай по запросу пользователя 3 РАЗНЫХ варианта логотипа (разные идеи знака, формы и палитры).',
    'Каждый вариант — ОДНО SVG <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"> в своём блоке ```svg, до ~3500 символов. Перед каждым блоком строка «Вариант N: короткое название идеи».',
    'Правила хорошего логотипа: простой запоминающийся знак (символ, монограмма или эмблема) и название, если оно есть в запросе; 2–4 цвета; плоский векторный стиль, чёткие формы, без мелких деталей — логотип должен читаться и в маленьком размере. Прозрачный фон: НЕ заливай весь холст, знак по центру с полями.',
    'Текст — только системными шрифтами: font-family="Arial, sans-serif", "Arial Black, Arial, sans-serif" или "Georgia, serif"; крупный и читаемый; название пиши точно как в запросе.',
    'Запрещено в SVG: script, foreignObject, image, ссылки, внешние шрифты, анимация, обработчики событий.',
    'Юмор приветствуется, в том числе мультяшный туалетный: какашка-смайлик 💩, пуки, лужи — смешно и без натурализма. Нельзя: кровь, жестокость, взрослые темы и насмешки или унижение конкретных людей по имени (это может обидеть настоящего человека). Если в просьбе есть такое — сделай смешную безопасную версию (например, вместо человека забавный персонаж) и ОБЯЗАТЕЛЬНО коротко и честно скажи в ответной фразе, что изменил и почему. Никогда не меняй просьбу молча.',
    $(if ($prev) { "Прошлые логотипы в этом чате: $prev. Если новый запрос — доработка (например «доработай вариант 2: сделай синим»), сделай 3 версии доработанного варианта." } else { '' }),
    'В самом конце — одна короткая фраза по-русски о вариантах. Если что-то в просьбе пришлось изменить — прямо скажи об этом в этой фразе.',
    "Запрос: $Q"
  ) -join "`n"
  $msgs = New-V3List; $msgs.Add([ordered]@{ role = 'user'; content = $prompt })
  $r = Invoke-V3Turn -Messages $msgs -System 'Ты — V3AI Design, дизайнер логотипов.' -Quiet -Waiting '✒ рисую логотипы…'
  $names = @([regex]::Matches($r.Text, 'Вариант\s*\d+\s*[:.—-]\s*([^\r\n`]+)') | ForEach-Object { $_.Groups[1].Value.Trim(' *«»') })
  $logos = New-V3List; $k = 0
  foreach ($m in [regex]::Matches($r.Text, '```svg\s*([\s\S]*?)```', 'IgnoreCase')) {
    $svg = Clear-V3Svg $m.Groups[1].Value
    if ($svg) { $logos.Add([ordered]@{ name = $(if ($k -lt $names.Count) { $names[$k] } else { '' }); svg = $svg }) }
    $k++
  }
  if (-not $logos.Count) { Write-V3Note 'Логотипы не получились — попробуй ещё раз или модель посильнее (/model).' Yellow; return }
  $cap = ([regex]::Replace(([regex]::Replace($r.Text, '```[\s\S]*?(```|$)', '')), 'Вариант\s*\d+\s*[:.—-][^\r\n]*', '')).Trim()
  $title = $(if ($Q.Length -gt 40) { $Q.Substring(0, 40) } else { $Q })
  $board = [ordered]@{ title = $title; note = $cap; logos = $logos }
  $html = $script:LogoTemplate.Replace('/*V3AI_LOGOS*/null', (ConvertTo-V3Json $board).Replace('</', '<\/'))
  $path = Save-V3File $script:Paths.Design ((Get-V3SafeName $title) + '.html') $html
  $lines = @()
  if ($cap) { $lines += $cap }
  for ($i = 0; $i -lt $logos.Count; $i++) { $lines += "$($i + 1). $(if ($logos[$i].name) { $logos[$i].name } else { 'Вариант' })" }
  $lines += $(if ($path) { "Файл: $path" } else { 'Файл не сохранён (EngineSecure).' })
  $lines += 'На странице: фон (светлый, тёмный, шахматка), 💾 PNG с прозрачным фоном и SVG. Доработка: «доработай вариант 2: …»'
  Write-V3Box "✒ $title" $lines Magenta
  if ($path) { Open-V3File $path }
  $Chat['lastLogos'] = (@(for ($i = 0; $i -lt $logos.Count; $i++) { "$($i + 1) — $($logos[$i].name)" }) -join ', ') + " (запрос «$Q»)"
  $Chat.messages.Add([ordered]@{ role = 'user'; content = $Q })
  $Chat.messages.Add([ordered]@{ role = 'assistant'; content = "(V3AI Design нарисовал логотипы по запросу «$Q».) $cap" })
}

# Доска с вариантами логотипа.
$script:LogoTemplate = @'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>V3AI Design</title>
<style>
:root { --bg: #0b1020; --panel: #121a30; --line: #263049; --fg: #eef2ff; --muted: #9aa6c4; }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; background: var(--bg); color: var(--fg); font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 1100px; margin: 0 auto; padding: 24px 16px 40px; display: flex; flex-direction: column; gap: 16px; }
header { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; }
.logo { font: 900 22px/1 "Segoe UI", system-ui, sans-serif; letter-spacing: 1px; background: linear-gradient(90deg, #00b4ff, #7dffcf); -webkit-background-clip: text; background-clip: text; color: transparent; }
h1 { margin: 0; font-size: 18px; }
p { margin: 0; color: var(--muted); }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 14px; }
.tile { display: flex; flex-direction: column; gap: 10px; padding: 12px; border-radius: 16px; border: 1px solid var(--line); background: var(--panel); }
.pic { aspect-ratio: 1; border-radius: 12px; display: grid; place-items: center; overflow: hidden; background: #fff; }
.pic img { width: 92%; height: 92%; object-fit: contain; }
.pic.dark { background: #0d1117; } .pic.check { background: repeating-conic-gradient(#d9dee8 0 25%, #ffffff 0 50%) 0 0 / 20px 20px; }
.row { display: flex; flex-wrap: wrap; gap: 8px; }
button { flex: 1 1 auto; min-height: 44px; padding: 8px 12px; border-radius: 12px; border: 1px solid var(--line); background: #1a2440; color: var(--fg); font: inherit; font-weight: 700; cursor: pointer; }
button:focus-visible { outline: 3px solid #7dffcf; outline-offset: 2px; }
</style>
</head>
<body>
<main>
  <header><span class="logo">V3AI</span><h1 id="title">Design</h1></header>
  <p id="note"></p>
  <div class="grid" id="grid"></div>
</main>
<script>
const BOARD = /*V3AI_LOGOS*/null;
(() => {
  "use strict";
  const data = BOARD || { title: "Логотипы", logos: [] };
  const url = (svg) => "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
  const file = (i, ext) => "V3AI-logo-" + String(data.title).replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "").slice(0, 30) + "-" + (i + 1) + ext;
  const save = (blob, name) => { const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click(); a.remove(); };
  document.title = "V3AI Design · " + data.title; document.getElementById("title").textContent = data.title;
  document.getElementById("note").textContent = data.note || "Три варианта логотипа. PNG — 1024×1024 с прозрачным фоном.";
  const BG = ["", "dark", "check"];
  (data.logos || []).forEach((L, i) => {
    const tile = document.createElement("div"); tile.className = "tile";
    const pic = document.createElement("div"); pic.className = "pic";
    const im = document.createElement("img"); im.src = url(L.svg); im.alt = "Логотип, вариант " + (i + 1); pic.appendChild(im);
    const name = document.createElement("b"); name.textContent = (i + 1) + ". " + (L.name || "Вариант");
    const row = document.createElement("div"); row.className = "row";
    const btn = (t, fn) => { const b = document.createElement("button"); b.type = "button"; b.textContent = t; b.addEventListener("click", fn); row.appendChild(b); };
    let bg = 0;
    btn("🌓 Фон", () => { bg = (bg + 1) % BG.length; pic.className = "pic " + BG[bg]; });
    btn("💾 PNG", () => { const c = document.createElement("canvas"); c.width = c.height = 1024; const g = new Image(); g.onload = () => { c.getContext("2d").drawImage(g, 0, 0, 1024, 1024); c.toBlob((b) => save(b, file(i, ".png")), "image/png"); }; g.src = url(L.svg); });
    btn("SVG", () => save(new Blob([L.svg], { type: "image/svg+xml" }), file(i, ".svg")));
    tile.append(pic, name, row); document.getElementById("grid").appendChild(tile);
  });
})();
</script>
</body>
</html>
'@

# ── Фото, голос, буфер обмена ──────────────────────────────────────────────────────────────────
function Get-V3Photo([string[]]$Words) {
  for ($k = $Words.Count; $k -ge 1; $k--) {
    $cand = ($Words[0..($k - 1)] -join ' ').Trim('"', "'")
    if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) {
      $ext = [IO.Path]::GetExtension($cand).ToLower()
      $type = @{ '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.png' = 'image/png'; '.gif' = 'image/gif'; '.webp' = 'image/webp' }[$ext]
      if (-not $type) { throw 'Подходят только фото JPG, PNG, GIF или WEBP.' }
      $full = (Resolve-Path -LiteralPath $cand).Path
      if ((Get-Item -LiteralPath $full).Length -gt 5242880) { throw 'Фото больше 5 МБ — уменьши его и попробуй снова.' }
      if (-not (Request-V3Permission 'photo' "Файл: $full")) { return $null }
      $q = $(if ($k -lt $Words.Count) { ($Words[$k..($Words.Count - 1)] -join ' ') } else { 'Что на этом фото?' })
      return @{ Question = $q; Block = [ordered]@{ type = 'image'; source = [ordered]@{ type = 'base64'; media_type = $type; data = [Convert]::ToBase64String([IO.File]::ReadAllBytes($full)) } } }
    }
  }
  throw 'Файл не найден. Пример: /photo C:\Фото\кот.jpg Что за порода?'
}

function Get-V3LastAnswer($Chat) {
  for ($i = $Chat.messages.Count - 1; $i -ge 0; $i--) {
    $m = $Chat.messages[$i]; if ($m.role -ne 'assistant') { continue }
    $t = $(if ($m.content -is [string]) { $m.content } else { (@($m.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n" })
    if ($t.Trim()) { return $t }
  }
  return ''
}

function Invoke-V3Say($Chat, [string]$Arg) {
  if ($Arg -eq 'stop') { if ($script:Voice) { try { [void]$script:Voice.Speak('', 2) } catch { } }; return }
  $t = Get-V3LastAnswer $Chat
  if (-not $t) { Write-V3Note 'Пока нечего озвучить.'; return }
  $t = ([regex]::Replace($t, '```[\s\S]*?(```|$)', ' (код) ') -replace '[*#`>|]', '').Trim()
  if ($t.Length -gt 2000) { $t = $t.Substring(0, 2000) }
  try {
    if ($IsMacOS) { & say $t; return }
    if ($IsLinux) {
      foreach ($c in @('spd-say', 'espeak-ng', 'espeak')) { if (Get-Command $c -ErrorAction SilentlyContinue) { & $c $t; return } }
      Write-V3Note 'Не нашёл синтез речи. Установи, например, espeak-ng.' Yellow; return
    }
    if (-not $script:Voice) {
      $script:Voice = New-Object -ComObject SAPI.SpVoice
      $vs = $script:Voice.GetVoices()
      for ($i = 0; $i -lt $vs.Count; $i++) { $v = $vs.Item($i); if ($v.GetAttribute('Language') -match '(^|;)419($|;)') { $script:Voice.Voice = $v; break } }
    }
    [void]$script:Voice.Speak($t, 3)   # асинхронно, прерывая прошлую озвучку
    Write-V3Note '🔊 Озвучиваю… (/say stop — остановить)'
  } catch { Write-V3Note 'Озвучка не получилась на этом компьютере.' Yellow }
}

function Copy-V3Answer($Chat) {
  $t = Get-V3LastAnswer $Chat
  if (-not $t) { Write-V3Note 'Пока нечего копировать.'; return }
  try { Set-Clipboard -Value $t; Write-V3Note '📋 Скопировано.' Green } catch { Write-V3Note 'Буфер обмена недоступен (на Linux нужен xclip или wl-clipboard).' Yellow }
}

# ── Проводник подключённого репозитория ────────────────────────────────────────────────────────
function Show-V3RepoFiles($Chat, [string]$Path) {
  if (-not $Chat.repo) { Write-V3Note 'Репозиторий не подключён. Пришли ссылку на GitHub.'; return }
  try { $items = @(Get-V3RepoDir $Chat.repo $Path) } catch { Write-V3Note "🐙 $($_.Exception.Message)" Yellow; return }
  Write-V3Rule ("🐙 /" + $Path.Trim('/'))
  foreach ($f in $items | Select-Object -First 100) {
    if ($f.type -eq 'dir') { Write-Host "   📁 $($f.name)/" -ForegroundColor Cyan } else { Write-Host ("   📄 $($f.name)".PadRight(48)) -NoNewline; Write-Host (Format-V3Size $f.size) -ForegroundColor DarkGray }
  }
  if ($items.Count -gt 100) { Write-V3Note "… и ещё $($items.Count - 100)" }
  Write-V3Note 'Папка: /files <путь>   ·   файл: /cat <путь>'
}

function Show-V3RepoFile($Chat, [string]$Path) {
  if (-not $Chat.repo) { Write-V3Note 'Репозиторий не подключён. Пришли ссылку на GitHub.'; return }
  if (-not $Path) { Write-V3Note 'Пример: /cat README.md'; return }
  try { $t = Get-V3RepoFile $Chat.repo $Path } catch { Write-V3Note "🐙 $($_.Exception.Message)" Yellow; return }
  if ($null -eq $t) { Write-V3Note 'Это двоичный файл (картинка, видео или архив) — показать нельзя.'; return }
  $lines = $t -split "`n"
  Write-Host "  ┌─ $Path" -ForegroundColor DarkYellow
  for ($i = 0; $i -lt [Math]::Min(200, $lines.Count); $i++) { Write-Host ('  │ ' + ($i + 1).ToString().PadLeft(4) + '  ') -NoNewline -ForegroundColor DarkYellow; Write-Host $lines[$i].TrimEnd("`r") -ForegroundColor Yellow }
  Write-Host '  └─' -ForegroundColor DarkYellow
  if ($lines.Count -gt 200) { Write-V3Note "Показаны первые 200 строк из $($lines.Count). Спроси V3AI о файле — он прочитает его целиком." }
}

# ── Dr. Agents ────────────────────────────────────────────────────────────────────────────────
$script:Skills = [ordered]@{ memory = '🧠 Память'; tasks = '✅ Список дел'; calc = '🧮 Калькулятор'; time = '🕐 Дата и время'; dice = '🎲 Случайности' }

function Get-V3Agents { $a = Read-V3Json $script:Paths.Agents; if ($a -is [System.Collections.IList]) { return , $a } ; return , (New-V3List) }
function Save-V3Agents($List) { Save-V3Json $script:Paths.Agents $List }
function Get-V3AgentById([string]$Id) { foreach ($a in (Get-V3Agents)) { if ($a.id -eq $Id) { return $a } }; return $null }
function Get-V3Mem($A) { $p = Join-Path $script:Paths.Memory ($A.id + '.json'); $m = Read-V3Json $p; if (-not $m) { $m = [ordered]@{ notes = (New-V3List); tasks = (New-V3List) } }; foreach ($k in 'notes', 'tasks') { if (-not ($m[$k] -is [System.Collections.IList])) { $m[$k] = New-V3List } }; return $m }
function Save-V3Mem($A, $M) { Save-V3Json (Join-Path $script:Paths.Memory ($A.id + '.json')) $M }

function Show-V3AgentCard($A) {
  $sk = ($A.skills | ForEach-Object { $script:Skills[$_] }) -join '  '
  Write-V3Box "$($A.emoji) $($A.name) — $($A.role)" @("Навыки: $sk", "«$($A.greeting)»") Magenta
}

function Show-V3Agents {
  $list = Get-V3Agents
  Write-V3Rule '🩺 Dr. Agents — мои агенты'
  if (-not $list.Count) { Write-V3Note 'Агентов пока нет. Включи режим Dr. Agents (/mode agents) и опиши, какой помощник нужен.'; return }
  for ($i = 0; $i -lt $list.Count; $i++) { $a = $list[$i]; Write-Host ("   $($i + 1). $($a.emoji) ") -NoNewline; Write-Host $a.name -NoNewline -ForegroundColor White; Write-Host "  — $($a.role)" -ForegroundColor DarkGray }
  Write-V3Note 'Чат с агентом: /agent <номер>   ·   удалить: /agent <номер> delete'
}

function New-V3Agent($Chat, [string]$Q, $Old = $null) {
  $prompt = @(
    'Ты — Dr. Agents, конструктор ИИ-агентов в V3AI. По просьбе пользователя спроектируй агента — ИИ-помощника с характером.',
    'Навыки (инструменты), которые агент сможет вызывать: memory — запоминать и вспоминать факты о пользователе; tasks — вести список дел; calc — точно считать; time — узнавать дату и время; dice — случайные числа и жребий. Выбери только нужные (1–5).',
    'Агент должен быть добрым и подходить детям. Юмор приветствуется, в том числе мультяшный туалетный: какашка-смайлик 💩, пуки, лужи — смешно и без натурализма. Нельзя: кровь, жестокость, взрослые темы и насмешки или унижение конкретных людей по имени (это может обидеть настоящего человека). Если в просьбе есть такое — сделай смешную безопасную версию (например, вместо человека забавный персонаж) и ОБЯЗАТЕЛЬНО коротко и честно скажи в ответной фразе, что изменил и почему. Никогда не меняй просьбу молча. Пиши об изменениях в comment.',
    $(if ($Old) { "Вот текущий агент: $(ConvertTo-V3Json $Old)`nИзмени его по просьбе пользователя и верни всего агента целиком в том же формате." } else { '' }),
    'Ответь ТОЛЬКО JSON без пояснений: {"name":"короткое имя","emoji":"один эмодзи","role":"роль до 60 символов","greeting":"первое сообщение пользователю в характере агента","instructions":"инструкция агенту 6–12 предложений: кто он, как говорит, что делает, когда использует навыки, чего не делает","skills":["memory","tasks"],"comment":"одна весёлая фраза о созданном агенте"}',
    "Запрос: $Q"
  ) -join "`n"
  $msgs = New-V3List; $msgs.Add([ordered]@{ role = 'user'; content = $prompt })
  $r = Invoke-V3Turn -Messages $msgs -System 'Ты — Dr. Agents.' -Quiet -Waiting '🩺 собираю агента…' -MaxTokens 16000
  $m = [regex]::Match($r.Text, '\{[\s\S]*\}')
  $j = $null; if ($m.Success) { try { $j = ConvertTo-V3Hash ($m.Value | ConvertFrom-Json) } catch { } }
  if (-not $j -or -not $j.name) { Write-V3Note 'Не получилось собрать агента — попробуй описать иначе.' Yellow; return }
  $skills = @(@($j.skills) | Where-Object { $script:Skills.Contains([string]$_) } | Select-Object -Unique)
  if (-not $skills.Count) { $skills = @('time') }
  $A = [ordered]@{
    id = 'a' + (Get-Date -Format 'yyyyMMddHHmmss') + (Get-Random -Maximum 99); name = ([string]$j.name).Substring(0, [Math]::Min(40, ([string]$j.name).Length))
    emoji = $(if ($j.emoji) { [string]$j.emoji } else { '🤖' }); role = [string]$j.role; greeting = $(if ($j.greeting) { [string]$j.greeting } else { "Привет! Я $($j.name)." })
    instructions = [string]$j.instructions; skills = $skills
  }
  $list = Get-V3Agents
  if ($Old) {
    $A.id = $Old.id
    for ($k = 0; $k -lt $list.Count; $k++) { if ($list[$k].id -eq $Old.id) { $list[$k] = $A } }
  } else { $list.Insert(0, $A) }
  Save-V3Agents $list
  if ($j.comment) { Write-V3Line ([string]$j.comment) }
  Show-V3AgentCard $A
  Write-V3Note $(if ($Old) { "✏️ Агент обновлён. Его память сохранилась." } else { 'Начать чат с ним: /agent 1' })
  $Chat.messages.Add([ordered]@{ role = 'user'; content = $Q })
  $Chat.messages.Add([ordered]@{ role = 'assistant'; content = "(Dr. Agents создал агента «$($A.name)».)" })
}

function Get-V3AgentTools($A) {
  $e = $true; $t = @()
  if ($A.skills -contains 'memory') {
    $t += [ordered]@{ name = 'remember'; description = 'Запомнить факт о пользователе или важную информацию надолго.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ key = @{ type = 'string' }; text = @{ type = 'string' } }; required = @('text') } }
    $t += [ordered]@{ name = 'recall'; description = 'Вспомнить сохранённые заметки. Пустой query — все.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ query = @{ type = 'string' } } } }
  }
  if ($A.skills -contains 'tasks') {
    $t += [ordered]@{ name = 'add_task'; description = 'Добавить дело в список.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ text = @{ type = 'string' } }; required = @('text') } }
    $t += [ordered]@{ name = 'list_tasks'; description = 'Показать список дел с номерами.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{} } }
    $t += [ordered]@{ name = 'complete_task'; description = 'Отметить дело выполненным по номеру.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ n = @{ type = 'integer' } }; required = @('n') } }
  }
  if ($A.skills -contains 'calc') { $t += [ordered]@{ name = 'calculate'; description = 'Точно вычислить выражение: + - * / % и скобки.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ expression = @{ type = 'string' } }; required = @('expression') } } }
  if ($A.skills -contains 'time') { $t += [ordered]@{ name = 'get_time'; description = 'Текущие дата, время и день недели.'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{} } } }
  if ($A.skills -contains 'dice') { $t += [ordered]@{ name = 'random'; description = 'Случайные целые числа от min до max (count штук).'; eager_input_streaming = $e; input_schema = [ordered]@{ type = 'object'; properties = [ordered]@{ min = @{ type = 'integer' }; max = @{ type = 'integer' }; count = @{ type = 'integer' } }; required = @('min', 'max') } } }
  return $t
}

function Invoke-V3AgentTool($A, [string]$Name, $In) {
  $mem = Get-V3Mem $A
  switch ($Name) {
    'remember' { $k = [string](Get-V3Prop $In 'key' ''); $keep = New-V3List; foreach ($x in $mem.notes) { if (-not $k -or $x.k -ne $k) { $keep.Add($x) } }; $keep.Add([ordered]@{ k = $k; t = [string](Get-V3Prop $In 'text' '') }); $mem.notes = $keep; Save-V3Mem $A $mem; return @{ ok = $true; saved = $keep.Count } }
    'recall' { $q = ([string](Get-V3Prop $In 'query' '')).ToLower(); return @{ notes = @($mem.notes | Where-Object { -not $q -or ("$($_.k) $($_.t)").ToLower().Contains($q) } | ForEach-Object { @{ key = $_.k; text = $_.t } }) } }
    'add_task' { $mem.tasks.Add([ordered]@{ t = [string](Get-V3Prop $In 'text' ''); done = $false }); Save-V3Mem $A $mem; return @{ ok = $true; count = $mem.tasks.Count } }
    'list_tasks' { $i = 0; return @{ tasks = @($mem.tasks | ForEach-Object { $i++; @{ n = $i; text = $_.t; done = [bool]$_.done } }) } }
    'complete_task' { $n = [int](Get-V3Prop $In 'n' 0); if ($n -lt 1 -or $n -gt $mem.tasks.Count) { throw 'нет такого дела' }; $mem.tasks[$n - 1].done = $true; Save-V3Mem $A $mem; return @{ ok = $true } }
    'calculate' { return @{ result = (Invoke-V3Calc ([string](Get-V3Prop $In 'expression' ''))) } }
    'get_time' { $c = [Globalization.CultureInfo]::GetCultureInfo('ru-RU'); $d = Get-Date; return @{ date = $d.ToString('d MMMM yyyy', $c); time = $d.ToString('HH:mm'); weekday = $d.ToString('dddd', $c) } }
    'random' { $a = [int](Get-V3Prop $In 'min' 1); $b = [int](Get-V3Prop $In 'max' 6); if ($a -gt $b) { $a, $b = $b, $a }; $n = [Math]::Min(20, [Math]::Max(1, [int](Get-V3Prop $In 'count' 1))); return @{ numbers = @(1..$n | ForEach-Object { Get-Random -Minimum $a -Maximum ($b + 1) }) } }
  }
  throw "Неизвестный инструмент $Name"
}

function Get-V3AgentRules($A) {
  $M = Get-V3Model $script:Cfg.model
  $sk = ($A.skills | ForEach-Object { $script:Skills[$_] }) -join ', '
  return @(
    "Ты — $($A.name) $($A.emoji), ИИ-агент, созданный в конструкторе Dr. Agents (V3AI для PowerShell). Твоя роль: $($A.role).",
    [string]$A.instructions,
    "Твои навыки — инструменты: $sk. Пользуйся ими сам, когда они помогают: точные расчёты — через калькулятор, важные факты о пользователе — запоминай.",
    "Отвечай на языке пользователя (по умолчанию по-русски), живо и в своём характере, до $($M.len) слов. Можно **жирный** и списки, без таблиц.",
    'С тобой могут говорить дети: никаких взрослых, опасных или грубых тем. Не проси пароли и личные данные.',
    'Сегодня ' + (Get-Date).ToString('dddd, d MMMM yyyy', [Globalization.CultureInfo]::GetCultureInfo('ru-RU')) + '.'
  ) -join "`n"
}

# ── Обычный ответ (с репозиторием или агентом) ────────────────────────────────────────────────
function Invoke-V3Chat($Chat, [string]$Q, $Image = $null) {
  if ($Image) { $Chat.messages.Add([ordered]@{ role = 'user'; content = @($Image, [ordered]@{ type = 'text'; text = $Q }) }) }
  else { $Chat.messages.Add([ordered]@{ role = 'user'; content = $Q }) }
  $A = $null; if ($Chat.agent) { $A = Get-V3AgentById $Chat.agent }
  $tools = @(); $handler = $null
  $script:Ctx = @{ Agent = $A; Repo = $Chat.repo }
  if ($A) { $system = Get-V3AgentRules $A; $tools = @(Get-V3AgentTools $A) }
  else { $system = Get-V3Rules (Get-V3Mode $Chat.mode) }
  if ($Chat.repo) { $system += Get-V3RepoRules $Chat; $tools = @($tools) + @(Get-V3RepoTools) }
  if ($tools.Count) {
    $handler = {
      param($name, $in)
      if ($name -in @('list_dir', 'read_file', 'list_commits', 'list_branches', 'list_issues', 'list_pull_requests') -and $script:Ctx.Repo) { return Invoke-V3RepoTool $script:Ctx.Repo $name $in }
      if ($script:Ctx.Agent) { return Invoke-V3AgentTool $script:Ctx.Agent $name $in }
      throw "Неизвестный инструмент $name"
    }
  }
  if ($script:T.box -eq 'heavy') { Write-Host ('  ◆ ' + $(if ($A) { "$($A.emoji) $($A.name)" } else { 'V3AI' })) -ForegroundColor $script:T.acc }
  $Mh = Get-V3Model $script:Cfg.model
  if ($script:T.box -eq 'panel') { Write-V3Frame ('ответ · ' + $(if ($A) { "$($A.emoji) $($A.name)" } else { $Mh.n })); $script:InPanel = $true; $script:Ln = 0 }
  try {
  $r = Invoke-V3Turn -Messages $Chat.messages -System $system -Tools $tools -Handler $handler -Waiting $(if ($A) { "$($A.name) думает…" } else { 'думает…' })
  $M = Get-V3Model $script:Cfg.model
  $tag = $(if ($A) { "$($A.name) · $($M.n)" } else { $M.n })
  if ($r.Used.Count) { $tag += ' · 🧰 ' + ($r.Used -join ', ') }
  } finally { $script:InPanel = $false }
  if ($script:T.box -eq 'panel') {
    Write-V3X ('  ╰' + ('─' * ((Get-V3Width) - 3))) dim
    Write-V3X '  ◆ ' orange -NoNewline; Write-V3X ('готово · ' + $tag) dim
    Write-V3Hints
    return
  }
  Write-Host $(if ($script:T.box -eq 'heavy') { "  ╰ $tag" } else { "  — $tag" }) -ForegroundColor DarkGray
}

# ── Команды ───────────────────────────────────────────────────────────────────────────────────
function Show-V3Help {
  Write-V3Rule 'Команды'
  $rows = @(
    @('/chat [вопрос]', 'обычный чат (без вопроса — переключиться в него)'),
    @('/image <описание>', 'нарисовать картинку (без описания — режим «Художник»)'),
    @('/video <сюжет>', 'снять 3D-видео; /video 2d <сюжет> — рисованное 2D'),
    @('/watt <описание>', 'WattAI: сделать игру (без описания — режим WattAI)'),
    @('/gif <описание>', 'анимированный GIF'),
    @('/design <описание>', 'V3AI Design: 3 варианта логотипа (то же: /logo)'),
    @('/photo <файл> [вопрос]', 'спросить ИИ о фото'),
    @('/again', 'ещё вариант последнего запроса'),
    @('/say', 'озвучить последний ответ (/say stop — замолчать)   /copy — скопировать его'),
    @('/files [папка]', 'файлы подключённого репозитория   /cat <файл> — показать файл'),
    @('/mode [имя]', 'режим: help, school, write, lang, code, fun, art, design, game, video, agents'),
    @('/model [номер]', 'выбрать модель V3AI'),
    @('/new', 'новый чат        /chats — история        /open <номер> — открыть'),
    @('/export', 'сохранить чат в файл .md'),
    @('<ссылка github>', 'подключить репозиторий (или /github <ссылка>)'),
    @('/github login', 'войти в GitHub (закрытые репозитории)   /github logout — выйти'),
    @('/repo', 'карточка репозитория   /disconnect — отключить'),
    @('/agents', 'мои агенты           /agent <номер> — чат с агентом'),
    @('/agent <n> memory', 'память агента;  forget — очистить;  edit <что изменить> — изменить'),
    @('/secure', 'EngineSecure: разрешения'),
    @('/key', 'ввести ключ Claude API'),
    @('/theme [studio|sunset|neon]', 'тема оформления'),
    @('/clear', 'очистить экран      /exit — выход'),
    @('Esc / Ctrl+C', 'во время ответа — остановить'),
    @('строка с \ в конце', 'продолжить ввод на следующей строке')
  )
  foreach ($r in $rows) { Write-Host ('   ' + $r[0].PadRight(22)) -NoNewline -ForegroundColor $script:T.acc; Write-Host $r[1] -ForegroundColor Gray }
  Write-V3Note 'Голосовой ввод (микрофон) есть только в веб-версии V3AI.'
}

function Show-V3Models {
  Write-V3Rule '🧠 Модели V3AI'
  for ($i = 0; $i -lt $script:Models.Count; $i++) {
    $m = $script:Models[$i]; $on = $m.id -eq $script:Cfg.model
    Write-Host ($(if ($on) { ' ▶ ' } else { '   ' }) + ($i + 1) + '. ') -NoNewline -ForegroundColor $(if ($on) { $script:T.acc2 } else { 'DarkGray' })
    Write-Host $m.n.PadRight(15) -NoNewline -ForegroundColor White
    Write-Host $m.tag.PadRight(11) -NoNewline -ForegroundColor $script:T.acc
    Write-Host $m.d -ForegroundColor Gray
  }
  Write-V3Note 'Выбрать: /model <номер>'
}

function Show-V3Modes {
  Write-V3Rule '🎛 Режимы'
  foreach ($m in $script:Modes) {
    $on = $m.id -eq $script:Cfg.mode
    Write-Host ($(if ($on) { ' ▶ ' } else { '   ' }) + "$($m.ico) ") -NoNewline -ForegroundColor $(if ($on) { $script:T.acc2 } else { 'DarkGray' })
    Write-Host $m.n.PadRight(12) -NoNewline -ForegroundColor White
    Write-Host "/mode $($m.id)" -ForegroundColor DarkGray
  }
}

function Show-V3Chats {
  $files = Get-V3Chats
  Write-V3Rule '🗂 История чатов'
  if (-not $files.Count) { Write-V3Note 'Пока пусто.'; return }
  for ($i = 0; $i -lt $files.Count; $i++) {
    $c = Read-V3Json $files[$i].FullName
    $t = $(if ($c -and $c.title) { $c.title } else { '(без названия)' })
    Write-Host ("   $($i + 1). ") -NoNewline -ForegroundColor DarkGray; Write-Host $t -NoNewline; Write-Host ('  ' + $files[$i].LastWriteTime.ToString('dd.MM HH:mm')) -ForegroundColor DarkGray
  }
  Write-V3Note 'Открыть: /open <номер>'
}

function Export-V3Chat($Chat) {
  $sb = [Text.StringBuilder]::new()
  [void]$sb.AppendLine("# $(if ($Chat.title) { $Chat.title } else { 'Чат V3AI' })").AppendLine()
  foreach ($m in $Chat.messages) {
    $txt = ''
    if ($m.content -is [string]) { $txt = $m.content } else { $txt = (@($m.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n" }
    if (-not $txt.Trim()) { continue }
    [void]$sb.AppendLine($(if ($m.role -eq 'user') { '**Ты:**' } else { '**V3AI:**' })).AppendLine($txt).AppendLine()
  }
  $path = Save-V3File $script:Paths.Export ((Get-V3SafeName $(if ($Chat.title) { $Chat.title } else { 'chat' })) + '.md') $sb.ToString()
  if ($path) { Write-V3Note "💾 Сохранено: $path" Green }
}

function Switch-V3Mode([string]$Id) {
  $mo = Get-V3Mode $Id
  $script:Cfg.mode = $mo.id; Save-V3Config
  if ($script:chat.messages.Count -and ($script:chat.mode -ne $mo.id -or $script:chat.agent)) { Save-V3Chat $script:chat; $script:chat = New-V3Chat $mo.id } else { $script:chat.mode = $mo.id }
  Write-V3Note "Режим «$($mo.n)» $($mo.ico)" Green
}

function Get-V3PromptText($Chat) {
  $M = Get-V3Model $script:Cfg.model
  $label = ''
  if ($Chat.agent) { $A = Get-V3AgentById $Chat.agent; if ($A) { $label = "$($A.emoji) $($A.name)" } }
  if (-not $label) { $mo = Get-V3Mode $Chat.mode; $label = "$($mo.ico) $($mo.n)" }
  $s = "$($M.n) · $label"
  if ($Chat.repo) { $s += " · 🐙 $($Chat.repo.repo)" }
  if ($script:Backend -eq 'offline') { $s += ' · 📴' }
  return $s
}

# ── Главный цикл ──────────────────────────────────────────────────────────────────────────────
Clear-Host
Write-V3Banner
switch ($script:Backend) {
  'api'         { Write-V3Note '🔑 ИИ: Claude API (ключ из ANTHROPIC_API_KEY)' }
  'claude-code' { Write-V3Note '✨ ИИ: Claude Code — через твой аккаунт Claude, ключ не нужен' }
  default       { Write-V3Note '📴 Офлайн-режим. Для ИИ установи Claude Code (claude.ai/code) и войди — ключ не нужен. Или /key.' Yellow }
}
$chat = New-V3Chat $script:Cfg.mode
if ($script:T.box -ne 'panel') { Write-V3Note 'Пиши вопрос и жми Enter. /help — команды, /model — модели, /mode — режимы.'; Write-Host '' }

while ($true) {
  if ($script:T.prompt -eq 'studio') {
    Write-V3X '  ❯ ' orange -NoNewline
  } elseif ($script:T.prompt -eq 'double') {
    $M0 = Get-V3Model $script:Cfg.model; $pt = Get-V3PromptText $chat
    Write-Host '╭─● ' -NoNewline -ForegroundColor $script:T.frame
    Write-Host $M0.n -NoNewline -ForegroundColor $script:T.acc
    Write-Host $pt.Substring($M0.n.Length) -NoNewline -ForegroundColor $script:T.acc2
    Write-Host ('  ' + (Get-Date -Format 'HH:mm')) -ForegroundColor DarkGray
    Write-Host '╰─❯ ' -NoNewline -ForegroundColor $script:T.frame
  } else {
    Write-Host ('[' + (Get-V3PromptText $chat) + ']') -NoNewline -ForegroundColor DarkCyan
    Write-Host ' ❯ ' -NoNewline -ForegroundColor Green
  }
  $line = Read-Host
  if ($null -eq $line) { break }
  while ($line.EndsWith('\')) { $line = $line.Substring(0, $line.Length - 1) + "`n" + (Read-Host '  …') }
  $line = $line.Trim()
  if (-not $line) { continue }
  if ($script:T.prompt -eq 'studio' -and $script:VT) {
    $up = ($line -split "`n").Count
    Write-Host ("$($script:ESC)[$($up)A$($script:ESC)[0J") -NoNewline   # стереть набранную строку и показать её на плашке
    Write-V3Band $line
  }

  $forced = ''
  if ($line.StartsWith('/')) {
    $words = @($line.Substring(1) -split '\s+' | Where-Object { $_ })
    if (-not $words.Count) { Show-V3Help; continue }
    $cmd = $words[0].ToLower(); $rest = @($words | Select-Object -Skip 1)
    switch ($cmd) {
      'help' { Show-V3Help }
      'exit' { Save-V3Chat $chat; Write-V3Note 'До встречи! 👋'; return }
      'quit' { Save-V3Chat $chat; Write-V3Note 'До встречи! 👋'; return }
      'clear' { Clear-Host; Write-V3Banner }
      'theme' {
        if ($rest.Count -and $script:Themes.ContainsKey($rest[0].ToLower())) {
          $script:Cfg.theme = $rest[0].ToLower(); $script:Cfg.themeSet = $true; Save-V3Config; $script:T = $script:Themes[$script:Cfg.theme]
          Clear-Host; Write-V3Banner; Write-V3Note "🎨 Тема: $($script:Cfg.theme)"
        } else { Write-V3Note ('Темы: studio (по умолчанию), sunset (закат) и neon (бирюзовый неон). Сейчас: ' + $script:Cfg.theme + '. Сменить: /theme neon') }
      }
      'key' { Request-V3ApiKey }
      'model' {
        $n = 0
        if ($rest.Count -and [int]::TryParse($rest[0], [ref]$n) -and $n -ge 1 -and $n -le $script:Models.Count) { $script:Cfg.model = $script:Models[$n - 1].id; Save-V3Config; Write-V3Note "🧠 Модель: $($script:Models[$n - 1].n)" Green }
        else { Show-V3Models }
      }
      'mode' {
        if ($rest.Count) {
          $mo = $script:Modes | Where-Object { $_.id -eq $rest[0].ToLower() -or $_.n.ToLower() -eq $rest[0].ToLower() } | Select-Object -First 1
          if ($mo) { Switch-V3Mode $mo.id } else { Show-V3Modes }
        } else { Show-V3Modes }
      }
      'new' { Save-V3Chat $chat; $chat = New-V3Chat $script:Cfg.mode; Write-V3Note '＋ Новый чат' Green }
      'chats' { Show-V3Chats }
      'open' {
        $files = Get-V3Chats; $n = 0
        if ($rest.Count -and [int]::TryParse($rest[0], [ref]$n) -and $n -ge 1 -and $n -le $files.Count) {
          Save-V3Chat $chat; $c = Open-V3Chat $files[$n - 1].FullName
          if ($c) { $chat = $c; Write-V3Note "Открыт: $($chat.title) (сообщений: $($chat.messages.Count))" Green }
        } else { Show-V3Chats }
      }
      'export' { Export-V3Chat $chat }
      'chat' {
        if ($chat.agent -or $chat.mode -ne 'help') { Switch-V3Mode 'help' }
        if ($rest.Count) { $forced = 'chat'; $line = $rest -join ' ' } else { Write-V3Note 'Обычный чат: просто пиши вопрос.' }
      }
      'image' { if ($rest.Count) { $forced = 'art'; $line = $rest -join ' ' } else { Switch-V3Mode 'art' } }
      'design' { if ($rest.Count) { $forced = 'design'; $line = $rest -join ' ' } else { Switch-V3Mode 'design' } }
      'logo' { if ($rest.Count) { $forced = 'design'; $line = $rest -join ' ' } else { Switch-V3Mode 'design' } }
      'gif' { if ($rest.Count) { $forced = 'gif'; $line = $rest -join ' ' } else { Write-V3Note 'Пример: /gif кот машет лапой' } }
      'photo' {
        try { $ph = Get-V3Photo $rest; if ($ph) { $forced = 'photo'; $script:PhotoBlock = $ph.Block; $line = $ph.Question } }
        catch { Write-V3Note "📷 $($_.Exception.Message)" Yellow }
      }
      'say' { Invoke-V3Say $chat ($rest -join ' ') }
      'copy' { Copy-V3Answer $chat }
      'again' {
        if ($script:LastReq) { $forced = $(if ($script:LastReq.cm -eq 'game') { 'game-new' } else { $script:LastReq.cm }); $line = $script:LastReq.line; $script:PhotoBlock = $script:LastReq.photo; Write-V3Note "🔁 Ещё вариант: $line" }
        else { Write-V3Note 'Пока нечего повторять.' }
      }
      'files' { Show-V3RepoFiles $chat ($rest -join ' ') }
      'cat' { Show-V3RepoFile $chat ($rest -join ' ') }
      'watt' { if ($rest.Count) { $forced = 'game'; $line = $rest -join ' ' } else { Switch-V3Mode 'game' } }
      'video' {
        if ($rest.Count -and $rest[0].ToLower() -in @('2d', '2д')) { $rest = @($rest | Select-Object -Skip 1); $forced = 'video2d' } else { $forced = 'video' }
        if ($rest.Count) { $line = $rest -join ' ' } else { $forced = ''; Switch-V3Mode 'video' }
      }
      'secure' { Set-V3Secure $rest }
      'github' {
        if ($rest.Count -and $rest[0] -eq 'login') { Invoke-V3GitHubLogin }
        elseif ($rest.Count -and $rest[0] -eq 'logout') { $script:GhToken = $null; Write-V3Note 'Вышел из GitHub на эту сессию.' }
        else { $R = ConvertFrom-V3RepoUrl ($rest -join ' '); if ($R) { [void](Connect-V3Repo $chat $R) } else { Write-V3Note 'Пришли ссылку вида https://github.com/владелец/репозиторий' } }
      }
      'repo' { if ($chat.repo) { [void](Connect-V3Repo $chat ([ordered]@{ owner = $chat.repo.owner; repo = $chat.repo.repo; ref = $chat.repo.ref })) } else { Write-V3Note 'Репозиторий не подключён. Пришли ссылку на GitHub.' } }
      'disconnect' { $chat.repo = $null; Save-V3Chat $chat; Write-V3Note '🐙 Репозиторий отключён.' }
      'agents' { Show-V3Agents }
      'agent' {
        $list = Get-V3Agents; $n = 0
        if ($rest.Count -and [int]::TryParse($rest[0], [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
          $A = $list[$n - 1]
          if ($rest.Count -ge 2 -and $rest[1] -eq 'memory') {
            $mem = Get-V3Mem $A
            Write-V3Box "🧠 Память: $($A.emoji) $($A.name)" (@('Заметки:') + @(@($mem.notes) | ForEach-Object { '  • ' + $(if ($_.k) { "$($_.k): " } else { '' }) + $_.t }) + @('Дела:') + @(@($mem.tasks) | ForEach-Object { '  ' + $(if ($_.done) { '✔ ' } else { '☐ ' }) + $_.t })) Magenta
          } elseif ($rest.Count -ge 2 -and $rest[1] -eq 'forget') {
            if ((Read-Host "  Очистить память агента «$($A.name)»? (да/нет)").Trim().ToLower() -in @('да', 'д', 'y', 'yes')) { Save-V3Mem $A ([ordered]@{ notes = (New-V3List); tasks = (New-V3List) }); Write-V3Note '🧠 Память очищена.' }
          } elseif ($rest.Count -ge 3 -and $rest[1] -eq 'edit') {
            if ($script:Backend -eq 'offline') { Write-V3Note 'Для этого нужен ИИ: установи Claude Code и войди, или /key.' Yellow }
            else { try { New-V3Agent $chat (($rest | Select-Object -Skip 2) -join ' ') $A } catch { Stop-V3Render; Write-V3Note ('⚠ ' + (Get-V3ErrorText $_.Exception)) Yellow } }
          } elseif ($rest.Count -ge 2 -and $rest[1] -eq 'delete') {
            if ((Read-Host "  Удалить агента «$($A.name)»? (да/нет)").Trim().ToLower() -in @('да', 'д', 'y', 'yes')) { $list.RemoveAt($n - 1); Save-V3Agents $list; Remove-Item -LiteralPath (Join-Path $script:Paths.Memory ($A.id + '.json')) -ErrorAction SilentlyContinue; Write-V3Note '🗑 Удалён.' }
          } else {
            Save-V3Chat $chat; $chat = New-V3Chat 'agents' $A.id; $chat.title = "$($A.emoji) $($A.name)"
            Show-V3AgentCard $A
            $chat.messages.Add([ordered]@{ role = 'user'; content = 'Привет!' }); $chat.messages.Add([ordered]@{ role = 'assistant'; content = [string]$A.greeting })
            Write-V3Line ([string]$A.greeting)
          }
        } else { Show-V3Agents }
      }
      default { Write-V3Note "Не знаю команду /$cmd. Список: /help" Yellow }
    }
    if (-not $forced) { Write-Host ''; continue }
  }

  # Ссылка на GitHub подключает репозиторий; вопрос рядом со ссылкой задаётся сразу после.
  $R = $(if ($forced) { $null } else { ConvertFrom-V3RepoUrl $line })
  if ($R) {
    $ok = Connect-V3Repo $chat $R
    $line = ($line.Replace($R.url, '')).Trim(' ', ',', '.', ':', ';', '!', '-')
    if (-not $ok -or $line.Length -lt 6) { Write-Host ''; continue }
  }

  if (-not $chat.title) { $chat.title = $(if ($line.Length -gt 40) { $line.Substring(0, 40) } else { $line }) }
  $script:Cfg.asked = [int]$script:Cfg.asked + 1; Save-V3Config

  $cm = $(if ($forced) { $forced } else { $chat.mode })
  if ($cm -eq 'video' -and $line -match '^(2d|2д)\s+(.+)$') { $cm = 'video2d'; $line = $Matches[2] }
  if ($cm -eq 'photo' -and $script:Backend -eq 'claude-code') { Write-V3Note '📷 Фото пока работает только с ключом API (/key).' Yellow; Write-Host ''; continue }
  if ($script:Backend -eq 'offline') {
    Write-Host ''
    if ($cm -in @('art', 'design', 'game', 'game-new', 'gif', 'photo', 'video', 'video2d', 'agents')) { Write-V3Note 'Для этого нужен ИИ: установи Claude Code (claude.ai/code) и войди — ключ не нужен. Или /key.' Yellow } else { Write-V3Line (Get-V3Offline $line) }
    Write-Host ''
    continue
  }
  Write-Host ''
  try {
    $kind = $(if ($cm -eq 'photo') { 'photo' } elseif (($chat.agent -and -not $forced) -or $cm -notin @('art', 'design', 'game', 'game-new', 'gif', 'video', 'video2d', 'agents')) { 'chat' } else { $cm })
    switch ($kind) {
      'photo'    { Invoke-V3Chat $chat $line $script:PhotoBlock }
      'chat'     { Invoke-V3Chat $chat $line }
      'art'      { Invoke-V3Art $chat $line }
      'gif'      { Invoke-V3Gif $chat $line }
      'design'   { Invoke-V3Logo $chat $line }
      'game'     { Invoke-V3Game $chat $line }
      'game-new' { Invoke-V3Game $chat $line -Fresh }
      'video'    { Invoke-V3Video $chat $line $true }
      'video2d'  { Invoke-V3Video $chat $line $false }
      'agents'   { New-V3Agent $chat $line }
    }
    $script:LastReq = @{ cm = $(if ($kind -eq 'game-new') { 'game' } else { $kind }); line = $line; photo = $(if ($kind -eq 'photo') { $script:PhotoBlock } else { $null }) }
  } catch {
    Stop-V3Render
    Write-V3Note ('⚠ ' + (Get-V3ErrorText $_.Exception)) Yellow
    Undo-V3LastUser $chat
  }
  Save-V3Chat $chat
  Write-Host ''
}
