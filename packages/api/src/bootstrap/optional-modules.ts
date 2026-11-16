/**
 * Lets the sidecar start without any service SDK installed.
 *
 * 1. The user's modules folder is added to NODE_PATH, so packages
 *    installed there resolve like any other dependency.
 * 2. A service package that can't be found is replaced by a stand-in
 *    module instead of crashing the import. Touching any export of the
 *    stand-in (`new S3Client()`, `new ListBucketsCommand()`) throws
 *    PackageMissingError, which the error handler answers with a 424
 *    naming the package.
 * 3. Every export access first re-checks the disk, so once the package
 *    is installed the stand-in forwards to the real module - no restart.
 *
 * This must be the first import of src/index.ts.
 */
import Module, { createRequire } from 'module';
import { join } from 'path';
import { OPTIONAL_PACKAGES, packageName, servicesUsing } from '../domain/service-packages.js';
import { apiDir, installedPackage, modulesNodeModules } from '../infrastructure/packages/modules-dir.js';

export class PackageMissingError extends Error {
  readonly packages: string[];
  readonly services: string[];
  readonly $metadata = { httpStatusCode: 424 };
  constructor(pkg: string) {
    super(`The npm package ${pkg} is not installed. Install it from Settings › Services.`);
    this.name = 'PackageMissing';
    this.packages = [pkg];
    this.services = servicesUsing(pkg);
  }
}

const M = Module as unknown as {
  _load: (request: string, parent: unknown, isMain: boolean) => unknown;
  _initPaths: () => void;
};

const extra = modulesNodeModules();
const current = (process.env.NODE_PATH || '').split(':').filter(Boolean);
if (!current.includes(extra)) {
  process.env.NODE_PATH = [...current, extra].join(':');
  M._initPaths();
}

const originalLoad = M._load;
const requireFromApi = createRequire(join(apiDir(), 'package.json'));
const stubs = new Map<string, object>();

/** Requests that are a missing optional package itself (not something inside a package that is missing a file). */
function isMissingOptional(request: string, err: unknown): boolean {
  const e = err as { code?: string; message?: string };
  return e?.code === 'MODULE_NOT_FOUND' && OPTIONAL_PACKAGES.has(packageName(request)) && (e.message || '').includes(`'${request}'`);
}

function stub(request: string): object {
  const existing = stubs.get(request);
  if (existing) return existing;
  const pkg = packageName(request);
  let real: Record<string | symbol, unknown> | undefined;
  const missingExports = new Map<string | symbol, unknown>();

  const loadReal = () => {
    if (real) return real;
    if (!installedPackage(pkg)) return undefined;
    try {
      real = originalLoad.call(Module, requireFromApi.resolve(request), null, false) as Record<string | symbol, unknown>;
    } catch {
      real = undefined;
    }
    return real;
  };

  /** A class-shaped export that fails the moment it's used. */
  const missingExport = (prop: string | symbol) => {
    if (!missingExports.has(prop)) {
      const fail = function () {
        const r = loadReal();
        if (r && typeof r[prop] === 'function') {
          // Installed since: behave like the real export.
          const Real = r[prop] as new (...a: unknown[]) => unknown;
          // eslint-disable-next-line prefer-rest-params
          return new.target ? Reflect.construct(Real, arguments as unknown as unknown[], new.target) : (Real as unknown as (...a: unknown[]) => unknown)(...(arguments as unknown as unknown[]));
        }
        throw new PackageMissingError(pkg);
      };
      missingExports.set(prop, fail);
    }
    return missingExports.get(prop);
  };

  const proxy = new Proxy(
    {},
    {
      get(_target, prop) {
        if (prop === '__esModule') return true;
        // Not a promise, not a primitive.
        if (prop === 'then' || typeof prop === 'symbol') return undefined;
        const r = loadReal();
        if (r) return r[prop];
        return missingExport(prop);
      },
      has(_target, prop) {
        const r = loadReal();
        return r ? prop in r : true;
      },
      ownKeys() {
        const r = loadReal();
        return r ? Reflect.ownKeys(r) : [];
      },
      getOwnPropertyDescriptor(_target, prop) {
        const r = loadReal();
        if (!r) return undefined;
        const d = Reflect.getOwnPropertyDescriptor(r, prop);
        return d ? { ...d, configurable: true } : undefined;
      },
    },
  );
  stubs.set(request, proxy);
  return proxy;
}

M._load = function (request: string, parent: unknown, isMain: boolean) {
  try {
    return originalLoad.call(this, request, parent, isMain);
  } catch (err) {
    if (isMissingOptional(request, err)) return stub(request);
    throw err;
  }
};

/** Packages that were imported while missing (for diagnostics). */
export const stubbedPackages = () => [...stubs.keys()];
