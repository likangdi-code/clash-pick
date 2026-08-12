<#
  deploy-agents.ps1 — 把 clash-pick 的 Agent Skill 部署到本机各 AI agent 工具

  覆盖工具（只要装了对应目录，就会把 SKILL.md 装到它的 skills 目录）：
    Claude Code / Gemini / Codex / OpenCode / Hermes / OpenClaw / Grok / 共享池(.agents)

  统一格式：所有工具都支持 Agent Skills 开放标准的 SKILL.md。
  其中 ~/.agents/skills 是跨工具共享路径（Gemini/Codex/Grok 原生扫描它）。

  用法：
    powershell -ExecutionPolicy Bypass -File deploy-agents.ps1
      # 默认从 GitHub raw 拉取 SKILL.md，部署到本机所有已装的 agent 工具
    powershell -ExecutionPolicy Bypass -File deploy-agents.ps1 -SourcePath .\skills\clash-pick\SKILL.md
      # 用本地文件（离线/开发时）
#>
param(
  [string]$SkillUrl = 'https://raw.githubusercontent.com/likangdi-code/clash-pick/main/skills/clash-pick/SKILL.md',
  [string]$SourcePath = ''
)
$ErrorActionPreference = 'Continue'
$skillName = 'clash-pick'

# 1. 准备 SKILL.md（本地文件或网络下载）
$tmp = Join-Path $env:TEMP "deploy-agents-$skillName"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$skillFile = Join-Path $tmp 'SKILL.md'
if ($SourcePath) {
  if (-not (Test-Path $SourcePath)) { Write-Error "本地 SKILL.md 不存在: $SourcePath"; exit 1 }
  Copy-Item $SourcePath $skillFile -Force
  Write-Host "使用本地 SKILL.md: $SourcePath" -ForegroundColor DarkGray
} else {
  try {
    Invoke-WebRequest -Uri $SkillUrl -OutFile $skillFile -UseBasicParsing
    Write-Host "已下载 SKILL.md: $SkillUrl" -ForegroundColor DarkGray
  } catch {
    Write-Error "下载 SKILL.md 失败: $($_.Exception.Message)"
    exit 1
  }
}

# 2. 各 agent 工具的 检测目录 -> skills 目录
$targets = @(
  @{ name = 'Claude Code'; dir = "$env:USERPROFILE\.claude";           skills = "$env:USERPROFILE\.claude\skills" },
  @{ name = 'Gemini';      dir = "$env:USERPROFILE\.gemini";          skills = "$env:USERPROFILE\.gemini\skills" },
  @{ name = 'Codex';       dir = "$env:USERPROFILE\.codex";           skills = "$env:USERPROFILE\.codex\skills" },
  @{ name = 'OpenCode';    dir = "$env:USERPROFILE\.config\opencode"; skills = "$env:USERPROFILE\.config\opencode\skills" },
  @{ name = 'Hermes';      dir = "$env:USERPROFILE\.hermes";          skills = "$env:USERPROFILE\.hermes\skills" },
  @{ name = 'OpenClaw';    dir = "$env:USERPROFILE\.openclaw";        skills = "$env:USERPROFILE\.openclaw\skills" },
  @{ name = 'Grok';        dir = "$env:USERPROFILE\.grok";            skills = "$env:USERPROFILE\.grok\skills" },
  @{ name = '共享池 .agents'; dir = "$env:USERPROFILE\.agents";        skills = "$env:USERPROFILE\.agents\skills" }
)

Write-Host ''
Write-Host "部署 clash-pick Skill 到各 agent 工具:" -ForegroundColor Cyan
$installed = @()
$skipped = @()
foreach ($t in $targets) {
  if (Test-Path $t.dir) {
    $dest = Join-Path $t.skills $skillName
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item $skillFile (Join-Path $dest 'SKILL.md') -Force
    Write-Host "  [✓] $($t.name)  ->  $dest" -ForegroundColor Green
    $installed += $t.name
  } else {
    Write-Host "  [–] $($t.name)  未安装，跳过" -ForegroundColor DarkGray
    $skipped += $t.name
  }
}

# 3. 汇总与提示
Write-Host ''
Write-Host "✓ 已部署到: $($installed -join ', ')" -ForegroundColor Green
if ($skipped.Count) { Write-Host "未安装跳过: $($skipped -join ', ')" -ForegroundColor DarkGray }

if ($installed -contains 'Grok') {
  Write-Host "  Grok 已装 ~/.grok/skills；且它兼容扫描 ~/.claude/skills 与 ~/.agents/skills（默认开启）。"
}
if (-not ($installed -contains 'Grok') -and -not ($skipped -contains 'Grok')) {
  # Grok 未单独安装，但若 Claude/共享池已装，Grok 装好后会自动扫到
  Write-Host "  Grok 未安装；装好后它会兼容扫描 ~/.claude/skills（若已装则自动生效）。"
}
Write-Host ''
Write-Host "提示：各 agent 需重启会话（或 /skills reload）后才会加载新 skill。" -ForegroundColor DarkGray
