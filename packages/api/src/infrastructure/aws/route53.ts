import {
  Route53Client,
  ListHostedZonesCommand,
  GetHostedZoneCommand,
  ListResourceRecordSetsCommand,
  ChangeResourceRecordSetsCommand,
  UpdateHostedZoneCommentCommand,
  ListTagsForResourceCommand,
  ChangeTagsForResourceCommand,
  type ResourceRecordSet,
  type RRType,
} from '@aws-sdk/client-route-53';
import { cachedCredentials } from './credential-cache.js';
import type { HostedZone, Route53ZoneDetail, Route53Record, Route53RecordPage } from '../../domain/entities/index.js';

// Route53 is global - every call goes to us-east-1 regardless of the
// region picked in the app (same as CloudFront).
function createClient(profile: string): Route53Client {
  return new Route53Client({ region: 'us-east-1', credentials: cachedCredentials(profile) });
}

/** Route53 returns some characters octal-escaped (`*` comes back as `\052`). */
function decodeName(name: string): string {
  return name.replace(/\\(\d{3})/g, (_, octal: string) => String.fromCharCode(parseInt(octal, 8)));
}

export async function listHostedZones(profile: string, _region: string): Promise<HostedZone[]> {
  const client = createClient(profile);
  const command = new ListHostedZonesCommand({});
  const response = await client.send(command);

  return (response.HostedZones || []).map((z) => ({
    id: z.Id?.replace('/hostedzone/', '') || '',
    name: z.Name || '',
    recordCount: z.ResourceRecordSetCount || 0,
    isPrivate: z.Config?.PrivateZone || false,
    comment: z.Config?.Comment,
  }));
}

export async function getZoneDetail(profile: string, zoneId: string): Promise<Route53ZoneDetail> {
  const client = createClient(profile);
  const [zoneRes, tagsRes] = await Promise.all([
    client.send(new GetHostedZoneCommand({ Id: zoneId })),
    client.send(new ListTagsForResourceCommand({ ResourceType: 'hostedzone', ResourceId: zoneId })),
  ]);
  const z = zoneRes.HostedZone;
  return {
    id: zoneId,
    name: z?.Name || '',
    isPrivate: z?.Config?.PrivateZone || false,
    comment: z?.Config?.Comment,
    recordCount: z?.ResourceRecordSetCount || 0,
    nameServers: zoneRes.DelegationSet?.NameServers || [],
    vpcs: (zoneRes.VPCs || []).map((v) => `${v.VPCId} (${v.VPCRegion})`),
    tags: (tagsRes.ResourceTagSet?.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
  };
}

function toRecord(r: ResourceRecordSet): Route53Record {
  return {
    name: decodeName(r.Name || ''),
    type: r.Type || '',
    ttl: r.TTL,
    values: (r.ResourceRecords || []).map((v) => v.Value || ''),
    aliasTarget: r.AliasTarget
      ? {
          dnsName: r.AliasTarget.DNSName || '',
          hostedZoneId: r.AliasTarget.HostedZoneId || '',
          evaluateTargetHealth: r.AliasTarget.EvaluateTargetHealth || false,
        }
      : undefined,
    setIdentifier: r.SetIdentifier,
    weight: r.Weight,
    region: r.Region,
    failover: r.Failover,
    healthCheckId: r.HealthCheckId,
  };
}

/** One page (100 records) in the API's own name/type order, with an opaque cursor for the next. */
export async function listRecords(
  profile: string,
  zoneId: string,
  start?: { name?: string; type?: string; identifier?: string }
): Promise<Route53RecordPage> {
  const client = createClient(profile);
  const res = await client.send(
    new ListResourceRecordSetsCommand({
      HostedZoneId: zoneId,
      StartRecordName: start?.name,
      StartRecordType: start?.type as RRType | undefined,
      StartRecordIdentifier: start?.identifier,
      MaxItems: 100,
    })
  );
  return {
    records: (res.ResourceRecordSets || []).map(toRecord),
    nextRecordName: res.IsTruncated ? res.NextRecordName : undefined,
    nextRecordType: res.IsTruncated ? res.NextRecordType : undefined,
    nextRecordIdentifier: res.IsTruncated ? res.NextRecordIdentifier : undefined,
  };
}

function normalizeName(name: string): string {
  const decoded = decodeName(name).toLowerCase();
  return decoded.endsWith('.') ? decoded : `${decoded}.`;
}

/**
 * Re-reads the exact record set as AWS has it. A DELETE has to match the
 * existing record field for field, and an edit has to carry over alias /
 * routing-policy fields this app doesn't expose - so both start from the
 * live record instead of trusting whatever the client sent back.
 */
async function findExactRecord(client: Route53Client, zoneId: string, name: string, type: string, setIdentifier?: string): Promise<ResourceRecordSet> {
  const res = await client.send(
    new ListResourceRecordSetsCommand({
      HostedZoneId: zoneId,
      StartRecordName: name,
      StartRecordType: type as RRType,
      StartRecordIdentifier: setIdentifier,
      MaxItems: 100,
    })
  );
  const wanted = normalizeName(name);
  const match = (res.ResourceRecordSets || []).find(
    (r) => normalizeName(r.Name || '') === wanted && r.Type === type && (r.SetIdentifier || undefined) === (setIdentifier || undefined)
  );
  if (!match) {
    throw Object.assign(new Error(`Record ${name} ${type} no longer exists`), { name: 'NoSuchRecord', $metadata: { httpStatusCode: 404 } });
  }
  return match;
}

export async function createRecord(profile: string, zoneId: string, name: string, type: string, ttl: number, values: string[]): Promise<void> {
  const client = createClient(profile);
  // CREATE (not UPSERT) so adding a record can never silently overwrite
  // an existing one with the same name and type.
  await client.send(
    new ChangeResourceRecordSetsCommand({
      HostedZoneId: zoneId,
      ChangeBatch: {
        Comment: 'Created from AWS Visualizer',
        Changes: [
          {
            Action: 'CREATE',
            ResourceRecordSet: { Name: name, Type: type as RRType, TTL: ttl, ResourceRecords: values.map((Value) => ({ Value })) },
          },
        ],
      },
    })
  );
}

export async function updateRecord(
  profile: string,
  zoneId: string,
  name: string,
  type: string,
  setIdentifier: string | undefined,
  ttl: number,
  values: string[]
): Promise<void> {
  const client = createClient(profile);
  const existing = await findExactRecord(client, zoneId, name, type, setIdentifier);
  if (existing.AliasTarget) {
    throw Object.assign(new Error('Alias records can only be edited in the AWS console'), { name: 'UnsupportedRecord', $metadata: { httpStatusCode: 400 } });
  }
  await client.send(
    new ChangeResourceRecordSetsCommand({
      HostedZoneId: zoneId,
      ChangeBatch: {
        Comment: 'Edited from AWS Visualizer',
        Changes: [{ Action: 'UPSERT', ResourceRecordSet: { ...existing, TTL: ttl, ResourceRecords: values.map((Value) => ({ Value })) } }],
      },
    })
  );
}

export async function deleteRecord(profile: string, zoneId: string, name: string, type: string, setIdentifier?: string): Promise<void> {
  const client = createClient(profile);
  const existing = await findExactRecord(client, zoneId, name, type, setIdentifier);
  await client.send(
    new ChangeResourceRecordSetsCommand({
      HostedZoneId: zoneId,
      ChangeBatch: { Comment: 'Deleted from AWS Visualizer', Changes: [{ Action: 'DELETE', ResourceRecordSet: existing }] },
    })
  );
}

export async function updateZoneComment(profile: string, zoneId: string, comment: string): Promise<Route53ZoneDetail> {
  const client = createClient(profile);
  await client.send(new UpdateHostedZoneCommentCommand({ Id: zoneId, Comment: comment }));
  return getZoneDetail(profile, zoneId);
}

export async function addZoneTag(profile: string, zoneId: string, key: string, value: string): Promise<Route53ZoneDetail> {
  const client = createClient(profile);
  await client.send(new ChangeTagsForResourceCommand({ ResourceType: 'hostedzone', ResourceId: zoneId, AddTags: [{ Key: key, Value: value }] }));
  return getZoneDetail(profile, zoneId);
}

export async function removeZoneTag(profile: string, zoneId: string, key: string): Promise<Route53ZoneDetail> {
  const client = createClient(profile);
  await client.send(new ChangeTagsForResourceCommand({ ResourceType: 'hostedzone', ResourceId: zoneId, RemoveTagKeys: [key] }));
  return getZoneDetail(profile, zoneId);
}
