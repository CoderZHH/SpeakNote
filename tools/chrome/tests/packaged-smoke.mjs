import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { request } from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { once } from 'node:events';

const resources = resolve(process.argv[2] || 'apple/Resources/ChromeRuntime');
const root = await mkdtemp(join(tmpdir(), 'workbench-packaged-chrome-'));
const socketPath = `/tmp/workbench-accounts-${createHash('sha256').update(root).digest('hex').slice(0, 20)}.sock`;
const processHandle = spawn(join(resources, 'backend.bundle/Contents/MacOS/workbench-node'), [join(resources, 'runtime/src/server.mjs')], {
  cwd: join(resources, 'runtime'), env: { ...process.env, WORKBENCH_SESSION_ROOT: root }, stdio: 'ignore',
});
let spawnError;
processHandle.on('error', error => { spawnError = error; });
const exited = once(processHandle, 'exit');
function call(path, method = 'GET') {
  return new Promise((resolve, reject) => {
    const req = request({ socketPath, path, method }, res => {
      let text = ''; res.on('data', chunk => { text += chunk; });
      res.on('end', () => { try { assert.equal(res.statusCode, 200); resolve(JSON.parse(text)); } catch (error) { reject(error); } });
    });
    req.on('error', reject); req.setTimeout(2000, () => req.destroy(new Error('request timeout'))); req.end(method === 'POST' ? '{}' : undefined);
  });
}
try {
  let ready = false;
  for (let i = 0; i < 100; i++) {
    if (spawnError) throw spawnError;
    assert.equal(processHandle.exitCode, null, 'packaged helper exited during startup');
    try { ready = (await call('/health')).ready === true; if (ready) break; } catch {}
    await new Promise(resolve => setTimeout(resolve, 30));
  }
  assert.equal(ready, true);
  assert.equal((await call('/shutdown', 'POST')).stopped, true);
  assert.equal((await exited)[0], 0);
  console.log('PASS: packaged Node starts the standalone socket service and shuts down cleanly');
} finally {
  if (processHandle.exitCode === null) processHandle.kill('SIGTERM');
  await rm(root, { recursive: true, force: true });
}
