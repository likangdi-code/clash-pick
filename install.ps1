<#
  clash-pick 一键安装脚本（Windows / PowerShell）

  用法（终端粘贴一行即可）：
    irm https://raw.githubusercontent.com/likangdi-code/clash-pick/main/install.ps1 | iex

  效果：
    - 把 clash-pick.mjs + clash-pick.cmd 安装到 %LOCALAPPDATA%\Programs\clash-pick
    - 把安装目录加入「用户 PATH」，当前与未来终端都能直接 `clash-pick`
    - 幂等：重复运行只覆盖更新，不产生重复 PATH 条目
#>
$ErrorActionPreference = 'Stop'

$repoBase = 'https://raw.githubusercontent.com/likangdi-code/clash-pick/main'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\clash-pick'

# 1. 前置检查：需要 Node.js（clash-pick 是零依赖 Node 脚本）
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error '未找到 Node.js。请先安装 Node.js（https://nodejs.org）后重试。'
    exit 1
}

# 2. 创建安装目录
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# 3. 下载脚本主体
Write-Host "下载 clash-pick.mjs -> $installDir" -ForegroundColor Cyan
$mjs = Join-Path $installDir 'clash-pick.mjs'
Invoke-WebRequest -Uri "$repoBase/clash-pick.mjs" -OutFile $mjs -UseBasicParsing

# 4. 生成命令包装 clash-pick.cmd
$cmdContent = "@echo off`r`nrem clash-pick command wrapper`r`nnode `"%~dp0clash-pick.mjs`" %*`r`n"
Set-Content -Path (Join-Path $installDir 'clash-pick.cmd') -Value $cmdContent -Encoding ASCII

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

# 6. 立即在当前进程生效并自检
$env:Path = $userPath + ';' + $installDir + ';' + $env:Path
Write-Host ''
Write-Host '✓ clash-pick 安装完成。' -ForegroundColor Green
Write-Host '  新开一个终端（或执行 $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")）后可直接：'
Write-Host '    clash-pick list'
Write-Host '    clash-pick pick "https://example.com/big-file.zip"'
Write-Host '    clash-pick --help'
