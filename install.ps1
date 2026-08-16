<#
  install.ps1 — clash-proxy 工具一键安装（兼作更新命令，重跑即更新工具 + skill）

  用法（PowerShell 终端粘贴一行即可）：
    irm https://raw.githubusercontent.com/likangdi-code/clash-verge-url-proxy-cli/main/install.ps1 | iex

  效果：
    - 把 clash-proxy.mjs + clash-proxy.cmd 安装到 %LOCALAPPDATA%\Programs\clash-proxy
    - 把安装目录加入「用户 PATH」，当前与未来终端都能直接 `clash-proxy`
    - 幂等：重复运行 = 更新命令。查 GitHub API 最新 commit 与每个文件的
      git blob SHA-1，与本地对比：只有变化的文件才重新下载（下载后哈希校验，
      CDN 缓存延迟自动重试），全部一致则提示「已是最新」并跳过下载
    - 删除 %LOCALAPPDATA%\Programs\clash-proxy\.version 再重跑 = 强制重装
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
# 菜单始终列出全部 agent；enabled=false（本机未检测到）的置灰且不可勾选。
# 读键：Win32 console API 优先（.NET Console 类与 RawUI.KeyAvailable 在
# Windows Terminal/ConPTY + PS5.1 下会抛错导致菜单被误跳过；Win32 是 Windows
# Terminal 官方兼容层）；Add-Type 不可用降级 RawUI；自动化（stdin 重定向）
# HasInput 恒 false → 超时跳过（默认 45s，CLASH_PROXY_MENU_TIMEOUT 可缩短）。
# 测试可用 $script:KeyQueue 注入按键流（ConsoleKeyInfo 数组）。
function Select-AgentMenu {
    param([object[]]$Agents)  # 每个元素含 key / name / enabled
    # 懒编译 Win32 控制台输入封装（一次会话一次；编译失败则降级 RawUI 轮询）。
    # 类型名带版本后缀：同一 PowerShell 窗口跑过旧版脚本会残留旧类型，
    # 同名 Add-Type 会抛"类型已存在"导致降级（菜单按键失效）。
    if ($null -eq $script:ConInReady) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClashConInV4 {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetNumberOfConsoleInputEvents(IntPtr hConsoleInput, out uint lpNumberOfEvents);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool ReadConsoleInput(IntPtr hConsoleInput, out INPUT_RECORD lpBuffer, uint nLength, out uint lpNumberOfEventsRead);
    [StructLayout(LayoutKind.Sequential)] public struct KEY_EVENT_RECORD {
        public bool bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode; public char UnicodeChar; public uint dwControlKeyState;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT_RECORD {
        public ushort EventType; public KEY_EVENT_RECORD KeyEvent;
    }
    public static bool HasInput() {
        IntPtr h = GetStdHandle(-10);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
        uint n; return GetNumberOfConsoleInputEvents(h, out n) && n > 0;
    }
    public static int ReadKeyVk() {
        // 只读队列中已有的事件（绝不阻塞）：ReadConsoleInput 队列空时会阻塞等待，
        // 会把用户后续按键吃掉。读到 KeyDown 返回 VK；只有 KeyUp/其他则返回 0，
        // 由 PS 层继续轮询。
        IntPtr h = GetStdHandle(-10);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return 0;
        uint n;
        if (!GetNumberOfConsoleInputEvents(h, out n) || n == 0) return 0;
        INPUT_RECORD r; uint read;
        for (uint i = 0; i < n; i++) {
            if (!ReadConsoleInput(h, out r, 1, out read) || read == 0) return 0;
            if (r.EventType == 1 && r.KeyEvent.bKeyDown) return r.KeyEvent.wVirtualKeyCode;
        }
        return 0;
    }
    public static void FlushInput() {
        // 丢弃队列中已有残留事件（如执行命令的 Enter KeyUp、鼠标/焦点事件），
        // 防止菜单刚显示就被残留事件误触发/读到空队列提前退出。
        // 注意：ReadConsoleInput 是阻塞调用，必须先查队列长度、只读已有事件数，
        // 否则队列空时会阻塞等待并把用户后续按键全部吃掉（菜单卡死不显示）。
        IntPtr h = GetStdHandle(-10);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return;
        uint n;
        if (!GetNumberOfConsoleInputEvents(h, out n) || n == 0) return;
        INPUT_RECORD r; uint read;
        for (uint i = 0; i < n; i++) ReadConsoleInput(h, out r, 1, out read);
    }
}
'@ -ErrorAction Stop
            $script:ConInReady = $true
        } catch { $script:ConInReady = $false }
    }
    # 菜单开始时清空一次输入队列：丢弃执行本安装命令的 Enter KeyUp 等残留事件，
    # 防止菜单刚显示就误读残留（KeyUp 读不到 KeyDown 会让旧逻辑提前跳过/误触发）
    if ($script:ConInReady) {
        try { [ClashConInV4]::FlushInput() } catch {}
    } elseif (-not $script:WarnedFallback) {
        Write-Host '（提示：Win32 读键不可用，菜单按键可能无响应）' -ForegroundColor DarkYellow
        $script:WarnedFallback = $true
    }
    $items = @()
    foreach ($a in $Agents) {
        $items += [pscustomobject]@{ key = $a.key; label = "[$($a.key)] $($a.name)"; checked = $a.enabled; enabled = $a.enabled }
    }
    $items += [pscustomobject]@{ key = ''; label = '开始部署'; checked = $true; enabled = $true }
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
            $label = $items[$i].label
            if (-not $items[$i].enabled) { $label += '（未检测到，不可选）' }
            $text = "  $prefix $mark $label".PadRight($width - 1)
            if ($i -eq $cur) { Write-Host $text -ForegroundColor White -BackgroundColor DarkBlue }
            elseif (-not $items[$i].enabled) { Write-Host $text -ForegroundColor DarkGray }
            elseif ($items[$i].checked) { Write-Host $text -ForegroundColor Cyan }
            else { Write-Host $text -ForegroundColor DarkGray }
        }
        try { [Console]::SetCursorPosition(0, $menuTop + $items.Count) } catch {}
        Write-Host ('  ↑/↓ 移动 · Enter 切换选中 · 「开始部署」回车确认 · Esc 跳过').PadRight($width - 1) -ForegroundColor DarkGray
        $key = $null
        try {
            if (@($script:KeyQueue).Count -gt 0) {
                $ki = $script:KeyQueue[0]
                $script:KeyQueue = @($script:KeyQueue | Select-Object -Skip 1)
                $key = [int]$ki.Key  # ConsoleKey 枚举值 == Win32 VK 码
            } elseif ($script:ConInReady) {
                # 首选：Win32 直接读控制台输入。.NET Console 类在 Windows Terminal
                # (ConPTY) + PS5.1 下会抛错导致菜单被误跳过；Win32 console API 是
                # Windows Terminal 官方承诺兼容的层。自动化（stdin 重定向）下
                # HasInput 恒 false → 超时跳过（默认 45s，可用
                # $env:CLASH_PROXY_MENU_TIMEOUT 缩短，CI 用）。
                # 残留事件（执行 irm|iex 命令的 Enter KeyUp 等）在菜单开始时已清空；
                # ReadKeyVk 读空队列（只剩 KeyUp 时）返回 0 → 继续轮询而非跳过。
                $timeoutSec = if ($env:CLASH_PROXY_MENU_TIMEOUT) { [int]$env:CLASH_PROXY_MENU_TIMEOUT } else { 45 }
                $deadline = [DateTime]::Now.AddSeconds($timeoutSec)
                $key = 0
                while ($key -eq 0) {
                    if ([DateTime]::Now -gt $deadline) { return @() }
                    if ([ClashConInV4]::HasInput()) { $key = [ClashConInV4]::ReadKeyVk() }
                    else { Start-Sleep -Milliseconds 100 }
                }
            } else {
                # 降级：RawUI 轮询（Add-Type 不可用时的传统 conhost / PS7 兜底）
                $timeoutSec = if ($env:CLASH_PROXY_MENU_TIMEOUT) { [int]$env:CLASH_PROXY_MENU_TIMEOUT } else { 45 }
                $deadline = [DateTime]::Now.AddSeconds($timeoutSec)
                while (-not $Host.UI.RawUI.KeyAvailable) {
                    if ([DateTime]::Now -gt $deadline) { return @() }
                    Start-Sleep -Milliseconds 100
                }
                $key = [int]($Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')).Key
            }
        } catch { return @() }
        if ($null -eq $key) { return @() }
        switch ($key) {  # VK 码：38=↑ 40=↓ 13=Enter 27=Esc
            38 { $cur = ($cur - 1 + $items.Count) % $items.Count }
            40 { $cur = ($cur + 1) % $items.Count }
            13 {  # agent 项切换选中（未检测到的不可选）；「开始部署」确认返回
                if ($items[$cur].key -eq '') {
                    return @($items | Where-Object { $_.key -and $_.checked -and $_.enabled } | ForEach-Object { $_.key })
                }
                if ($items[$cur].enabled) { $items[$cur].checked = -not $items[$cur].checked }
            }
            27 { return @() }  # 跳过部署
        }
    }
}

$repoBase = 'https://raw.githubusercontent.com/likangdi-code/clash-verge-url-proxy-cli/main'
$repoRaw  = 'https://raw.githubusercontent.com/likangdi-code/clash-verge-url-proxy-cli'
$apiBase  = 'https://api.github.com/repos/likangdi-code/clash-verge-url-proxy-cli'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\clash-proxy'
$versionFile = Join-Path $installDir '.version'

# 需要下载并哈希校验的文件（git 树路径 → 安装目录内路径）
$files = @(
  @{ path = 'clash-proxy.mjs';    dest = 'clash-proxy.mjs' },
  @{ path = 'downloader.mjs';     dest = 'downloader.mjs' },
  @{ path = 'vendor/js-yaml.mjs'; dest = 'vendor\js-yaml.mjs' },
  @{ path = 'deploy-agents.ps1';  dest = 'deploy-agents.ps1' }
)

# 查最新 commit SHA（= 版本号）。API 不可用时返回 $null（降级：跳过版本判定与校验）
function Get-GitLatestSha {
    try {
        $r = Invoke-RestMethod -Uri "$apiBase/commits/main" -Headers @{ 'User-Agent' = 'clash-proxy-install' } -UseBasicParsing
        return $r.sha
    } catch { return $null }
}

# 一次拿全仓文件的 git blob SHA-1 表（path -> sha）。API 不可用时返回 $null
function Get-GitFileShas {
    param([string]$Ref)
    try {
        # 注意：必须写成 ${Ref}——PowerShell 变量名可含 '?'，$Ref?recursive 会把 ?recursive 吞进变量名
        $r = Invoke-RestMethod -Uri "$apiBase/git/trees/${Ref}?recursive=1" -Headers @{ 'User-Agent' = 'clash-proxy-install' } -UseBasicParsing
        $map = @{}
        foreach ($t in $r.tree) { if ($t.type -eq 'blob') { $map[$t.path] = $t.sha } }
        return $map
    } catch { return $null }
}

# 计算文件的 git blob SHA-1（"blob <字节数>\0" + 内容），与 GitHub 树里的一致可比对
function Get-GitBlobSha([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $all = New-Object byte[] ($header.Length + $bytes.Length)
    [Array]::Copy($header, 0, $all, 0, $header.Length)
    [Array]::Copy($bytes, 0, $all, $header.Length, $bytes.Length)
    $hash = [Security.Cryptography.SHA1]::Create().ComputeHash($all)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

# 下载 + 哈希校验 + 重试（CDN 缓存延迟/网络抖动时自动重试；校验仍失败返回 $false）
function Invoke-DownloadChecked {
    param([string]$Url, [string]$Dest, [string]$ExpectedSha, [int]$Retries = 3)
    for ($i = 1; $i -le $Retries; $i++) {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
        $actual = Get-GitBlobSha $Dest
        if ($actual -eq $ExpectedSha) { return $true }
        Write-Host "    哈希不一致（预期 $($ExpectedSha.Substring(0, 8))… 实际 $($actual.Substring(0, 8))…），$($Retries - $i) 次后重试…" -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
    return $false
}

# 1. 前置检查：需要 Node.js（clash-proxy 是零依赖 Node 脚本）
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error '未找到 Node.js。请先安装 Node.js（https://nodejs.org）后重试。'
    exit 1
}

# 2. 创建安装目录
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# 3. 版本判定 + 逐文件增量下载 + 哈希校验
Write-Host '检查更新…' -ForegroundColor DarkGray
$latestSha = Get-GitLatestSha
$treeShas = if ($latestSha) { Get-GitFileShas $latestSha } else { $null }
$lastSha = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
if ($latestSha -and $treeShas) {
    if ($lastSha -eq $latestSha) {
        Write-Host "已是最新版本（commit $($latestSha.Substring(0, 8))），工具无需更新。" -ForegroundColor Green
    } else {
        Write-Host ("发现新版本：{0} → {1}" -f $(if ($lastSha) { $lastSha.Substring(0, 8) } else { '全新安装' }), $latestSha.Substring(0, 8)) -ForegroundColor Cyan
    }
} else {
    Write-Host '⚠ 无法访问 GitHub API（网络/代理问题），跳过版本检查与哈希校验，直接安装。' -ForegroundColor Yellow
}
New-Item -ItemType Directory -Force -Path (Join-Path $installDir 'vendor') | Out-Null
$downloaded = @(); $skipped = @()
foreach ($f in $files) {
    $dest = Join-Path $installDir $f.dest
    $expected = if ($treeShas) { $treeShas[$f.path] } else { $null }
    if ($expected -and (Test-Path $dest) -and ((Get-GitBlobSha $dest) -eq $expected)) {
        Write-Host "  [=] $($f.path) 未变化，跳过" -ForegroundColor DarkGray
        $skipped += $f.path
        continue
    }
    Write-Host "  [↓] 下载 $($f.path)" -ForegroundColor Cyan
    # 用 commit SHA 路径下载（不可变对象，绕开 main 分支 CDN 渐进缓存）；API 不可用时退回 main 路径
    $url = if ($latestSha) { "$repoRaw/$latestSha/$($f.path)" } else { "$repoBase/$($f.path)" }
    $ok = if ($expected) { Invoke-DownloadChecked $url $dest $expected } else { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing; $true }
    if (-not $ok) {
        Write-Host "  ✗ $($f.path) 下载后哈希校验失败（GitHub CDN 缓存延迟），请稍后重跑本命令。" -ForegroundColor Red
        exit 1
    }
    $downloaded += $f.path
}
if ($latestSha) { Set-Content -Path $versionFile -Value $latestSha -Encoding ASCII }
if ($downloaded.Count -gt 0) {
    Write-Host "已更新 $($downloaded.Count) 个文件：$($downloaded -join '、')" -ForegroundColor Green
}
if ($skipped.Count -gt 0) {
    Write-Host "跳过 $($skipped.Count) 个未变化文件：$($skipped -join '、')" -ForegroundColor DarkGray
}

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

# 6. deploy-agents.ps1 已在第 3 步随 files 清单下载并校验
$depScript = Join-Path $installDir 'deploy-agents.ps1'

# 6.5 交互选择：方向键多选菜单选择部署目标（全部列出，已检测的可选，Esc 跳过）
Write-Host ''
Write-Host '是否把 skill 部署到本机 agent 工具：' -ForegroundColor Cyan
# 与 deploy-agents.ps1 保持一致的 agent 清单（菜单列出全部，未检测到的置灰不可选）
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
# 菜单列出全部 agent（已检测到的可选、默认选中；未检测到的置灰「不可选」）
$menuItems = @()
foreach ($t in $targets) {
    $menuItems += [pscustomobject]@{ key = $t.key; name = $t.name; enabled = (Test-Path $t.dir) }
}
$selected = Select-AgentMenu $menuItems
if ($selected.Count -gt 0) {
    Write-Host ''
    Write-Host "已选择 $($selected.Count) 个：$($selected -join '、')" -ForegroundColor Green
    & powershell -NoProfile -ExecutionPolicy Bypass -File $depScript -Agent ($selected -join ',')
} else {
    Write-Host ''
    Write-Host '未选择任何 agent，跳过 skill 部署。' -ForegroundColor Yellow
    Write-Host "（之后想装：powershell -ExecutionPolicy Bypass -File `"$depScript`"）" -ForegroundColor DarkGray
}
$notFound = @($targets | Where-Object { -not (Test-Path $_.dir) })
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
