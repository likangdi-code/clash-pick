<#
  deploy-agents.ps1 — 把 clash-proxy 的 Agent Skill 部署到本机各 AI agent 工具

  默认部署两个 skill：
    clash-proxy      — 工具使用说明（下载/选节点）
    clash-proxy-fix  — 安装与排障修复

  覆盖工具（检测到对应目录就装；统一 SKILL.md 开放标准）：
    claude / gemini / codex / opencode / hermes / openclaw / grok / agents(共享池 .agents)

  用法：
    powershell -ExecutionPolicy Bypass -File deploy-agents.ps1
        # 部署两个 skill 到本机【所有】已检测到的 agent 工具（默认从 GitHub raw 拉取）
    powershell -ExecutionPolicy Bypass -File deploy-agents.ps1 -Agent claude
        # 只装到【指定】工具（供某个 agent 自己给自己装 skill）
    powershell -ExecutionPolicy Bypass -File deploy-agents.ps1 -SourcePath .\skills\clash-proxy\SKILL.md -SkillName clash-proxy
        # 用本地 SKILL.md 部署单个自定义 skill（离线 / 开发时）

  结束后会汇总「已安装到哪些」「未检测到哪些」，方便你确认还有哪些工具需要单独处理。
#>
param(
  [string]$SkillUrl = '',        # 显式指定单个 skill 的下载 URL（配 -SkillName）
  [string]$SourcePath = '',      # 用本地 SKILL.md（配 -SkillName）
  [string]$Agent = '',           # 只部署指定工具：claude/gemini/codex/opencode/hermes/openclaw/grok/agents
  [string]$SkillName = 'clash-proxy'   # 配合 -SkillUrl/-SourcePath 自定义 skill 时用
)
$ErrorActionPreference = 'Continue'

# 1. 确定要部署的 skills 清单（默认两个；显式传了 SkillUrl/SourcePath 则只部署这一个）
$repoBase = 'https://raw.githubusercontent.com/likangdi-code/clash-verge-url-proxy-cli/main'
if ($SkillUrl -or $SourcePath) {
  $skills = @(@{ name = $SkillName; url = $SkillUrl; src = $SourcePath })
} else {
  $skills = @(
    @{ name = 'clash-proxy';     url = "$repoBase/skills/clash-proxy/SKILL.md";     src = '' },
    @{ name = 'clash-proxy-fix'; url = "$repoBase/skills/clash-proxy-fix/SKILL.md"; src = '' }
  )
}

# 2. 各 agent 工具： key -> (检测目录, skills 目录, 显示名)
$targets = @(
  @{ key = 'claude';    name = 'Claude Code'; dir = "$HOME\.claude";           skills = "$HOME\.claude\skills" },
  @{ key = 'gemini';    name = 'Gemini';      dir = "$HOME\.gemini";          skills = "$HOME\.gemini\skills" },
  @{ key = 'codex';     name = 'Codex';       dir = "$HOME\.codex";           skills = "$HOME\.codex\skills" },
  @{ key = 'opencode';  name = 'OpenCode';    dir = "$HOME\.config\opencode"; skills = "$HOME\.config\opencode\skills" },
  @{ key = 'hermes';    name = 'Hermes';      dir = "$HOME\.hermes";          skills = "$HOME\.hermes\skills" },
  @{ key = 'openclaw';  name = 'OpenClaw';    dir = "$HOME\.openclaw";        skills = "$HOME\.openclaw\skills" },
  @{ key = 'grok';      name = 'Grok';        dir = "$HOME\.grok";            skills = "$HOME\.grok\skills" },
  @{ key = 'agents';    name = '共享池 .agents'; dir = "$HOME\.agents";         skills = "$HOME\.agents\skills" }
)

# 过滤：-Agent 指定了则只处理该工具
if ($Agent) {
  $targets = $targets | Where-Object { $_.key -eq $Agent }
  if (-not $targets) {
    Write-Error "未知工具: $Agent。可用：claude / gemini / codex / opencode / hermes / openclaw / grok / agents"
    exit 1
  }
}

Write-Host ''
$scope = if ($Agent) { "指定工具 [$Agent]" } else { '本机所有 agent 工具' }
$skillList = ($skills | ForEach-Object { $_.name }) -join ' + '
Write-Host "部署 Skill [$skillList] 到 $scope：" -ForegroundColor Cyan

$installed = @()   # { skill, name, dest }
$missing = @()     # { name, key, skillsDir } 工具未检测到
foreach ($t in $targets) {
  if (Test-Path $t.dir) {
    foreach ($s in $skills) {
      # 3. 准备 SKILL.md（本地文件或网络下载），按 skill 名分目录缓存
      $tmp = Join-Path $env:TEMP "deploy-agents-$($s.name)"
      New-Item -ItemType Directory -Force -Path $tmp | Out-Null
      $skillFile = Join-Path $tmp 'SKILL.md'
      if ($s.src) {
        if (-not (Test-Path $s.src)) { Write-Error "本地 SKILL.md 不存在: $($s.src)"; exit 1 }
        Copy-Item $s.src $skillFile -Force
      } elseif (-not (Test-Path $skillFile)) {
        try {
          Invoke-WebRequest -Uri $s.url -OutFile $skillFile -UseBasicParsing
          Write-Host "已下载 SKILL.md: $($s.url)" -ForegroundColor DarkGray
        } catch {
          Write-Error "下载 SKILL.md 失败: $($_.Exception.Message)"
          exit 1
        }
      }
      $dest = Join-Path $t.skills $s.name
      New-Item -ItemType Directory -Force -Path $dest | Out-Null
      Copy-Item $skillFile (Join-Path $dest 'SKILL.md') -Force
      Write-Host "  [✓] $($t.name)  <-  $($s.name)  ->  $dest" -ForegroundColor Green
      $installed += @{ skill = $s.name; name = $t.name; dest = $dest }
    }
  } else {
    Write-Host "  [–] $($t.name)  未检测到（工具未安装），跳过" -ForegroundColor DarkGray
    $missing += @{ name = $t.name; key = $t.key; skillsDir = $t.skills }
  }
}

# 4. 汇总：已安装 / 未检测到（可能要单独安装 skill）
Write-Host ''
if ($installed.Count) {
  Write-Host '✓ 已安装 skill 到：' -ForegroundColor Green -NoNewline
  Write-Host (($installed | ForEach-Object { "$($_.name)[$($_.skill)]" }) -join '、')
} else {
  Write-Host '✗ 未安装到任何工具。' -ForegroundColor Yellow
}
if ($missing.Count) {
  Write-Host ''
  Write-Host '⚠ 以下工具未检测到（对应 agent 未安装或目录不同），可能需要单独安装 skill：' -ForegroundColor Yellow
  foreach ($m in $missing) {
    Write-Host "  · $($m.name) — 装好该工具后重跑本脚本即可自动部署；或手动把 SKILL.md 复制到：$($m.skillsDir)\<skill名>\SKILL.md"
  }
}

# 5. 提示
Write-Host ''
if ($Agent) {
  Write-Host "已完成 [$Agent] 的 skill 部署。" -ForegroundColor DarkGray
} else {
  Write-Host '提示：已装工具重启会话（或 /skills reload）后即可自主调用 clash-proxy。' -ForegroundColor DarkGray
  Write-Host '单个工具单独补装：powershell -ExecutionPolicy Bypass -File deploy-agents.ps1 -Agent <claude|gemini|codex|opencode|hermes|openclaw|grok|agents>' -ForegroundColor DarkGray
}
