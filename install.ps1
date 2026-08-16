<#
  install.ps1 — clash-proxy 工具一键安装（兼作更新命令，重跑即更新工具 + skill）

  用法（PowerShell 终端粘贴一行即可）：
    irm https://raw.githubusercontent.com/likangdi-code/clash-verge-url-proxy-cli/main/install.ps1 | iex

  效果：
    - 把 clash-proxy.mjs + clash-proxy.cmd 安装到 %LOCALAPPDATA%\Programs\clash-proxy
    - 把安装目录加入「用户 PATH」，当前与未来终端都能直接 `clash-proxy`
    - 幂等：重复运行只覆盖更新，不产生重复 PATH 条目
    - 安装完成后交互式选择是否部署 skill：默认全选已检测到的 agent 工具，
      逐个回车保留、输入 n 取消；选好后自动部署 clash-proxy + clash-proxy-fix

  skill 也可随时单独部署（不装工具）：
    powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\deploy-agents.ps1"
        # 部署到全部 agent；或 -Agent claude 只装当前（可逗号分隔多个）
#>
$ErrorActionPreference = 'Stop'

# 交互输入：非交互环境（管道/自动化）读到 EOF 时返回 $null，按「默认回车」处理
function Read-Interactive([string]$Prompt) {
    try { return Read-Host $Prompt } catch { return $null }
}

$repoBase = 'https://raw.githubusercontent.com/likangdi-code/clash-verge-url-proxy-cli/main'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\clash-proxy'

# 1. 前置检查：需要 Node.js（clash-proxy 是零依赖 Node 脚本）
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error '未找到 Node.js。请先安装 Node.js（https://nodejs.org）后重试。'
    exit 1
}

# 2. 创建安装目录
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# 3. 下载脚本主体 + vendored js-yaml + 独立下载引擎（add 解析 YAML / dl 多线程下载用）
Write-Host "下载 clash-proxy.mjs -> $installDir" -ForegroundColor Cyan
$mjs = Join-Path $installDir 'clash-proxy.mjs'
Invoke-WebRequest -Uri "$repoBase/clash-proxy.mjs" -OutFile $mjs -UseBasicParsing
Invoke-WebRequest -Uri "$repoBase/downloader.mjs" -OutFile (Join-Path $installDir 'downloader.mjs') -UseBasicParsing
New-Item -ItemType Directory -Force -Path (Join-Path $installDir 'vendor') | Out-Null
Invoke-WebRequest -Uri "$repoBase/vendor/js-yaml.mjs" -OutFile (Join-Path $installDir 'vendor\js-yaml.mjs') -UseBasicParsing

# 4. 生成命令包装 clash-proxy.cmd + clash-dl.cmd（均纯 ASCII，避免 cmd 代码页解析乱码）
$cmdContent = "@echo off`r`nrem clash-proxy command wrapper`r`nnode `"%~dp0clash-proxy.mjs`" %*`r`n"
Set-Content -Path (Join-Path $installDir 'clash-proxy.cmd') -Value $cmdContent -Encoding ASCII
$dlCmdContent = "@echo off`r`nrem clash-dl: standalone multi-threaded downloader (proxy/direct), wraps clash-proxy dl`r`nnode `"%~dp0clash-proxy.mjs`" dl %*`r`n"
Set-Content -Path (Join-Path $installDir 'clash-dl.cmd') -Value $dlCmdContent -Encoding ASCII

# 5. 把安装目录加入用户 PATH（幂等）
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $installDir) {
    $newPath = ($userPath.TrimEnd(';')) + ';' + $installDir
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "已加入用户 PATH: $installDir" -ForegroundColor Green
} else {
    Write-Host "PATH 已包含安装目录，跳过" -ForegroundColor DarkGray
}

# 6. 下载 deploy-agents.ps1 到安装目录（skill 部署脚本，覆盖更新）
$depScript = Join-Path $installDir 'deploy-agents.ps1'
Invoke-WebRequest -Uri "$repoBase/deploy-agents.ps1" -OutFile $depScript -UseBasicParsing
Write-Host "已更新 skill 部署脚本 -> $depScript" -ForegroundColor DarkGray

# 6.5 交互选择：把 skill 部署到哪些 agent（默认全选，回车保留 / 输入 n 取消）
Write-Host ''
$deployAns = Read-Interactive '是否把 skill 部署到本机 agent 工具？(回车=选择部署 / n=跳过)'
if ($null -eq $deployAns -or $deployAns -notmatch '^[nN]') {
    # 与 deploy-agents.ps1 保持一致的 agent 清单（只对已检测到的询问）
    $targets = @(
      @{ key = 'claude';    name = 'Claude Code'; dir = "$HOME\.claude" },
      @{ key = 'gemini';    name = 'Gemini';      dir = "$HOME\.gemini" },
      @{ key = 'codex';     name = 'Codex';       dir = "$HOME\.codex" },
      @{ key = 'opencode';  name = 'OpenCode';    dir = "$HOME\.config\opencode" },
      @{ key = 'hermes';    name = 'Hermes';      dir = "$HOME\.hermes" },
      @{ key = 'openclaw';  name = 'OpenClaw';    dir = "$HOME\.openclaw" },
      @{ key = 'grok';      name = 'Grok';        dir = "$HOME\.grok" },
      @{ key = 'agents';    name = '共享池 .agents'; dir = "$HOME\.agents" }
    )
    $detected = @($targets | Where-Object { Test-Path $_.dir })
    $notFound = @($targets | Where-Object { -not (Test-Path $_.dir) })
    if ($detected.Count -eq 0) {
        Write-Host '未检测到任何已安装的 agent 工具，跳过 skill 部署。' -ForegroundColor Yellow
        Write-Host '（装好 agent 后重跑本命令即可检测并选择部署）' -ForegroundColor DarkGray
    } else {
        Write-Host '选择要安装 skill 的 agent（回车=保留，输入 n=取消；默认全选）：' -ForegroundColor Cyan
        $selected = @()
        foreach ($t in $detected) {
            $ans = Read-Interactive "  [$($t.key)] $($t.name)"
            if ($null -eq $ans -or $ans -notmatch '^[nN]') { $selected += $t.key }
        }
        if ($selected.Count -gt 0) {
            Write-Host "已选择 $($selected.Count) 个：$($selected -join '、')" -ForegroundColor Green
            & powershell -NoProfile -ExecutionPolicy Bypass -File $depScript -Agent ($selected -join ',')
        } else {
            Write-Host '未选择任何 agent，跳过 skill 部署。' -ForegroundColor Yellow
            Write-Host "（之后想装：powershell -ExecutionPolicy Bypass -File `"$depScript`"）" -ForegroundColor DarkGray
        }
    }
    if ($notFound.Count) {
        Write-Host "未检测到的 agent（装好后重跑本命令即可部署）：$((($notFound | ForEach-Object { $_.name }) -join '、'))" -ForegroundColor DarkGray
    }
}

# 7. 立即在当前进程生效并自检
$env:Path = $userPath + ';' + $installDir + ';' + $env:Path
Write-Host ''
Write-Host '✓ clash-proxy 工具安装完成。' -ForegroundColor Green
Write-Host '  新开终端（或刷新 PATH）后可直接：'
Write-Host '    clash-proxy list'
Write-Host '    clash-proxy pick "https://example.com/big-file.zip"'
Write-Host '    clash-dl "https://example.com/big-file.zip"   （独立多线程下载）'
Write-Host ''
Write-Host '  再次运行本安装命令 = 更新工具 + 重新选择 skill 部署。' -ForegroundColor DarkGray
Write-Host '  skill 也可随时单独部署/补装：' -ForegroundColor DarkGray
Write-Host "    powershell -ExecutionPolicy Bypass -File `"$installDir\deploy-agents.ps1`"   （全部 agent）" -ForegroundColor DarkGray
Write-Host "    powershell -ExecutionPolicy Bypass -File `"$installDir\deploy-agents.ps1`" -Agent claude,codex" -ForegroundColor DarkGray
Write-Host '  skill 文件也可手动下载：' -ForegroundColor DarkGray
Write-Host "    $repoBase/skills/clash-proxy/SKILL.md" -ForegroundColor DarkGray
