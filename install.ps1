<#
  install.ps1 — clash-proxy 工具一键安装（只装工具本体，不装 skill）

  用法（PowerShell 终端粘贴一行即可）：
    irm https://raw.githubusercontent.com/likangdi-code/clash-verge-url-proxy-cli/main/install.ps1 | iex

  效果：
    - 把 clash-proxy.mjs + clash-proxy.cmd 安装到 %LOCALAPPDATA%\Programs\clash-proxy
    - 把安装目录加入「用户 PATH」，当前与未来终端都能直接 `clash-proxy`
    - 幂等：重复运行只覆盖更新，不产生重复 PATH 条目

  ⚠️ 本脚本**只安装工具**，不装 skill。
  skill（让 agent 自主调用 clash-proxy）由各 agent 工具单独部署：
    - 全部 agent 一键部署： powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\deploy-agents.ps1"
    - 只装当前 agent（如 Claude Code）： powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\deploy-agents.ps1" -Agent claude
  install.ps1 会把 deploy-agents.ps1 一并下载到安装目录（备用，不执行）。
#>
$ErrorActionPreference = 'Stop'

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

# 6. 下载 deploy-agents.ps1 到安装目录（skill 部署脚本，备用不执行）
$depScript = Join-Path $installDir 'deploy-agents.ps1'
if (-not (Test-Path $depScript)) {
    Invoke-WebRequest -Uri "$repoBase/deploy-agents.ps1" -OutFile $depScript -UseBasicParsing
    Write-Host "已下载 skill 部署脚本 -> $depScript（未执行）" -ForegroundColor DarkGray
} else {
    Write-Host "skill 部署脚本已存在，跳过下载" -ForegroundColor DarkGray
}

# 7. 立即在当前进程生效并自检
$env:Path = $userPath + ';' + $installDir + ';' + $env:Path
Write-Host ''
Write-Host '✓ clash-proxy 工具安装完成（未安装 skill）。' -ForegroundColor Green
Write-Host '  新开终端（或刷新 PATH）后可直接：'
Write-Host '    clash-proxy list'
Write-Host '    clash-proxy pick "https://example.com/big-file.zip"'
Write-Host '    clash-dl "https://example.com/big-file.zip"   （独立多线程下载）'
Write-Host ''
Write-Host '▶ 部署 skill 到本机【所有】agent 工具：' -ForegroundColor Cyan
Write-Host "    powershell -ExecutionPolicy Bypass -File `"$installDir\deploy-agents.ps1`""
Write-Host '  只装到【当前】agent（如 Claude Code / Gemini / Codex ...）：' -ForegroundColor Cyan
Write-Host "    powershell -ExecutionPolicy Bypass -File `"$installDir\deploy-agents.ps1`" -Agent claude"
Write-Host '  可用的 -Agent 值：claude / gemini / codex / opencode / hermes / openclaw / grok / agents' -ForegroundColor DarkGray
Write-Host '  skill 文件也可手动下载：' -ForegroundColor DarkGray
Write-Host "    $repoBase/skills/clash-proxy/SKILL.md" -ForegroundColor DarkGray
