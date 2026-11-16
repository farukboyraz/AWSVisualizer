import {
  OutpostsClient,
  ListOutpostsCommand,
  GetOutpostCommand,
  GetOutpostInstanceTypesCommand,
  ListAssetsCommand,
  GetSiteCommand,
  type Outpost as SdkOutpost,
} from '@aws-sdk/client-outposts';
import { cachedCredentials } from './credential-cache.js';
import type { Outpost, OutpostDetail, OutpostAsset } from '../../domain/entities/index.js';

function createClient(profile: string, region: string): OutpostsClient {
  return new OutpostsClient({ region, credentials: cachedCredentials(profile) });
}

function mapOutpost(o: SdkOutpost): Outpost {
  return {
    outpostId: o.OutpostId || '',
    outpostArn: o.OutpostArn || '',
    name: o.Name || o.OutpostId || '',
    description: o.Description,
    siteId: o.SiteId,
    availabilityZone: o.AvailabilityZone,
    lifeCycleStatus: o.LifeCycleStatus,
    supportedHardwareType: o.SupportedHardwareType,
    ownerId: o.OwnerId,
    tags: Object.entries(o.Tags || {}).map(([key, value]) => ({ key, value })),
  };
}

export async function listOutposts(profile: string, region: string): Promise<Outpost[]> {
  const client = createClient(profile, region);
  const out: Outpost[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new ListOutpostsCommand({ NextToken }));
    out.push(...(res.Outposts || []).map(mapOutpost));
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

async function instanceTypes(client: OutpostsClient, outpostId: string): Promise<string[]> {
  const out: string[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new GetOutpostInstanceTypesCommand({ OutpostId: outpostId, NextToken }));
    out.push(...(res.InstanceTypes || []).map((t) => t.InstanceType || '').filter(Boolean));
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort();
}

/** ListAssets is only allowed for the Outpost owner - a shared Outpost reports why instead. */
async function assets(client: OutpostsClient, outpostId: string): Promise<OutpostAsset[]> {
  const out: OutpostAsset[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new ListAssetsCommand({ OutpostIdentifier: outpostId, NextToken }));
    for (const a of res.Assets || []) {
      out.push({
        assetId: a.AssetId || '',
        assetType: a.AssetType,
        rackId: a.RackId,
        hostId: a.ComputeAttributes?.HostId,
        state: a.ComputeAttributes?.State,
      });
    }
    NextToken = res.NextToken;
  } while (NextToken);
  return out;
}

export async function getOutpostDetail(profile: string, region: string, outpostId: string): Promise<OutpostDetail> {
  const client = createClient(profile, region);
  const res = await client.send(new GetOutpostCommand({ OutpostId: outpostId }));
  if (!res.Outpost) throw new Error(`Outpost not found: ${outpostId}`);
  const outpost = mapOutpost(res.Outpost);

  const [types, assetResult, site] = await Promise.all([
    instanceTypes(client, outpostId).catch(() => [] as string[]),
    assets(client, outpostId).then(
      (list) => ({ list, error: undefined as string | undefined }),
      (err) => ({ list: [] as OutpostAsset[], error: (err as Error)?.message || String(err) })
    ),
    outpost.siteId
      ? client.send(new GetSiteCommand({ SiteId: outpost.siteId })).then((r) => r.Site, () => undefined)
      : Promise.resolve(undefined),
  ]);

  return {
    ...outpost,
    siteName: site?.Name,
    siteDescription: site?.Description,
    instanceTypes: types,
    assets: assetResult.list,
    assetsError: assetResult.error,
  };
}
