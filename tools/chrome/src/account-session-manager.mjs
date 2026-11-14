import { mkdir, chmod, writeFile, rename, readFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { accountDirectory, backendUrl } from './account-session-config.mjs';

// A separate marker prevents an in-flight open from resurrecting a deleted
// account, including after the native app or manager restarts.
export async function retireAccountSession(root, id) {
  const directory = accountDirectory(root, id);
  await mkdir(directory, { recursive: true, mode: 0o700 }); await chmod(directory, 0o700);
  await writeFile(join(directory, '.retired'), 'removed', { mode: 0o600 });
}

// Owns browser instances independently of the native application. Queue every operation per account,
// including a second click during launch/reset, so one directory has one owner.
export class AccountSessionManager {
  constructor({ root, launch, urlFor = backendUrl }) {
    this.root = root; this.launch = launch; this.urlFor = urlFor;
    this.sessions = new Map(); this.queues = new Map();
  }
  serial(id, action) {
    const next = (this.queues.get(id) || Promise.resolve()).catch(() => {}).then(action);
    this.queues.set(id, next);
    next.finally(() => { if (this.queues.get(id) === next) this.queues.delete(id); }).catch(() => {});
    return next;
  }
  async metadata(id, patch) {
    const path = join(accountDirectory(this.root, id), 'workbench-session.json');
    let prior = {}; try { prior = JSON.parse(await readFile(path, 'utf8')); } catch {}
    const temporary = `${path}.tmp`;
    await writeFile(temporary, JSON.stringify({ ...prior, ...patch }), { mode: 0o600 });
    await rename(temporary, path);
  }
  async open(account) { return this.serial(account.id, () => this.openUnlocked(account)); }
  async openUnlocked(account) {
    const url = this.urlFor(account.platform);
    const directory = accountDirectory(this.root, account.id);
    if (existsSync(join(directory, '.retired'))) throw new Error('账号已删除');
    const existing = this.sessions.get(account.id);
    if (existing) {
      if (existing.platform !== account.platform) throw new Error('账号平台与已有会话不一致');
      try {
        let page = existing.context.pages().find(p => !p.isClosed() && p.url() !== 'about:blank');
        let navigationPending = false;
        if (!page) {
          page = existing.context.pages().find(p => !p.isClosed()) || await existing.context.newPage();
          try { await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 }); } catch { navigationPending = true; }
        }
        await page.bringToFront();
        return { opened: true, reused: true, ...(navigationPending ? { navigationPending: true } : {}) };
      } catch (error) {
        // A network failure must not start a second browser with the same directory.
        if (this.sessions.get(account.id) === existing) throw error;
      }
    }
    await mkdir(directory, { recursive: true, mode: 0o700 }); await chmod(directory, 0o700);
    const context = await this.launch(join(directory, 'browser'));
    if (existsSync(join(directory, '.retired'))) { await context.close(); throw new Error('账号已删除'); }
    const session = { context, platform: account.platform };
    this.sessions.set(account.id, session);
    context.on('close', () => { if (this.sessions.get(account.id) === session) this.sessions.delete(account.id); });
    await this.metadata(account.id, { initialized: true, openedAt: new Date().toISOString() });
    let page = context.pages().find(p => !p.isClosed()) || await context.newPage();
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 }); await page.bringToFront();
    } catch {
      // Leave the browser usable for manual retry; persistence does not depend on navigation.
      return { opened: true, reused: false, navigationPending: true };
    }
    return { opened: true, reused: false };
  }
  async reset(account) {
    return this.serial(account.id, async () => {
      this.urlFor(account.platform);
      if (existsSync(join(accountDirectory(this.root, account.id), '.retired'))) throw new Error('账号已删除');
      const existing = this.sessions.get(account.id);
      if (existing) await existing.context.close();
      this.sessions.delete(account.id);
      // Only this account's generated profile is removed after Chrome releases it.
      // Clear all login origins and storage together; daily Chrome is untouched.
      await rm(join(accountDirectory(this.root, account.id), 'browser'), { recursive: true, force: true });
      return this.openUnlocked(account);
    });
  }
  async close(id) {
    return this.serial(id, async () => {
      const session = this.sessions.get(id); if (session) await session.context.close();
      this.sessions.delete(id);
      return { closed: true };
    });
  }
  async shutdown() {
    await Promise.allSettled([...this.queues.values()]);
    await Promise.all([...this.sessions.keys()].map(id => this.close(id)));
  }
}
