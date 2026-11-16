import { Router } from 'express';
import { getCost, type CostQuery } from '../../infrastructure/aws/cost-explorer.js';
import { withAuthGuard } from '../middleware/auth-guard.js';
import { loadConfig, COST_VIEWS, COST_WIDGETS, COST_MONTH_RANGES, saveDashboardCache } from '../../config/index.js';
import { costKey } from './dashboard.js';

const router = Router();

/** Cost Explorer bills every request; the same question within this window is answered from memory. */
const CACHE_MS = 30 * 60_000;
const cache = new Map<string, { at: number; data: unknown }>();

// GET /api/cost?profile=&view=daily|monthly|month&months=3|6|12&month=YYYY-MM&fresh=1
router.get('/cost', async (req, res) => {
  const profile = req.query.profile as string;
  if (!profile) {
    res.status(400).json({ error: 'profile parameter is required' });
    return;
  }

  // The dashboard's cost widgets are all off: never call Cost Explorer.
  const prefs = loadConfig().dashboard;
  if (!COST_WIDGETS.some((w) => prefs.widgets[w])) {
    res.json({ authorized: true, data: null, disabled: true });
    return;
  }

  const view = (req.query.view as string) || prefs.cost.view;
  if (!(COST_VIEWS as readonly string[]).includes(view)) {
    res.status(400).json({ error: `view must be one of ${COST_VIEWS.join(', ')}` });
    return;
  }
  const months = req.query.months ? Number(req.query.months) : prefs.cost.months;
  if (!(COST_MONTH_RANGES as readonly number[]).includes(months)) {
    res.status(400).json({ error: `months must be one of ${COST_MONTH_RANGES.join(', ')}` });
    return;
  }
  const month = req.query.month as string | undefined;
  if (month !== undefined) {
    const now = new Date();
    const current = now.getUTCFullYear() * 12 + now.getUTCMonth();
    const match = /^(\d{4})-(\d{2})$/.exec(month);
    const asked = match ? Number(match[1]) * 12 + Number(match[2]) - 1 : NaN;
    // Cost Explorer keeps 13 months plus the current one.
    if (!match || Number(match[2]) < 1 || Number(match[2]) > 12 || asked > current || current - asked > 13) {
      res.status(400).json({ error: 'month must be YYYY-MM within the last 13 months' });
      return;
    }
  }

  const query: CostQuery = { view: view as CostQuery['view'], months, month };
  const key = JSON.stringify([profile, query.view, query.view === 'monthly' ? months : '', query.view === 'month' ? month ?? '' : '']);
  const hit = cache.get(key);
  if (hit && req.query.fresh !== '1' && Date.now() - hit.at < CACHE_MS) {
    res.json({ authorized: true, data: hit.data, cached: true });
    return;
  }

  await withAuthGuard(res, async () => {
    const data = await getCost(profile, query);
    cache.set(key, { at: Date.now(), data });
    // Saved for the next time the dashboard opens (no new Cost Explorer call).
    saveDashboardCache(costKey(profile, query.view, months, month ?? currentMonth()), data);
    return data;
  });
});

function currentMonth(): string {
  const now = new Date();
  return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
}

export default router;
