import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs';
import { homedir } from 'os';
import { join, resolve } from 'path';

/**
 * Where service SDKs are installed: a per-user npm prefix, outside the
 * repo, so each service can be installed on its own without npm
 * re-installing everything in packages/api's package.json.
 * `AWSVIS_MODULES_DIR` overrides it (tests, custom setups).
 */
export function modulesDir(): string {
  if (process.env.AWSVIS_MODULES_DIR) return resolve(process.env.AWSVIS_MODULES_DIR);
  const base = process.platform === 'darwin' ? join(homedir(), 'Library', 'Application Support', 'AWSVisualizer') : join(homedir(), '.local', 'share', 'awsvisualizer');
  return join(base, 'modules');
}

export const modulesNodeModules = () => join(modulesDir(), 'node_modules');

/** packages/api (this file is src/infrastructure/packages/modules-dir.ts). */
export const apiDir = () => resolve(__dirname, '..', '..', '..');

/** Creates the prefix with a private package.json so `npm install --prefix` has somewhere to record installs. */
export function ensureModulesDir(): string {
  const dir = modulesDir();
  mkdirSync(dir, { recursive: true });
  const pj = join(dir, 'package.json');
  if (!existsSync(pj)) {
    writeFileSync(pj, JSON.stringify({ name: 'awsvisualizer-modules', private: true, description: 'AWS SDK packages installed by AWS Visualizer', dependencies: {} }, null, 2));
  }
  return dir;
}

/** node_modules folders a package may live in: the repo's (dev / core) and the user's. */
function searchRoots(): { root: string; source: 'repo' | 'user' }[] {
  const api = apiDir();
  return [
    { root: join(api, 'node_modules'), source: 'repo' },
    { root: join(api, '..', '..', 'node_modules'), source: 'repo' },
    { root: modulesNodeModules(), source: 'user' },
  ];
}

export interface InstalledPackage {
  version: string;
  source: 'repo' | 'user';
  path: string;
}

/** Looks the package up on disk (not via require, so `exports` maps don't matter). */
export function installedPackage(name: string): InstalledPackage | undefined {
  for (const { root, source } of searchRoots()) {
    const pj = join(root, name, 'package.json');
    if (!existsSync(pj)) continue;
    try {
      const version = JSON.parse(readFileSync(pj, 'utf-8')).version;
      if (typeof version === 'string') return { version, source, path: join(root, name) };
    } catch {
      // Half-written install; treat as missing.
    }
  }
  return undefined;
}
