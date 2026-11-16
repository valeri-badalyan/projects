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

$script:Version = '1.0'
$script:Root = Join-Path $HOME '.v3ai'
$script:Paths = @{
  Config = Join-Path $script:Root 'config.json'
  Chats  = Join-Path $script:Root 'chats'
  Agents = Join-Path $script:Root 'agents.json'
  Memory = Join-Path $script:Root 'agent-memory'
  Games  = Join-Path $script:Root 'games'
  Art    = Join-Path $script:Root 'art'
  Export = Join-Path $script:Root 'export'
}
$script:VT = (-not $NoColor) -and ($Host.UI.SupportsVirtualTerminal -eq $true)
$script:ESC = [char]27
$script:Http = [System.Net.Http.HttpClient]::new()
$script:Http.Timeout = [TimeSpan]::FromMinutes(20)
$script:ApiKey = $env:ANTHROPIC_API_KEY
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

# ── Внешний вид: «V3AI Terminal» ──────────────────────────────────────────────────────────────
function Get-V3Rgb([int]$r, [int]$g, [int]$b, [string]$text) {
  if ($script:VT) { return "$($script:ESC)[38;2;$r;$g;${b}m$text$($script:ESC)[0m" }
  return $text
}

function Write-V3Gradient([string]$Text, [int[]]$From = @(0, 180, 255), [int[]]$To = @(125, 255, 207)) {
  if (-not $script:VT) { Write-Host $Text -ForegroundColor Cyan; return }
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
  $logo = @(
    '  ██╗   ██╗██████╗  █████╗ ██╗',
    '  ██║   ██║╚════██╗██╔══██╗██║',
    '  ██║   ██║ █████╔╝███████║██║',
    '  ╚██╗ ██╔╝ ╚═══██╗██╔══██║██║',
    '   ╚████╔╝ ██████╔╝██║  ██║██║',
    '    ╚═══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝'
  )
  Write-Host ''
  foreach ($line in $logo) { Write-V3Gradient $line }
  Write-Host ('  ' + (Get-V3Rgb 125 255 207 'Terminal') + "  v$($script:Version) · ИИ-помощник от команды V3 · PowerShell $($PSVersionTable.PSVersion)") -ForegroundColor DarkGray
  Write-Host ''
}

function Write-V3Rule([string]$Title = '') {
  $w = 60; try { $w = [Math]::Min(78, [Console]::WindowWidth - 2) } catch { }
  if ($Title) {
    $rest = [Math]::Max(3, $w - $Title.Length - 4)
    Write-V3Gradient ("──╴$Title╶" + ('─' * $rest))
  } else { Write-V3Gradient ('─' * $w) }
}

function Write-V3Box([string]$Title, [string[]]$Lines, [ConsoleColor]$Color = 'Cyan') {
  Write-Host "  ╭─ $Title" -ForegroundColor $Color
  foreach ($l in $Lines) { Write-Host "  │ " -ForegroundColor $Color -NoNewline; Write-Host $l }
  Write-Host '  ╰─' -ForegroundColor $Color
}

function Write-V3Note([string]$Text, [ConsoleColor]$Color = 'DarkGray') { Write-Host "  $Text" -ForegroundColor $Color }

# Рендер ответа: построчно, с подсветкой **жирного**, `кода`, блоков ```, заголовков и списков.
$script:R = @{ Buf = ''; InCode = $false; Started = $false; Spinner = $false }

function Start-V3Render([string]$Waiting = 'думает…') {
  $script:R = @{ Buf = ''; InCode = $false; Started = $false; Spinner = $true }
  Write-Host "  ◌ $Waiting" -NoNewline -ForegroundColor DarkGray
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

function Write-V3Inline([string]$Line, [ConsoleColor]$Base = 'Gray') {
  $parts = [regex]::Split($Line, '(\*\*[^*]+\*\*|`[^`]+`)')
  foreach ($p in $parts) {
    if (-not $p) { continue }
    if ($p.StartsWith('**') -and $p.EndsWith('**') -and $p.Length -gt 4) { Write-Host $p.Substring(2, $p.Length - 4) -NoNewline -ForegroundColor White }
    elseif ($p.StartsWith('`') -and $p.EndsWith('`') -and $p.Length -gt 2) { Write-Host $p.Substring(1, $p.Length - 2) -NoNewline -ForegroundColor Yellow }
    else { Write-Host $p -NoNewline -ForegroundColor $Base }
  }
  Write-Host ''
}

function Write-V3Line([string]$Line) {
  $t = $Line.Trim()
  if ($t.StartsWith('```')) {
    $script:R.InCode = -not $script:R.InCode
    $lang = $t.Substring(3).Trim()
    if ($script:R.InCode) { Write-Host ('  ┌─ ' + ($(if ($lang) { $lang } else { 'код' }))) -ForegroundColor DarkYellow } else { Write-Host '  └─' -ForegroundColor DarkYellow }
    return
  }
  if ($script:R.InCode) { Write-Host '  │ ' -NoNewline -ForegroundColor DarkYellow; Write-Host $Line -ForegroundColor Yellow; return }
  if ($t -match '^#{1,4}\s+(.*)$') { Write-Host ('  ' + $Matches[1]) -ForegroundColor Cyan; return }
  if ($t -match '^[-*•]\s+(.*)$') { Write-Host '   • ' -NoNewline -ForegroundColor Green; Write-V3Inline $Matches[1]; return }
  if ($t -match '^(\d+)[.)]\s+(.*)$') { Write-Host ('   ' + $Matches[1] + '. ') -NoNewline -ForegroundColor Green; Write-V3Inline $Matches[2]; return }
  Write-Host '  ' -NoNewline
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
  @{ id = 'agents'; ico = '🩺'; n = 'Dr. Agents'; p = '' }
)

function Get-V3Model([string]$Id) { foreach ($m in $script:Models) { if ($m.id -eq $Id) { return $m } }; return $script:Models[5] }
function Get-V3Mode([string]$Id) { foreach ($m in $script:Modes) { if ($m.id -eq $Id) { return $m } }; return $script:Modes[0] }

$script:Cfg = Read-V3Json $script:Paths.Config
if (-not $script:Cfg) { $script:Cfg = [ordered]@{} }
foreach ($kv in @(@('model', 'ortl55'), @('mode', 'help'), @('secureOn', $true), @('asked', 0))) { if (-not $script:Cfg.Contains($kv[0])) { $script:Cfg[$kv[0]] = $kv[1] } }
if (-not $script:Cfg.Contains('secure') -or -not ($script:Cfg['secure'] -is [System.Collections.IDictionary])) { $script:Cfg['secure'] = [ordered]@{} }
if ($Model) { $script:Cfg.model = (Get-V3Model $Model).id }
if ($Mode) { $script:Cfg.mode = (Get-V3Mode $Mode).id }
function Save-V3Config { Save-V3Json $script:Paths.Config $script:Cfg }

# ── EngineSecure ──────────────────────────────────────────────────────────────────────────────
$script:SecureActs = [ordered]@{
  open   = @{ ico = '🕹'; n = 'Открытие файлов'; d = 'Игры WattAI и картинки откроются в браузере. Игра — это программа, которую написал ИИ.' }
  save   = @{ ico = '💾'; n = 'Сохранение файлов'; d = 'Игры, картинки и экспорт чатов сохраняются в папку ~/.v3ai.' }
  github = @{ ico = '🐙'; n = 'Доступ к GitHub'; d = 'V3AI читает репозиторий (только чтение). С токеном — и закрытые репозитории твоего аккаунта.' }
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
  $script:ApiKey = $k
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

# Один потоковый запрос. Возвращает @{ Blocks; Stop; Model; Stopped }.
# OnText получает куски текста, OnTool — имя инструмента, когда модель начинает его вызывать.
function Invoke-V3Stream($Body, [string]$Beta, [scriptblock]$OnText, [scriptblock]$OnTool) {
  $json = ConvertTo-V3Json $Body
  $attempt = 0
  while ($true) {
    $attempt++
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://api.anthropic.com/v1/messages')
    [void]$req.Headers.TryAddWithoutValidation('x-api-key', $script:ApiKey)
    [void]$req.Headers.TryAddWithoutValidation('anthropic-version', '2026-10-21')
    if ($Beta) { [void]$req.Headers.TryAddWithoutValidation('anthropic-beta', $Beta) }
    $req.Content = [System.Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
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

# Разговор с инструментами: стримит текст, сам выполняет вызовы инструментов, повторяет до конца.
# $Messages — List, в него дописываются ответы (только добавление, без правок прошлого).
function Invoke-V3Turn {
  param($Messages, [string]$System, $Tools, [scriptblock]$Handler, [switch]$Quiet, [int]$MaxTokens = 64000, [string]$Waiting = 'думает…')
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
    $onTool = { param($n) if (-not $Quiet) { Stop-V3Render; Write-Host "  🧰 $n…" -ForegroundColor DarkCyan; Start-V3Render 'работает…' } }
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
    0   { if ($Ex.Data['type'] -eq 'network') { return 'Нет связи с Claude. Проверь интернет.' } else { return "Сервер прервал ответ ($($Ex.Data['type'])). Попробуй ещё раз." } }
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
  return 'Сейчас я в офлайн-режиме 📴: умею считать примеры («12*7+3»), подсказать время и дату, пошутить и загадать загадку. Добавь ключ Claude API командой **/key** — и я отвечу на что угодно.'
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
  if ($n -and $Chat.messages[$n - 1].role -eq 'user' -and ($Chat.messages[$n - 1].content -is [string])) { $Chat.messages.RemoveAt($n - 1) }
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
    'Только добрые сюжеты, подходящие детям.',
    $(if ($prev) { "Предыдущая картинка в этом чате была по запросу «$prev». Если новый запрос — правка, нарисуй ту же сцену с изменением." } else { '' }),
    'Ответ: сначала SVG в блоке ```svg, затем одна короткая весёлая фраза по-русски о том, что нарисовано.',
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

function Invoke-V3Game($Chat, [string]$Q) {
  $prevCode = ''
  if ($Chat.lastGame -and (Test-Path -LiteralPath $Chat.lastGame)) { $prevCode = Get-Content -LiteralPath $Chat.lastGame -Raw -Encoding UTF8 }
  $prompt = @(
    'Ты — WattAI, создатель игр внутри V3AI. Напиши по запросу пользователя готовую браузерную игру — ОДИН полный HTML-документ.',
    'Требования:',
    '- Всё в одном файле: HTML, CSS и JavaScript внутри. Никаких внешних файлов, библиотек, шрифтов, картинок по ссылкам и сетевых запросов. Графика — canvas 2D (фигуры, градиенты, эмодзи) или DOM/CSS; звук — только Web Audio API, после первого нажатия.',
    '- Игра занимает всё окно и подстраивается под размер. Стартовый экран с названием, правилом и «Нажми, чтобы начать»; потом игра; в конце «Игра окончена» со счётом, рекордом (localStorage) и перезапуском.',
    '- Управление и мышью/касанием, и с клавиатуры. Без alert/prompt/confirm, без открытия окон и ссылок.',
    '- Живая и красивая игра: анимации, частицы, нарастающая сложность, понятная цель. Тексты в игре по-русски.',
    '- Аккуратный рабочий код: requestAnimationFrame с dt, без ошибок в консоли. Размер — до ~25 000 символов.',
    '- Только добрые игры, подходящие детям.',
    $(if ($prevCode) { "`nВ этом чате уже есть игра. Её код ниже. Если запрос — правка этой игры, верни ВЕСЬ исправленный документ; если просят другую игру — сделай новую.`n``````html`n$prevCode`n``````" } else { '' }),
    "`nОтвет: строка «Название: …», затем весь код в блоке ``````html, затем одна-две короткие фразы по-русски: как играть.",
    "Запрос: $Q"
  ) -join "`n"
  $msgs = New-V3List; $msgs.Add([ordered]@{ role = 'user'; content = $prompt })
  $r = Invoke-V3Turn -Messages $msgs -System 'Ты — WattAI, создатель браузерных игр в V3AI.' -Quiet -Waiting '🕹 WattAI пишет игру…'
  $html = Get-V3Block $r.Text 'html'
  if (-not $html) { $mm = [regex]::Match($r.Text, '<!doctype html[\s\S]*</html>', 'IgnoreCase'); if ($mm.Success) { $html = $mm.Value } }
  if (-not $html -or $html -notmatch '<script') { Write-V3Note 'Игра не получилась — попробуй ещё раз или модель посильнее (/model).' Yellow; return }
  $title = ''; $tm = [regex]::Match($r.Text, 'Название:\s*([^\r\n]+)'); if ($tm.Success) { $title = $tm.Groups[1].Value.Trim(' *«»"') }
  $how = ([regex]::Replace(([regex]::Replace($r.Text, '```[\s\S]*?(```|$)', '')), 'Название:[^\r\n]*', '')).Trim()
  $path = Save-V3File $script:Paths.Games ((Get-V3SafeName $(if ($title) { $title } else { $Q })) + '.html') $html
  Write-V3Box ('🕹 ' + $(if ($title) { $title } else { 'Игра готова' })) @($(if ($how) { $how } else { 'Играй!' }), $(if ($path) { "Файл: $path" } else { 'Файл не сохранён (EngineSecure).' })) Magenta
  if ($path) { $Chat.lastGame = $path; Open-V3File $path }
  $Chat.messages.Add([ordered]@{ role = 'user'; content = $Q })
  $Chat.messages.Add([ordered]@{ role = 'assistant'; content = "(WattAI сделал игру «$title» по запросу «$Q».) $how" })
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

function New-V3Agent($Chat, [string]$Q) {
  $prompt = @(
    'Ты — Dr. Agents, конструктор ИИ-агентов в V3AI. По просьбе пользователя спроектируй агента — ИИ-помощника с характером.',
    'Навыки (инструменты), которые агент сможет вызывать: memory — запоминать и вспоминать факты о пользователе; tasks — вести список дел; calc — точно считать; time — узнавать дату и время; dice — случайные числа и жребий. Выбери только нужные (1–5).',
    'Агент должен быть добрым и подходить детям.',
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
  $list = Get-V3Agents; $list.Insert(0, $A); Save-V3Agents $list
  if ($j.comment) { Write-V3Line ([string]$j.comment) }
  Show-V3AgentCard $A
  Write-V3Note 'Начать чат с ним: /agent 1'
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
function Invoke-V3Chat($Chat, [string]$Q) {
  $Chat.messages.Add([ordered]@{ role = 'user'; content = $Q })
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
  $r = Invoke-V3Turn -Messages $Chat.messages -System $system -Tools $tools -Handler $handler -Waiting $(if ($A) { "$($A.name) думает…" } else { 'думает…' })
  $M = Get-V3Model $script:Cfg.model
  $tag = $(if ($A) { "$($A.name) · $($M.n)" } else { $M.n })
  if ($r.Used.Count) { $tag += ' · 🧰 ' + ($r.Used -join ', ') }
  Write-Host "  — $tag" -ForegroundColor DarkGray
}

# ── Команды ───────────────────────────────────────────────────────────────────────────────────
function Show-V3Help {
  Write-V3Rule 'Команды'
  $rows = @(
    @('/mode [имя]', 'режим: help, school, write, lang, code, fun, art, game, agents'),
    @('/model [номер]', 'выбрать модель V3AI'),
    @('/new', 'новый чат        /chats — история        /open <номер> — открыть'),
    @('/export', 'сохранить чат в файл .md'),
    @('<ссылка github>', 'подключить репозиторий (или /github <ссылка>)'),
    @('/github login', 'войти в GitHub (закрытые репозитории)   /github logout — выйти'),
    @('/repo', 'карточка репозитория   /disconnect — отключить'),
    @('/agents', 'мои агенты           /agent <номер> — чат с агентом'),
    @('/secure', 'EngineSecure: разрешения'),
    @('/key', 'ввести ключ Claude API'),
    @('/clear', 'очистить экран      /exit — выход'),
    @('Esc / Ctrl+C', 'во время ответа — остановить'),
    @('строка с \ в конце', 'продолжить ввод на следующей строке')
  )
  foreach ($r in $rows) { Write-Host ('   ' + $r[0].PadRight(22)) -NoNewline -ForegroundColor Cyan; Write-Host $r[1] -ForegroundColor Gray }
  Write-V3Note 'GIF, видео и 3D-мультфильмы есть только в веб-версии V3AI.'
}

function Show-V3Models {
  Write-V3Rule '🧠 Модели V3AI'
  for ($i = 0; $i -lt $script:Models.Count; $i++) {
    $m = $script:Models[$i]; $on = $m.id -eq $script:Cfg.model
    Write-Host ($(if ($on) { ' ▶ ' } else { '   ' }) + ($i + 1) + '. ') -NoNewline -ForegroundColor $(if ($on) { 'Green' } else { 'DarkGray' })
    Write-Host $m.n.PadRight(15) -NoNewline -ForegroundColor White
    Write-Host $m.tag.PadRight(11) -NoNewline -ForegroundColor Cyan
    Write-Host $m.d -ForegroundColor Gray
  }
  Write-V3Note 'Выбрать: /model <номер>'
}

function Show-V3Modes {
  Write-V3Rule '🎛 Режимы'
  foreach ($m in $script:Modes) {
    $on = $m.id -eq $script:Cfg.mode
    Write-Host ($(if ($on) { ' ▶ ' } else { '   ' }) + "$($m.ico) ") -NoNewline -ForegroundColor $(if ($on) { 'Green' } else { 'DarkGray' })
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

function Get-V3PromptText($Chat) {
  $M = Get-V3Model $script:Cfg.model
  $label = ''
  if ($Chat.agent) { $A = Get-V3AgentById $Chat.agent; if ($A) { $label = "$($A.emoji) $($A.name)" } }
  if (-not $label) { $mo = Get-V3Mode $Chat.mode; $label = "$($mo.ico) $($mo.n)" }
  $s = "$($M.n) · $label"
  if ($Chat.repo) { $s += " · 🐙 $($Chat.repo.repo)" }
  if (-not $script:ApiKey) { $s += ' · 📴' }
  return $s
}

# ── Главный цикл ──────────────────────────────────────────────────────────────────────────────
Clear-Host
Write-V3Banner
if (-not $script:ApiKey) { Request-V3ApiKey }
$chat = New-V3Chat $script:Cfg.mode
Write-V3Note 'Пиши вопрос и жми Enter. /help — команды, /model — модели, /mode — режимы.'
Write-Host ''

while ($true) {
  Write-Host ('[' + (Get-V3PromptText $chat) + ']') -NoNewline -ForegroundColor DarkCyan
  Write-Host ' ❯ ' -NoNewline -ForegroundColor Green
  $line = Read-Host
  if ($null -eq $line) { break }
  while ($line.EndsWith('\')) { $line = $line.Substring(0, $line.Length - 1) + "`n" + (Read-Host '  …') }
  $line = $line.Trim()
  if (-not $line) { continue }

  if ($line.StartsWith('/')) {
    $words = @($line.Substring(1) -split '\s+' | Where-Object { $_ })
    if (-not $words.Count) { Show-V3Help; continue }
    $cmd = $words[0].ToLower(); $rest = @($words | Select-Object -Skip 1)
    switch ($cmd) {
      'help' { Show-V3Help }
      'exit' { Save-V3Chat $chat; Write-V3Note 'До встречи! 👋'; return }
      'quit' { Save-V3Chat $chat; Write-V3Note 'До встречи! 👋'; return }
      'clear' { Clear-Host; Write-V3Banner }
      'key' { Request-V3ApiKey }
      'model' {
        $n = 0
        if ($rest.Count -and [int]::TryParse($rest[0], [ref]$n) -and $n -ge 1 -and $n -le $script:Models.Count) { $script:Cfg.model = $script:Models[$n - 1].id; Save-V3Config; Write-V3Note "🧠 Модель: $($script:Models[$n - 1].n)" Green }
        else { Show-V3Models }
      }
      'mode' {
        if ($rest.Count) {
          $mo = $script:Modes | Where-Object { $_.id -eq $rest[0].ToLower() -or $_.n.ToLower() -eq $rest[0].ToLower() } | Select-Object -First 1
          if ($mo) {
            $script:Cfg.mode = $mo.id; Save-V3Config
            if ($chat.messages.Count -and ($chat.mode -ne $mo.id -or $chat.agent)) { Save-V3Chat $chat; $chat = New-V3Chat $mo.id } else { $chat.mode = $mo.id }
            Write-V3Note "Режим «$($mo.n)» $($mo.ico)" Green
          } else { Show-V3Modes }
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
          if ($rest.Count -ge 2 -and $rest[1] -eq 'delete') {
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
    Write-Host ''
    continue
  }

  # Ссылка на GitHub подключает репозиторий; вопрос рядом со ссылкой задаётся сразу после.
  $R = ConvertFrom-V3RepoUrl $line
  if ($R) {
    $ok = Connect-V3Repo $chat $R
    $line = ($line.Replace($R.url, '')).Trim(' ', ',', '.', ':', ';', '!', '-')
    if (-not $ok -or $line.Length -lt 6) { Write-Host ''; continue }
  }

  if (-not $chat.title) { $chat.title = $(if ($line.Length -gt 40) { $line.Substring(0, 40) } else { $line }) }
  $script:Cfg.asked = [int]$script:Cfg.asked + 1; Save-V3Config

  if (-not $script:ApiKey) {
    Write-Host ''; Write-V3Line (Get-V3Offline $line); Write-Host ''
    continue
  }
  Write-Host ''
  try {
    $cm = $chat.mode
    if ($chat.agent) { Invoke-V3Chat $chat $line }
    elseif ($cm -eq 'art') { Invoke-V3Art $chat $line }
    elseif ($cm -eq 'game') { Invoke-V3Game $chat $line }
    elseif ($cm -eq 'agents') { New-V3Agent $chat $line }
    else { Invoke-V3Chat $chat $line }
  } catch {
    Stop-V3Render
    Write-V3Note ('⚠ ' + (Get-V3ErrorText $_.Exception)) Yellow
    Undo-V3LastUser $chat
  }
  Save-V3Chat $chat
  Write-Host ''
}
