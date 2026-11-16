import { Router } from 'express';
import { loadConfig, updateDefaultRegion, saveMaxTabs, saveTerminalPanelEnabled, saveKiroCliPanelEnabled, saveDynamoDbAutoColumnWidth, saveDynamoDbItemView, DYNAMODB_ITEM_VIEWS, saveCodeTheme, CODE_THEMES, saveViewPreferences, LAYOUT_MODES, FILE_ICON_THEMES, HISTORY_LAYOUTS, saveButtonColors, saveDefaultIde, readConfigFileRaw, saveDevTools, readDashboardPrefs, saveDashboardPrefs, DASHBOARD_WIDGETS, COST_VIEWS, COST_MONTH_RANGES, DASHBOARD_COLOR_STYLES, DASHBOARD_SERVICE_LAYOUTS, REFRESH_MINUTES_MAX, MAX_CARDS, readDashboardCard } from '../../config/index.js';

import { findTemplate, validateParams } from '../../infrastructure/dashboard-cards/registry.js';

const router = Router();

// GET /api/config
router.get('/config', async (_req, res) => {
  try {
    const config = loadConfig();
    res.json(config);
  } catch (err: any) {
    res.status(500).json({
      error: 'Failed to load config',
      message: err.message,
    });
  }
});

// PUT /api/config/dynamodb-auto-column-width - persist whether DynamoDB's
// grid auto-sizes columns to fit content vs. splitting width evenly
router.put('/config/dynamodb-auto-column-width', async (req, res) => {
  try {
    const { enabled } = req.body || {};
    if (typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'enabled must be a boolean' });
      return;
    }
    saveDynamoDbAutoColumnWidth(enabled);
    res.json(loadConfig());
  } catch (err: any) {
    res.status(500).json({
      error: 'Failed to update config',
      message: err.message,
    });
  }
});

// PUT /api/config/dynamodb-item-view - persist the default view of
// DynamoDB's item popup ("json" | "dynamodb-json" | "form")
router.put('/config/dynamodb-item-view', async (req, res) => {
  try {
    const { view } = req.body || {};
    if (!DYNAMODB_ITEM_VIEWS.includes(view)) {
      res.status(400).json({ error: `view must be one of ${DYNAMODB_ITEM_VIEWS.join(', ')}` });
      return;
    }
    saveDynamoDbItemView(view);
    res.json(loadConfig());
  } catch (err: any) {
    res.status(500).json({
      error: 'Failed to update config',
      message: err.message,
    });
  }
});

// PUT /api/config/code-theme - syntax-color theme of the code viewers
router.put('/config/code-theme', async (req, res) => {
  try {
    const { theme } = req.body || {};
    if (!CODE_THEMES.includes(theme)) {
      res.status(400).json({ error: `theme must be one of ${CODE_THEMES.join(', ')}` });
      return;
    }
    saveCodeTheme(theme);
    res.json(loadConfig());
  } catch (err: any) {
    res.status(500).json({ error: 'Failed to update config', message: err.message });
  }
});

// PUT /api/config/view-preferences - layout mode (side by side / single
// page) and the default word wrap of text viewers; either key may be sent
router.put('/config/view-preferences', async (req, res) => {
  try {
    const { layoutMode, wordWrap, fileIconTheme, historyLayout } = req.body || {};
    if (historyLayout !== undefined && !HISTORY_LAYOUTS.includes(historyLayout)) {
      res.status(400).json({ error: `historyLayout must be one of ${HISTORY_LAYOUTS.join(', ')}` });
      return;
    }
    if (fileIconTheme !== undefined && !FILE_ICON_THEMES.includes(fileIconTheme)) {
      res.status(400).json({ error: `fileIconTheme must be one of ${FILE_ICON_THEMES.join(', ')}` });
      return;
    }
    if (layoutMode !== undefined && !LAYOUT_MODES.includes(layoutMode)) {
      res.status(400).json({ error: `layoutMode must be one of ${LAYOUT_MODES.join(', ')}` });
      return;
    }
    if (wordWrap !== undefined && typeof wordWrap !== 'boolean') {
      res.status(400).json({ error: 'wordWrap must be a boolean' });
      return;
    }
    saveViewPreferences({ layoutMode, wordWrap, fileIconTheme, historyLayout });
    res.json(loadConfig());
  } catch (err: any) {
    res.status(500).json({ error: 'Failed to update config', message: err.message });
  }
});

// PUT /api/config/dashboard - Settings › Display › Dashboard. The whole
// object is sent; anything malformed is rejected instead of half-saved.
router.put('/config/dashboard', async (req, res) => {
  try {
    const body = req.body || {};
    const problems: string[] = [];
    for (const [key, value] of Object.entries(body.widgets || {})) {
      if (!(DASHBOARD_WIDGETS as readonly string[]).includes(key)) problems.push(`unknown widget ${key}`);
      else if (typeof value !== 'boolean') problems.push(`widgets.${key} must be a boolean`);
    }
    if (body.excludedServices !== undefined && (!Array.isArray(body.excludedServices) || body.excludedServices.some((x: unknown) => typeof x !== 'string'))) problems.push('excludedServices must be a list of service ids');
    if (body.cost?.view !== undefined && !(COST_VIEWS as readonly string[]).includes(body.cost.view)) problems.push(`cost.view must be one of ${COST_VIEWS.join(', ')}`);
    if (body.cost?.months !== undefined && !(COST_MONTH_RANGES as readonly number[]).includes(body.cost.months)) problems.push(`cost.months must be one of ${COST_MONTH_RANGES.join(', ')}`);
    if (body.cost?.chartStyle !== undefined && !['bar', 'line', 'points'].includes(body.cost.chartStyle)) problems.push('cost.chartStyle must be one of bar, line, points');
    if (body.cost?.showEstimate !== undefined && typeof body.cost.showEstimate !== 'boolean') problems.push('cost.showEstimate must be a boolean');
    if (body.colorStyle !== undefined && !(DASHBOARD_COLOR_STYLES as readonly string[]).includes(body.colorStyle)) problems.push(`colorStyle must be one of ${DASHBOARD_COLOR_STYLES.join(', ')}`);
    if (body.hideEmptyServices !== undefined && typeof body.hideEmptyServices !== 'boolean') problems.push('hideEmptyServices must be a boolean');
    if (body.servicesLayout !== undefined && !(DASHBOARD_SERVICE_LAYOUTS as readonly string[]).includes(body.servicesLayout)) problems.push(`servicesLayout must be one of ${DASHBOARD_SERVICE_LAYOUTS.join(', ')}`);
    if (body.refreshMinutes !== undefined && !(Number.isInteger(body.refreshMinutes) && body.refreshMinutes >= 0 && body.refreshMinutes <= REFRESH_MINUTES_MAX)) problems.push(`refreshMinutes must be a whole number from 0 to ${REFRESH_MINUTES_MAX}`);
    if (body.refreshOnOpen !== undefined && typeof body.refreshOnOpen !== 'boolean') problems.push('refreshOnOpen must be a boolean');
    if (body.cards !== undefined) {
      if (!Array.isArray(body.cards) || body.cards.length > MAX_CARDS) problems.push(`cards must be a list of at most ${MAX_CARDS} cards`);
      else
        body.cards.forEach((c: unknown, i: number) => {
          const card = readDashboardCard(c);
          const tpl = card && findTemplate(card.service, card.template);
          if (!card || !tpl) {
            problems.push(`cards[${i}] is not a valid card`);
            return;
          }
          try {
            validateParams(tpl, card.params, 'card');
          } catch (err) {
            problems.push(`cards[${i}]: ${(err as Error).message}`);
          }
        });
    }
    if (problems.length) {
      res.status(400).json({ error: problems.join('; ') });
      return;
    }
    const prefs = readDashboardPrefs(body);
    // Kind and icon always come from the template, never from the client.
    prefs.cards = prefs.cards.map((c) => {
      const tpl = findTemplate(c.service, c.template)!;
      return { ...c, kind: tpl.kind, icon: tpl.icon };
    });
    saveDashboardPrefs(prefs);
    res.json(loadConfig());
  } catch (err: any) {
    res.status(500).json({ error: 'Failed to update config', message: err.message });
  }
});

// PUT /api/config/button-colors - persist Settings' per-kind AppButton
// background colors (any subset of keys; merged into the stored config)
router.put('/config/button-colors', async (req, res) => {
  try {
    saveButtonColors(req.body || {});
    res.json(loadConfig());
  } catch (err: any) {
    res.status(500).json({
      error: 'Failed to update config',
      message: err.message,
    });
  }
});

// GET /api/config/raw - the literal ~/.awsvisualizer file contents, for the
// Settings "view raw config" popup.
router.get('/config/raw', async (_req, res) => {
  try {
    res.json({ text: readConfigFileRaw() });
  } catch (err: any) {
    res.status(500).json({
      error: 'Failed to read config file',
      message: err.message,
    });
  }
});

router.put('/config/dev-tools', async (req, res) => {
  const { enabled, custom } = req.body || {};
  const validCustom =
    Array.isArray(custom) &&
    custom.every((t: any) => t && typeof t.id === 'string' && /^custom-[A-Za-z0-9-]{1,40}$/.test(t.id) && typeof t.name === 'string' && t.name.trim() && typeof t.command === 'string' && t.command.trim() && typeof t.icon === 'string');
  if (!Array.isArray(enabled) || !enabled.every((id: unknown) => typeof id === 'string') || !validCustom) {
    res.status(400).json({ error: 'enabled (string[]) and custom ({id: "custom-...", name, command, icon}[]) are required' });
    return;
  }
  saveDevTools({ enabled, custom: custom.map((t: any) => ({ id: t.id, name: t.name.trim(), command: t.command.trim(), icon: t.icon || 'terminal' })) });
  res.json({ ok: true });
});

// PUT /api/config/aws - default region (platforms are managed under /api/setup)
router.put('/config/aws', async (req, res) => {
  try {
    const { defaultRegion } = req.body || {};
    if (typeof defaultRegion !== 'string' || !defaultRegion) {
      res.status(400).json({ error: 'defaultRegion is required' });
      return;
    }
    res.json(updateDefaultRegion(defaultRegion));
  } catch (err: any) {
    res.status(500).json({
      error: 'Failed to update config',
      message: err.message,
    });
  }
});

// PUT /api/config/max-tabs - persist the "number of screens" setting in ~/.awsvisualizer
router.put('/config/max-tabs', async (req, res) => {
  try {
    const { maxTabs } = req.body || {};
    if (typeof maxTabs !== 'number' || maxTabs < 1) {
      res.status(400).json({ error: 'maxTabs must be a positive number' });
      return;
    }
    saveMaxTabs(maxTabs);
    res.json(loadConfig());
  } catch (err: any) {
    res.status(500).json({
      error: 'Failed to update config',
      message: err.message,
    });
  }
});

// PUT /api/config/terminal-panel - persist whether the Terminal tab is shown
router.put('/config/terminal-panel', async (req, res) => {
  try {
    const { enabled } = req.body || {};
    if (typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'enabled must be a boolean' });
      return;
    }
    saveTerminalPanelEnabled(enabled);
    res.json(loadConfig());
  } catch (err: any) {
    res.status(500).json({
      error: 'Failed to update config',
      message: err.message,
    });
  }
});

// PUT /api/config/kiro-cli-panel - persist whether the Kiro CLI tab is shown
router.put('/config/kiro-cli-panel', async (req, res) => {
  try {
    const { enabled } = req.body || {};
    if (typeof enabled !== 'boolean') {
      res.status(400).json({ error: 'enabled must be a boolean' });
      return;
    }
    saveKiroCliPanelEnabled(enabled);
    res.json(loadConfig());
  } catch (err: any) {
    res.status(500).json({
      error: 'Failed to update config',
      message: err.message,
    });
  }
});

// PUT /api/config/default-ide - persist which IDE the "Open in <IDE>"
// control (OpenInIDEControl on the Swift side) preselects
router.put('/config/default-ide', async (req, res) => {
  try {
    const { bundleIdentifier } = req.body || {};
    if (typeof bundleIdentifier !== 'string') {
      res.status(400).json({ error: 'bundleIdentifier must be a string' });
      return;
    }
    saveDefaultIde(bundleIdentifier);
    res.json(loadConfig());
  } catch (err: any) {
    res.status(500).json({
      error: 'Failed to update config',
      message: err.message,
    });
  }
});

export default router;
