import {
  CloudFrontClient,
  ListDistributionsCommand,
  GetDistributionCommand,
  GetDistributionConfigCommand,
  UpdateDistributionCommand,
  DeleteDistributionCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  ListInvalidationsCommand,
  CreateInvalidationCommand,
  GetInvalidationCommand,
  type DistributionConfig,
} from '@aws-sdk/client-cloudfront';
import { cachedCredentials } from './credential-cache.js';
import type {
  CloudFrontDistribution,
  CloudFrontDistributionDetail,
  CloudFrontOrigin,
  CloudFrontCacheBehavior,
  CloudFrontErrorResponse,
  CloudFrontInvalidation,
} from '../../domain/entities/index.js';

// CloudFront is a global service - always queried via us-east-1.
function createClient(profile: string): CloudFrontClient {
  return new CloudFrontClient({ region: 'us-east-1', credentials: cachedCredentials(profile) });
}

export async function listDistributions(profile: string, _region: string): Promise<CloudFrontDistribution[]> {
  const client = createClient(profile);
  const response = await client.send(new ListDistributionsCommand({}));

  return (response.DistributionList?.Items || []).map((d) => ({
    id: d.Id || '',
    domainName: d.DomainName || '',
    status: d.Status || '',
    enabled: d.Enabled || false,
    origins: (d.Origins?.Items || []).map((o) => o.DomainName || ''),
    comment: d.Comment,
    lastModified: d.LastModifiedTime?.toISOString(),
    priceClass: d.PriceClass,
  }));
}

function mapOrigins(config: DistributionConfig | undefined): CloudFrontOrigin[] {
  return (config?.Origins?.Items || []).map((o) => ({
    id: o.Id || '',
    domainName: o.DomainName || '',
    originPath: o.OriginPath,
    type: o.S3OriginConfig ? 's3' : 'custom',
  }));
}

function mapBehaviors(config: DistributionConfig | undefined): CloudFrontCacheBehavior[] {
  const behaviors: CloudFrontCacheBehavior[] = [];
  if (config?.DefaultCacheBehavior) {
    behaviors.push({
      pathPattern: '*',
      targetOriginId: config.DefaultCacheBehavior.TargetOriginId || '',
      viewerProtocolPolicy: config.DefaultCacheBehavior.ViewerProtocolPolicy,
      isDefault: true,
      allowedMethods: config.DefaultCacheBehavior.AllowedMethods?.Items,
      compress: config.DefaultCacheBehavior.Compress,
      cachePolicyId: config.DefaultCacheBehavior.CachePolicyId,
      originRequestPolicyId: config.DefaultCacheBehavior.OriginRequestPolicyId,
    });
  }
  for (const b of config?.CacheBehaviors?.Items || []) {
    behaviors.push({
      pathPattern: b.PathPattern || '',
      targetOriginId: b.TargetOriginId || '',
      viewerProtocolPolicy: b.ViewerProtocolPolicy,
      isDefault: false,
      allowedMethods: b.AllowedMethods?.Items,
      compress: b.Compress,
      cachePolicyId: b.CachePolicyId,
      originRequestPolicyId: b.OriginRequestPolicyId,
    });
  }
  return behaviors;
}

export async function getDistributionDetail(profile: string, _region: string, id: string): Promise<CloudFrontDistributionDetail> {
  const client = createClient(profile);
  const [distRes, configRes] = await Promise.all([
    client.send(new GetDistributionCommand({ Id: id })),
    client.send(new GetDistributionConfigCommand({ Id: id })),
  ]);

  const dist = distRes.Distribution;
  const config = configRes.DistributionConfig;
  const arn = dist?.ARN;

  const tagsRes = arn
    ? await client.send(new ListTagsForResourceCommand({ Resource: arn })).catch(() => undefined)
    : undefined;
  const tags = (tagsRes?.Tags?.Items || []).map((t) => ({ key: t.Key || '', value: t.Value || '' }));

  return {
    id: dist?.Id || id,
    arn,
    domainName: dist?.DomainName || '',
    status: dist?.Status || '',
    enabled: config?.Enabled ?? dist?.DistributionConfig?.Enabled ?? false,
    comment: config?.Comment,
    lastModified: dist?.LastModifiedTime?.toISOString(),
    priceClass: config?.PriceClass,
    origins: mapOrigins(config),
    behaviors: mapBehaviors(config),
    tags,
    aliases: config?.Aliases?.Items || [],
    defaultRootObject: config?.DefaultRootObject || undefined,
    httpVersion: config?.HttpVersion,
    ipv6Enabled: config?.IsIPV6Enabled,
    webAclId: config?.WebACLId || undefined,
    certificateSource: config?.ViewerCertificate?.CloudFrontDefaultCertificate ? 'cloudfront' : config?.ViewerCertificate?.CertificateSource,
    certificateArn: config?.ViewerCertificate?.ACMCertificateArn || config?.ViewerCertificate?.IAMCertificateId,
    minimumProtocolVersion: config?.ViewerCertificate?.MinimumProtocolVersion,
    sslSupportMethod: config?.ViewerCertificate?.SSLSupportMethod,
    geoRestrictionType: config?.Restrictions?.GeoRestriction?.RestrictionType,
    geoRestrictionLocations: config?.Restrictions?.GeoRestriction?.Items || [],
    loggingBucket: config?.Logging?.Enabled ? config.Logging.Bucket : undefined,
    errorResponses: mapErrorResponses(config),
  };
}

function mapErrorResponses(config: DistributionConfig | undefined): CloudFrontErrorResponse[] {
  return (config?.CustomErrorResponses?.Items || []).map((e) => ({
    errorCode: e.ErrorCode ?? 0,
    responsePagePath: e.ResponsePagePath || undefined,
    responseCode: e.ResponseCode || undefined,
    errorCachingMinTtl: e.ErrorCachingMinTTL,
  }));
}

/** Newest first, as the console shows them; one page (up to 100). */
export async function listInvalidations(profile: string, _region: string, id: string): Promise<CloudFrontInvalidation[]> {
  const client = createClient(profile);
  const response = await client.send(new ListInvalidationsCommand({ DistributionId: id, MaxItems: 100 }));
  return (response.InvalidationList?.Items || [])
    .map((i) => ({ id: i.Id || '', status: i.Status || '', createTime: i.CreateTime?.toISOString() }))
    .sort((a, b) => (b.createTime || '').localeCompare(a.createTime || ''));
}

export async function getInvalidation(profile: string, _region: string, id: string, invalidationId: string): Promise<CloudFrontInvalidation> {
  const client = createClient(profile);
  const response = await client.send(new GetInvalidationCommand({ DistributionId: id, Id: invalidationId }));
  const inv = response.Invalidation;
  return {
    id: inv?.Id || invalidationId,
    status: inv?.Status || '',
    createTime: inv?.CreateTime?.toISOString(),
    paths: inv?.InvalidationBatch?.Paths?.Items || [],
  };
}

/**
 * Paths must start with "/" (a trailing "*" wildcard is allowed). Each
 * path counts toward the monthly free invalidation quota; "/*" counts as one.
 */
export async function createInvalidation(profile: string, _region: string, id: string, paths: string[]): Promise<CloudFrontInvalidation> {
  const cleaned = normalizeInvalidationPaths(paths);
  const client = createClient(profile);
  const response = await client.send(
    new CreateInvalidationCommand({
      DistributionId: id,
      InvalidationBatch: { CallerReference: `awsvisualizer-${Date.now()}`, Paths: { Quantity: cleaned.length, Items: cleaned } },
    })
  );
  const inv = response.Invalidation;
  return { id: inv?.Id || '', status: inv?.Status || '', createTime: inv?.CreateTime?.toISOString(), paths: cleaned };
}

export async function setDistributionEnabled(profile: string, region: string, id: string, enabled: boolean): Promise<CloudFrontDistributionDetail> {
  const client = createClient(profile);
  const configRes = await client.send(new GetDistributionConfigCommand({ Id: id }));
  const config = configRes.DistributionConfig;
  if (!config) {
    throw new Error('Distribution config not found');
  }
  await client.send(
    new UpdateDistributionCommand({
      Id: id,
      IfMatch: configRes.ETag,
      DistributionConfig: { ...config, Enabled: enabled },
    })
  );
  return getDistributionDetail(profile, region, id);
}

export async function deleteDistribution(profile: string, _region: string, id: string): Promise<void> {
  const client = createClient(profile);
  const configRes = await client.send(new GetDistributionConfigCommand({ Id: id }));
  await client.send(new DeleteDistributionCommand({ Id: id, IfMatch: configRes.ETag }));
}

async function getDistributionArn(client: CloudFrontClient, id: string): Promise<string> {
  const distRes = await client.send(new GetDistributionCommand({ Id: id }));
  const arn = distRes.Distribution?.ARN;
  if (!arn) {
    throw new Error('Could not resolve distribution ARN');
  }
  return arn;
}

export async function addDistributionTag(profile: string, region: string, id: string, key: string, value: string): Promise<CloudFrontDistributionDetail> {
  const client = createClient(profile);
  const arn = await getDistributionArn(client, id);
  await client.send(new TagResourceCommand({ Resource: arn, Tags: { Items: [{ Key: key, Value: value }] } }));
  return getDistributionDetail(profile, region, id);
}

export async function removeDistributionTag(profile: string, region: string, id: string, key: string): Promise<CloudFrontDistributionDetail> {
  const client = createClient(profile);
  const arn = await getDistributionArn(client, id);
  await client.send(new UntagResourceCommand({ Resource: arn, TagKeys: { Items: [key] } }));
  return getDistributionDetail(profile, region, id);
}

/** Trimmed, de-duplicated, empty lines dropped. */
export function normalizeInvalidationPaths(paths: string[]): string[] {
  return [...new Set(paths.map((p) => p.trim()).filter(Boolean))];
}
