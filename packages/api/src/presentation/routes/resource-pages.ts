import { Router, type Request, type Response } from 'express';
import { PAGE_SERVICES } from '../../infrastructure/aws/page-services.js';
import type { PageServiceAdapter } from '../../infrastructure/aws/page-adapter.js';
import { profileRegion, respond, rejectMissing } from '../middleware/respond.js';
import { validateFields } from '../../infrastructure/form-fields.js';
import { CardInputError } from '../../infrastructure/dashboard-cards/types.js';
import { httpError } from '../../infrastructure/aws/page-common.js';

/**
 * Shared routes for the services that use the ResourcePage
 * model: /pages/<service>/list, /detail, /action, /forms, /create, /options,
 * /tags, /tags/remove.
 */
const router = Router();

function adapterFor(req: Request, res: Response): PageServiceAdapter | undefined {
  const adapter = PAGE_SERVICES[req.params.service];
  if (!adapter) res.status(404).json({ error: `Unknown database service: ${req.params.service}` });
  return adapter;
}

router.get('/pages/:service/list', async (req, res) => {
  const adapter = adapterFor(req, res);
  if (!adapter) return;
  const { profile, region } = profileRegion(req);
  await respond(res, () => adapter.list(profile, region));
});

router.get('/pages/:service/detail', async (req, res) => {
  const adapter = adapterFor(req, res);
  if (!adapter) return;
  const { profile, region } = profileRegion(req);
  const id = req.query.id as string;
  if (rejectMissing(res, { id })) return;
  await respond(res, () => adapter.detail(profile, region, id));
});

/**
 * Runs an action the page currently offers. The page is read first: an
 * action that isn't offered in the resource's current state (Stop on a
 * stopped cluster) is refused, and form values are checked against the
 * action's own fields before any AWS call.
 */
router.post('/pages/:service/action', async (req, res) => {
  const adapter = adapterFor(req, res);
  if (!adapter) return;
  const { profile, region } = profileRegion(req);
  const { id, action, params } = req.body || {};
  if (rejectMissing(res, { id, action })) return;
  if (!adapter.action) {
    res.status(400).json({ error: `${req.params.service} has no actions` });
    return;
  }
  const run = adapter.action;
  await respond(res, async () => {
    const page = await adapter.detail(profile, region, id);
    const offered = page.actions.find((a) => a.id === action);
    if (!offered) throw new CardInputError({ en: `${action} isn't available for this resource right now`, tr: `${action} bu kaynak için şu an kullanılamıyor` });
    const values = validateFields(offered.form ?? [], params, 'run');
    await run(profile, region, id, action, values);
    return adapter.detail(profile, region, id);
  });
});

/** The service's list-level "New ..." forms. */
router.get('/pages/:service/forms', (req, res) => {
  const adapter = adapterFor(req, res);
  if (!adapter) return;
  res.json({ forms: adapter.create ? adapter.createForms ?? [] : [] });
});

router.post('/pages/:service/create', async (req, res) => {
  const adapter = adapterFor(req, res);
  if (!adapter) return;
  const { profile, region } = profileRegion(req);
  const { form, params } = req.body || {};
  if (rejectMissing(res, { form })) return;
  const spec = adapter.create ? adapter.createForms?.find((f) => f.id === form) : undefined;
  if (!spec || !adapter.create) {
    res.status(400).json({ error: `${req.params.service} has no form ${form}` });
    return;
  }
  const create = adapter.create;
  await respond(res, async () => {
    const values = validateFields(spec.form ?? [], params, 'run');
    const id = await create(profile, region, form, values);
    return { id: id ?? null };
  });
});

/** Dropdown choices for a form's combo field; `p.<key>` query params carry the fields it depends on. */
router.get('/pages/:service/options', async (req, res) => {
  const adapter = adapterFor(req, res);
  if (!adapter) return;
  const { profile, region } = profileRegion(req);
  const source = req.query.source as string;
  if (rejectMissing(res, { source })) return;
  const load = adapter.options?.[source];
  await respond(res, async () => {
    if (!load) throw httpError(`Unknown option source: ${source}`, 404);
    const deps: Record<string, string> = {};
    for (const [k, v] of Object.entries(req.query)) if (k.startsWith('p.') && typeof v === 'string') deps[k.slice(2)] = v;
    return { items: await load({ profile, region, deps }) };
  });
});

router.post('/pages/:service/tags', async (req, res) => {
  const adapter = adapterFor(req, res);
  if (!adapter) return;
  const { profile, region } = profileRegion(req);
  const { id, arn, key, value } = req.body || {};
  if (rejectMissing(res, { id, key })) return;
  if (!adapter.addTag) {
    res.status(400).json({ error: `${req.params.service} does not support tags` });
    return;
  }
  const add = adapter.addTag;
  await respond(res, async () => {
    await add(profile, region, id, arn ?? '', key, value ?? '');
    return adapter.detail(profile, region, id);
  });
});

router.post('/pages/:service/tags/remove', async (req, res) => {
  const adapter = adapterFor(req, res);
  if (!adapter) return;
  const { profile, region } = profileRegion(req);
  const { id, arn, key } = req.body || {};
  if (rejectMissing(res, { id, key })) return;
  if (!adapter.removeTag) {
    res.status(400).json({ error: `${req.params.service} does not support tags` });
    return;
  }
  const remove = adapter.removeTag;
  await respond(res, async () => {
    await remove(profile, region, id, arn ?? '', key);
    return adapter.detail(profile, region, id);
  });
});

export default router;
