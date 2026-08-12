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

给 agent 用的下载工具：**针对下载链接，自动测出延迟最低的代理节点并切换，再用代理下载**。
可用 `dl` 把「选节点 + 多线程下载」一步完成，也可只选节点（`add`/`pick`）后自行 curl。
复用 Clash Verge Rev「网址代理」建好的组与规则。

## 前置条件（不满足先装）

1. Node.js ≥18。
2. Clash Verge Rev 正在运行（本机 mihomo，命名管道 `\\.\pipe\verge-mihomo` 免配置直连）。
3. `clash-pick` 命令可用。检查：PowerShell 里 `Get-Command clash-pick`。
   没有 → 一键安装：
   ```powershell
   irm https://raw.githubusercontent.com/likangdi-code/clash-pick-cli/main/install.ps1 | iex
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

## 时序要求：先选节点，后下载（强制）

**当你要下载一个链接、且决定用 clash-pick 选节点时，必须严格按顺序执行——不得提前下载、不得跳过选节点、不得与选节点并行发起下载：**

**首选 `dl`（内置顺序保证）**：`clash-pick dl <下载URL> --json` 内部就是「先建组/复用组 + 测速切节点，全部完成后才开始下载」，天然满足时序要求，无需分步。

若分步（`add`/`pick` + curl）：
1. **先**运行 `clash-pick add <下载URL> --json`（或 `pick`），**等它执行完、拿到结果**。
2. 从返回结果里**确认节点已选好**（`switched: true` / `bestNode` 非空，人类可读模式会打印「下载: curl ...」这一行指令）。
3. **然后**才发起下载——用 CLI 返回的指令（`curl --proxy http://127.0.0.1:7897 -L -O ...`）或同端口的代理工具，或再跑 `clash-pick dl <下载URL>`。

**为什么**：mihomo 按「网址代理」规则把该域名的流量路由到选中的节点。**选节点必须先于下载完成**，否则下载流量会走错误的节点（或 GLOBAL 兜底），测速选最优节点就白做了。

**何时可下载**：只有 clash-pick 成功返回（退出码 0，且 `switched` 或 `bestNode` 非空）才下载。失败（clash 离线 / 无可用节点）→ 不要硬下，按「先判断 Clash 是否在运行」处理。

## Agent 下载工作流（标准流程）

下载**任何需要走代理的文件**，最省事的做法是**一步到位**用 `dl`：选节点 + 多线程下载一次完成。

```bash
# 0. 推荐：选节点 + 走代理多线程下载一步完成
#    → 该域名没建过组时自动建 URL-Proxy-* 组；再测速切最优节点；最后直接下载
clash-pick dl "<下载URL>" --json
#    结果里 engine / filePath / bytes / durationMs 为下载信息
```

分步（需要拿到节点信息再自行处理时）：

```bash
# 1a. 全自动：为 URL 建网址代理组（已存在则复用）+ 测速切换最低延迟节点
clash-pick add "<下载URL>" --json

# 1b. 或仅对已建的组测速切换（无需建组）
clash-pick pick "<下载URL>" --json

# 2. 解析 JSON 拿到 bestNode / group，确认已切换（switched: true）

# 3. 走 mihomo 混入端口下载（命中网址代理规则 → 流量走刚选中的节点）
curl --proxy http://127.0.0.1:7897 -L -o <文件名> "<下载URL>"
#    或继续用多线程下载：clash-pick dl "<下载URL>" --json
```

`add`/`pick` 的 `--json` 返回字段（供 agent 程序化解析）：
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
| `clash-pick dl <url>` | 选节点 + 走代理多线程下载一步完成 |
| `clash-dl <url>` | **独立**多线程下载命令（下载器独立于选节点，可单独用） |
| `clash-pick add <url>` | 自动建组 + 测速切换最低延迟节点（分步流程第一步） |
| `clash-pick pick <url>` | 测速 + 自动切换已有组 |
| `clash-pick test <url>` | 只测速不切换（看节点快慢） |
| `clash-pick list` | 列真节点、网址代理组、域名→组规则 |
| `clash-pick current` | 看 GLOBAL 与各网址代理组当前选中 |

下载器与选节点**解耦**：`clash-dl <url>` 是独立下载命令，可单独用（走 7897 代理，命中已选节点）；`clash-pick dl` 是「选节点 + 下载」一步快捷方式。两者共用同一下载引擎。

常用选项：`--timeout 6000`（测速超时，下载慢时加大）、`--concurrency 16`（并发）、`--group <组名>`（显式指定切换组）、`--json`。

`dl`/`clash-dl` 专属选项：`-o <文件>`（输出文件名）、`-d <目录>`（保存目录）、`-t <n>`（并发线程数，默认 8）、`-H/--header "Name: value"`（自定义 HTTP 头，可多次，非公开 URL 认证用）、`--no-proxy`（直连，不选节点）、`--force-node`（强制内置 Node 下载器，不用 aria2c）。

**非公开 URL**：下载需要认证的文件时加 `-H` 指定认证头（如 `Authorization: Bearer <token>` / `Cookie`）。一次性签名/受限 URL 多线程分片遇 401/403/429 时自动降级单线程，文件仍完整下载，不会整体失败。

**下载引擎（混合）**：装了 aria2c 自动优先用 aria2c（多连接 + 断点续传，成熟引擎）；没装则用内置 Node 分片下载器兜底（`--force-node` 可强制用内置）。**跨域名重定向会自动剥离敏感头**（如 `api.github.com` 302 → 签名 CDN：Authorization/Cookie 不会误传给 CDN 导致 401），GitHub Actions 私有产物等场景可用 `clash-dl <url> -H "Authorization: Bearer <token>"` 正常下载。

## 常见场景

- **GitHub Release 下载慢**：`clash-pick dl "https://github.com/<owner>/<repo>/releases/download/..."` 一步选节点 + 多线程下载；或分步：`clash-pick pick <url>` 选节点 → `clash-dl <url>` 独立下载。
- **无法直连的域名**：先看 `clash-pick list` 里有没有该域名已建的网址代理组；没有就 `dl`/`pick`（回退 GLOBAL）并提示用户可在 Verge 里建组。
- **大文件/多线程下载**：`clash-dl <url> -t 8` 或 `clash-pick dl <url> -t 8` 走代理多线程分片下载（本机已装 aria2c → 自动用 aria2c 多连接；`--force-node` 强制用内置 Node 兜底）。中断后重跑同 URL 同目录自动断点续传。
- **Clash 离线时**：`clash-dl <url> --no-proxy` 直连多线程下载，不依赖 Clash。
- **非公开 URL（需认证）**：`clash-dl <url> -H "Authorization: Bearer <token>"` 或 `-H "Cookie: ..."`；一次性签名/受限 URL 分片遇 403 自动降级单线程；GitHub Actions 产物等跨域 302 自动剥离敏感头，可正常下载。

## 排障

- `clash-pick list` 报「无法连接」→ Verge 没在跑 / 内核没起，先启动 Clash Verge Rev。
- 测速全部失败（`无可用节点`）→ 网络不通或超时太短，加 `--timeout 10000` 重试。
- `✗ 切换失败（HTTP 400 ... proxy not exist）` → 订阅刷新后该节点已重命名/移除，重新 `clash-pick pick` 一次即可（会用当前有效节点）。
- 下载走了错误节点 → 该域名可能被订阅内其他规则先匹配；用 `--group` 指定网址代理组，或在 Verge「网址代理」页为该域名建组。

## 边界

- `add` 会自动建组（写增强文件 + reload，走 Verge 命令桥）；`pick` 只对已建组测速切换。全新域名优先用 `add`。
- 只测速**真实节点**，跳过策略组（Selector/URLTest/Fallback 等）。

## 参考

- 仓库：https://github.com/likangdi-code/clash-pick-cli（README 有完整说明）
- 配套 GUI 项目（网址代理功能来源）：https://github.com/likangdi-code/clash-verge-url-proxy
