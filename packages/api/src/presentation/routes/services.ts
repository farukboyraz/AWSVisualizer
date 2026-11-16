import { loadConfig, COUNT_WIDGETS, saveDashboardCache, getDashboardCache } from '../../config/index.js';
import { countsKey } from './dashboard.js';
import { Router } from 'express';
import { AWS_SERVICE_CATALOG } from '../../domain/aws-service-catalog.js';
import { getSelectedServices, saveSelectedServices, getFavoriteServices, saveFavoriteServices } from '../../config/index.js';
import { getServiceCounts } from '../../infrastructure/aws/service-counts.js';
import { handleApiError } from '../../infrastructure/aws/credentials.js';
import { isServiceInstalled, clearResolvedFailures } from '../../infrastructure/packages/installer.js';
import { SERVICE_PACKAGES } from '../../domain/service-packages.js';

const router = Router();

// GET /api/services/catalog
// Implemented entries carry whether their SDK packages are installed and whether the last install failed.
router.get('/services/catalog', (_req, res) => {
  const failures = clearResolvedFailures();
  res.json({
    services: AWS_SERVICE_CATALOG.map((e) => (SERVICE_PACKAGES[e.id] ? { ...e, packagesInstalled: isServiceInstalled(e.id), packageInstallFailed: Boolean(failures[e.id]) } : e)),
  });
});

// GET /api/services/selected
router.get('/services/selected', (_req, res) => {
  res.json({ selected: getSelectedServices() });
});

// POST /api/services/selected
router.post('/services/selected', (req, res) => {
  const services = req.body?.services;
  if (!Array.isArray(services) || !services.every((s) => typeof s === 'string')) {
    res.status(400).json({ error: 'services must be an array of strings' });
    return;
  }
  saveSelectedServices(services);
  res.json({ success: true, selected: services });
});

// GET /api/services/favorites
router.get('/services/favorites', (_req, res) => {
  res.json({ favorites: getFavoriteServices() });
});

// POST /api/services/favorites
router.post('/services/favorites', (req, res) => {
  const services = req.body?.services;
  if (!Array.isArray(services) || !services.every((s) => typeof s === 'string')) {
    res.status(400).json({ error: 'services must be an array of strings' });
    return;
  }
  saveFavoriteServices(services);
  res.json({ success: true, favorites: services });
});

// GET /api/services/counts
router.get('/services/counts', async (req, res) => {
  try {
    const profile = (req.query.profile as string) || '';
    const region = (req.query.region as string) || '';
    const servicesParam = (req.query.services as string) || '';
    let serviceIds = servicesParam.split(',').map((s) => s.trim()).filter(Boolean);

    // The dashboard asks with source=dashboard: services it excludes, or all
    // of them when every count widget is off, are never listed on AWS.
    if (req.query.source === 'dashboard') {
      const prefs = loadConfig().dashboard;
      const excluded = new Set(prefs.excludedServices);
      serviceIds = COUNT_WIDGETS.some((w) => prefs.widgets[w]) ? serviceIds.filter((id) => !excluded.has(id)) : [];
    }

    const counts = await getServiceCounts(profile, region, serviceIds);
    if (req.query.source === 'dashboard' && serviceIds.length) {
      // Keep the counts of services not asked this time (merged per service).
      const key = countsKey(profile, region);
      const previous = (getDashboardCache([key])[key]?.data as Record<string, number | null>) || {};
      saveDashboardCache(key, { ...previous, ...counts });
    }
    res.json({ counts });
  } catch (err) {
    const error = handleApiError(err);
    res.status(error.status).json(error);
  }
});

export default router;
