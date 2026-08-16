<#
  install.ps1 — clash-proxy 工具一键安装（兼作更新命令，重跑即更新工具 + skill）

  用法（PowerShell 终端粘贴一行即可）：
    irm https://raw.githubusercontent.com/likangdi-code/clash-verge-url-proxy-cli/main/install.ps1 | iex

  效果：
    - 把 clash-proxy.mjs + clash-proxy.cmd 安装到 %LOCALAPPDATA%\Programs\clash-proxy
    - 把安装目录加入「用户 PATH」，当前与未来终端都能直接 `clash-proxy`
    - 幂等：重复运行只覆盖更新，不产生重复 PATH 条目
    - 安装完成后方向键多选菜单选择部署 skill 到哪些 agent 工具：默认全选，
      ↑/↓ 移动、Enter 切换选中（▣→▢）、移到「开始部署」回车确认、Esc 跳过；
      选好后自动部署 clash-proxy + clash-proxy-fix

  skill 也可随时单独部署（不装工具）：
    powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\deploy-agents.ps1"
        # 部署到全部 agent；或 -Agent claude 只装当前（可逗号分隔多个）
#>
$ErrorActionPreference = 'Stop'

# 交互多选菜单（Claude Code 问问题式）：↑/↓ 移动光标，Enter 在 agent 项上切换选中
# （▣→▢，选中项显示青色），光标移到「开始部署」按 Enter 开始部署，Esc 跳过。
# 非交互环境（管道/自动化）ReadKey 失败时返回空数组 = 跳过部署；
# 测试可用 $script:KeyQueue 注入按键流（ConsoleKeyInfo 数组）。
function Select-AgentMenu {
    param([object[]]$Agents)  # 每个元素含 key / name，默认全部选中
    $items = @()
    foreach ($a in $Agents) {
        $items += [pscustomobject]@{ key = $a.key; label = "[$($a.key)] $($a.name)"; checked = $true }
    }
    $items += [pscustomobject]@{ key = ''; label = '开始部署'; checked = $true }
    $cur = 0
    $width = $Host.UI.RawUI.WindowSize.Width
    $menuTop = $Host.UI.RawUI.CursorPosition.Y
    while ($true) {
        # 整块重绘：从菜单起始行逐行覆盖（光标行整行反色，选中项青色）；
        # 输出重定向导致无法定位光标时退化为顺序打印（功能不变）
        for ($i = 0; $i -lt $items.Count; $i++) {
            try { [Console]::SetCursorPosition(0, $menuTop + $i) } catch {}
            $isConfirm = $items[$i].key -eq ''
            $prefix = if ($isConfirm) { '>' } else { ' ' }
            $mark = if ($items[$i].checked) { '▣' } else { '▢' }
            $text = "  $prefix $mark $($items[$i].label)".PadRight($width - 1)
            if ($i -eq $cur) { Write-Host $text -ForegroundColor White -BackgroundColor DarkBlue }
            elseif ($items[$i].checked) { Write-Host $text -ForegroundColor Cyan }
            else { Write-Host $text -ForegroundColor DarkGray }
        }
        try { [Console]::SetCursorPosition(0, $menuTop + $items.Count) } catch {}
        Write-Host ('  ↑/↓ 移动 · Enter 切换选中 · 「开始部署」回车确认 · Esc 跳过').PadRight($width - 1) -ForegroundColor DarkGray
        # 读键：测试用 $script:KeyQueue 注入；真实交互读控制台。
        # 非交互防卡死：stdin 被重定向（管道/自动化）时 KeyAvailable 立即抛错 → 跳过；
        # 交互终端无人按键时 45 秒超时 → 跳过（真人操作一般远快于此）。
        $key = $null
        try {
            if (@($script:KeyQueue).Count -gt 0) {
                $key = $script:KeyQueue[0]
                $script:KeyQueue = @($script:KeyQueue | Select-Object -Skip 1)
            } else {
                $deadline = [DateTime]::Now.AddSeconds(45)
                while (-not [Console]::KeyAvailable) {
                    if ([DateTime]::Now -gt $deadline) { return @() }
                    Start-Sleep -Milliseconds 100
                }
                $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            }
        } catch { return @() }
        if ($null -eq $key) { return @() }
        switch ($key.Key) {
            ([ConsoleKey]::UpArrow)   { $cur = ($cur - 1 + $items.Count) % $items.Count }
            ([ConsoleKey]::DownArrow) { $cur = ($cur + 1) % $items.Count }
            ([ConsoleKey]::Enter) {  # agent 项切换选中；「开始部署」确认返回
                if ($items[$cur].key -eq '') {
                    return @($items | Where-Object { $_.key -and $_.checked } | ForEach-Object { $_.key })
                }
                $items[$cur].checked = -not $items[$cur].checked
            }
            ([ConsoleKey]::Escape) { return @() }  # 跳过部署
        }
    }
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

# 6.5 交互选择：方向键多选菜单选择部署目标（默认全选，Enter 切换，Esc 跳过）
Write-Host ''
Write-Host '是否把 skill 部署到本机 agent 工具：' -ForegroundColor Cyan
# 与 deploy-agents.ps1 保持一致的 agent 清单（菜单只显示已检测到的）
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
    $selected = Select-AgentMenu $detected
    if ($selected.Count -gt 0) {
        Write-Host ''
        Write-Host "已选择 $($selected.Count) 个：$($selected -join '、')" -ForegroundColor Green
        & powershell -NoProfile -ExecutionPolicy Bypass -File $depScript -Agent ($selected -join ',')
    } else {
        Write-Host ''
        Write-Host '未选择任何 agent，跳过 skill 部署。' -ForegroundColor Yellow
        Write-Host "（之后想装：powershell -ExecutionPolicy Bypass -File `"$depScript`"）" -ForegroundColor DarkGray
    }
}
if ($notFound.Count) {
    Write-Host "未检测到的 agent（装好后重跑本命令即可部署）：$((($notFound | ForEach-Object { $_.name }) -join '、'))" -ForegroundColor DarkGray
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
