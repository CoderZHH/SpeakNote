import { cp, mkdir, mkdtemp, readFile, writeFile, rm, rename, chmod } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const source = dirname(fileURLToPath(import.meta.url));
const project = resolve(source, '../..');
const target = join(project, 'apple/Resources/ChromeRuntime');
const [major, minor] = process.versions.node.split('.').map(Number);
if (process.platform !== 'darwin' || major < 24 || (major === 24 && minor < 11)) throw new Error('需要 macOS 与官方 Node.js 24.11+');
function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  if (result.error || result.status !== 0) throw new Error(`${command} 未能完成：${result.stderr || result.error}`);
  return result.stdout;
}
const libraries = run('/usr/bin/otool', ['-L', process.execPath]);
if (/\/(opt\/homebrew|usr\/local|Users)\//.test(libraries.split('\n').slice(1).join('\n'))) throw new Error('请使用官方独立 Node.js 发行版，不能分发依赖本机动态库的运行时');
const license = process.env.WORKBENCH_NODE_LICENSE || resolve(dirname(process.execPath), '../LICENSE');
await readFile(license); // Fail before replacing a working runtime.
const manifest = JSON.parse(await readFile(join(source, 'runtime-manifest.json'), 'utf8'));
const archive = join(source, 'vendor/playwright-core-1.62.1.tgz');
if (createHash('sha256').update(await readFile(archive)).digest('hex') !== manifest.playwrightArchiveSHA256) throw new Error('Playwright 资源校验失败');
await mkdir(dirname(target), { recursive: true });
const staging = await mkdtemp(join(dirname(target), '.ChromeRuntime-'));
try {
  const helper = join(staging, 'backend.bundle');
  const runtime = join(staging, 'runtime');
  await mkdir(join(helper, 'Contents/MacOS'), { recursive: true });
  await mkdir(join(runtime, 'node_modules/playwright-core'), { recursive: true });
  await cp(process.execPath, join(helper, 'Contents/MacOS/workbench-node'));
  await chmod(join(helper, 'Contents/MacOS/workbench-node'), 0o755);
  await cp(join(source, 'Helper-Info.plist'), join(helper, 'Contents/Info.plist'));
  run('/usr/bin/codesign', ['--force', '--sign', '-', '--entitlements', join(source, 'Helper.entitlements'), helper]);
  await cp(join(source, 'src'), join(runtime, 'src'), { recursive: true });
  run('/usr/bin/tar', ['-xzf', archive, '--strip-components=1', '-C', join(runtime, 'node_modules/playwright-core')]);
  await cp(license, join(runtime, 'NODE-LICENSE'));
  await cp(join(project, 'THIRD_PARTY_NOTICES.md'), join(runtime, 'THIRD_PARTY_NOTICES.md'));
  await writeFile(join(runtime, 'runtime.json'), JSON.stringify({ node: process.versions.node, arch: process.arch, playwright: '1.62.1' }, null, 2) + '\n');
  await writeFile(join(staging, '.gitkeep'), '');
  await rm(target, { recursive: true, force: true });
  await rename(staging, target);
  console.log('Chrome 工具已独立准备；Xcode Run 不执行 JavaScript 构建。');
} finally { await rm(staging, { recursive: true, force: true }); }
