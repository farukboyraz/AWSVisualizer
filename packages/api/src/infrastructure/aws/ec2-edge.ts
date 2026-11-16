import {
  EC2Client,
  DescribeAvailabilityZonesCommand,
  DescribeSubnetsCommand,
  DescribeCarrierGatewaysCommand,
  DescribeInstancesCommand,
  ModifyAvailabilityZoneGroupCommand,
  type Tag,
} from '@aws-sdk/client-ec2';
import { cachedCredentials } from './credential-cache.js';
import type {
  EdgeZone,
  EdgeZoneGroupDetail,
  EdgeCarrierGateway,
  Ec2Instance,
} from '../../domain/entities/index.js';

/**
 * Wavelength Zones, Local Zones and Nitro Enclaves have no API of their
 * own - they're all EC2: zones are `DescribeAvailabilityZones` entries of
 * zone-type `wavelength-zone` / `local-zone` (opted in per zone group),
 * enclaves are an option on an EC2 instance.
 */

export type EdgeZoneType = 'wavelength-zone' | 'local-zone';

function createClient(profile: string, region: string): EC2Client {
  return new EC2Client({ region, credentials: cachedCredentials(profile) });
}

function nameTag(tags?: Tag[]): string | undefined {
  return tags?.find((t) => t.Key === 'Name')?.Value;
}

export async function listEdgeZones(profile: string, region: string, zoneType: EdgeZoneType): Promise<EdgeZone[]> {
  const client = createClient(profile, region);
  const res = await client.send(new DescribeAvailabilityZonesCommand({
    AllAvailabilityZones: true,
    Filters: [{ Name: 'zone-type', Values: [zoneType] }],
  }));
  return (res.AvailabilityZones || [])
    .map((z) => ({
      zoneName: z.ZoneName || '',
      zoneId: z.ZoneId,
      zoneType: z.ZoneType,
      groupName: z.GroupName || z.ZoneName || '',
      networkBorderGroup: z.NetworkBorderGroup,
      optInStatus: z.OptInStatus,
      parentZoneName: z.ParentZoneName,
      state: z.State,
    }))
    .sort((a, b) => a.groupName.localeCompare(b.groupName) || a.zoneName.localeCompare(b.zoneName));
}

/** Counted only once opted in - not-opted-in zones exist in every account. */
export async function listOptedInZones(profile: string, region: string, zoneType: EdgeZoneType): Promise<EdgeZone[]> {
  return (await listEdgeZones(profile, region, zoneType)).filter((z) => z.optInStatus === 'opted-in');
}

export async function getEdgeZoneGroup(
  profile: string,
  region: string,
  zoneType: EdgeZoneType,
  groupName: string
): Promise<EdgeZoneGroupDetail> {
  const client = createClient(profile, region);
  const zones = (await listEdgeZones(profile, region, zoneType)).filter((z) => z.groupName === groupName);
  if (zones.length === 0) throw new Error(`Zone group not found: ${groupName}`);
  const zoneNames = zones.map((z) => z.zoneName);

  const [subnetRes, carrierGateways] = await Promise.all([
    client.send(new DescribeSubnetsCommand({ Filters: [{ Name: 'availability-zone', Values: zoneNames }] })),
    zoneType === 'wavelength-zone' ? listCarrierGateways(client) : Promise.resolve([] as EdgeCarrierGateway[]),
  ]);

  return {
    groupName,
    zones,
    subnets: (subnetRes.Subnets || []).map((s) => ({
      subnetId: s.SubnetId || '',
      vpcId: s.VpcId,
      cidrBlock: s.CidrBlock,
      availabilityZone: s.AvailabilityZone,
      availableIpAddressCount: s.AvailableIpAddressCount,
      name: nameTag(s.Tags),
    })),
    carrierGateways,
  };
}

async function listCarrierGateways(client: EC2Client): Promise<EdgeCarrierGateway[]> {
  const out: EdgeCarrierGateway[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new DescribeCarrierGatewaysCommand({ NextToken }));
    for (const g of res.CarrierGateways || []) {
      out.push({ carrierGatewayId: g.CarrierGatewayId || '', vpcId: g.VpcId, state: g.State, name: nameTag(g.Tags) });
    }
    NextToken = res.NextToken;
  } while (NextToken);
  return out;
}

/** Opt a zone group in or out (EC2 console › Settings › Zones). */
export async function setZoneGroupOptIn(
  profile: string,
  region: string,
  zoneType: EdgeZoneType,
  groupName: string,
  optedIn: boolean
): Promise<EdgeZoneGroupDetail> {
  const client = createClient(profile, region);
  await client.send(new ModifyAvailabilityZoneGroupCommand({
    GroupName: groupName,
    OptInStatus: optedIn ? 'opted-in' : 'not-opted-in',
  }));
  return getEdgeZoneGroup(profile, region, zoneType, groupName);
}

/** Instances launched with `EnclaveOptions.Enabled` - the hosts of Nitro Enclaves. */
export async function listEnclaveInstances(profile: string, region: string): Promise<Ec2Instance[]> {
  const client = createClient(profile, region);
  const out: Ec2Instance[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new DescribeInstancesCommand({
      Filters: [{ Name: 'enclave-options.enabled', Values: ['true'] }],
      NextToken,
    }));
    for (const reservation of res.Reservations || []) {
      for (const inst of reservation.Instances || []) {
        out.push({
          instanceId: inst.InstanceId || '',
          instanceType: inst.InstanceType || '',
          state: inst.State?.Name || '',
          name: nameTag(inst.Tags) || '',
          privateIp: inst.PrivateIpAddress,
          publicIp: inst.PublicIpAddress,
          launchTime: inst.LaunchTime?.toISOString(),
          platform: inst.PlatformDetails,
          availabilityZone: inst.Placement?.AvailabilityZone,
        });
      }
    }
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => (a.name || a.instanceId).localeCompare(b.name || b.instanceId));
}
