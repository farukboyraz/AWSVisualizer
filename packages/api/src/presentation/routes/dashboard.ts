import { Router, type Request, type Response } from 'express';
import { loadConfig, getDashboardCache, saveDashboardCache, type DashboardCard } from '../../config/index.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';
import { checkProfile, checkRegion, ValidationError } from '../middleware/validate-input.js';
import { describeTemplate, findTemplate, optionSource, templatesFor, validateParams } from '../../infrastructure/dashboard-cards/registry.js';
import { CardInputError, type CardTemplate } from '../../infrastructure/dashboard-cards/types.js';

/**
 * Saved dashboard data and the user's cards.
 *
 * Cache keys (also written by /services/counts?source=dashboard and /cost):
 *   counts|<profile>|<region>
 *   cost|<profile>|<view>|<months>|<month>
 *   card|<id>|<profile>|<region>   last value of a metric card
 *   run|<id>|<profile>|<region>    last result of an action card
 * (an "all profiles" card has one entry per profile / region it ran in)
 *
 * Checks before any AWS call: the template exists for the service, params
 * pass the template's rules, profile / region are valid; value / run only
 * for cards saved in ~/.awsvisualizer while "My cards" is on; an action
 * only with `confirm: true`. Options and preview are read-only.
 */
const router = Router();

export const countsKey = (profile: string, region: string) => `counts|${profile}|${region}`;
export const costKey = (profile: string, view: string, months: number, month: string) => `cost|${profile}|${view}|${view === 'monthly' ? months : ''}|${view === 'month' ? month : ''}`;
export const cardKey = (id: string, profile: string, region: string) => `card|${id}|${profile}|${region}`;
export const runKey = (id: string, profile: string, region: string) => `run|${id}|${profile}|${region}`;

/**
 * The profile / region a card runs with: the profile the app is using
 * (`?profile=`) - which must be one of the card's profiles unless it is on
 * every profile - and the card's region, or the one in use (`?region=`)
 * when it has none. Both are checked like on every other route.
 */
function contextOf(card: DashboardCard, req: Request): { profile: string; region: string } {
  const profile = String(req.query.profile || '');
  const region = card.region || String(req.query.region || '');
  checkProfile(profile);
  checkRegion(region);
  if (!profile || !region) throw new CardInputError({ en: 'Choose a profile and a region', tr: 'Bir profil ve bölge seç' });
  if (!card.allProfiles && !card.profiles.includes(profile)) {
    throw new CardInputError({ en: `This card isn't on ${profile}'s dashboard`, tr: `Bu kart ${profile} profilinin dashboard'unda değil` });
  }
  return { profile, region };
}

/** Card errors: input problems as a bilingual 400, AWS errors as usual. */
function fail(res: Response, err: unknown) {
  if (err instanceof CardInputError) {
    res.status(400).json({ error: err.text.en, type: 'CardInput', text: err.text, status: 400 });
    return;
  }
  if (err instanceof ValidationError) {
    res.status(400).json(err.toJSON());
    return;
  }
  const error = handleApiError(err);
  res.status(error.status).json(error);
}

function templateOrFail(res: Response, service: string, id: string): CardTemplate | undefined {
  const tpl = findTemplate(service, id);
  if (!tpl) res.status(404).json({ error: `No card type ${id} for ${service}` });
  return tpl;
}

/** A saved card while "My cards" is on - or a reply saying why not. */
function savedCard(res: Response, id: string): DashboardCard | undefined {
  const prefs = loadConfig().dashboard;
  if (!prefs.widgets.customCards) {
    res.status(409).json({ error: 'Custom cards are turned off on the dashboard', type: 'Disabled' });
    return undefined;
  }
  const card = prefs.cards.find((c) => c.id === id);
  if (!card) res.status(404).json({ error: `No saved card with id ${id}` });
  return card;
}

// GET /api/dashboard/cache?keys=a,b,c - what the dashboard last fetched; never calls AWS.
router.get('/dashboard/cache', (req, res) => {
  const keys = String(req.query.keys || '')
    .split(',')
    .map((k) => k.trim())
    .filter(Boolean)
    .slice(0, 100);
  res.json({ entries: getDashboardCache(keys) });
});

// GET /api/dashboard/card-templates?service=s3 - the card types of a service (no AWS call).
router.get('/dashboard/card-templates', (req, res) => {
  const service = String(req.query.service || '');
  if (!/^[a-z0-9-]{1,64}$/.test(service)) {
    res.status(400).json({ error: 'service is required' });
    return;
  }
  res.json({ templates: templatesFor(service).map(describeTemplate) });
});

// GET /api/dashboard/card-options?service=&source=&profile=&region=&p.<param>=… - a dropdown's choices (read-only).
router.get('/dashboard/card-options', async (req, res) => {
  const service = String(req.query.service || '');
  const source = optionSource(service, String(req.query.source || ''));
  if (!source) {
    res.status(404).json({ error: `Unknown option source ${req.query.source}` });
    return;
  }
  const deps: Record<string, string> = {};
  for (const [k, v] of Object.entries(req.query)) if (k.startsWith('p.') && typeof v === 'string') deps[k.slice(2, 66)] = v.slice(0, 2048);
  try {
    res.json({ items: (await source({ profile: String(req.query.profile || ''), region: String(req.query.region || ''), deps })).slice(0, 2000) });
  } catch (err) {
    fail(res, err);
  }
});

// POST /api/dashboard/card-preview { service, template, profile, region, params } - the data the card would work on (read-only).
router.post('/dashboard/card-preview', async (req, res) => {
  const { service, template, profile, region, params } = req.body || {};
  const tpl = templateOrFail(res, String(service || ''), String(template || ''));
  if (!tpl) return;
  if (!tpl.preview) {
    res.status(400).json({ error: 'This card type has no preview' });
    return;
  }
  try {
    checkProfile(String(profile || ''));
    checkRegion(String(region || ''));
    const clean = validateParams(tpl, params, 'card');
    res.json(await tpl.preview({ profile, region, params: clean }));
  } catch (err) {
    fail(res, err);
  }
});

// POST /api/dashboard/cards/:id/value - runs one saved metric card and saves the answer.
router.post('/dashboard/cards/:id/value', async (req, res) => {
  const card = savedCard(res, req.params.id);
  if (!card) return;
  const tpl = templateOrFail(res, card.service, card.template);
  if (!tpl) return;
  if (tpl.kind !== 'metric' || !tpl.value) {
    res.status(400).json({ error: 'This card has no value to fetch' });
    return;
  }
  try {
    const { profile, region } = contextOf(card, req);
    const params = validateParams(tpl, card.params, 'card');
    res.json(saveDashboardCache(cardKey(card.id, profile, region), await tpl.value({ profile, region, params })));
  } catch (err) {
    fail(res, err);
  }
});

// POST /api/dashboard/cards/:id/run { confirm: true, params } - runs one saved action card; `params` are the run-time inputs.
router.post('/dashboard/cards/:id/run', async (req, res) => {
  const card = savedCard(res, req.params.id);
  if (!card) return;
  const tpl = templateOrFail(res, card.service, card.template);
  if (!tpl) return;
  if (tpl.kind !== 'action' || !tpl.run) {
    res.status(400).json({ error: 'This card is not an action' });
    return;
  }
  if (req.body?.confirm !== true) {
    res.status(400).json({ error: 'Actions run only with confirm: true', type: 'ConfirmRequired' });
    return;
  }
  try {
    const { profile, region } = contextOf(card, req);
    // Saved params, with this run's inputs on top (run-scope params only).
    const runKeys = new Set(tpl.params.filter((p) => p.scope === 'run').map((p) => p.key));
    const inputs = Object.fromEntries(Object.entries(req.body?.params || {}).filter(([k]) => runKeys.has(k)));
    const params = validateParams(tpl, { ...card.params, ...inputs }, 'run');
    const result = await tpl.run({ profile, region, params });
    res.json(saveDashboardCache(runKey(card.id, profile, region), result));
  } catch (err) {
    fail(res, err);
  }
});

// POST /api/dashboard/cards/:id/link - where a saved link card goes (no AWS call).
router.post('/dashboard/cards/:id/link', (req, res) => {
  const card = loadConfig().dashboard.cards.find((c) => c.id === req.params.id);
  if (!card) {
    res.status(404).json({ error: `No saved card with id ${req.params.id}` });
    return;
  }
  const tpl = templateOrFail(res, card.service, card.template);
  if (!tpl) return;
  if (!tpl.link) {
    res.status(400).json({ error: 'This card has nothing to open' });
    return;
  }
  try {
    res.json(tpl.link({ profile: card.profile, region: card.region, params: validateParams(tpl, card.params, 'card') }));
  } catch (err) {
    fail(res, err);
  }
});

export default router;
