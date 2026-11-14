import { createHash } from 'node:crypto';
import { join, resolve, dirname } from 'node:path';

export const accountBackends = Object.freeze({
  douyin: 'https://creator.douyin.com/', bilibili: 'https://member.bilibili.com/',
  xiaohongshu: 'https://creator.xiaohongshu.com/', x: 'https://x.com/compose/post',
  youtube: 'https://studio.youtube.com/',
  tiktok: 'https://www.tiktok.com/tiktokstudio', instagram: 'https://www.instagram.com/',
});
export const chromeExecutable = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
export function sessionConfig() {
  const database = resolve(process.env.WORKBENCH_DB_PATH || 'data/workbench.sqlite');
  const root = resolve(process.env.WORKBENCH_SESSION_ROOT || join(dirname(database), 'account-sessions'));
  const key = createHash('sha256').update(root).digest('hex').slice(0, 20);
  return { root, socket: `/tmp/workbench-accounts-${key}.sock`, lock: join(root, 'manager.lock') };
}
export function accountDirectory(root, id) {
  if (typeof id !== 'string' || !id.trim() || id.length > 200) throw new Error('账号 ID 不正确');
  return join(root, createHash('sha256').update(id).digest('hex'));
}
export function backendUrl(platform) {
  if (!Object.hasOwn(accountBackends, platform)) throw new Error('不支持的平台');
  return accountBackends[platform];
}
