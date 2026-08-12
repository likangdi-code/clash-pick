# 🔀 Clash Pick

给 **agent / 脚本** 用的 mihomo 节点选择 CLI。**下载前为任意 URL 自动测出延迟最低的节点并切换**，随后走代理下载。可**自动建「网址代理」组**（配合 Clash Verge 网址代理版），也可复用已建好的组。

## 简介

Clash Pick 是一个 **Node 零 npm 依赖** 的命令行工具，直接连接 [Clash Verge（网址代理版）](https://github.com/likangdi-code/clash-verge-url-proxy) 内置的 mihomo（Windows 命名管道 / macOS·Linux Unix socket，免配置、无 secret）。它解决一个具体问题：**下载文件之前，先针对下载链接选出最快的节点，再开始下载**——尤其适合 AI agent 自动执行。

```
下载链接 ──▶ clash-pick add/pick <url> ──▶ 自动命中网址代理组（无则 add 自动建组）
                                                │ 并发测速（针对该 URL）
                                                ▼
                                        切到延迟最低的节点
                                                │
                                  curl --proxy http://127.0.0.1:7897 -L -O <url>
```

## Preview

```console
$ clash-pick add "https://example.com"

✓ 已创建网址代理组 URL-Proxy-ptDiIw（example.com）
组: URL-Proxy-ptDiIw  测速节点: 71 个
✓ 已切换 URL-Proxy-ptDiIw → 距离下次重置剩余：17 天 (46 ms)
下载: curl --proxy http://127.0.0.1:7897 -L -O 'https://example.com'
```

## 与 Clash Verge（网址代理版）联合使用

Clash Pick 与 [Clash Verge（网址代理版）](https://github.com/likangdi-code/clash-verge-url-proxy) 是**同一个体系的两面**——共用同一份「网址代理」组与规则：

| | Clash Verge（网址代理版）GUI | Clash Pick CLI |
|---|---|---|
| 角色 | 可视化管理「网址代理」 | 自动化测速选节点 |
| 建组 | 界面手动新建 `URL-Proxy-*` 组 | `add` 全自动建组（走命令桥） |
| 选节点 | 手动点击 / ⚡ 测速 / AUTO | `pick` 自动切最低延迟 |
| 适用 | 日常手动使用 | agent / 脚本 / 下载自动化 |

**联合工作流（AI agent 下载场景）**：

```bash
# 1. agent 拿到下载链接，全自动建组 + 选最优节点（Verge 在跑即可）
clash-pick add "https://example.com/big-file.zip" --json
#    → 该域名没建过组时自动建 URL-Proxy-* 组（写增强文件 + reload，命令桥完成）

# 2. 走 mihomo 混入端口下载（命中网址代理规则 → 走刚选中的节点）
curl --proxy http://127.0.0.1:7897 -L -o big-file.zip "https://example.com/big-file.zip"

# 3. 打开 Clash Verge 的「网址代理」页 → 能看到刚才自动建的组，随时手动调整节点
```

- **共用同一份组/规则**：GUI 建的组，CLI 能 `pick`；CLI `add` 建的组，GUI 能看到并可手动管理。两者操作同一个 mihomo 内核与增强文件。
- **互补**：GUI 适合可视化巡检和手动微调，CLI 适合把「下载前选最优节点」自动化（尤其 agent 自主执行）。

> ⚠️ `add` 依赖 Verge 的**命令桥**（`/commands/profile-save`），需要**含命令桥的构建**（本次发布的安装包已含此能力）。旧版 Verge 仍可用 `pick`（对已建组测速切换）。

## 快速开始

### 安装工具

**Windows**（PowerShell 终端一行）：

```powershell
irm https://raw.githubusercontent.com/likangdi-code/clash-pick-cli/main/install.ps1 | iex
```

**macOS / Linux**（终端一行）：

```sh
curl -fsSL https://raw.githubusercontent.com/likangdi-code/clash-pick-cli/main/install.sh | sh
```

安装后新开终端即可用 `clash-pick`。需要 Node.js（≥18）。本脚本**只装工具、不装 skill**。

### 平台支持

| 平台 | 连接 mihomo | 安装 |
|---|---|---|
| Windows | 命名管道 `\\.\pipe\verge-mihomo`（免配置） | `install.ps1` |
| macOS | Unix socket `/tmp/verge/verge-mihomo.sock`（免配置） | `install.sh` |
| Linux | Unix socket `/tmp/verge/verge-mihomo.sock`（免配置） | `install.sh` |

clash-pick 自动检测平台选 IPC 方式；也可用 `CLASH_API` 指向任意 mihomo HTTP external-controller。

### 部署 Agent Skill（让 agent 自主调用）

把 clash-pick 的 **Agent Skill** 部署到本机**所有已装的 AI agent 工具**（Claude Code / Gemini / Codex / OpenCode / Hermes / OpenClaw / Grok / 共享池 `~/.agents/skills`），结束后汇总「已安装到哪些 / 未检测到哪些」：

```powershell
# Windows: powershell · macOS/Linux 需 pwsh（brew install powershell）
powershell -ExecutionPolicy Bypass -File deploy-agents.ps1
# 只装到指定 agent（如 Claude Code）：
powershell -ExecutionPolicy Bypass -File deploy-agents.ps1 -Agent claude
```

装好后对应 agent 在「下载 / 选节点 / 走代理」场景下会**自主调用** clash-pick，无需手动敲命令。

## 使用教程（Agent 下载流程）

1. **全自动建组 + 选节点**：
   ```bash
   clash-pick add "https://example.com/big-file.zip"   # 没建过组 → 自动建；已建 → 复用
   ```
   或仅对已建组测速切换：`clash-pick pick "https://example.com/big-file.zip"`
2. 走 mihomo 混入端口下载：
   ```bash
   curl --proxy http://127.0.0.1:7897 -L -o big-file.zip "https://example.com/big-file.zip"
   ```

## 核心功能

- **子命令**：`add <url>`（自动建组 + 测速切换）、`pick <url>`（测速切换已有组）、`test <url>`（只测速）、`list`、`current`
- **`--json` 输出**：机器可读（bestNode / bestDelay / group / top），供 agent 程序化解析
- **自动命中网址代理组**：从 mihomo `/rules` 探测 `DOMAIN-SUFFIX` 规则 → `URL-Proxy-*` 组；命中多个取最具体的域名
- **无命中回退 GLOBAL**：未建组的域名切 GLOBAL（rule 模式下未匹配规则的流量走它）
- **针对 URL 精确测速**：`GET /proxies/{name}/delay?url=<url>`

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
| `CLASH_API` | 覆盖端点，如 `http://127.0.0.1:9097`（默认命名管道 / Unix socket） |
| `CLASH_SOCK` | 覆盖 Unix socket 路径（macOS/Linux） |
| `CLASH_PIPE` | 覆盖 Windows 命名管道路径 |
| `CLASH_SECRET` | HTTP 模式下的 secret（socket/pipe 传输无需 secret） |
| `CLASH_MIXED_PORT` | 下载命令提示的代理端口（默认 7897） |

## 特性

- **零配置**：走 Verge 命名管道 / Unix socket，免开 external controller、免 secret
- **零 npm 依赖**：纯 Node + vendored js-yaml，无需 `npm install`
- **针对 URL 精确测速**，而不是用固定测试站
- **并发测速**（默认 12 路），全节点秒出结果
- **自动建组**：`add` 全自动写增强文件 + reload（走 Verge 命令桥）
- **`--json`** 结构化输出，天然适配 agent 工具调用
- **幂等安装脚本**：重复运行只更新不产生重复 PATH 条目

## 工作原理

1. 解析 URL → 域名
2. `GET /proxies` 拿节点与组；`GET /rules` 探测命中的网址代理组
3. `add`：读当前订阅增强文件 → 生成 `URL-Proxy-*` 组 + `DOMAIN-SUFFIX` 规则 → 经 Verge 命令桥写盘 + 校验 + reload
4. 组内节点**针对该 URL** 并发测速
5. `PUT /proxies/{group}` 切到延迟最低的节点

## 开发

零 npm 依赖的 Node 脚本，无需构建：

```bash
git clone https://github.com/likangdi-code/clash-pick-cli
cd clash-pick
node clash-pick.mjs list        # 直接运行
```

前置：本机运行着 Clash Verge（网址代理版）（或任意暴露 external-controller 的 mihomo，用 `CLASH_API` 指定）。

## 致谢

- [clash-verge-url-proxy](https://github.com/likangdi-code/clash-verge-url-proxy) — 「网址代理」功能、组/规则机制与命令桥
- [clash-verge-rev](https://github.com/clash-verge-rev/clash-verge-rev) — Clash Verge Rev 项目
- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) — mihomo 内核与 external-controller API

## License

[GPL-3.0](LICENSE)
