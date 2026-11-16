// Must stay first: lets missing service SDKs resolve to stand-ins (see the file).
import './bootstrap/optional-modules.js';
import express from 'express';
import { loadConfig, APP_VERSION } from './config/index.js';
import { errorHandler } from './presentation/middleware/error-handler.js';

// Route imports
import statusRoutes from './presentation/routes/status.js';
import authRoutes from './presentation/routes/auth.js';
import profilesRoutes from './presentation/routes/profiles.js';
import environmentsRoutes from './presentation/routes/environments.js';
import dynamodbRoutes from './presentation/routes/dynamodb.js';
import s3Routes from './presentation/routes/s3.js';
import lambdaRoutes from './presentation/routes/lambda.js';
import ec2Routes from './presentation/routes/ec2.js';
import rdsRoutes from './presentation/routes/rds.js';
import ecsRoutes from './presentation/routes/ecs.js';
import sqsRoutes from './presentation/routes/sqs.js';
import cloudwatchRoutes from './presentation/routes/cloudwatch.js';
import cloudfrontRoutes from './presentation/routes/cloudfront.js';
import route53Routes from './presentation/routes/route53.js';
import costRoutes from './presentation/routes/cost.js';
import configRoutes from './presentation/routes/config.js';
import servicesRoutes from './presentation/routes/services.js';
import codecommitRoutes from './presentation/routes/codecommit.js';
import secretsManagerRoutes from './presentation/routes/secrets-manager.js';
import cloudformationRoutes from './presentation/routes/cloudformation.js';
import elbRoutes from './presentation/routes/elb.js';
import apiGatewayRoutes from './presentation/routes/api-gateway.js';
import apiGatewayV2Routes from './presentation/routes/api-gateway-v2.js';
import setupRoutes from './presentation/routes/setup.js';
import personalRoutes from './presentation/routes/personal.js';
import snsRoutes from './presentation/routes/sns.js';
import ecrRoutes from './presentation/routes/ecr.js';
import computeRoutes from './presentation/routes/compute.js';
import containersRoutes from './presentation/routes/containers.js';
import storageRoutes from './presentation/routes/storage.js';
import resourcePageRoutes from './presentation/routes/resource-pages.js';
import kmsRoutes from './presentation/routes/kms.js';
import workspaceRoutes from './presentation/routes/workspace.js';
import packagesRoutes from './presentation/routes/packages.js';
import dashboardRoutes from './presentation/routes/dashboard.js';
import { recordRuntime } from './infrastructure/packages/installer.js';
import { bigIntJsonBody, bigIntJsonResponse } from './presentation/middleware/bigint-json.js';
import { requireSidecarToken } from './presentation/middleware/sidecar-token.js';
import { validateInput } from './presentation/middleware/validate-input.js';

const app = express();

// Middleware. No CORS: only the Mac app calls this API, never a web page,
// so a browser tab can't read anything from it.
// Every answer (the 403 below too) says it comes from this API, so the app
// can tell it apart from another program listening on the same port.
app.use((_req, res, next) => {
  res.setHeader('X-AWSVisualizer-API', APP_VERSION);
  next();
});
app.use(requireSidecarToken);
app.use(bigIntJsonBody);
app.use(bigIntJsonResponse);
// Profile / region / id / tag checks for every route (see the file).
app.use('/api', validateInput);

// All routes mounted under /api
app.use('/api', statusRoutes);
app.use('/api', authRoutes);
app.use('/api', profilesRoutes);
app.use('/api', environmentsRoutes);
app.use('/api', dynamodbRoutes);
app.use('/api', s3Routes);
app.use('/api', lambdaRoutes);
app.use('/api', ec2Routes);
app.use('/api', rdsRoutes);
app.use('/api', ecsRoutes);
app.use('/api', sqsRoutes);
app.use('/api', cloudwatchRoutes);
app.use('/api', cloudfrontRoutes);
app.use('/api', route53Routes);
app.use('/api', costRoutes);
app.use('/api', configRoutes);
app.use('/api', servicesRoutes);
app.use('/api', codecommitRoutes);
app.use('/api', secretsManagerRoutes);
app.use('/api', cloudformationRoutes);
app.use('/api', elbRoutes);
app.use('/api', apiGatewayRoutes);
app.use('/api', apiGatewayV2Routes);
app.use('/api', setupRoutes);
app.use('/api', personalRoutes);
app.use('/api', snsRoutes);
app.use('/api', ecrRoutes);
app.use('/api', kmsRoutes);
app.use('/api', computeRoutes);
app.use('/api', containersRoutes);
app.use('/api', storageRoutes);
app.use('/api', resourcePageRoutes);
app.use('/api', workspaceRoutes);
app.use('/api', packagesRoutes);
app.use('/api', dashboardRoutes);

// Global error handler
app.use(errorHandler);

// Start server
const config = loadConfig();
const PORT = config.app.port || 9000;
// Loopback only: other devices on the same network can't reach it.
const HOST = '127.0.0.1';

app.listen(PORT, HOST, () => {
  console.log(`🚀 ${config.app.name} API running on http://${HOST}:${PORT}`);
  console.log(`   Version: ${config.app.version}`);
  console.log(`   Default Region: ${config.aws.defaultRegion}`);
  recordRuntime().catch((err) => console.error('Could not record node/npm versions:', err));
});

export default app;
