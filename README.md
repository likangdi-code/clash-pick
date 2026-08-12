# 🔀 Clash Pick

给 **agent / 脚本** 用的 mihomo 节点选择 CLI。**下载前为任意 URL 自动测出延迟最低的代理节点并切换**，随后走代理下载——复用 Clash Verge Rev「网址代理」建好的组与规则。

## 简介

Clash Pick 是一个 **Node.js 零依赖** 的命令行工具，直接连接 Clash Verge Rev 内置的 mihomo（走命名管道 `\\.\pipe\verge-mihomo`，免配置、无 secret）。它解决一个具体问题：**AI agent 下载文件之前，先针对下载链接选出最快的节点，再开始下载**。

```
下载链接 ──▶ clash-pick pick <url> ──▶ 自动命中网址代理组/回退 GLOBAL
                                            │ 并发测速（针对该 URL）
                                            ▼
                                   切到延迟最低的节点
                                            │
                                    curl --proxy http://127.0.0.1:7897 -L -O <url>
```

## Preview

```console
$ clash-pick pick "https://web.telegram.org"

目标: web.telegram.org  (https://web.telegram.org)
切换组: URL-Proxy-duZqQPjG (网址代理组)
测速节点: 71 个
延迟最低:
     281 ms  🇯🇵 日本01 ◀
     285 ms  🇨🇳 台湾02
     296 ms  🇨🇭 瑞士
✓ 已切换 URL-Proxy-duZqQPjG → 🇯🇵 日本01 (281 ms)
下载: curl --proxy http://127.0.0.1:7897 -L -O 'https://web.telegram.org'
```

## 核心功能

### 一键安装

Windows PowerShell 终端粘贴**一行命令**即完成部署（安装到 `%LOCALAPPDATA%\Programs\clash-pick` 并加入 PATH）：

```powershell
irm https://raw.githubusercontent.com/likangdi-code/clash-pick/main/install.ps1 | iex
```

安装后新开终端即可使用 `clash-pick`。需要 Node.js（≥18）。

> ✨ 安装脚本还会把 **Agent Skill** 部署到本机**所有已装的 AI agent 工具**——Claude Code、Gemini CLI、Codex、OpenCode、Hermes、OpenClaw、Grok、共享池 `~/.agents/skills`。它们在「下载 / 选节点 / 走代理」场景下会**自主调用** clash-pick，无需手动敲命令。想单独重装/补装：`powershell -ExecutionPolicy Bypass -File deploy-agents.ps1`。

### 使用教程（Agent 下载流程）

1. 为下载链接选最低延迟节点：
   ```bash
   clash-pick pick "https://example.com/big-file.zip"
   ```
2. 用 mihomo 混入端口下载（命中网址代理规则 → 走刚选中的节点）：
   ```bash
   curl --proxy http://127.0.0.1:7897 -L -o big-file.zip "https://example.com/big-file.zip"
   ```

### 功能细节

- **子命令**：`pick <url>`（测速+自动切换）、`test <url>`（只测速不切）、`list`、`current`
- **`--json` 输出**：机器可读，供 agent 程序化解析（含 bestNode/bestDelay/group/top）
- **自动命中网址代理组**：从 mihomo `/rules` 探测 `DOMAIN-SUFFIX` 规则 → `URL-Proxy-*` 组；命中多个取最具体的域名
- **无命中回退 GLOBAL**：未建网址代理组的域名切 GLOBAL，rule 模式下未匹配规则的下载流量走它
- **针对 URL 测速**：`GET /proxies/{name}/delay?url=<url>`，测的是目标 URL 的真实连通延迟
- **纯 REST 读取/切换**：不建组（建组需 Verge 增强文件 + reload，请在 Verge「网址代理」页面操作）

### 选项与环境变量

| 选项 | 说明 |
|---|---|
| `--group <组名>` | 指定切换的组（默认自动探测） |
| `--timeout <ms>` | 单节点测速超时（默认 5000） |
| `--concurrency <n>` | 并发测速数（默认 12） |
| `--top <n>` | 只显示延迟最低的前 n 个 |
| `--json` | 输出 JSON |
| `--no-switch` | 只测速不切换 |

| 环境变量 | 说明 |
|---|---|
| `CLASH_API` | 覆盖端点，如 `http://127.0.0.1:9097`（默认命名管道） |
| `CLASH_SECRET` | HTTP 模式下的 secret |
| `CLASH_MIXED_PORT` | 下载命令提示的代理端口（默认 7897） |

## 特性

- **零配置**：走 Clash Verge Rev 命名管道，免开 external controller、免 secret
- **零依赖**：纯 Node 原生模块，无 `npm install`
- **针对 URL 精确测速**，而不是用固定测试站
- **并发测速**（默认 12 路），全节点秒出结果
- **`--json`** 结构化输出，天然适配 agent 工具调用
- **幂等安装脚本**：重复运行只更新不产生重复 PATH 条目

## 工作原理

1. 解析 URL → 域名
2. `GET /proxies` 拿节点与组
3. `GET /rules` 探测该域名命中的网址代理组
4. 组内节点**针对该 URL** 并发测速
5. `PUT /proxies/{group}` 切到延迟最低的节点

## 开发

零依赖 Node 脚本，无需构建：

```bash
git clone https://github.com/likangdi-code/clash-pick
cd clash-pick
node clash-pick.mjs list        # 直接运行
```

前置：本机运行着 Clash Verge Rev（或任意暴露 external-controller 的 mihomo，用 `CLASH_API` 指定）。

## 致谢

- [clash-verge-url-proxy](https://github.com/likangdi-code/clash-verge-url-proxy) — 「网址代理」功能与组/规则机制
- [clash-verge-rev](https://github.com/clash-verge-rev/clash-verge-rev) — Clash Verge Rev 项目
- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) — mihomo 内核与 external-controller API

## License

[GPL-3.0](LICENSE)
