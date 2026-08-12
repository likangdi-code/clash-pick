---
name: clash-pick
description: >
  下载前为 URL 自动选最低延迟节点的 mihomo/Clash Verge Rev CLI 工具。
  TRIGGER on: "下载"、"download"、"走代理下载"、"通过代理下载"、"选节点"、"选最快节点"、
  "最低延迟节点"、"最快节点"、"clash"、"mihomo"、"网址代理"、"URL proxy"、"代理测速"、
  "节点测速"、"换节点下载"、"Github release 下载"、"telegram 文件下载"、"下载速度慢"、
  "下载失败"、"curl 代理下载"、"big-file"、"release asset 下载"、"代理下载大文件"。
---

# Clash Pick — 下载前为 URL 选最低延迟节点

给 agent 用的下载前置工具：**针对下载链接，自动测出延迟最低的代理节点并切换，再用代理下载**。
复用 Clash Verge Rev「网址代理」建好的组与规则。

## 前置条件（不满足先装）

1. Node.js ≥18。
2. Clash Verge Rev 正在运行（本机 mihomo，命名管道 `\\.\pipe\verge-mihomo` 免配置直连）。
3. `clash-pick` 命令可用。检查：PowerShell 里 `Get-Command clash-pick`。
   没有 → 一键安装：
   ```powershell
   irm https://raw.githubusercontent.com/likangdi-code/clash-pick/main/install.ps1 | iex
   ```

## 先判断 Clash 是否在运行（未运行则跳过测速）

调用 clash-pick 前先确认本机 mihomo 在线。**判断方法**：直接跑

```bash
clash-pick list
```

- 正常输出「内核 / 真节点 / 网址代理组」→ clash 在跑，继续下面的选节点流程。
- 输出 `⚠️ 未检测到 Clash 在运行`（退出码非 0）→ **跳过测速，不要硬跑 `pick`**。此时二选一：
  1. 告诉用户「Clash Verge Rev 未运行，无法走代理选节点」，请用户先启动 Clash Verge Rev；
  2. 或直接**直连下载**（不经代理）。若直连下载失败/太慢，再回头让用户启动 clash 后重新选节点。

> 只有 clash 在线时才需要测速选节点；clash 离线时测速毫无意义（还会报连接错误浪费时间）。

## Agent 下载工作流（标准流程）

下载**任何需要走代理的文件**前，先选节点再下载。**优先用 `add`**——该域名没建过网址代理组时自动建组（写增强文件 + reload，走 Verge 命令桥；Verge 在跑即可）：

```bash
# 1a. 全自动：为 URL 建网址代理组（已存在则复用）+ 测速切换最低延迟节点
clash-pick add "<下载URL>" --json

# 1b. 或仅对已建的组测速切换（无需建组）
clash-pick pick "<下载URL>" --json

# 2. 解析 JSON 拿到 bestNode / group，确认已切换（switched: true）

# 3. 走 mihomo 混入端口下载（命中网址代理规则 → 流量走刚选中的节点）
curl --proxy http://127.0.0.1:7897 -L -o <文件名> "<下载URL>"
```

`--json` 返回字段（供 agent 程序化解析）：
```json
{"ok":true,"host":"github.com","group":"GLOBAL","isUrlProxy":false,
 "bestNode":"🇯🇵 日本02","bestDelay":70,"switched":true,
 "candidatesTested":70,"top":[{"name":"🇯🇵 日本02","delay":70}]}
```
- `switched: true` = 已切到 `bestNode`；`isUrlProxy: true` = 命中网址代理组（精准路由）。
- `isUrlProxy: false` = 该域名没建网址代理组，切的是 GLOBAL——rule 模式下**只有未匹配规则的流量**走它。若下载仍走别的组，说明该域名被订阅里的其他规则匹配了，需在 Verge「网址代理」页面为该域名建组。

## 常用命令

| 命令 | 说明 |
|---|---|
| `clash-pick pick <url>` | 测速 + 自动切换最低延迟节点（推荐） |
| `clash-pick test <url>` | 只测速不切换（看节点快慢） |
| `clash-pick list` | 列真节点、网址代理组、域名→组规则 |
| `clash-pick current` | 看 GLOBAL 与各网址代理组当前选中 |

常用选项：`--timeout 6000`（测速超时，下载慢时加大）、`--concurrency 16`（并发）、`--group <组名>`（显式指定切换组）、`--json`。

## 常见场景

- **GitHub Release 下载慢**：`clash-pick pick "https://github.com/<owner>/<repo>/releases/download/..."` → 解析 `bestNode` → curl 下载。
- **无法直连的域名**：先看 `clash-pick list` 里有没有该域名已建的网址代理组；没有就 `pick`（回退 GLOBAL）并提示用户可在 Verge 里建组。
- **大文件/多线程下载**：`clash-pick pick` 选好节点后，可用 `curl --proxy http://127.0.0.1:7897` 或任何支持 socks5 的工具（`socks5h://127.0.0.1:7897`）下载。

## 排障

- `clash-pick list` 报「无法连接」→ Verge 没在跑 / 内核没起，先启动 Clash Verge Rev。
- 测速全部失败（`无可用节点`）→ 网络不通或超时太短，加 `--timeout 10000` 重试。
- `✗ 切换失败（HTTP 400 ... proxy not exist）` → 订阅刷新后该节点已重命名/移除，重新 `clash-pick pick` 一次即可（会用当前有效节点）。
- 下载走了错误节点 → 该域名可能被订阅内其他规则先匹配；用 `--group` 指定网址代理组，或在 Verge「网址代理」页为该域名建组。

## 边界

- clash-pick **不建组**（建组需 Verge 增强文件 + reload）。全新域名想精准路由：先在 Verge「网址代理」页面添加该域名，再 `pick`。
- 只测速**真实节点**，跳过策略组（Selector/URLTest/Fallback 等）。

## 参考

- 仓库：https://github.com/likangdi-code/clash-pick（README 有完整说明）
- 配套 GUI 项目（网址代理功能来源）：https://github.com/likangdi-code/clash-verge-url-proxy
