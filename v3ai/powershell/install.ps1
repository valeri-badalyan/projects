<#
  Установщик V3AI для PowerShell.
  Запуск одной строкой:
    irm https://raw.githubusercontent.com/valeri-badalyan/projects/ccr-617a6cca-m3ccsg/v3ai/powershell/install.ps1 | iex

  Что делает:
    1. скачивает v3ai.ps1 в папку ~/.v3ai/bin;
    2. по вашему согласию добавляет команду «v3ai» (Windows: v3ai.cmd + папка в PATH пользователя;
       macOS/Linux: скрипт ~/.local/bin/v3ai);
    3. предлагает сразу запустить V3AI.
  Ничего не меняет в системе без вопроса, права администратора не нужны.
#>
& {
  $ErrorActionPreference = 'Stop'
  $branch = 'ccr-617a6cca-m3ccsg'
  $url = "https://raw.githubusercontent.com/valeri-badalyan/projects/$branch/v3ai/powershell/v3ai.ps1"
  $isWin = -not ($IsLinux -or $IsMacOS)
  if ($PSVersionTable.PSVersion.Major -lt 6) { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
  try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

  Write-Host ''
  Write-Host '  V3AI · установка' -ForegroundColor Cyan
  Write-Host '  ────────────────' -ForegroundColor DarkCyan

  $bin = Join-Path (Join-Path $HOME '.v3ai') 'bin'
  if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Path $bin -Force | Out-Null }
  $script = Join-Path $bin 'v3ai.ps1'

  Write-Host '  ◌ скачиваю V3AI…' -ForegroundColor DarkGray
  Invoke-WebRequest -Uri $url -OutFile $script -UseBasicParsing
  if ((Get-Item -LiteralPath $script).Length -lt 10000) { throw 'Файл скачался не полностью — попробуйте ещё раз.' }
  if ($isWin -and (Get-Command Unblock-File -ErrorAction SilentlyContinue)) { Unblock-File -LiteralPath $script }
  Write-Host "  ✓ V3AI: $script" -ForegroundColor Green

  $answer = Read-Host '  Добавить команду «v3ai», чтобы запускать из любой папки? (Д/н)'
  if ($answer.Trim().ToLower() -notin @('н', 'нет', 'n', 'no')) {
    if ($isWin) {
      $cmd = Join-Path $bin 'v3ai.cmd'
      $runner = $(if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' })
      Set-Content -LiteralPath $cmd -Value "@$runner -NoProfile -ExecutionPolicy Bypass -File `"%~dp0v3ai.ps1`" %*" -Encoding ASCII
      $path = [Environment]::GetEnvironmentVariable('Path', 'User')
      if (-not (($path -split ';') -contains $bin)) {
        [Environment]::SetEnvironmentVariable('Path', ((@($path, $bin) | Where-Object { $_ }) -join ';'), 'User')
        Write-Host "  ✓ Папка $bin добавлена в PATH пользователя (заработает в новых окнах терминала)." -ForegroundColor Green
      }
      $env:Path = "$env:Path;$bin"
    } else {
      $local = Join-Path (Join-Path $HOME '.local') 'bin'
      if (-not (Test-Path -LiteralPath $local)) { New-Item -ItemType Directory -Path $local -Force | Out-Null }
      $launcher = Join-Path $local 'v3ai'
      Set-Content -LiteralPath $launcher -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$script`" `"`$@`"`n" -NoNewline
      & chmod +x $launcher
      Write-Host "  ✓ Команда: $launcher" -ForegroundColor Green
      if (-not (($env:PATH -split ':') -contains $local)) { Write-Host "  ! Добавьте $local в PATH (например, в ~/.bashrc или ~/.zshrc)." -ForegroundColor Yellow }
    }
    Write-Host '  Запуск в любой момент: v3ai' -ForegroundColor Cyan
  }

  if ((Read-Host '  Запустить V3AI сейчас? (Д/н)').Trim().ToLower() -notin @('н', 'нет', 'n', 'no')) {
    if ($isWin -and $PSVersionTable.PSVersion.Major -lt 6) { & powershell -NoProfile -ExecutionPolicy Bypass -File $script }
    else { & pwsh -NoProfile -File $script }
  }
}
