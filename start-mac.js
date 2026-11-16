#!/usr/bin/env node
/**
 * Builds the macOS app and opens it.
 *
 *   npm run mac            release build (recommended)
 *   npm run mac:debug      debug build (faster to compile)
 *
 * Steps: check the tools, `swift build`, assemble
 * `dist/mac/AWS Visualizer.app` (binary, Info.plist, icon, resources), sign
 * it ad hoc for this Mac, stop a copy that is already running (and its
 * local API on 127.0.0.1:9000), open the new one.
 *
 * The app starts its own local API (packages/api) on launch - there is no
 * separate server to run - and on first launch it checks Node.js / npm and
 * installs the packages it needs.
 */
const { execSync, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const ROOT = __dirname;
const MAC_DIR = path.join(ROOT, 'packages', 'mac', 'AWSVisualizer');
const APP = path.join(ROOT, 'dist', 'mac', 'AWS Visualizer.app');
const config = process.argv.includes('--debug') ? 'debug' : 'release';

const log = (msg) => console.log(`[AWS Visualizer] ${msg}`);
const fail = (msg) => {
  console.error(`[AWS Visualizer] ${msg}`);
  process.exit(1);
};
const has = (cmd) => spawnSync('/bin/sh', ['-c', `command -v ${cmd}`]).status === 0;
const run = (cmd, opts = {}) => execSync(cmd, { stdio: 'inherit', ...opts });

// 1. Tools
if (process.platform !== 'darwin') fail('The app is macOS only (macOS 14 or later).');
if (!has('swift')) fail('Swift is missing. Install Xcode or the Command Line Tools: xcode-select --install');
// Any Node runs this script; the app itself needs 20+ (22 recommended) and
// offers to install it on first launch (Settings › Node.js & Packages).
const nodeMajor = Number(process.versions.node.split('.')[0]);
if (nodeMajor < 20) log(`Note: Node.js ${process.versions.node} is older than the app needs (20+, 22 recommended) - it will offer to install a newer one on first launch.`);
if (!has('aws')) log('Note: the AWS CLI v2 was not found. It is needed to sign in (aws sso login) - https://aws.amazon.com/cli/');

// 2. Build
log(`Building the app (${config})...`);
run(`swift build -c ${config}`, { cwd: MAC_DIR });
const binDir = execSync(`swift build -c ${config} --show-bin-path`, { cwd: MAC_DIR }).toString().trim();

// 3. App bundle
log('Assembling dist/mac/AWS Visualizer.app...');
fs.rmSync(APP, { recursive: true, force: true });
const contents = path.join(APP, 'Contents');
const macos = path.join(contents, 'MacOS');
const resources = path.join(contents, 'Resources');
fs.mkdirSync(macos, { recursive: true });
fs.mkdirSync(resources, { recursive: true });
fs.copyFileSync(path.join(binDir, 'AWSVisualizer'), path.join(macos, 'AWSVisualizer'));
fs.chmodSync(path.join(macos, 'AWSVisualizer'), 0o755);
fs.copyFileSync(path.join(MAC_DIR, 'Info.plist'), path.join(contents, 'Info.plist'));
// SwiftPM resource bundles (the brand image, the terminal's resources).
for (const entry of fs.readdirSync(binDir)) {
  if (entry.endsWith('.bundle')) fs.cpSync(path.join(binDir, entry), path.join(resources, entry), { recursive: true });
}
fs.copyFileSync(path.join(MAC_DIR, 'Sources', 'Resources', 'awsvis.png'), path.join(resources, 'awsvis.png'));
// App icon: the AWS cloud icon (AppIcon.icns, made from awsvis.png). If the
// .icns is missing (fresh clone), build it from awsvis.png instead.
const appIcon = path.join(MAC_DIR, 'Resources', 'AppIcon.icns');
if (fs.existsSync(appIcon)) fs.copyFileSync(appIcon, path.join(resources, 'AppIcon.icns'));
else makeIcon(path.join(MAC_DIR, 'Sources', 'Resources', 'awsvis.png'), path.join(resources, 'AppIcon.icns'));

// 4. Sign for this Mac (ad hoc - no developer account needed).
log('Signing...');
run(`codesign --force --deep --entitlements "${path.join(MAC_DIR, 'AWSVisualizer.entitlements')}" --sign - "${APP}"`);

// 5. Restart
spawnSync('pkill', ['-x', 'AWSVisualizer']);
// Only an earlier copy of the app's API (started from a packages/api folder)
// is stopped; any other program on port 9000 is left alone.
const listener = spawnSync('lsof', ['-nP', '-iTCP:9000', '-sTCP:LISTEN', '-t']).stdout.toString().trim();
for (const pid of listener.split('\n').filter(Boolean)) {
  const cwd = spawnSync('lsof', ['-a', '-p', pid, '-d', 'cwd', '-Fn']).stdout.toString();
  if (!cwd.split('\n').some((line) => line.startsWith('n') && line.endsWith('/packages/api'))) {
    log(`Note: port 9000 is used by another program (pid ${pid}). The app's local API needs it - quit that program first.`);
    continue;
  }
  try {
    process.kill(Number(pid), 'SIGTERM');
  } catch {
    // already gone
  }
}
log('Opening the app...');
run(`open "${APP}"`);
log('Done. Settings › About shows the version; Settings › Node.js & Packages the runtime.');

/** PNG -> AppIcon.icns with the system's sips + iconutil. */
function makeIcon(png, icns) {
  if (!fs.existsSync(png)) return;
  const set = fs.mkdtempSync(path.join(os.tmpdir(), 'awsvis-')) + '/AppIcon.iconset';
  fs.mkdirSync(set);
  for (const size of [16, 32, 128, 256, 512]) {
    execSync(`sips -z ${size} ${size} "${png}" --out "${set}/icon_${size}x${size}.png"`, { stdio: 'ignore' });
    execSync(`sips -z ${size * 2} ${size * 2} "${png}" --out "${set}/icon_${size}x${size}@2x.png"`, { stdio: 'ignore' });
  }
  execSync(`iconutil -c icns "${set}" -o "${icns}"`, { stdio: 'ignore' });
  fs.rmSync(path.dirname(set), { recursive: true, force: true });
}
