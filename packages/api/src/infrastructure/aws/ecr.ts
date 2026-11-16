import {
  ECRClient,
  DescribeRepositoriesCommand,
  DescribeImagesCommand,
  DescribeImageScanFindingsCommand,
  StartImageScanCommand,
  BatchDeleteImageCommand,
  GetLifecyclePolicyCommand,
  PutLifecyclePolicyCommand,
  DeleteLifecyclePolicyCommand,
  GetRepositoryPolicyCommand,
  SetRepositoryPolicyCommand,
  DeleteRepositoryPolicyCommand,
  PutImageTagMutabilityCommand,
  PutImageScanningConfigurationCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
} from '@aws-sdk/client-ecr';
import { cachedCredentials } from './credential-cache.js';
import type {
  EcrRepository,
  EcrRepositoryDetail,
  EcrImagePage,
  EcrScanFindings,
} from '../../domain/entities/index.js';

function createClient(profile: string, region: string): ECRClient {
  return new ECRClient({ region, credentials: cachedCredentials(profile) });
}

/** The "...NotFoundException"s ECR throws when a repository simply has no policy of that kind. */
function isNotFound(err: unknown): boolean {
  const name = (err as { name?: string })?.name || '';
  return name === 'LifecyclePolicyNotFoundException' || name === 'RepositoryPolicyNotFoundException';
}

function prettyJson(raw?: string): string | undefined {
  if (!raw) return undefined;
  try {
    return JSON.stringify(JSON.parse(raw), null, 2);
  } catch {
    return raw;
  }
}

export async function listRepositories(profile: string, region: string): Promise<EcrRepository[]> {
  const client = createClient(profile, region);
  const repositories: EcrRepository[] = [];
  let nextToken: string | undefined;
  do {
    const response = await client.send(new DescribeRepositoriesCommand({ nextToken }));
    for (const r of response.repositories || []) {
      repositories.push({
        repositoryName: r.repositoryName || '',
        repositoryUri: r.repositoryUri,
        createdAt: r.createdAt?.toISOString(),
        imageTagMutability: r.imageTagMutability,
      });
    }
    nextToken = response.nextToken;
  } while (nextToken);
  return repositories.sort((a, b) => a.repositoryName.localeCompare(b.repositoryName));
}

export async function getRepositoryDetail(profile: string, region: string, repositoryName: string): Promise<EcrRepositoryDetail> {
  const client = createClient(profile, region);
  const res = await client.send(new DescribeRepositoriesCommand({ repositoryNames: [repositoryName] }));
  const r = res.repositories?.[0];
  if (!r) throw new Error('Repository not found');
  const tagRes = await client.send(new ListTagsForResourceCommand({ resourceArn: r.repositoryArn }));

  return {
    repositoryName: r.repositoryName || repositoryName,
    repositoryArn: r.repositoryArn || '',
    repositoryUri: r.repositoryUri || '',
    registryId: r.registryId || '',
    createdAt: r.createdAt?.toISOString(),
    imageTagMutability: r.imageTagMutability,
    scanOnPush: r.imageScanningConfiguration?.scanOnPush || false,
    encryptionType: r.encryptionConfiguration?.encryptionType,
    kmsKey: r.encryptionConfiguration?.kmsKey,
    tags: (tagRes.tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
  };
}

/**
 * One page of images (DescribeImages has no server-side sort; each page is
 * sorted newest-push-first, which matches the console for repositories
 * that fit in one page and stays stable across "Load more").
 */
export async function listImages(profile: string, region: string, repositoryName: string, nextToken?: string): Promise<EcrImagePage> {
  const client = createClient(profile, region);
  const res = await client.send(new DescribeImagesCommand({ repositoryName, nextToken, maxResults: 100 }));
  const images = (res.imageDetails || [])
    .map((i) => ({
      imageDigest: i.imageDigest || '',
      imageTags: i.imageTags || [],
      pushedAt: i.imagePushedAt?.toISOString(),
      sizeInBytes: i.imageSizeInBytes,
      lastPulledAt: i.lastRecordedPullTime?.toISOString(),
      mediaType: i.artifactMediaType || i.imageManifestMediaType,
      scanStatus: i.imageScanStatus?.status,
      findingCounts: Object.entries(i.imageScanFindingsSummary?.findingSeverityCounts || {}).map(([key, value]) => ({
        key,
        value: String(value),
      })),
    }))
    .sort((a, b) => (b.pushedAt || '').localeCompare(a.pushedAt || ''));
  return { images, nextToken: res.nextToken };
}

export async function getScanFindings(profile: string, region: string, repositoryName: string, imageDigest: string): Promise<EcrScanFindings> {
  const client = createClient(profile, region);
  const res = await client.send(
    new DescribeImageScanFindingsCommand({ repositoryName, imageId: { imageDigest }, maxResults: 1000 })
  );
  const f = res.imageScanFindings;
  const attr = (attrs: { key?: string; value?: string }[] | undefined, key: string) => attrs?.find((a) => a.key === key)?.value;

  // Basic scanning fills `findings`, enhanced (Inspector) scanning fills
  // `enhancedFindings` - normalised into the same row shape.
  const basic = (f?.findings || []).map((x) => ({
    name: x.name || '',
    severity: x.severity || 'UNDEFINED',
    description: x.description,
    uri: x.uri,
    packageName: attr(x.attributes, 'package_name'),
    packageVersion: attr(x.attributes, 'package_version'),
  }));
  const enhanced = (f?.enhancedFindings || []).map((x) => ({
    name: x.packageVulnerabilityDetails?.vulnerabilityId || x.title || '',
    severity: x.severity || 'UNDEFINED',
    description: x.description,
    uri: x.packageVulnerabilityDetails?.sourceUrl,
    packageName: x.packageVulnerabilityDetails?.vulnerablePackages?.[0]?.name,
    packageVersion: x.packageVulnerabilityDetails?.vulnerablePackages?.[0]?.version,
  }));
  const order = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW', 'INFORMATIONAL', 'UNDEFINED'];

  return {
    scanStatus: res.imageScanStatus?.status,
    scanStatusDescription: res.imageScanStatus?.description,
    completedAt: f?.imageScanCompletedAt?.toISOString(),
    findings: [...basic, ...enhanced].sort((a, b) => order.indexOf(a.severity) - order.indexOf(b.severity)),
  };
}

export async function startImageScan(profile: string, region: string, repositoryName: string, imageDigest: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new StartImageScanCommand({ repositoryName, imageId: { imageDigest } }));
}

export async function deleteImage(profile: string, region: string, repositoryName: string, imageDigest: string): Promise<void> {
  const client = createClient(profile, region);
  const res = await client.send(new BatchDeleteImageCommand({ repositoryName, imageIds: [{ imageDigest }] }));
  // BatchDeleteImage reports per-image failures in the body instead of throwing.
  const failure = res.failures?.[0];
  if (failure) {
    throw Object.assign(new Error(failure.failureReason || 'Image could not be deleted'), {
      name: failure.failureCode || 'ImageDeleteFailed',
      $metadata: { httpStatusCode: 400 },
    });
  }
}

export async function getLifecyclePolicy(profile: string, region: string, repositoryName: string): Promise<{ policy?: string }> {
  const client = createClient(profile, region);
  try {
    const res = await client.send(new GetLifecyclePolicyCommand({ repositoryName }));
    return { policy: prettyJson(res.lifecyclePolicyText) };
  } catch (err) {
    if (isNotFound(err)) return {};
    throw err;
  }
}

export async function putLifecyclePolicy(profile: string, region: string, repositoryName: string, policy: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new PutLifecyclePolicyCommand({ repositoryName, lifecyclePolicyText: policy }));
}

export async function deleteLifecyclePolicy(profile: string, region: string, repositoryName: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteLifecyclePolicyCommand({ repositoryName }));
}

export async function getRepositoryPolicy(profile: string, region: string, repositoryName: string): Promise<{ policy?: string }> {
  const client = createClient(profile, region);
  try {
    const res = await client.send(new GetRepositoryPolicyCommand({ repositoryName }));
    return { policy: prettyJson(res.policyText) };
  } catch (err) {
    if (isNotFound(err)) return {};
    throw err;
  }
}

export async function setRepositoryPolicy(profile: string, region: string, repositoryName: string, policy: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new SetRepositoryPolicyCommand({ repositoryName, policyText: policy }));
}

export async function deleteRepositoryPolicy(profile: string, region: string, repositoryName: string): Promise<void> {
  const client = createClient(profile, region);
  await client.send(new DeleteRepositoryPolicyCommand({ repositoryName }));
}

export async function setTagMutability(profile: string, region: string, repositoryName: string, mutability: 'MUTABLE' | 'IMMUTABLE'): Promise<EcrRepositoryDetail> {
  const client = createClient(profile, region);
  await client.send(new PutImageTagMutabilityCommand({ repositoryName, imageTagMutability: mutability }));
  return getRepositoryDetail(profile, region, repositoryName);
}

export async function setScanOnPush(profile: string, region: string, repositoryName: string, enabled: boolean): Promise<EcrRepositoryDetail> {
  const client = createClient(profile, region);
  await client.send(new PutImageScanningConfigurationCommand({ repositoryName, imageScanningConfiguration: { scanOnPush: enabled } }));
  return getRepositoryDetail(profile, region, repositoryName);
}

export async function addRepositoryTag(profile: string, region: string, repositoryName: string, arn: string, key: string, value: string): Promise<EcrRepositoryDetail> {
  const client = createClient(profile, region);
  await client.send(new TagResourceCommand({ resourceArn: arn, tags: [{ Key: key, Value: value }] }));
  return getRepositoryDetail(profile, region, repositoryName);
}

export async function removeRepositoryTag(profile: string, region: string, repositoryName: string, arn: string, key: string): Promise<EcrRepositoryDetail> {
  const client = createClient(profile, region);
  await client.send(new UntagResourceCommand({ resourceArn: arn, tagKeys: [key] }));
  return getRepositoryDetail(profile, region, repositoryName);
}
