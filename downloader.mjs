#!/usr/bin/env node
/**
 * downloader.mjs — 走代理的多线程下载引擎（clash-pick dl 用）
 *
 * 混合引擎：
 *   1. 探测 aria2c（业界最强开源多线程下载器）：装了 → spawn aria2c 满速下载
 *      （-x 多连接、-s 分片、-k 分片大小、-c 断点续传、--all-proxy 走 mihomo 混入端口）
 *   2. 没装 → 内置纯 Node 零依赖多线程下载器：
 *      - GET + Range 探测（Content-Length / Accept-Ranges / 文件名 / 重定向）
 *      - 支持 Range → 按 Range 分片并发下载到 .part 文件，完成后拼接
 *      - 不支持 Range / 大小未知 / 需认证（401/403）→ 降级单线程流式下载
 *      - 走代理：http 用绝对 URI 直发代理端口；https 用 CONNECT 隧道 + TLS
 *      - 断点续传：已存在且大小匹配的 .part 分片自动跳过；完整文件命中直接完成
 *
 * 非公开 URL（需认证）支持：
 *   - --header "Name: value" 可多次指定（如 Authorization / Cookie），
 *     探测、分片、单线程、aria2c 全部透传
 *   - 一次性签名 / 受限 URL：多线程分片遇 401/403/429 自动清理降级单线程
 *   - probe 遇 401/403 时给出「用 --header 指定认证头」的清晰提示
 *
 * 用法（一般由 clash-pick.mjs dl 调用，也可独立使用）：
 *   node downloader.mjs <url> [--proxy-port 7897] [--threads 8] [-o 文件名] [-d 目录]
 *   node downloader.mjs <url> --header "Authorization: Bearer <token>" --header "Cookie: a=b"
 *
 * 返回：Promise<{ok, engine, filePath, bytes, threads, durationMs, error?}>
 */
import net from 'node:net'
import tls from 'node:tls'
import fs from 'node:fs'
import path from 'node:path'
import { Transform } from 'node:stream'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

// ─── aria2c 探测 ─────────────────────────────────────────────────────────────

/** 在 PATH 中找 aria2c（win 平台同时兼容 aria2c.exe / .cmd / .bat 包装） */
export function findAria2c() {
  const names = process.platform === 'win32'
    ? ['aria2c.exe', 'aria2c.cmd', 'aria2c.bat', 'aria2c']
    : ['aria2c']
  const pathDirs = (process.env.PATH ?? '').split(path.delimiter).filter(Boolean)
  for (const dir of pathDirs) {
    for (const n of names) {
      try {
        const p = path.join(dir, n)
        if (fs.existsSync(p)) return p
      } catch { /* 路径非法跳过 */ }
    }
  }
  // Windows 常见安装目录兜底
  if (process.platform === 'win32') {
    for (const dir of [
      path.join(process.env.LOCALAPPDATA ?? '', 'Programs', 'aria2'),
      'C:\\Program Files\\aria2',
      'C:\\aria2',
    ]) {
      for (const n of names) {
        try {
          const p = path.join(dir, n)
          if (fs.existsSync(p)) return p
        } catch {}
      }
    }
  }
  return null
}

/** 用 aria2c 下载（继承 stdio 展示 aria2 自带进度条） */
function runAria2c(url, { proxyPort, threads, output, dir, ariaPath, headers }) {
  return new Promise((resolve) => {
    const args = [
      '--auto-file-renaming=false',
      '--allow-overwrite=true',
      '--summary-interval=1',
      '-x', String(threads),
      '-s', String(threads),
      '-k', '1M',
      '-c', // 断点续传
    ]
    if (proxyPort) args.push('--all-proxy', `http://127.0.0.1:${proxyPort}`)
    else args.push('--no-proxy', '*')
    for (const [k, v] of Object.entries(headers ?? {})) args.push(`--header=${k}: ${v}`)
    if (output) args.push('-o', output)
    if (dir) args.push('-d', dir)
    args.push(url)

    // Windows 下 aria2c 常以 aria2c.exe 存在，.cmd/.bat 包装时需走 cmd shell
    const isBat = process.platform === 'win32' && /\.(cmd|bat)$/i.test(ariaPath ?? 'aria2c')
    let child
    if (isBat) {
      // cmd 下 URL 可能含 & 等元字符：把每个参数用双引号包裹后拼成命令行，
      // 这样 cmd 把整个串当一个参数，避免 & 截断 / DEP0190 未转义警告
      const quoted = args.map((a) => `"${a.replace(/"/g, '\\"')}"`).join(' ')
      child = spawn(`"${ariaPath}" ${quoted}`, { stdio: 'inherit', shell: true })
    } else {
      child = spawn(ariaPath ?? 'aria2c', args, { stdio: 'inherit' })
    }
    child.on('error', (e) => resolve({ ok: false, engine: 'aria2c', error: e.message }))
    child.on('close', (code) => {
      resolve({ ok: code === 0, engine: 'aria2c', filePath: output ? path.join(dir ?? '.', output) : null, exitCode: code })
    })
  })
}

// ─── 工具函数 ────────────────────────────────────────────────────────────────

function formatBytes(n) {
  if (n == null || isNaN(n)) return '?'
  if (n >= 1 << 30) return (n / (1 << 30)).toFixed(2) + ' GiB'
  if (n >= 1 << 20) return (n / (1 << 20)).toFixed(1) + ' MiB'
  if (n >= 1 << 10) return (n / (1 << 10)).toFixed(0) + ' KiB'
  return n + ' B'
}

function formatSpeed(bytes, ms) {
  if (ms <= 0) return '?'
  return formatBytes((bytes / ms) * 1000) + '/s'
}

/** 从 URL / Content-Disposition 推断文件名 */
function guessFilename(urlStr, disposition) {
  if (disposition) {
    const utf8 = disposition.match(/filename\*=(?:UTF-8'')?["']?([^"';]+)["']?/i)
    if (utf8) return decodeURIComponent(utf8[1])
    const plain = disposition.match(/filename=["']?([^"';]+)["']?/i)
    if (plain) return plain[1]
  }
  const u = new URL(urlStr)
  const base = path.basename(u.pathname)
  if (base && base !== '/' && base !== '\\') return decodeURIComponent(base)
  return `download-${Date.now()}`
}

/** chunked 解码转换流 */
function createDechunker() {
  let state = 'size' // size | sizeLF | data | sizeCRLF | done
  let remaining = 0
  let sizeBuf = ''
  return new Transform({
    transform(chunk, _enc, cb) {
      let pos = 0
      const push = (b) => { if (b.length) this.push(b) }
      while (pos < chunk.length) {
        if (state === 'size') {
          const c = String.fromCharCode(chunk[pos])
          if (c === '\r') { state = 'sizeLF'; pos++ }
          else { sizeBuf += c; pos++ }
        } else if (state === 'sizeLF') {
          if (chunk[pos] === 0x0a) {
            remaining = parseInt(sizeBuf.trim().split(';')[0], 16) || 0
            sizeBuf = ''
            state = remaining === 0 ? 'done' : 'data'
          }
          pos++
        } else if (state === 'data') {
          const take = Math.min(remaining, chunk.length - pos)
          push(chunk.subarray(pos, pos + take))
          remaining -= take
          pos += take
          if (remaining === 0) state = 'sizeCRLF'
        } else if (state === 'sizeCRLF') {
          pos += 2 // 跳过 chunk 末尾 \r\n
          state = 'size'
        } else if (state === 'done') {
          pos = chunk.length
        }
      }
      cb()
    },
  })
}

// ─── 代理/直连 HTTP 请求（返回 {statusCode, headers, stream}）─────────────────
//
// proxyPort 存在 → 走 HTTP 代理（mihomo 混入端口）：
//   http  : 绝对 URI 形式 GET http://host/path 发给代理端口
//   https : CONNECT 隧道 → TLS → origin-form GET
// proxyPort 为 null → 直连
//
// 超时策略（避免连接卡死导致 Promise 永久挂起）：
//   - 连接建立超时 CONNECT_TIMEOUT（默认 20s）
//   - 空闲超时 IDLE_TIMEOUT（默认 60s，收到任意数据即重置；大文件持续传输不会误杀）
function proxiedRequest(urlStr, proxyPort, { method = 'GET', headers = {}, range } = {}) {
  const CONNECT_TIMEOUT = 20000
  const IDLE_TIMEOUT = 60000
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr)
    const isHttps = u.protocol === 'https:'
    const targetPort = u.port || (isHttps ? 443 : 80)
    const allHeaders = { 'User-Agent': 'clash-pick', Host: u.host, ...headers }
    if (range) allHeaders.Range = range

    // 在已连好的 socket（或 TLS socket）上发请求、解析响应头、泵 body 到 stream
    const sendOn = (sock) => {
      const reqPath = proxyPort && !isHttps ? urlStr : u.pathname + u.search
      const lines = [`${method} ${reqPath} HTTP/1.1`]
      for (const [k, v] of Object.entries(allHeaders)) lines.push(`${k}: ${v}`)
      lines.push('Connection: close')
      sock.write(lines.join('\r\n') + '\r\n\r\n')

      let headBuf = Buffer.alloc(0)
      let responded = false
      const out = new Transform({ transform(c, _e, cb) { cb(null, c) } })
      let exposed = out

      // 空闲超时：每次收到数据重置；卡死（无数据、连接不关）时强制失败
      const armIdle = () => { try { sock.setTimeout(IDLE_TIMEOUT) } catch {} }
      armIdle()
      sock.on('timeout', () => {
        sock.destroy(new Error(`下载空闲超时（${IDLE_TIMEOUT / 1000}s 无数据）`))
      })

      sock.on('data', (d) => {
        armIdle()
        if (!responded) {
          headBuf = Buffer.concat([headBuf, d])
          const sep = headBuf.indexOf('\r\n\r\n')
          if (sep < 0) return
          responded = true
          const headText = headBuf.subarray(0, sep).toString('utf8')
          const statusMatch = headText.match(/^HTTP\/1\.[01] (\d+)/)
          if (!statusMatch) { out.destroy(new Error('无法解析响应状态行')); return }
          const hdrs = {}
          for (const line of headText.split('\r\n').slice(1)) {
            const i = line.indexOf(':')
            if (i > 0) hdrs[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim()
          }
          if (hdrs['transfer-encoding'] === 'chunked') exposed = out.pipe(createDechunker())
          resolve({ statusCode: Number(statusMatch[1]), headers: hdrs, stream: exposed })
          const bodyStart = headBuf.subarray(sep + 4)
          if (bodyStart.length) out.write(bodyStart)
        } else {
          out.write(d)
        }
      })
      sock.on('end', () => {
        if (responded) out.end()
        else { out.destroy(new Error('连接提前关闭')); reject(new Error('连接提前关闭')) }
      })
      sock.on('error', (e) => {
        out.destroy(e)
        if (!responded) reject(e)
      })
    }

    // 通用：连接建立超时
    const withConnectTimeout = (s) => {
      s.setTimeout(CONNECT_TIMEOUT)
      s.on('timeout', () => s.destroy(new Error('连接超时')))
      return s
    }

    if (!proxyPort) {
      // 直连
      if (isHttps) {
        const s = withConnectTimeout(tls.connect({ host: u.hostname, port: targetPort, servername: u.hostname }))
        s.on('secureConnect', () => sendOn(s))
        s.on('error', reject)
      } else {
        const s = withConnectTimeout(net.connect(targetPort, u.hostname))
        s.on('connect', () => sendOn(s))
        s.on('error', reject)
      }
      return
    }

    // 走 HTTP 代理
    if (!isHttps) {
      const s = withConnectTimeout(net.connect(proxyPort, '127.0.0.1'))
      s.on('connect', () => sendOn(s))
      s.on('error', reject)
      return
    }

    // https → CONNECT 隧道
    const conn = withConnectTimeout(net.connect(proxyPort, '127.0.0.1'))
    conn.on('connect', () => {
      conn.write(`CONNECT ${u.hostname}:${targetPort} HTTP/1.1\r\nHost: ${u.hostname}:${targetPort}\r\n\r\n`)
    })
    let cbuf = Buffer.alloc(0)
    let tunneled = false
    conn.on('data', (d) => {
      if (tunneled) return
      cbuf = Buffer.concat([cbuf, d])
      const sep = cbuf.indexOf('\r\n\r\n')
      if (sep < 0) return
      const headText = cbuf.subarray(0, sep).toString('utf8')
      if (!/^HTTP\/1\.[01] 200/.test(headText)) {
        conn.destroy()
        return reject(new Error('代理 CONNECT 失败: ' + (headText.split('\r\n')[0] ?? '?') + '（代理端口不正确？）'))
      }
      tunneled = true
      conn.removeAllListeners('data') // 交还剩余字节给 TLS 层
      conn.unshift(cbuf.subarray(sep + 4))
      const tlsSock = tls.connect({ socket: conn, servername: u.hostname })
      tlsSock.on('secureConnect', () => sendOn(tlsSock))
      tlsSock.on('error', reject)
    })
    conn.on('error', reject)
  })
}

// ─── 内置 Node 下载器 ────────────────────────────────────────────────────────

/** 连接类错误码（代理/服务器瞬时抖动时重试；供 clash-pick.mjs 导入判断降级） */
export const RETRYABLE_CODES = new Set(['ECONNRESET', 'ECONNREFUSED', 'EPIPE', 'ETIMEDOUT', 'ENETUNREACH', 'ECONNABORTED'])

/** 带重试的 proxiedRequest：连接类错误重试 2 次（应对 mihomo 重载/测速抖动） */
async function proxiedRequestRetry(urlStr, proxyPort, opts, retries = 2) {
  let lastErr
  for (let i = 0; i <= retries; i++) {
    try {
      return await proxiedRequest(urlStr, proxyPort, opts)
    } catch (e) {
      lastErr = e
      if (i < retries && RETRYABLE_CODES.has(e?.code)) {
        await new Promise((r) => setTimeout(r, 400 * (i + 1)))
        continue
      }
      throw e
    }
  }
  throw lastErr
}

async function probe(urlStr, proxyPort, headers) {
  // 用 GET + Range: bytes=0-0 探测：同时拿 Content-Length / Accept-Ranges / 文件名 / 处理重定向
  const MAX_REDIRECT = 8
  let cur = urlStr
  for (let i = 0; i < MAX_REDIRECT; i++) {
    const res = await proxiedRequestRetry(cur, proxyPort, { range: 'bytes=0-0', headers })
    if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
      cur = new URL(res.headers.location, cur).toString()
      res.stream.resume() // 丢弃探测 body
      continue
    }
    res.stream.resume() // 丢弃探测 body
    // 非公开 URL：401/403 说明缺认证（或 URL 签名已失效），给出清晰提示
    if (res.statusCode === 401 || res.statusCode === 403) {
      const authNeeded = !headers || Object.keys(headers).length === 0
      throw new Error(
        `HTTP ${res.statusCode}（${authNeeded ? '非公开 URL 需要认证，请用 --header "Authorization: Bearer <token>" 等指定认证头' : '认证失败或签名过期，请检查 --header 提供的认证信息'}）`,
      )
    }
    const cr = res.headers['content-range'] // 'bytes 0-0/12345'
    let total = null
    if (cr) {
      const m = cr.match(/\/(\d+)$/)
      if (m) total = Number(m[1])
    }
    if (total == null && res.headers['content-length']) total = Number(res.headers['content-length'])
    return {
      url: cur,
      total,
      acceptsRange: res.headers['accept-ranges'] === 'bytes' || !!cr,
      disposition: res.headers['content-disposition'],
      statusCode: res.statusCode,
    }
  }
  throw new Error('重定向次数过多')
}

/**
 * 内置多线程下载
 * @param {string} urlStr 目标 URL
 * @param {{proxyPort:number|null, threads:number, output?:string, dir?:string, onProgress?:Function, headers?:Object, signal?:AbortSignal}} opts
 */
export async function downloadNode(urlStr, { proxyPort, threads = 4, output, dir = '.', onProgress, headers } = {}) {
  const info = await probe(urlStr, proxyPort, headers)
  if (info.statusCode >= 400) throw new Error(`HTTP ${info.statusCode}（服务器返回错误）`)
  const filename = output ?? guessFilename(info.url, info.disposition)
  const filePath = path.join(dir, filename)
  const started = Date.now()

  const cleanPath = (p) => {
    try { if (fs.existsSync(p)) fs.unlinkSync(p) } catch {}
  }
  const partOf = (i) => `${filePath}.part${i}`
  const report = (doneBytes, threadsUsed) => {
    if (!onProgress) return
    onProgress({
      doneBytes,
      total: info.total,
      threads: threadsUsed ?? 1,
      speed: formatSpeed(doneBytes, Date.now() - started),
      eta: info.total && doneBytes > 0 ? Math.round(((info.total - doneBytes) / doneBytes) * (Date.now() - started) / 1000) : null,
      filename,
    })
  }

  // 完整文件已存在且大小吻合 → 直接完成（断点续传 / 幂等）
  const existingSize = () => {
    try { return fs.statSync(filePath).size } catch { return 0 }
  }
  if (info.total != null && existingSize() === info.total) {
    return { ok: true, engine: 'node', filePath, bytes: info.total, threads: 1, durationMs: Date.now() - started, resumed: true }
  }

  // 单线程流式下载（也用于非公开 URL 降级）
  const downloadSingle = async () => {
    const res = await proxiedRequestRetry(info.url, proxyPort, { headers })
    if (res.statusCode >= 400) throw new Error(`HTTP ${res.statusCode}`)
    await fs.promises.mkdir(dir, { recursive: true })
    const ws = fs.createWriteStream(filePath)
    let done = 0
    res.stream.on('data', (d) => { done += d.length; report(done, 1) })
    await new Promise((resolvePromise, rejectPromise) => {
      res.stream.pipe(ws)
      ws.on('finish', resolvePromise)
      ws.on('error', rejectPromise)
      res.stream.on('error', rejectPromise)
    })
    return { ok: true, engine: 'node', filePath, bytes: done, threads: 1, durationMs: Date.now() - started }
  }

  // 决定模式：不支持 Range / 大小未知 / 太小 → 单线程
  const useMulti = !!info.acceptsRange && info.total != null && info.total >= 256 * 1024
  if (!useMulti) return downloadSingle()

  // ─── 多线程 Range 分片并发（worker 池）───
  await fs.promises.mkdir(dir, { recursive: true })
  const total = info.total
  const n = Math.max(1, Math.min(threads, Math.ceil(total / (256 * 1024))))
  const CONCURRENCY = Math.min(n, threads, 8)
  const ranges = []
  for (let i = 0; i < n; i++) {
    const start = Math.floor((total * i) / n)
    const end = Math.floor((total * (i + 1)) / n) - 1
    ranges.push([start, end])
  }

  const doneParts = new Array(n).fill(false)
  let doneBytes = 0

  // 断点续传：检查已有 .part 是否完整，完整则跳过
  for (let i = 0; i < n; i++) {
    const p = partOf(i)
    if (fs.existsSync(p)) {
      try {
        const sz = fs.statSync(p).size
        if (sz === ranges[i][1] - ranges[i][0] + 1) { doneParts[i] = true; doneBytes += sz }
        else cleanPath(p) // 不完整分片 → 重下
      } catch { cleanPath(p) }
    }
  }

  const timer = setInterval(() => report(doneBytes, n), 500)
  let errored = null
  let forbidden = false // 401/403/429 → 一次性签名/受限 URL，降级单线程
  try {
    await new Promise((resolvePromise, rejectPromise) => {
      let nextIdx = 0
      let activeCount = 0
      let completed = doneParts.filter(Boolean).length

      const startOne = () => {
        while (activeCount < CONCURRENCY && nextIdx < n) {
          const idx = nextIdx++
          if (doneParts[idx]) continue
          activeCount++
          const [start, end] = ranges[idx]
          const ws = fs.createWriteStream(partOf(idx))
          ws.on('finish', () => {
            doneParts[idx] = true
            doneBytes += end - start + 1
            activeCount--
            completed++
            report(doneBytes, n)
            if (completed === n) resolvePromise()
            else startOne()
          })
          ws.on('error', (e) => { if (!errored) { errored = e; rejectPromise(e) } })
          proxiedRequestRetry(info.url, proxyPort, { range: `bytes=${start}-${end}`, headers }).then((res) => {
            if ([401, 403, 429].includes(res.statusCode)) { forbidden = true; res.stream.resume(); rejectPromise(new Error(`分片 ${idx} HTTP ${res.statusCode}`)); return }
            if (res.statusCode >= 400) throw new Error(`分片 ${idx} HTTP ${res.statusCode}`)
            res.stream.pipe(ws)
            res.stream.on('error', (e) => { if (!errored) { errored = e; rejectPromise(e) } })
          }).catch((e) => { if (!errored) { errored = e; rejectPromise(e) } })
        }
        if (activeCount === 0 && completed === n) resolvePromise()
      }
      startOne()
    })
  } catch (e) {
    // 捕获 worker 池异常（await 直接抛出会跳过降级检查），记录后走下方降级判定
    errored = errored ?? e
  } finally {
    clearInterval(timer)
  }

  // 分片因认证/限流失败 → 一次性签名或受限 URL，清理分片后降级单线程完整下载
  if (forbidden || (errored && /HTTP (401|403|429)/.test(errored.message))) {
    for (let i = 0; i < n; i++) cleanPath(partOf(i))
    if (fs.existsSync(filePath)) cleanPath(filePath)
    return downloadSingle()
  }
  if (errored) throw errored

  // 拼接分片 → 最终文件
  await new Promise((resolvePromise, rejectPromise) => {
    const ws = fs.createWriteStream(filePath)
    let i = 0
    const pump = () => {
      if (i >= n) return ws.end()
      const rs = fs.createReadStream(partOf(i))
      rs.on('error', rejectPromise)
      rs.pipe(ws, { end: false })
      rs.on('end', () => { i++; pump() })
    }
    ws.on('finish', resolvePromise)
    ws.on('error', rejectPromise)
    pump()
  })
  for (let i = 0; i < n; i++) cleanPath(partOf(i))

  return { ok: true, engine: 'node', filePath, bytes: total, threads: n, durationMs: Date.now() - started }
}

// ─── 统一入口 ────────────────────────────────────────────────────────────────

/**
 * 下载（混合引擎：优先 aria2c，缺失用内置 Node 下载器）
 * @param {string} urlStr
 * @param {{proxyPort:number|null, threads?:number, output?:string, dir?:string, forceNode?:boolean, headers?:Object, onProgress?:Function}} opts
 */
export async function download(urlStr, { proxyPort, threads = 8, output, dir = '.', forceNode = false, headers, onProgress } = {}) {
  const aria = forceNode ? null : findAria2c()
  if (aria) {
    // aria2c 自带进度条（stdio inherit），不重复 onProgress
    return runAria2c(urlStr, { proxyPort, threads, output, dir, ariaPath: aria, headers })
  }
  return downloadNode(urlStr, { proxyPort, threads, output, dir, headers, onProgress })
}

/** 解析 "Name: value" 字符串为 headers 对象（多个 header 用数组传入） */
export function parseHeaders(list) {
  const headers = {}
  for (const h of list ?? []) {
    const i = h.indexOf(':')
    if (i > 0) headers[h.slice(0, i).trim()] = h.slice(i + 1).trim()
  }
  return headers
}

// ─── CLI 独立入口（node downloader.mjs <url> ...）─────────────────────────────
async function main() {
  const argv = process.argv.slice(2)
  const opts = { proxyPort: Number(process.env.CLASH_MIXED_PORT ?? 7897), threads: 8, output: null, dir: '.', forceNode: false, json: false, headers: null }
  const headerList = []
  const positional = []
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--proxy-port') opts.proxyPort = Number(argv[++i])
    else if (a === '--threads' || a === '-t') opts.threads = Number(argv[++i])
    else if (a === '-o') opts.output = argv[++i]
    else if (a === '-d') opts.dir = argv[++i]
    else if (a === '--no-proxy') opts.proxyPort = null
    else if (a === '--force-node') opts.forceNode = true
    else if (a === '--header' || a === '-H') headerList.push(argv[++i])
    else if (a === '--json') opts.json = true
    else if (a.startsWith('-')) { console.error(`未知选项: ${a}`); process.exit(2) }
    else positional.push(a)
  }
  const urlStr = positional[0]
  if (!urlStr) { console.error('用法: node downloader.mjs <url> [--proxy-port 7897] [--threads 8] [-o 文件] [-d 目录] [-H "Authorization: Bearer xxx"] [--no-proxy]'); process.exit(2) }
  if (headerList.length) opts.headers = parseHeaders(headerList)

  let last = null
  const res = await download(urlStr, { ...opts, onProgress: (p) => { last = p } })
  if (res.ok && !res.filePath && res.engine === 'aria2c') {
    if (!opts.json) console.log('✓ aria2c 下载完成（退出码 0）')
    process.exit(0)
  }
  if (res.ok) {
    if (opts.json) {
      console.log(JSON.stringify({ ok: true, engine: res.engine, filePath: res.filePath, bytes: res.bytes, threads: res.threads, durationMs: res.durationMs, speed: last ? last.speed : null }))
    } else {
      console.log(`✓ 下载完成  ${res.filePath}  ${formatBytes(res.bytes)}  （${res.engine} ${res.threads} 线程, ${(res.durationMs / 1000).toFixed(1)}s${last ? ', ' + last.speed : ''}）`)
    }
    process.exit(0)
  }
  console.error(`✗ 下载失败: ${res.error ?? `退出码 ${res.exitCode}`}`)
  process.exit(1)
}

// 独立运行入口
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((e) => { console.error('downloader 错误:', e.message); process.exit(1) })
}
