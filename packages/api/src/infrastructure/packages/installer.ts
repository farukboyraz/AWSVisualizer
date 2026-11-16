import { spawn, execFile } from 'child_process';
import { existsSync } from 'fs';
import { dirname, join } from 'path';
import { randomUUID } from 'crypto';
import { SDK_VERSION, CORE_PACKAGES, SERVICE_PACKAGES } from '../../domain/service-packages.js';
import { AWS_SERVICE_CATALOG } from '../../domain/aws-service-catalog.js';
import { loadConfig, updatePackageRecords, saveRuntimeInfo, type PackageFailure } from '../../config/index.js';
import { ensureModulesDir, installedPackage, modulesDir } from './modules-dir.js';

/** One npm install per service; output is kept per step for the progress / error screens. */
export interface InstallStep {
  service: string;
  name: string;
  packages: string[];
  status: 'pending' | 'running' | 'installed' | 'already' | 'failed';
  command: string;
  output: string;
  error?: string;
  startedAt?: string;
  finishedAt?: string;
}

export interface InstallJob {
  id: string;
  status: 'running' | 'finished';
  startedAt: string;
  finishedAt?: string;
  steps: InstallStep[];
  installedCount: number;
  alreadyCount: number;
  failedCount: number;
}

const OUTPUT_LIMIT = 300_000;
const FAILURE_OUTPUT_LIMIT = 6_000;
const STEP_TIMEOUT_MS = 10 * 60_000;

const nodeBin = () => dirname(process.execPath);
/** The npm that ships with the node running the sidecar (the one the app checked), else whatever is on PATH. */
const npmPath = () => (existsSync(join(nodeBin(), 'npm')) ? join(nodeBin(), 'npm') : 'npm');
const npmEnv = () => ({ ...process.env, PATH: [nodeBin(), process.env.PATH].filter(Boolean).join(':'), npm_config_update_notifier: 'false' });

const serviceName = (id: string) => AWS_SERVICE_CATALOG.find((e) => e.id === id)?.name ?? id;
const spec = (pkg: string) => `${pkg}@${pkg.startsWith('@aws-sdk/') ? SDK_VERSION : 'latest'}`;
const npmArgs = (pkgs: string[]) => ['install', '--prefix', modulesDir(), '--save-exact', '--no-audit', '--no-fund', '--loglevel=http', ...pkgs.map(spec)];
/** Copy-pasteable equivalent of what the app runs. */
export const installCommand = (pkgs: string[]) => `npm install --prefix "${modulesDir()}" --save-exact --no-audit --no-fund ${pkgs.map(spec).join(' ')}`;

// ---------------------------------------------------------------- status

export interface PackageState {
  name: string;
  required: string;
  installed: string | null;
  source?: 'repo' | 'user';
}

const packageState = (name: string): PackageState => {
  const p = installedPackage(name);
  return { name, required: name.startsWith('@aws-sdk/') ? SDK_VERSION : '*', installed: p?.version ?? null, source: p?.source };
};

/** A service counts as installed when every package it needs is on disk. */
export function isServiceInstalled(id: string): boolean {
  return (SERVICE_PACKAGES[id] || []).every((p) => installedPackage(p));
}

/** Drops failure records whose service has since been installed (terminal, retry, another service sharing the package). */
export function clearResolvedFailures(): Record<string, PackageFailure> {
  const failures = loadConfig().packages.failures;
  const resolved = Object.keys(failures).filter(isServiceInstalled);
  if (!resolved.length) return failures;
  return updatePackageRecords((r) => resolved.forEach((id) => delete r.failures[id])).failures;
}

export function packagesStatus() {
  const failures = clearResolvedFailures();
  const config = loadConfig();
  return {
    sdkVersion: SDK_VERSION,
    modulesDir: modulesDir(),
    runtime: config.runtime,
    core: CORE_PACKAGES.map(packageState),
    services: Object.fromEntries(
      Object.entries(SERVICE_PACKAGES).map(([id, pkgs]) => {
        const packages = pkgs.map(packageState);
        return [id, { name: serviceName(id), installed: packages.every((p) => p.installed), packages, command: installCommand(pkgs) }];
      }),
    ),
    failures,
  };
}

// ---------------------------------------------------------------- runtime

function npmVersion(): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile(npmPath(), ['-v'], { env: npmEnv(), timeout: 15_000 }, (err, stdout) => resolve(err ? undefined : stdout.trim()));
  });
}

/** Records the node / npm the sidecar runs on, plus where service packages go. */
export async function recordRuntime(): Promise<void> {
  const npm = await npmVersion();
  saveRuntimeInfo({
    node: { version: process.version.replace(/^v/, ''), path: process.execPath, managedByApp: process.execPath.includes(join('AWSVisualizer', 'node')) },
    npm: npm ? { version: npm } : undefined,
    checkedAt: new Date().toISOString(),
  });
  updatePackageRecords((r) => {
    r.sdkVersion = SDK_VERSION;
    r.modulesDir = modulesDir();
  });
}

// ---------------------------------------------------------------- jobs

const jobs = new Map<string, InstallJob>();
let running: InstallJob | undefined;

export const getJob = (id: string) => jobs.get(id);
export const runningJob = () => running;

function append(step: InstallStep, text: string) {
  step.output += text;
  if (step.output.length > OUTPUT_LIMIT) step.output = `…\n${step.output.slice(-OUTPUT_LIMIT)}`;
}

/** The most useful error line npm printed, else the exit code. */
function errorSummary(output: string, code: number | null, signal: string | null): string {
  const lines = output.split('\n').map((l) => l.trim());
  const npmErr = lines.filter((l) => /^npm (ERR!|error)/.test(l)).map((l) => l.replace(/^npm (ERR!|error)\s*/, '').trim());
  const errCode = npmErr.map((l) => l.match(/^code (\S+)/)?.[1]).find(Boolean);
  // Skip the `key value` detail lines, stack frames and object dumps npm prints around the message.
  const prose = npmErr.filter((l) => l && !/^(code|syscall|errno|path|dest|type|address|port)\b|^at |^[{}]|^\w+: '|^A complete log|^Log files/i.test(l));
  const message = prose.find((l) => /error|failed|not found|denied|permission|ETARGET|E404|EACCES|ENOTFOUND/i.test(l)) ?? prose[0];
  if (message) return errCode && !message.includes(errCode) ? `${errCode}: ${message}` : message;
  if (errCode) return errCode;
  if (signal) return `npm was stopped (${signal})`;
  return `npm exited with code ${code}`;
}

function runNpm(step: InstallStep, pkgs: string[]): Promise<{ code: number | null; signal: string | null }> {
  return new Promise((resolve) => {
    append(step, `$ ${step.command}\n`);
    const child = spawn(npmPath(), npmArgs(pkgs), { cwd: modulesDir(), env: npmEnv() });
    const timer = setTimeout(() => child.kill('SIGTERM'), STEP_TIMEOUT_MS);
    child.stdout.on('data', (d) => append(step, d.toString()));
    child.stderr.on('data', (d) => append(step, d.toString()));
    child.on('error', (err) => {
      append(step, `\n${err.message}\n`);
      clearTimeout(timer);
      resolve({ code: -1, signal: null });
    });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal });
    });
  });
}

async function runStep(step: InstallStep) {
  step.status = 'running';
  step.startedAt = new Date().toISOString();
  const missing = step.packages.filter((p) => !installedPackage(p));
  if (!missing.length) {
    step.status = 'already';
    append(step, `All packages are already installed:\n${step.packages.map((p) => `  ${p}@${installedPackage(p)?.version}`).join('\n')}\n`);
  } else {
    step.command = installCommand(missing);
    const { code, signal } = await runNpm(step, missing);
    const stillMissing = missing.filter((p) => !installedPackage(p));
    if (code === 0 && !stillMissing.length) {
      step.status = 'installed';
    } else {
      step.status = 'failed';
      step.error = code === 0 ? `npm finished but ${stillMissing.join(', ')} is still missing` : errorSummary(step.output, code, signal);
    }
  }
  step.finishedAt = new Date().toISOString();

  updatePackageRecords((r) => {
    for (const p of step.packages) {
      const found = installedPackage(p);
      if (found?.source === 'user') r.installed[p] = { version: found.version, installedAt: r.installed[p]?.version === found.version ? r.installed[p].installedAt : step.finishedAt! };
    }
    if (step.status === 'failed') {
      r.failures[step.service] = {
        service: step.service,
        packages: step.packages,
        error: step.error || 'Install failed',
        command: step.command,
        output: step.output.slice(-FAILURE_OUTPUT_LIMIT),
        failedAt: step.finishedAt!,
      };
    } else {
      delete r.failures[step.service];
    }
  });
}

/** Starts installing `services` one after another; returns immediately with the job to poll. */
export function startInstall(services: string[]): InstallJob {
  if (running) throw Object.assign(new Error('Another install is still running'), { $metadata: { httpStatusCode: 409 }, jobId: running.id });
  ensureModulesDir();
  const job: InstallJob = {
    id: randomUUID(),
    status: 'running',
    startedAt: new Date().toISOString(),
    steps: [...new Set(services)]
      .filter((id) => SERVICE_PACKAGES[id])
      .map((id) => ({ service: id, name: serviceName(id), packages: SERVICE_PACKAGES[id], status: 'pending', command: installCommand(SERVICE_PACKAGES[id]), output: '' })),
    installedCount: 0,
    alreadyCount: 0,
    failedCount: 0,
  };
  jobs.set(job.id, job);
  // Keep the last few jobs only.
  for (const id of [...jobs.keys()].slice(0, Math.max(0, jobs.size - 10))) jobs.delete(id);
  running = job;
  (async () => {
    try {
      for (const step of job.steps) {
        await runStep(step);
        job.installedCount = job.steps.filter((s) => s.status === 'installed').length;
        job.alreadyCount = job.steps.filter((s) => s.status === 'already').length;
        job.failedCount = job.steps.filter((s) => s.status === 'failed').length;
      }
    } finally {
      job.status = 'finished';
      job.finishedAt = new Date().toISOString();
      running = undefined;
    }
  })();
  return job;
}
