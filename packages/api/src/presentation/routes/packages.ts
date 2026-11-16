import { Router } from 'express';
import { SERVICE_PACKAGES } from '../../domain/service-packages.js';
import { getUserDefaultServices, saveUserDefaultServices, savePreferredNodeBin, loadConfig, isConfigPersisted } from '../../config/index.js';
import { packagesStatus, startInstall, getJob, runningJob } from '../../infrastructure/packages/installer.js';

/**
 * Service SDK packages: status, step-by-step installs (polled), and the
 * user's default services picked on first sign-in.
 */
const router = Router();

// GET /api/packages/status
router.get('/packages/status', (_req, res) => {
  res.json(packagesStatus());
});

// POST /api/packages/install { services: string[] } -> the job to poll
router.post('/packages/install', (req, res) => {
  const services = req.body?.services;
  if (!Array.isArray(services) || !services.length || !services.every((s) => typeof s === 'string')) {
    res.status(400).json({ error: 'services must be a non-empty array of strings' });
    return;
  }
  const unknown = services.filter((s) => !SERVICE_PACKAGES[s]);
  if (unknown.length) {
    res.status(400).json({ error: `No packages known for: ${unknown.join(', ')}` });
    return;
  }
  const current = runningJob();
  if (current) {
    res.status(409).json({ error: 'Another install is still running', jobId: current.id });
    return;
  }
  res.json(startInstall(services));
});

// GET /api/packages/jobs/current -> the running job, if any
router.get('/packages/jobs/current', (_req, res) => {
  res.json({ job: runningJob() ?? null });
});

// GET /api/packages/jobs/:id
router.get('/packages/jobs/:id', (req, res) => {
  const job = getJob(req.params.id);
  if (!job) {
    res.status(404).json({ error: 'Unknown install job' });
    return;
  }
  res.json(job);
});

// GET /api/services/defaults
router.get('/services/defaults', (_req, res) => {
  res.json({ defaults: getUserDefaultServices() });
});

// POST /api/services/defaults { services: string[] }
router.post('/services/defaults', (req, res) => {
  const services = req.body?.services;
  if (!Array.isArray(services) || !services.every((s) => typeof s === 'string')) {
    res.status(400).json({ error: 'services must be an array of strings' });
    return;
  }
  saveUserDefaultServices(services);
  res.json({ defaults: services });
});

// GET /api/runtime/preference
router.get('/runtime/preference', (_req, res) => {
  res.json({ preferredNodeBin: loadConfig().runtime.preferredNodeBin ?? null, persisted: isConfigPersisted() });
});

// POST /api/runtime/preference { preferredNodeBin: string | null } - null = automatic
router.post('/runtime/preference', (req, res) => {
  const bin = req.body?.preferredNodeBin;
  if (bin !== null && bin !== undefined && typeof bin !== 'string') {
    res.status(400).json({ error: 'preferredNodeBin must be a string or null' });
    return;
  }
  savePreferredNodeBin(bin || undefined);
  res.json({ preferredNodeBin: bin || null, persisted: isConfigPersisted() });
});

export default router;
