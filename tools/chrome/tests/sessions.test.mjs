import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, mkdir, writeFile, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AccountSessionManager } from '../src/account-session-manager.mjs';
import { accountDirectory, backendUrl, sessionConfig, accountBackends } from '../src/account-session-config.mjs';

function fakeBrowser() {
  const launches = [], contexts = [];
  const launch = async (directory) => {
    launches.push(directory); await mkdir(directory, { recursive: true });
    await new Promise(resolve => setTimeout(resolve, 5));
    const context = new EventEmitter();
    const page = { closed: false, href: 'about:blank', brought: 0, isClosed() { return this.closed; }, url() { return this.href; }, async goto(url) { this.href = url; }, async bringToFront() { this.brought++; } };
    context.pages = () => [page]; context.newPage = async () => page;
    context.close = async () => { page.closed = true; context.emit('close'); };
    contexts.push(context); return context;
  };
  return { launch, launches, contexts };
}

test('parallel duplicate opens share one browser; two same-platform accounts stay separate, reopen preserves data', async () => {
  const root = await mkdtemp(join(tmpdir(), 'workbench-session-test-')); const fake = fakeBrowser();
  const manager = new AccountSessionManager({ root, launch: fake.launch }); const a = { id: 'A', platform: 'douyin' }, b = { id: 'B', platform: 'douyin' };
  try {
    const results = await Promise.all([manager.open(a), manager.open(a), manager.open(b), manager.open(a)]);
    assert.equal(fake.launches.length, 2); assert.equal(results.filter(r => r.reused).length, 2);
    assert.notEqual(fake.launches[0], fake.launches[1]);
    await writeFile(join(accountDirectory(root, 'A'), 'browser', 'login-fixture'), 'persisted-A');
    await manager.close('A'); await manager.open(a);
    assert.equal(await readFile(join(accountDirectory(root, 'A'), 'browser', 'login-fixture'), 'utf8'), 'persisted-A');
    assert.equal((await stat(accountDirectory(root, 'A'))).mode & 0o777, 0o700);
    assert.equal((await stat(join(accountDirectory(root, 'A'), 'workbench-session.json'))).mode & 0o777, 0o600);
    assert.equal(manager.sessions.size, 2);
  } finally { await manager.shutdown(); await rm(root, { recursive: true, force: true }); }
});

test('reset is serialized and removes only its own browser data; other accounts survive', async () => {
  const root = await mkdtemp(join(tmpdir(), 'workbench-session-reset-')); const fake = fakeBrowser();
  const manager = new AccountSessionManager({ root, launch: fake.launch }); const a = { id: 'A', platform: 'douyin' }, b = { id: 'B', platform: 'douyin' };
  try {
    await Promise.all([manager.open(a), manager.open(b)]);
    for (const id of ['A', 'B']) await writeFile(join(accountDirectory(root, id), 'browser', 'login-fixture'), id);
    await Promise.all([manager.reset(a), manager.open(a)]);
    assert.equal(fake.launches.length, 3);
    await assert.rejects(readFile(join(accountDirectory(root, 'A'), 'browser', 'login-fixture')), { code: 'ENOENT' });
    assert.equal(await readFile(join(accountDirectory(root, 'B'), 'browser', 'login-fixture'), 'utf8'), 'B');
    assert.equal(manager.sessions.size, 2);
    await manager.close('B'); assert.equal(manager.sessions.size, 1);
    assert.equal(await readFile(join(accountDirectory(root, 'B'), 'browser', 'login-fixture'), 'utf8'), 'B');
  } finally { await manager.shutdown(); await rm(root, { recursive: true, force: true }); }
});

test('failed navigation leaves one usable session, failed launches can retry, unsupported platforms create no directory', async () => {
  const root = await mkdtemp(join(tmpdir(), 'workbench-session-errors-')); const fake = fakeBrowser(); let fail = true;
  const manager = new AccountSessionManager({ root, launch: async (directory) => { if (fail) { fail = false; throw new Error('Launch failed'); } const context = await fake.launch(directory); context.pages()[0].goto = async () => { throw new Error('offline'); }; return context; } });
  try {
    await assert.rejects(manager.open({ id: 'A', platform: 'douyin' }), /Launch failed/);
    const result = await manager.open({ id: 'A', platform: 'douyin' }); assert.equal(result.navigationPending, true);
    assert.equal((await manager.open({ id: 'A', platform: 'douyin' })).reused, true); assert.equal(fake.launches.length, 1);
    await assert.rejects(manager.open({ id: 'A', platform: 'x' }), /不一致/);
    await assert.rejects(manager.open({ id: 'B', platform: '__proto__' }), /不支持/);
    await assert.rejects(stat(accountDirectory(root, 'B')), { code: 'ENOENT' });
  } finally { await manager.shutdown(); await rm(root, { recursive: true, force: true }); }
});

test('session directories are path-safe and backend destinations are fixed', () => {
  for (const id of ['../../Google/Chrome', 'A; rm', 'A', 'B']) assert.equal(accountDirectory('/tmp/root', id).split('/').length, 4);
  assert.notEqual(accountDirectory('/tmp/root', 'A'), accountDirectory('/tmp/root', 'B'));
  assert.throws(() => accountDirectory('/tmp/root', ''), /ID/);
  assert.throws(() => backendUrl('https://example.com'), /不支持/);
  assert.ok(sessionConfig().socket.length < 104);
});
test('TikTok, Instagram and YouTube use their own backend destinations and isolated persistent sessions', async () => {
  const root=await mkdtemp(join(tmpdir(),'workbench-new-platforms-')),fake=fakeBrowser();
  const manager=new AccountSessionManager({root,launch:fake.launch});
  try {
    for(const platform of ['tiktok','instagram','youtube']){
      const a={id:`${platform}-a`,platform},b={id:`${platform}-b`,platform};
      await manager.open(a);await manager.open(b);
      assert.equal(fake.contexts.at(-1).pages()[0].url(),accountBackends[platform]);
      assert.equal(fake.contexts.at(-2).pages()[0].url(),backendUrl(platform));
      assert.notEqual(accountDirectory(root,a.id),accountDirectory(root,b.id));
      assert.equal((await manager.open(a)).reused,true);
    }
    assert.equal(fake.launches.length,6);
    for(const [platform,definition] of Object.entries(accountBackends))assert.equal(backendUrl(platform),definition);
  } finally {await manager.shutdown();await rm(root,{recursive:true,force:true});}
});

test('deletion blocks an in-flight launch and future opens after manager restart', async () => {
  const { retireAccountSession } = await import('../src/account-session-manager.mjs');
  const root = await mkdtemp(join(tmpdir(), 'workbench-session-delete-')); const fake = fakeBrowser();
  let released, started;
  const launched = new Promise(resolve => { started = resolve; });
  const gate = new Promise(resolve => { released = resolve; });
  const manager = new AccountSessionManager({ root, launch: async (directory) => { started(); await gate; return fake.launch(directory); } });
  try {
    const opening = manager.open({ id: 'A', platform: 'douyin' });
    const rejected = assert.rejects(opening, /已删除/);
    await launched; await retireAccountSession(root, 'A'); released(); await rejected;
    assert.equal(manager.sessions.size, 0);
    const restarted = new AccountSessionManager({ root, launch: fake.launch });
    await assert.rejects(restarted.open({ id: 'A', platform: 'douyin' }), /已删除/);
    assert.equal(fake.launches.length, 1);
    assert.equal(fake.contexts[0].pages()[0].closed, true);
  } finally { released(); await manager.shutdown(); await rm(root, { recursive: true, force: true }); }
});
