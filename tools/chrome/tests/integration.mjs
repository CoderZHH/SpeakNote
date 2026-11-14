// Explicit integration check using disposable profiles and a synthetic local site.
// Never touches existing accounts, Chrome profiles, or platform login data.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright-core';
import { AccountSessionManager } from '../src/account-session-manager.mjs';
import { chromeExecutable } from '../src/account-session-config.mjs';

const fixture = createServer((req, res) => { res.setHeader('Content-Type', 'text/html'); res.end('<!doctype html><title>Session fixture</title><body>Independent account session</body>'); });
await new Promise(resolve => fixture.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${fixture.address().port}`;
const root = await mkdtemp(join(tmpdir(), 'workbench-real-sessions-'));
const makeManager = () => new AccountSessionManager({ root, urlFor: () => url, launch: directory => chromium.launchPersistentContext(directory, { executablePath: chromeExecutable, headless: true, chromiumSandbox: true }) });
let manager = makeManager();
const a = { id: 'qa-a', platform: 'douyin' }, b = { id: 'qa-b', platform: 'douyin' };
async function stored(id) {
  return manager.sessions.get(id).context.pages()[0].evaluate(async () => {
    const db = await new Promise((resolve, reject) => { const request = indexedDB.open('fixture', 1); request.onupgradeneeded = () => request.result.createObjectStore('state'); request.onsuccess = () => resolve(request.result); request.onerror = reject; });
    const value = await new Promise(resolve => { const request = db.transaction('state').objectStore('state').get('account'); request.onsuccess = () => resolve(request.result ?? null); }); db.close();
    return { cookie: document.cookie, local: localStorage.getItem('account'), indexed: value };
  });
}
try {
  const first = await Promise.all([manager.open(a), manager.open(a), manager.open(b)]);
  assert.equal(first.filter(result => result.reused).length, 1); assert.equal(manager.sessions.size, 2);
  for (const [account, marker] of [[a, 'A'], [b, 'B']]) {
    await manager.sessions.get(account.id).context.pages()[0].evaluate(async marker => {
      document.cookie = `fixture=${marker}; max-age=86400; path=/`; localStorage.setItem('account', marker);
      const db = await new Promise((resolve, reject) => { const request = indexedDB.open('fixture', 1); request.onupgradeneeded = () => request.result.createObjectStore('state'); request.onsuccess = () => resolve(request.result); request.onerror = reject; });
      await new Promise(resolve => { const transaction = db.transaction('state', 'readwrite'); transaction.objectStore('state').put(marker, 'account'); transaction.oncomplete = resolve; }); db.close();
    }, marker);
  }
  assert.deepEqual(await stored(a.id), { cookie: 'fixture=A', local: 'A', indexed: 'A' });
  assert.deepEqual(await stored(b.id), { cookie: 'fixture=B', local: 'B', indexed: 'B' });
  await manager.shutdown(); manager = makeManager(); // Same profile directories, new process ownership.
  await Promise.all([manager.open(a), manager.open(b)]);
  assert.deepEqual(await stored(a.id), { cookie: 'fixture=A', local: 'A', indexed: 'A' });
  assert.deepEqual(await stored(b.id), { cookie: 'fixture=B', local: 'B', indexed: 'B' });
  await manager.reset(a);
  assert.deepEqual(await stored(a.id), { cookie: '', local: null, indexed: null });
  assert.deepEqual(await stored(b.id), { cookie: 'fixture=B', local: 'B', indexed: 'B' });
  await manager.sessions.get(b.id).context.close(); await manager.open(b);
  assert.equal((await stored(b.id)).local, 'B');
  console.log('PASS: real Chrome parallel isolation, duplicate reuse, Cookie/LocalStorage/IndexedDB persistence, targeted reset and manual close/reopen');
} finally { await manager.shutdown(); await new Promise(resolve => fixture.close(resolve)); await rm(root, { recursive: true, force: true }); }
