#!/usr/bin/env node
/**
 * clash-pick — 下载前为 URL 选择最低延迟节点的 CLI 工具
 *
 * 通过 mihomo 的 external-controller（默认走 Clash Verge Rev 的命名管道
 * \\.\pipe\verge-mihomo，免配置；也可用 CLASH_API 指向 HTTP 端口）：
 *   1. 解析目标 URL 的域名
 *   2. 自动探测该域名命中的「网址代理」组（DOMAIN-SUFFIX 规则 → URL-Proxy-* 组）
 *   3. 对该组内所有节点并发测速（针对目标 URL）
 *   4. 切到延迟最低的节点
 *   5. 输出结果（人类可读 / --json 机器可读，供 agent 解析后调用下载器）
 *
 * 用法：
 *   node clash-pick.mjs <url>                 # 测速 + 自动切最低延迟节点
 *   node clash-pick.mjs test <url>            # 只测速，不切换
 *   node clash-pick.mjs list                  # 列出节点与网址代理组
 *   node clash-pick.mjs current               # 查看当前选中
 *
 * 选项：
 *   --group <组名>     指定要切换的组（默认自动探测，无命中则 GLOBAL）
 *   --timeout <ms>     单节点测速超时（默认 5000）
 *   --concurrency <n>  并发测速数（默认 12）
 *   --top <n>          只显示延迟最低的前 n 个
 *   --json             输出 JSON
 *   --no-switch        只测速不切换
 *
 * 环境变量：
 *   CLASH_API     覆盖端点，如 http://127.0.0.1:9097（默认命名管道）
 *   CLASH_SECRET  HTTP 模式下的 secret（命名管道无需）
 *
 * 下载走代理：curl --proxy http://127.0.0.1:7897 -L -O <url>
 */
import net from 'node:net'
import http from 'node:http'

const PIPE = String.raw`\\.\pipe\verge-mihomo`
const DEFAULT_MIXED_PORT = 7897

// ─── 传输层：命名管道 / HTTP，统一返回 {status, json, body} ──────────────────

async function request(method, path, body) {
  const api = process.env.CLASH_API
  const secret = process.env.CLASH_SECRET
  if (api && !api.startsWith('pipe:')) {
    return httpRequest(api, method, path, body, secret)
  }
  return pipeRequest(method, path, body)
}

function httpRequest(base, method, path, body, secret) {
  const u = new URL(path, base)
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: u.hostname, port: u.port, path: u.pathname + u.search, method },
      (res) => {
        let buf = ''
        res.setEncoding('utf8')
        res.on('data', (d) => (buf += d))
        res.on('end', () => {
          let json = null
          try { json = JSON.parse(buf) } catch {}
          resolve({ status: res.statusCode, body: buf, json })
        })
      },
    )
    req.on('error', reject)
    if (secret) req.setHeader('Authorization', `Bearer ${secret}`)
    if (body) req.setHeader('Content-Type', 'application/json')
    req.end(body ?? undefined)
  })
}

function pipeRequest(method, path, body) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(PIPE)
    let buf = Buffer.alloc(0)
    let settled = false
    const done = (err, res) => {
      if (settled) return
      settled = true
      sock.destroy()
      err ? reject(err) : resolve(res)
    }
    sock.on('connect', () => {
      const h = [`${method} ${path} HTTP/1.1`, 'Host: localhost', 'Connection: close']
      if (body) {
        h.push('Content-Type: application/json')
        h.push(`Content-Length: ${Buffer.byteLength(body)}`) // PUT 必须带字节长度，否则 mihomo 读不到 body
      }
      sock.write(h.join('\r\n') + '\r\n\r\n' + (body ?? ''))
    })
    sock.on('data', (d) => { buf = Buffer.concat([buf, d]) })
    sock.on('end', () => {
      const sep = buf.indexOf('\r\n\r\n')
      if (sep < 0) return done(new Error('响应缺少 HTTP 头分隔符'))
      const head = buf.subarray(0, sep).toString('utf8')
      let bodyBuf = buf.subarray(sep + 4)
      const m = head.split('\r\n')[0].match(/^HTTP\/1\.[01] (\d+)/)
      if (!m) return done(new Error('无法解析 HTTP 状态行'))
      const status = Number(m[1])
      const headers = {}
      for (const l of head.split('\r\n').slice(1)) {
        const c = l.indexOf(':')
        if (c > 0) headers[l.slice(0, c).trim().toLowerCase()] = l.slice(c + 1).trim()
      }
      if (headers['transfer-encoding'] === 'chunked') {
        bodyBuf = decodeChunkedBuffer(bodyBuf)
      }
      const bodyText = bodyBuf.toString('utf8')
      let json = null
      try { json = JSON.parse(bodyText) } catch {}
      done(null, { status, headers, body: bodyText, json })
    })
    sock.on('error', (e) => done(e))
  })
}

/** 按字节解码 chunked（chunk size 是字节数，节点名含 emoji 时字符/字节不一致，必须用 Buffer） */
function decodeChunkedBuffer(buf) {
  const out = []
  let pos = 0
  let guard = 0
  while (pos < buf.length && guard++ < 100000) {
    const nl = buf.indexOf('\r\n', pos)
    if (nl < 0) { out.push(buf.subarray(pos)); break }
    const size = parseInt(buf.subarray(pos, nl).toString('utf8').split(';')[0].trim(), 16)
    if (isNaN(size) || size < 0) { out.push(buf.subarray(pos)); break }
    pos = nl + 2
    if (size === 0) break
    out.push(buf.subarray(pos, pos + size))
    pos = pos + size + 2
  }
  return Buffer.concat(out)
}

// ─── 工具函数 ───────────────────────────────────────────────────────────────

const STRATEGY_TYPES = new Set([
  'Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Direct', 'Reject', 'Compatible', 'Pass', 'Unknown',
])
const RESERVED = new Set(['GLOBAL', 'DIRECT', 'REJECT', 'COMPATIBLE', 'PASS', 'DIRECT-REJECT'])
const isUrlProxyName = (n) => String(n).startsWith('URL-Proxy-')

function parseHost(input) {
  const s = String(input).trim()
  const withScheme = /^https?:\/\//i.test(s) ? s : s.endsWith('.onion') ? `http://${s}` : `https://${s}`
  const u = new URL(withScheme)
  return { host: u.hostname.replace(/^www\./, ''), url: withScheme }
}

/** host 是否命中规则的 payload（规则域名自身或其子域，避免误匹配） */
function hostMatches(host, payload) {
  return host === payload || host.endsWith('.' + payload)
}

/** /rules API 的 type 是驼峰枚举（DomainSuffix），不是配置格式的 DOMAIN-SUFFIX */
const DOMAIN_SUFFIX_TYPES = new Set(['DomainSuffix', 'DOMAIN-SUFFIX'])

/** 从 /rules 探测 host 命中的网址代理组；命中多个取最具体的（payload 最长） */
function detectUrlProxyGroup(rules, host) {
  let best = null
  let bestLen = -1
  for (const r of rules ?? []) {
    if (!DOMAIN_SUFFIX_TYPES.has(r.type) || !isUrlProxyName(r.proxy)) continue
    if (hostMatches(host, r.payload) && r.payload.length > bestLen) {
      best = r.proxy
      bestLen = r.payload.length
    }
  }
  return best
}

/** 取 /proxies 中目标组的可选节点（过滤策略组与保留名） */
function groupCandidates(proxies, groupName) {
  const info = proxies[groupName]
  if (!info || !Array.isArray(info.all)) return []
  return info.all.filter((n) => !RESERVED.has(n) && !isUrlProxyName(n) && !STRATEGY_TYPES.has(proxies[n]?.type))
}

/** 并发池测速：返回 [{name, delay|null, status}] */
async function speedTest(names, url, timeoutMs, concurrency) {
  const results = []
  let i = 0
  const workers = Array.from({ length: Math.min(concurrency, names.length) }, async () => {
    while (i < names.length) {
      const idx = i++
      const name = names[idx]
      const path = `/proxies/${encodeURIComponent(name)}/delay?url=${encodeURIComponent(url)}&timeout=${timeoutMs}`
      try {
        const r = await request('GET', path)
        const d = r.json?.delay
        results.push({ name, delay: typeof d === 'number' && d > 0 ? d : null, status: r.status })
      } catch (e) {
        results.push({ name, delay: null, status: 0 })
      }
    }
  })
  await Promise.all(workers)
  return results
}

function pickBest(results) {
  let best = null
  for (const r of results) {
    if (r.delay != null && (best == null || r.delay < best.delay)) best = r
  }
  return best
}

// ─── 主逻辑 ─────────────────────────────────────────────────────────────────

async function main() {
  const argv = process.argv.slice(2)
  const opts = { timeout: 5000, concurrency: 12, group: null, top: null, json: false, noSwitch: false }
  const positional = []
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--group') opts.group = argv[++i]
    else if (a === '--timeout') opts.timeout = Number(argv[++i])
    else if (a === '--concurrency') opts.concurrency = Number(argv[++i])
    else if (a === '--top') opts.top = Number(argv[++i])
    else if (a === '--json') opts.json = true
    else if (a === '--no-switch') opts.noSwitch = true
    else if (a.startsWith('-')) { console.error(`未知选项: ${a}`); process.exit(2) }
    else positional.push(a)
  }

  // 区分「隐式 pick」（clash-pick <url>）与「显式 pick」（clash-pick pick <url>）
  const rawCmd = positional[0] ?? ''
  let cmd, argUrl
  if (['pick', 'test', 'list', 'current'].includes(rawCmd)) {
    cmd = rawCmd
    argUrl = cmd === 'test' ? positional[1] : cmd === 'pick' ? positional[1] : null
  } else {
    cmd = 'pick' // 第一个位置参数就是 URL
    argUrl = rawCmd
  }

  if (cmd === 'list') return cmdList()
  if (cmd === 'current') return cmdCurrent()
  if ((cmd === 'pick' || cmd === 'test') && argUrl) return cmdPick(argUrl, opts, cmd === 'test')
  if (cmd === 'pick' || cmd === 'test') {
    console.error(`用法: node clash-pick.mjs ${cmd} <url> [--group 组名] [--timeout ms] [--json]`)
    process.exit(2)
  }
  console.error(`未知命令: ${cmd}`)
  process.exit(2)
}

async function cmdList() {
  const proxies = (await request('GET', '/proxies')).json?.proxies ?? {}
  const rules = (await request('GET', '/rules')).json?.rules ?? []
  const realNodes = []
  const groups = []
  for (const [name, info] of Object.entries(proxies)) {
    if (Array.isArray(info.all)) groups.push({ name, type: info.type, now: info.now, members: info.all.length })
    else if (!RESERVED.has(name)) realNodes.push(name)
  }
  const urlProxy = groups.filter((g) => isUrlProxyName(g.name))
  const urlProxyRules = rules.filter((r) => DOMAIN_SUFFIX_TYPES.has(r.type) && isUrlProxyName(r.proxy))
  const rows = [
    `内核: ${(await request('GET', '/version')).json?.version ?? '?'}`,
    `真节点: ${realNodes.length} 个`,
    `网址代理组: ${urlProxy.length} 个`,
    ...urlProxy.map((g) => `  ${g.name}  (成员 ${g.members}, 当前 ${g.now})`),
  ]
  if (urlProxyRules.length) {
    rows.push(`URL-Proxy 规则 (域名 -> 组):`)
    for (const r of urlProxyRules) rows.push(`  ${r.payload} -> ${r.proxy}`)
  }
  console.log(rows.join('\n'))
}

async function cmdCurrent() {
  const proxies = (await request('GET', '/proxies')).json?.proxies ?? {}
  for (const name of ['GLOBAL', ...Object.keys(proxies).filter(isUrlProxyName)]) {
    const info = proxies[name]
    if (info?.now) console.log(`${name} -> ${info.now}`)
  }
}

async function cmdPick(url, opts, testOnly) {
  const { host, url: normalizedUrl } = parseHost(url)
  const proxies = (await request('GET', '/proxies')).json?.proxies ?? {}

  // 1. 探测命中的网址代理组
  let group = opts.group
  if (!group) {
    try {
      const rules = (await request('GET', '/rules')).json?.rules ?? []
      group = detectUrlProxyGroup(rules, host)
    } catch { /* 忽略，回退 GLOBAL */ }
  }
  if (!group) group = 'GLOBAL'

  const candidates = groupCandidates(proxies, group)
  if (candidates.length === 0) {
    const msg = `组 ${group} 无可测节点（${host}）`
    if (opts.json) console.log(JSON.stringify({ ok: false, error: msg, host }))
    else console.error(msg)
    process.exit(1)
  }

  // 2. 并发测速（针对下载 URL）
  const results = await speedTest(candidates, normalizedUrl, opts.timeout, opts.concurrency)
  const sorted = results.filter((r) => r.delay != null).sort((a, b) => a.delay - b.delay)
  const best = pickBest(results)
  const display = opts.top ? sorted.slice(0, opts.top) : sorted

  // 3. 切换最低延迟节点
  let switched = false
  let switchStatus = null
  if (!testOnly && !opts.noSwitch && best) {
    try {
      const r = await request('PUT', `/proxies/${encodeURIComponent(group)}`, JSON.stringify({ name: best.name }))
      switchStatus = r.status
      switched = r.status >= 200 && r.status < 300
    } catch (e) { switchStatus = e.message }
  }

  const result = {
    ok: true,
    host,
    url: normalizedUrl,
    group,
    isUrlProxy: isUrlProxyName(group),
    bestNode: best?.name ?? null,
    bestDelay: best?.delay ?? null,
    switched,
    candidatesTested: candidates.length,
    testUrl: normalizedUrl,
  }

  if (opts.json) {
    console.log(JSON.stringify({ ...result, top: display.map((r) => ({ name: r.name, delay: r.delay })) }))
    return
  }

  console.log(`目标: ${host}  (${normalizedUrl})`)
  console.log(`切换组: ${group}${isUrlProxyName(group) ? ' (网址代理组)' : ' (GLOBAL 兜底)'}`)
  console.log(`测速节点: ${candidates.length} 个`)
  if (display.length === 0) {
    console.log('⚠  无可用节点（全部超时/失败）')
  } else {
    console.log('延迟最低:')
    for (const r of display) {
      const mark = r.name === best?.name ? ' ◀' : ''
      console.log(`  ${String(r.delay).padStart(6)} ms  ${r.name}${mark}`)
    }
  }
  if (switched) console.log(`✓ 已切换 ${group} → ${best.name} (${best.delay} ms)`)
  else if (!testOnly && best) console.log(`✗ 切换失败（HTTP ${switchStatus}；组可能不存在，可用 --group 显式指定）`)
  else if (testOnly) console.log('(仅测速，未切换)')
  if (!isUrlProxyName(group)) {
    console.log('ℹ  该域名无网址代理组，已回退 GLOBAL。rule 模式下只有未匹配规则的流量走它；')
    console.log('   如需精准路由，请先在 Verge「网址代理」添加该域名。')
  }
  console.log(`下载: curl --proxy http://127.0.0.1:${process.env.CLASH_MIXED_PORT ?? DEFAULT_MIXED_PORT} -L -O '${url}'`)
}

main().catch((e) => {
  // 连接类错误 = Clash Verge Rev / mihomo 没在运行（命名管道不存在、HTTP 端口拒绝、管道被断）
  if (['ENOENT', 'ECONNREFUSED', 'EPIPE', 'ECONNRESET'].includes(e?.code)) {
    console.error(`⚠️ 未检测到 Clash 在运行（连接失败: ${e.message}）`)
    console.error('已跳过测速。如需走代理选节点下载，请先启动 Clash Verge Rev。')
  } else {
    console.error('clash-pick 错误:', e.message)
  }
  process.exit(1)
})
