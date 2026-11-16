import { existsSync, readFileSync, writeFileSync } from 'fs';

/**
 * The sidecar's version is packages/api/package.json's (kept equal to the
 * app's Info.plist and the root package.json - see the README's
 * "Versioning"). Read once at start; a saved ~/.awsvisualizer can't override it.
 */
export const APP_VERSION: string = (() => {
  try {
    return JSON.parse(readFileSync(join(__dirname, '../../package.json'), 'utf-8')).version || '0.0.0';
  } catch {
    return '0.0.0';
  }
})();
import { join } from 'path';
import { homedir } from 'os';

export const DYNAMODB_ITEM_VIEWS = ['json', 'dynamodb-json', 'form'] as const;
export type DynamoDbItemView = (typeof DYNAMODB_ITEM_VIEWS)[number];
export const CODE_THEMES = ['vscode', 'vscode-dark', 'vscode-light', 'github', 'monokai', 'xcode'] as const;
export type CodeTheme = (typeof CODE_THEMES)[number];
export const LAYOUT_MODES = ['sideBySide', 'singlePage'] as const;
export const FILE_ICON_THEMES = ['colorful', 'monochrome', 'minimal'] as const;
export type FileIconTheme = (typeof FILE_ICON_THEMES)[number];
export const HISTORY_LAYOUTS = ['singlePage', 'sideBySide'] as const;
export type HistoryLayout = (typeof HISTORY_LAYOUTS)[number];
export type LayoutMode = (typeof LAYOUT_MODES)[number];

// ---- Dashboard (Settings › Display › Dashboard)

export const DASHBOARD_WIDGETS = ['resourcesKpi', 'activeKpi', 'costKpi', 'attentionKpi', 'customCards', 'distribution', 'topServices', 'costTrend', 'costByService', 'services'] as const;
export type DashboardWidget = (typeof DASHBOARD_WIDGETS)[number];
/** Widgets that need the per-service resource counts (one AWS list call per service). */
export const COUNT_WIDGETS: DashboardWidget[] = ['resourcesKpi', 'activeKpi', 'attentionKpi', 'distribution', 'topServices', 'services'];
/** Widgets that need Cost Explorer (billed per request). */
export const COST_WIDGETS: DashboardWidget[] = ['costKpi', 'costTrend', 'costByService'];
export const COST_VIEWS = ['daily', 'monthly', 'month'] as const;
export type CostView = (typeof COST_VIEWS)[number];
export const COST_MONTH_RANGES = [3, 6, 12] as const;
/** How the spend chart draws its series (switchable on the dashboard; this is the default). */
export const COST_CHART_STYLES = ['bar', 'line', 'points'] as const;
export const DASHBOARD_COLOR_STYLES = ['muted', 'vivid'] as const;
/** categories = one block per catalog category; flat = one row of icons, most resources first. */
export const DASHBOARD_SERVICE_LAYOUTS = ['categories', 'flat'] as const;
/** Refresh interval: 0 = manual only, otherwise 1 minute .. 24 hours. */
export const REFRESH_MINUTES_MAX = 24 * 60;
export const MAX_CARDS = 30;

/**
 * A card the user added to their dashboard: a template of a service
 * (packages/api/src/infrastructure/dashboard-cards) with its parameters.
 * Metric and action cards carry the profile / region they work on; link
 * and note cards ignore them.
 */
export interface DashboardCard {
  id: string;
  title: string;
  /** Catalog service id, or "note". */
  service: string;
  /** Template id, e.g. "codecommit.createPullRequest". */
  template: string;
  /** metric | action | link | note - copied from the template when saved, so the app needn't ask. */
  kind: string;
  /** SF Symbol, copied from the template. */
  icon: string;
  /**
   * true: shown on every profile's dashboard. false: only on `profiles`.
   * Either way the card runs with the profile in use at the time.
   */
  allProfiles: boolean;
  /** Kept for older files: the first of `profiles`. */
  profile: string;
  /** The profiles whose dashboard shows the card (ignored when `allProfiles`). */
  profiles: string[];
  /** Region the card reads; "" = the region in use at the time. */
  region: string;
  params: Record<string, string>;
}

const str = (x: unknown, max: number) => (typeof x === 'string' ? x.slice(0, max) : '');

/**
 * Shape check only (the template's own rules are checked by the route
 * that saves cards). Cards saved before templates (`kind: s3Prefix |
 * dynamoCount | note`) are converted.
 */
export function readDashboardCard(raw: any): DashboardCard | null {
  if (!raw || typeof raw.id !== 'string' || !raw.id) return null;
  // `profiles` (several); older cards had one `profile`, none = everywhere.
  const profiles: string[] = Array.isArray(raw.profiles)
    ? [...new Set<string>(raw.profiles.filter((p: unknown) => typeof p === 'string' && p).map((p: string) => p.slice(0, 128)))].slice(0, 50)
    : str(raw.profile, 128) ? [str(raw.profile, 128)] : [];
  const allProfiles = typeof raw.allProfiles === 'boolean' ? raw.allProfiles : profiles.length === 0;
  const base = { id: raw.id.slice(0, 64), title: str(raw.title, 80), profile: profiles[0] ?? '', profiles, region: str(raw.region, 32), kind: str(raw.kind, 16), icon: str(raw.icon, 64), allProfiles };
  if (typeof raw.service === 'string' && typeof raw.template === 'string') {
    const params: Record<string, string> = {};
    if (raw.params && typeof raw.params === 'object' && !Array.isArray(raw.params)) {
      for (const [k, v] of Object.entries(raw.params).slice(0, 30)) if (typeof v === 'string') params[k.slice(0, 64)] = v.slice(0, 10_000);
    }
    // The DynamoDB "query count" card became the "search" card (mode: query).
    if (raw.template === 'dynamodb.queryCount') {
      let search = '';
      try {
        search = JSON.stringify({ mode: 'query', ...JSON.parse(params.query || '{}') });
      } catch {
        search = '';
      }
      return { ...base, service: 'dynamodb', template: 'dynamodb.search', params: { table: params.table ?? '', search } };
    }
    if (raw.template === 'dynamodb.openTable') return { ...base, service: 'dynamodb', template: 'dynamodb.itemCount', params: { table: params.table ?? '' } };
    return { ...base, service: raw.service.slice(0, 64), template: raw.template.slice(0, 96), params };
  }
  if (raw.kind === 's3Prefix' && raw.s3?.bucket) return { ...base, kind: 'metric', icon: 'folder.fill', service: 's3', template: 's3.folderStats', params: { bucket: str(raw.s3.bucket, 63), prefix: str(raw.s3.prefix, 1024) } };
  if (raw.kind === 'dynamoCount' && raw.dynamo?.table) return { ...base, kind: 'metric', icon: 'tablecells.fill', service: 'dynamodb', template: 'dynamodb.itemCount', params: { table: str(raw.dynamo.table, 255) } };
  if (raw.kind === 'note') return { ...base, kind: 'note', icon: 'note.text', service: 'note', template: 'note.text', params: { text: str(raw.note?.text, 2000) } };
  return null;
}

export interface DashboardPrefs {
  /** Widget id -> shown. A hidden widget's data is never requested. */
  widgets: Record<DashboardWidget, boolean>;
  /** Selected services left out of the dashboard: not counted, no AWS call. */
  excludedServices: string[];
  cost: {
    /** daily = last 30 days by day, monthly = last N months by month, month = one month by day. */
    view: CostView;
    months: (typeof COST_MONTH_RANGES)[number];
    showEstimate: boolean;
    chartStyle: (typeof COST_CHART_STYLES)[number];
  };
  colorStyle: (typeof DASHBOARD_COLOR_STYLES)[number];
  hideEmptyServices: boolean;
  servicesLayout: (typeof DASHBOARD_SERVICE_LAYOUTS)[number];
  /** How old the saved dashboard data may get before it is fetched again (0 = only with Refresh). */
  refreshMinutes: number;
  /** Fetch again every time the dashboard opens, even when the saved data is fresh. */
  refreshOnOpen: boolean;
  /** The user's own cards, in display order (drag and drop). */
  cards: DashboardCard[];
}

export const DEFAULT_DASHBOARD: DashboardPrefs = {
  widgets: Object.fromEntries(DASHBOARD_WIDGETS.map((w) => [w, true])) as Record<DashboardWidget, boolean>,
  excludedServices: [],
  cost: { view: 'month', months: 6, showEstimate: true, chartStyle: 'bar' },
  colorStyle: 'muted',
  hideEmptyServices: false,
  servicesLayout: 'categories',
  refreshMinutes: 15,
  refreshOnOpen: false,
  cards: [],
};

/** Unknown keys / wrong types fall back to the defaults field by field. */
export function readDashboardPrefs(raw: any): DashboardPrefs {
  const d = DEFAULT_DASHBOARD;
  const widgets = { ...d.widgets };
  for (const w of DASHBOARD_WIDGETS) if (typeof raw?.widgets?.[w] === 'boolean') widgets[w] = raw.widgets[w];
  // Older files had autoRefreshMinutes (0 / 5 / 15 / 30).
  const minutes = typeof raw?.refreshMinutes === 'number' ? raw.refreshMinutes : typeof raw?.autoRefreshMinutes === 'number' && raw.autoRefreshMinutes > 0 ? raw.autoRefreshMinutes : d.refreshMinutes;
  const seen = new Set<string>();
  return {
    widgets,
    excludedServices: Array.isArray(raw?.excludedServices) ? raw.excludedServices.filter((x: unknown) => typeof x === 'string') : [],
    cost: {
      view: COST_VIEWS.includes(raw?.cost?.view) ? raw.cost.view : d.cost.view,
      months: COST_MONTH_RANGES.includes(raw?.cost?.months) ? raw.cost.months : d.cost.months,
      showEstimate: typeof raw?.cost?.showEstimate === 'boolean' ? raw.cost.showEstimate : d.cost.showEstimate,
      chartStyle: COST_CHART_STYLES.includes(raw?.cost?.chartStyle) ? raw.cost.chartStyle : d.cost.chartStyle,
    },
    colorStyle: DASHBOARD_COLOR_STYLES.includes(raw?.colorStyle) ? raw.colorStyle : d.colorStyle,
    hideEmptyServices: typeof raw?.hideEmptyServices === 'boolean' ? raw.hideEmptyServices : d.hideEmptyServices,
    servicesLayout: DASHBOARD_SERVICE_LAYOUTS.includes(raw?.servicesLayout) ? raw.servicesLayout : d.servicesLayout,
    refreshMinutes: Number.isInteger(minutes) && minutes >= 0 && minutes <= REFRESH_MINUTES_MAX ? minutes : d.refreshMinutes,
    refreshOnOpen: typeof raw?.refreshOnOpen === 'boolean' ? raw.refreshOnOpen : d.refreshOnOpen,
    cards: (Array.isArray(raw?.cards) ? raw.cards : [])
      .map(readDashboardCard)
      .filter((c: DashboardCard | null): c is DashboardCard => !!c && !seen.has(c.id) && !!seen.add(c.id))
      .slice(0, MAX_CARDS),
  };
}

// ---- Saved dashboard data (`dashboardCache` in ~/.awsvisualizer)

/** One saved answer: counts, a cost view or a card value. */
export interface DashboardCacheEntry {
  fetchedAt: string;
  data: unknown;
}

const CACHE_MAX_ENTRIES = 80;
const CACHE_MAX_AGE_MS = 14 * 86_400_000;

export interface AppConfig {
  app: {
    name: string;
    version: string;
    port: number;
  };
  aws: {
    /** AWS access portals (IAM Identity Center start URLs) the user signs in to. */
    platforms: SsoPlatform[];
    defaultRegion: string;
  };
  selectedServices: string[];
  favoriteServices: string[];
  maxTabs: number;
  /** Independent switches for the right-edge Dev Tools panel's two tools -
   * the panel itself only renders if at least one is on. Both off by
   * default for new installs, the user explicitly opts each in. */
  terminalPanelEnabled: boolean;
  kiroCliPanelEnabled: boolean;
  /** Right-edge Dev Tools panel: which tools it offers (built-in ids or custom ones). */
  devTools: DevToolsConfig;
  /** CodeCommit repository name -> absolute local path of its git clone (Workspace tab). */
  workspaces: Record<string, string>;
  /** Whether DynamoDB's scan-results grid sizes each column to fit its
   * longest value/header (on) or splits the available width evenly across
   * columns (off). On by default. */
  dynamoDbAutoColumnWidth: boolean;
  /** Which view DynamoDB's item popup opens in: plain JSON, typed DynamoDB
   * JSON ({"S": ...}), or the console-style attribute form. */
  dynamoDbItemView: DynamoDbItemView;
  /** Syntax-color theme of the code / file viewers (default: VS Code). */
  codeTheme: CodeTheme;
  /** List + detail screens: side by side (list left, detail right - the
   * default) or one page at a time with a Back button. */
  layoutMode: LayoutMode;
  /** Whether text / code viewers open with word wrap on (View → Word Wrap
   * still flips it for the session). */
  wordWrap: boolean;
  /** File / folder icons in every file list (S3, CodeCommit, Lambda, archives). */
  fileIconTheme: FileIconTheme;
  /** CodeCommit file History: over the file (single page, default) or next to it. */
  historyLayout: HistoryLayout;
  /** Dashboard layout, colors and which data it may request. */
  dashboard: DashboardPrefs;
  /** Last dashboard data per profile / region / view / card, so opening the dashboard needs no AWS call. */
  dashboardCache: Record<string, DashboardCacheEntry>;
  /** Background color (as `#RRGGBB`) for each semantic `AppButton` kind on
   * the Swift side - text/icon color is never stored, always derived from
   * the background for contrast. */
  buttonColors: ButtonColorConfig;
  /** Bundle identifier (e.g. `com.microsoft.VSCode`) of the IDE the "Open
   * in <IDE>" control (Lambda's Code tab, `OpenInIDEControl` on the Swift
   * side) preselects. Empty string means "no preference" - the control
   * falls back to the first installed IDE from its own registry. */
  defaultIdeBundleIdentifier: string;
  /** Services the user picked on first sign-in; their SDK packages are installed right after. */
  userDefaultServices: string[];
  /** Node / npm the sidecar last ran on (written on every start). */
  runtime: RuntimeInfo;
  /** Service SDK installs: what is installed and which services failed (with the npm output). */
  packages: PackageRecords;
}

export interface RuntimeInfo {
  node?: { version: string; path: string; managedByApp: boolean };
  /** Node bin directory picked in Settings › Node.js & Packages (unset: automatic). Read by the app before the sidecar starts. */
  preferredNodeBin?: string;
  npm?: { version: string };
  checkedAt?: string;
}

export interface PackageFailure {
  service: string;
  packages: string[];
  error: string;
  command: string;
  /** Last lines of the npm output. */
  output: string;
  failedAt: string;
}

export interface PackageRecords {
  sdkVersion: string;
  modulesDir: string;
  /** npm package name -> version + install time (packages installed by the app). */
  installed: Record<string, { version: string; installedAt: string }>;
  /** Catalog service id -> its last failed install; cleared once the packages are present. */
  failures: Record<string, PackageFailure>;
}

/**
 * One AWS access portal. `id` is the `[sso-session <id>]` name in
 * ~/.aws/config, so `aws sso login --sso-session <id>` (app or terminal)
 * logs in every profile of that portal at once.
 */
export interface SsoPlatform {
  id: string;
  name: string;
  startUrl: string;
  region: string;
}

/** A user-defined panel tool: any command run in a login shell (PATH, nvm... work). */
export interface CustomDevTool {
  id: string;
  name: string;
  command: string;
  icon: string;
}

export interface DevToolsConfig {
  /** Enabled tool ids, in panel order (built-in ids like "terminal", "claude-code", or custom ids). */
  enabled: string[];
  custom: CustomDevTool[];
}

export interface ButtonColorConfig {
  newItem: string;
  edit: string;
  delete: string;
  save: string;
  clone: string;
  refresh: string;
  confirm: string;
  open: string;
  download: string;
  run: string;
  stop: string;
  reveal: string;
  clear: string;
  warning: string;
  secondary: string;
  close: string;
}

const DEFAULT_BUTTON_COLORS: ButtonColorConfig = {
  newItem: '#2563EB',
  edit: '#F97316',
  delete: '#7F1D1D',
  save: '#14532D',
  clone: '#7C3AED',
  refresh: '#0F766E',
  confirm: '#065F46',
  open: '#4338CA',
  download: '#4B5563',
  run: '#0369A1',
  stop: '#DC2626',
  reveal: '#B45309',
  clear: '#64748B',
  warning: '#C2410C',
  secondary: '#64748B',
  close: '#DC2626',
};

const DEFAULT_CONFIG: AppConfig = {
  app: {
    name: 'AWS Visualizer',
    version: APP_VERSION,
    port: 9000,
  },
  aws: {
    platforms: [],
    defaultRegion: 'eu-west-1',
  },
  selectedServices: [],
  favoriteServices: [],
  maxTabs: 7,
  terminalPanelEnabled: false,
  kiroCliPanelEnabled: false,
  devTools: { enabled: [], custom: [] },
  workspaces: {},
  dynamoDbAutoColumnWidth: true,
  dynamoDbItemView: 'json',
  codeTheme: 'vscode',
  layoutMode: 'sideBySide',
  wordWrap: false,
  fileIconTheme: 'colorful',
  historyLayout: 'singlePage',
  dashboard: DEFAULT_DASHBOARD,
  dashboardCache: {},
  buttonColors: DEFAULT_BUTTON_COLORS,
  defaultIdeBundleIdentifier: '',
  userDefaultServices: [],
  runtime: {},
  packages: { sdkVersion: '', modulesDir: '', installed: {}, failures: {} },
};

function getConfigPath(): string {
  return join(homedir(), '.awsvisualizer');
}

/** The literal bytes of ~/.awsvisualizer (Settings "view raw config"). */
export function readConfigFileRaw(): string {
  const path = getConfigPath();
  if (!existsSync(path)) {
    return '// ~/.awsvisualizer does not exist - settings are kept for this session only.\n' + JSON.stringify(toFile(loadConfig()), null, 2);
  }
  return readFileSync(path, 'utf-8');
}

let cachedConfig: AppConfig | null = null;

/**
 * The file is only created with the user's consent (first-run setup);
 * until then every change lives in memory for the current session and the
 * setup screen asks again on the next launch.
 */
export function isConfigPersisted(): boolean {
  return existsSync(getConfigPath());
}

/**
 * What goes into ~/.awsvisualizer. Display settings are grouped the way
 * Settings › Display shows them:
 *   display.general    - layoutMode, wordWrap, fileIconTheme, codeTheme
 *   display.codeCommit - historyLayout
 *   display.dashboard  - DashboardPrefs
 * In memory (and in GET /api/config) the first two stay flat, so the
 * routes and the app read them as before. Files written before this
 * layout are read through the old top-level keys and rewritten once.
 */
function toFile(config: AppConfig): Record<string, unknown> {
  const { layoutMode, wordWrap, fileIconTheme, codeTheme, historyLayout, dashboard, ...rest } = config;
  return { ...rest, display: { general: { layoutMode, wordWrap, fileIconTheme, codeTheme }, codeCommit: { historyLayout }, dashboard } };
}

const LEGACY_DISPLAY_KEYS = ['layoutMode', 'wordWrap', 'fileIconTheme', 'codeTheme', 'historyLayout'];

function writeConfig(config: AppConfig): void {
  if (!isConfigPersisted()) return;
  writeFileSync(getConfigPath(), JSON.stringify(toFile(config), null, 2), 'utf-8');
}

/** Creates ~/.awsvisualizer from the current (in-memory) settings. */
export function enableConfigPersistence(): void {
  writeFileSync(getConfigPath(), JSON.stringify(toFile(loadConfig()), null, 2), 'utf-8');
}

function freshDefaults(): AppConfig {
  return JSON.parse(JSON.stringify(DEFAULT_CONFIG));
}

/** Older files had a single `aws.sso` block instead of `aws.platforms`. */
function readPlatforms(aws: any): SsoPlatform[] {
  if (Array.isArray(aws?.platforms)) {
    return aws.platforms
      .filter((p: any) => p && typeof p.id === 'string' && typeof p.startUrl === 'string' && typeof p.region === 'string')
      .map((p: any) => ({ id: p.id, name: typeof p.name === 'string' && p.name ? p.name : p.id, startUrl: p.startUrl, region: p.region }));
  }
  if (aws?.sso?.startUrl && aws?.sso?.sessionName) {
    return [{ id: aws.sso.sessionName, name: aws.sso.sessionName, startUrl: aws.sso.startUrl, region: aws.sso.region || 'eu-west-1' }];
  }
  return [];
}

function readPackageRecords(raw: any): PackageRecords {
  const obj = (x: unknown) => (x && typeof x === 'object' && !Array.isArray(x) ? (x as Record<string, any>) : {});
  return {
    sdkVersion: typeof raw?.sdkVersion === 'string' ? raw.sdkVersion : '',
    modulesDir: typeof raw?.modulesDir === 'string' ? raw.modulesDir : '',
    installed: obj(raw?.installed),
    failures: obj(raw?.failures),
  };
}

/** Older files only had the two terminal / Kiro CLI switches. */
function readDevTools(parsed: any): DevToolsConfig {
  const raw = parsed.devTools;
  if (raw && Array.isArray(raw.enabled)) {
    return {
      enabled: raw.enabled.filter((id: unknown) => typeof id === 'string'),
      custom: Array.isArray(raw.custom)
        ? raw.custom
            .filter((t: any) => t && typeof t.id === 'string' && typeof t.name === 'string' && typeof t.command === 'string')
            .map((t: any) => ({ id: t.id, name: t.name, command: t.command, icon: typeof t.icon === 'string' && t.icon ? t.icon : 'terminal' }))
        : [],
    };
  }
  const enabled: string[] = [];
  if (parsed.terminalPanelEnabled === true) enabled.push('terminal');
  if (parsed.kiroCliPanelEnabled === true) enabled.push('kiro-cli');
  return { enabled, custom: [] };
}

export function saveDevTools(devTools: DevToolsConfig): void {
  const config = loadConfig();
  config.devTools = devTools;
  config.terminalPanelEnabled = devTools.enabled.includes('terminal');
  config.kiroCliPanelEnabled = devTools.enabled.includes('kiro-cli');
  writeConfig(config);
}

export function loadConfig(): AppConfig {
  if (cachedConfig) return cachedConfig;

  const path = getConfigPath();
  if (!existsSync(path)) {
    cachedConfig = freshDefaults();
    return cachedConfig;
  }

  try {
    const parsed = JSON.parse(readFileSync(path, 'utf-8'));
    // New layout first, then the old top-level keys.
    const general = parsed.display?.general ?? parsed;
    const codeCommitDisplay = parsed.display?.codeCommit ?? parsed;
    cachedConfig = {
      app: { ...DEFAULT_CONFIG.app, ...parsed.app, version: APP_VERSION },
      aws: {
        platforms: readPlatforms(parsed.aws),
        defaultRegion: parsed.aws?.defaultRegion || DEFAULT_CONFIG.aws.defaultRegion,
      },
      selectedServices: Array.isArray(parsed.selectedServices) ? parsed.selectedServices : [],
      favoriteServices: Array.isArray(parsed.favoriteServices) ? parsed.favoriteServices : [],
      maxTabs: typeof parsed.maxTabs === 'number' ? parsed.maxTabs : DEFAULT_CONFIG.maxTabs,
      terminalPanelEnabled: typeof parsed.terminalPanelEnabled === 'boolean' ? parsed.terminalPanelEnabled : DEFAULT_CONFIG.terminalPanelEnabled,
      kiroCliPanelEnabled: typeof parsed.kiroCliPanelEnabled === 'boolean' ? parsed.kiroCliPanelEnabled : DEFAULT_CONFIG.kiroCliPanelEnabled,
      devTools: readDevTools(parsed),
      workspaces: parsed.workspaces && typeof parsed.workspaces === 'object' ? parsed.workspaces : {},
      dynamoDbAutoColumnWidth: typeof parsed.dynamoDbAutoColumnWidth === 'boolean' ? parsed.dynamoDbAutoColumnWidth : DEFAULT_CONFIG.dynamoDbAutoColumnWidth,
      dynamoDbItemView: DYNAMODB_ITEM_VIEWS.includes(parsed.dynamoDbItemView) ? parsed.dynamoDbItemView : DEFAULT_CONFIG.dynamoDbItemView,
      codeTheme: CODE_THEMES.includes(general.codeTheme) ? general.codeTheme : DEFAULT_CONFIG.codeTheme,
      layoutMode: LAYOUT_MODES.includes(general.layoutMode) ? general.layoutMode : DEFAULT_CONFIG.layoutMode,
      wordWrap: typeof general.wordWrap === 'boolean' ? general.wordWrap : DEFAULT_CONFIG.wordWrap,
      fileIconTheme: FILE_ICON_THEMES.includes(general.fileIconTheme) ? general.fileIconTheme : DEFAULT_CONFIG.fileIconTheme,
      historyLayout: HISTORY_LAYOUTS.includes(codeCommitDisplay.historyLayout) ? codeCommitDisplay.historyLayout : DEFAULT_CONFIG.historyLayout,
      dashboard: readDashboardPrefs(parsed.display?.dashboard),
      dashboardCache: parsed.dashboardCache && typeof parsed.dashboardCache === 'object' && !Array.isArray(parsed.dashboardCache) ? parsed.dashboardCache : {},
      buttonColors: { ...DEFAULT_BUTTON_COLORS, ...parsed.buttonColors },
      defaultIdeBundleIdentifier: typeof parsed.defaultIdeBundleIdentifier === 'string' ? parsed.defaultIdeBundleIdentifier : DEFAULT_CONFIG.defaultIdeBundleIdentifier,
      userDefaultServices: Array.isArray(parsed.userDefaultServices) ? parsed.userDefaultServices.filter((x: unknown) => typeof x === 'string') : [],
      runtime: parsed.runtime && typeof parsed.runtime === 'object' ? parsed.runtime : {},
      packages: readPackageRecords(parsed.packages),
    };
    // One-time move of an old file to the grouped layout.
    if (!parsed.display || LEGACY_DISPLAY_KEYS.some((k) => k in parsed)) writeConfig(cachedConfig);
  } catch {
    cachedConfig = freshDefaults();
  }

  return cachedConfig;
}

export function getDashboardCache(keys: string[]): Record<string, DashboardCacheEntry> {
  const cache = loadConfig().dashboardCache;
  return Object.fromEntries(keys.filter((k) => cache[k]).map((k) => [k, cache[k]]));
}

/** Saves one answer; old and surplus entries are dropped so the file stays small. */
export function saveDashboardCache(key: string, data: unknown): DashboardCacheEntry {
  const config = loadConfig();
  const entry = { fetchedAt: new Date().toISOString(), data };
  const now = Date.now();
  const kept = Object.entries({ ...config.dashboardCache, [key]: entry })
    .filter(([, e]) => now - Date.parse(e.fetchedAt) < CACHE_MAX_AGE_MS)
    .sort(([, a], [, b]) => Date.parse(b.fetchedAt) - Date.parse(a.fetchedAt))
    .slice(0, CACHE_MAX_ENTRIES);
  config.dashboardCache = Object.fromEntries(kept);
  writeConfig(config);
  cachedConfig = config;
  return entry;
}

export function saveDashboardPrefs(prefs: DashboardPrefs): void {
  const config = loadConfig();
  config.dashboard = prefs;
  writeConfig(config);
  cachedConfig = config;
}

export function getSelectedServices(): string[] {
  return loadConfig().selectedServices;
}

export function saveSelectedServices(services: string[]): void {
  const config = loadConfig();
  config.selectedServices = services;
  writeConfig(config);
  cachedConfig = config;
}

export function getFavoriteServices(): string[] {
  return loadConfig().favoriteServices;
}

export function saveFavoriteServices(services: string[]): void {
  const config = loadConfig();
  config.favoriteServices = services;
  writeConfig(config);
  cachedConfig = config;
}

export function saveMaxTabs(maxTabs: number): void {
  const config = loadConfig();
  config.maxTabs = maxTabs;
  writeConfig(config);
  cachedConfig = config;
}

export function saveTerminalPanelEnabled(enabled: boolean): void {
  const config = loadConfig();
  config.terminalPanelEnabled = enabled;
  writeConfig(config);
  cachedConfig = config;
}

export function saveKiroCliPanelEnabled(enabled: boolean): void {
  const config = loadConfig();
  config.kiroCliPanelEnabled = enabled;
  writeConfig(config);
  cachedConfig = config;
}

export function saveDynamoDbAutoColumnWidth(enabled: boolean): void {
  const config = loadConfig();
  config.dynamoDbAutoColumnWidth = enabled;
  writeConfig(config);
  cachedConfig = config;
}

export function saveCodeTheme(theme: CodeTheme): void {
  const config = loadConfig();
  config.codeTheme = theme;
  writeConfig(config);
  cachedConfig = config;
}

export function saveViewPreferences(update: { layoutMode?: LayoutMode; wordWrap?: boolean; fileIconTheme?: FileIconTheme; historyLayout?: HistoryLayout }): void {
  const config = loadConfig();
  if (update.historyLayout !== undefined) config.historyLayout = update.historyLayout;
  if (update.layoutMode !== undefined) config.layoutMode = update.layoutMode;
  if (update.fileIconTheme !== undefined) config.fileIconTheme = update.fileIconTheme;
  if (update.wordWrap !== undefined) config.wordWrap = update.wordWrap;
  writeConfig(config);
  cachedConfig = config;
}

export function saveDynamoDbItemView(view: DynamoDbItemView): void {
  const config = loadConfig();
  config.dynamoDbItemView = view;
  writeConfig(config);
  cachedConfig = config;
}

export function saveButtonColors(update: Partial<ButtonColorConfig>): void {
  const config = loadConfig();
  config.buttonColors = { ...config.buttonColors, ...update };
  writeConfig(config);
  cachedConfig = config;
}

export function saveDefaultIde(bundleIdentifier: string): void {
  const config = loadConfig();
  config.defaultIdeBundleIdentifier = bundleIdentifier;
  writeConfig(config);
  cachedConfig = config;
}

export function getUserDefaultServices(): string[] {
  return loadConfig().userDefaultServices;
}

export function saveUserDefaultServices(services: string[]): void {
  const config = loadConfig();
  config.userDefaultServices = services;
  writeConfig(config);
  cachedConfig = config;
}

/** Replaces the detected node / npm; the user's preferred node is kept. */
export function saveRuntimeInfo(runtime: RuntimeInfo): void {
  const config = loadConfig();
  config.runtime = { ...runtime, preferredNodeBin: runtime.preferredNodeBin ?? config.runtime.preferredNodeBin };
  writeConfig(config);
  cachedConfig = config;
}

export function savePreferredNodeBin(bin: string | undefined): void {
  const config = loadConfig();
  config.runtime = { ...config.runtime, preferredNodeBin: bin };
  if (!bin) delete config.runtime.preferredNodeBin;
  writeConfig(config);
  cachedConfig = config;
}

/** Applies `update` to the package records and writes them. */
export function updatePackageRecords(update: (records: PackageRecords) => void): PackageRecords {
  const config = loadConfig();
  update(config.packages);
  writeConfig(config);
  cachedConfig = config;
  return config.packages;
}

export function clearConfigCache(): void {
  cachedConfig = null;
}

export function getWorkspacePath(repositoryName: string): string | undefined {
  return loadConfig().workspaces[repositoryName];
}

/** Every repo -> local path association currently saved, regardless of
 * whether that folder still exists on disk - used for the global Settings
 * list ("which projects have a workspace") and app-startup preloading. */
export function listWorkspaces(): { repositoryName: string; localPath: string }[] {
  return Object.entries(loadConfig().workspaces).map(([repositoryName, localPath]) => ({ repositoryName, localPath }));
}

export function saveWorkspacePath(repositoryName: string, path: string): void {
  const config = loadConfig();
  config.workspaces[repositoryName] = path;
  writeConfig(config);
  cachedConfig = config;
}

export function removeWorkspacePath(repositoryName: string): void {
  const config = loadConfig();
  delete config.workspaces[repositoryName];
  writeConfig(config);
  cachedConfig = config;
}

export function updateDefaultRegion(defaultRegion: string): AppConfig {
  const config = loadConfig();
  config.aws.defaultRegion = defaultRegion;
  writeConfig(config);
  return config;
}

export function getPlatforms(): SsoPlatform[] {
  return loadConfig().aws.platforms;
}

/** Adds or replaces (same id) a platform. */
export function savePlatform(platform: SsoPlatform): SsoPlatform[] {
  const config = loadConfig();
  const others = config.aws.platforms.filter((p) => p.id !== platform.id);
  config.aws.platforms = [...others, platform];
  writeConfig(config);
  return config.aws.platforms;
}

export function removePlatform(id: string): SsoPlatform[] {
  const config = loadConfig();
  config.aws.platforms = config.aws.platforms.filter((p) => p.id !== id);
  writeConfig(config);
  return config.aws.platforms;
}
