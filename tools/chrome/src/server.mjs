import { createServer, request } from 'node:http';
import { mkdirSync, chmodSync, openSync, writeFileSync, closeSync, readFileSync, statSync, unlinkSync, existsSync } from 'node:fs';
import { chromium } from 'playwright-core';
import { AccountSessionManager } from './account-session-manager.mjs';
import { sessionConfig, chromeExecutable } from './account-session-config.mjs';

const config = sessionConfig();
if (process.argv.includes('--stop')) {
  const req = request({ socketPath: config.socket, path: '/shutdown', method: 'POST' }, res => { res.resume(); res.on('end', () => process.exit(res.statusCode === 200 ? 0 : 1)); });
  req.on('error', () => { console.log('账号会话管理器未运行'); process.exit(0); }); req.end('{}');
} else {
  mkdirSync(config.root, { recursive: true, mode: 0o700 }); chmodSync(config.root, 0o700);
  function acquire() {
    try { const lock = openSync(config.lock, 'wx', 0o600); writeFileSync(lock, String(process.pid)); closeSync(lock); return true; }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      let alive = true;
      try { const pid = Number(readFileSync(config.lock, 'utf8')); if (!Number.isInteger(pid) || pid <= 0) { alive = Date.now() - statSync(config.lock).mtimeMs < 30000; } else { try { process.kill(pid, 0); } catch (e) { if (e.code === 'ESRCH') alive = false; } } } catch {}
      if (alive) return false;
      try { unlinkSync(config.lock); } catch {} return acquire();
    }
  }
  if (!acquire()) process.exit(0);
  // The lock proves the former manager has stopped before removing a stale socket.
  if (existsSync(config.socket)) unlinkSync(config.socket);
  const manager = new AccountSessionManager({ root: config.root, launch: directory => chromium.launchPersistentContext(directory, {
    executablePath: chromeExecutable, headless: false, viewport: null,
    chromiumSandbox: true, acceptDownloads: false,
    ignoreDefaultArgs: ['--disable-extensions', '--mute-audio'],
    timeout: 30000,
  }) });
  let closing = false;
  async function stop() {
    if (closing) return; closing = true;
    clearInterval(idle);
    await manager.shutdown(); server.close();
    try { unlinkSync(config.socket); } catch {} try { unlinkSync(config.lock); } catch {}
    process.exit(0);
  }
  const server = createServer(async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    if (closing) { res.writeHead(503); res.end('{"error":"会话管理器正在停止"}'); return; }
    if (req.method === 'GET' && req.url === '/health') { res.end(JSON.stringify({ ready: true, pid: process.pid })); return; }
    let raw = '';
    try {
      if (req.method !== 'POST') throw new Error('不支持的请求');
      for await (const chunk of req) { raw += chunk; if (raw.length > 4096) throw new Error('请求过大'); }
      const body = JSON.parse(raw);
      let result;
      if (req.url === '/open') result = await manager.open(body);
      else if (req.url === '/reset') result = await manager.reset(body);
      else if (req.url === '/close') result = await manager.close(body.id);
      else if (req.url === '/shutdown') { res.end('{"stopped":true}'); void stop(); return; }
      else throw new Error('不支持的操作');
      res.end(JSON.stringify(result));
    } catch (error) {
      // Browser errors can contain URLs; do not return or log session contents.
      const message = /账号|平台|请求|操作/.test(error.message) && error.message.length < 100 ? error.message : '后台未能打开，请关闭该账号窗口后重试';
      res.writeHead(400); res.end(JSON.stringify({ error: message }));
    }
  });
  server.listen(config.socket, () => chmodSync(config.socket, 0o600));
  server.on('error', () => { console.error('账号会话管理器启动失败'); void stop(); });
  let idleSince = Date.now();
  const idle = setInterval(() => {
    if (manager.sessions.size || manager.queues.size) idleSince = Date.now();
    else if (Date.now() - idleSince > 5 * 60000) void stop();
  }, 30000);
  process.on('SIGTERM', () => void stop()); process.on('SIGINT', () => void stop());
}
