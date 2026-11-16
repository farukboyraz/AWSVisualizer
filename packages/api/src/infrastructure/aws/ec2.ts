import {
  EC2Client,
  DescribeInstancesCommand,
  DescribeInstanceAttributeCommand,
  ModifyInstanceAttributeCommand,
  StartInstancesCommand,
  StopInstancesCommand,
  RebootInstancesCommand,
  TerminateInstancesCommand,
  MonitorInstancesCommand,
  UnmonitorInstancesCommand,
  CreateTagsCommand,
  DeleteTagsCommand,
  RunInstancesCommand,
  DescribeKeyPairsCommand,
  type Instance,
} from '@aws-sdk/client-ec2';
import { cachedCredentials } from './credential-cache.js';
import type { Ec2Instance, Ec2InstanceDetail, Ec2KeyPair, Ec2LaunchParams } from '../../domain/entities/index.js';

function createEc2Client(profile: string, region: string): EC2Client {
  return new EC2Client({ region, credentials: cachedCredentials(profile) });
}

export async function listInstances(profile: string, region: string): Promise<Ec2Instance[]> {
  const client = createEc2Client(profile, region);
  const instances: Ec2Instance[] = [];
  let NextToken: string | undefined;
  do {
    const response = await client.send(new DescribeInstancesCommand({ NextToken, MaxResults: 1000 }));
    for (const reservation of response.Reservations || []) {
      for (const inst of reservation.Instances || []) {
        instances.push({
          instanceId: inst.InstanceId || '',
          instanceType: inst.InstanceType || '',
          state: inst.State?.Name || '',
          name: inst.Tags?.find((t) => t.Key === 'Name')?.Value || '',
          privateIp: inst.PrivateIpAddress,
          publicIp: inst.PublicIpAddress,
          launchTime: inst.LaunchTime?.toISOString(),
          platform: inst.PlatformDetails,
          availabilityZone: inst.Placement?.AvailabilityZone,
        });
      }
    }
    NextToken = response.NextToken;
  } while (NextToken);
  return instances;
}

async function fetchInstance(client: EC2Client, instanceId: string): Promise<Instance> {
  const response = await client.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
  const inst = response.Reservations?.[0]?.Instances?.[0];
  if (!inst) {
    throw new Error(`Instance not found: ${instanceId}`);
  }
  return inst;
}

export async function getInstanceDetail(profile: string, region: string, instanceId: string): Promise<Ec2InstanceDetail> {
  const client = createEc2Client(profile, region);
  const [inst, terminationAttr] = await Promise.all([
    fetchInstance(client, instanceId),
    client.send(new DescribeInstanceAttributeCommand({ InstanceId: instanceId, Attribute: 'disableApiTermination' })).catch(() => undefined),
  ]);

  return {
    instanceId: inst.InstanceId || instanceId,
    instanceType: inst.InstanceType || '',
    state: inst.State?.Name || '',
    name: inst.Tags?.find((t) => t.Key === 'Name')?.Value || '',
    privateIp: inst.PrivateIpAddress,
    publicIp: inst.PublicIpAddress,
    launchTime: inst.LaunchTime?.toISOString(),
    platform: inst.PlatformDetails,
    availabilityZone: inst.Placement?.AvailabilityZone,
    imageId: inst.ImageId,
    keyName: inst.KeyName,
    vpcId: inst.VpcId,
    subnetId: inst.SubnetId,
    rootDeviceType: inst.RootDeviceType,
    monitoringEnabled: inst.Monitoring?.State === 'enabled',
    disableApiTermination: terminationAttr?.DisableApiTermination?.Value ?? false,
    iamInstanceProfileArn: inst.IamInstanceProfile?.Arn,
    securityGroups: (inst.SecurityGroups || []).map((g) => ({ groupId: g.GroupId || '', groupName: g.GroupName || '' })),
    tags: (inst.Tags || []).map((t) => ({ key: t.Key || '', value: t.Value || '' })),
    architecture: inst.Architecture,
    privateDnsName: inst.PrivateDnsName || undefined,
    publicDnsName: inst.PublicDnsName || undefined,
    rootDeviceName: inst.RootDeviceName,
    ebsOptimized: inst.EbsOptimized,
    hostname: inst.PrivateDnsNameOptions?.HostnameType,
    blockDevices: (inst.BlockDeviceMappings || []).map((b) => ({
      deviceName: b.DeviceName || '',
      volumeId: b.Ebs?.VolumeId,
      status: b.Ebs?.Status,
      attachTime: b.Ebs?.AttachTime?.toISOString(),
      deleteOnTermination: b.Ebs?.DeleteOnTermination ?? false,
    })),
    networkInterfaces: (inst.NetworkInterfaces || []).map((n) => ({
      networkInterfaceId: n.NetworkInterfaceId || '',
      description: n.Description || undefined,
      privateIp: n.PrivateIpAddress,
      publicIp: n.Association?.PublicIp,
      macAddress: n.MacAddress,
      subnetId: n.SubnetId,
      status: n.Status,
    })),
  };
}

export type Ec2InstanceStateAction = 'start' | 'stop' | 'reboot' | 'terminate';

export async function setInstanceState(profile: string, region: string, instanceId: string, action: Ec2InstanceStateAction): Promise<void> {
  const client = createEc2Client(profile, region);
  switch (action) {
    case 'start':
      await client.send(new StartInstancesCommand({ InstanceIds: [instanceId] }));
      break;
    case 'stop':
      await client.send(new StopInstancesCommand({ InstanceIds: [instanceId] }));
      break;
    case 'reboot':
      await client.send(new RebootInstancesCommand({ InstanceIds: [instanceId] }));
      break;
    case 'terminate':
      await client.send(new TerminateInstancesCommand({ InstanceIds: [instanceId] }));
      break;
  }
}

// Only takes effect while the instance is stopped - AWS itself rejects this
// on a running instance (IncorrectInstanceState), surfaced as a normal API
// error rather than pre-validated here.
export async function setInstanceType(profile: string, region: string, instanceId: string, instanceType: string): Promise<Ec2InstanceDetail> {
  const client = createEc2Client(profile, region);
  await client.send(new ModifyInstanceAttributeCommand({ InstanceId: instanceId, InstanceType: { Value: instanceType } }));
  return getInstanceDetail(profile, region, instanceId);
}

export async function setTerminationProtection(profile: string, region: string, instanceId: string, enabled: boolean): Promise<Ec2InstanceDetail> {
  const client = createEc2Client(profile, region);
  await client.send(new ModifyInstanceAttributeCommand({ InstanceId: instanceId, DisableApiTermination: { Value: enabled } }));
  return getInstanceDetail(profile, region, instanceId);
}

export async function setMonitoring(profile: string, region: string, instanceId: string, enabled: boolean): Promise<Ec2InstanceDetail> {
  const client = createEc2Client(profile, region);
  await client.send(
    enabled ? new MonitorInstancesCommand({ InstanceIds: [instanceId] }) : new UnmonitorInstancesCommand({ InstanceIds: [instanceId] })
  );
  return getInstanceDetail(profile, region, instanceId);
}

export async function addInstanceTag(profile: string, region: string, instanceId: string, key: string, value: string): Promise<Ec2InstanceDetail> {
  const client = createEc2Client(profile, region);
  await client.send(new CreateTagsCommand({ Resources: [instanceId], Tags: [{ Key: key, Value: value }] }));
  return getInstanceDetail(profile, region, instanceId);
}

export async function removeInstanceTag(profile: string, region: string, instanceId: string, key: string): Promise<Ec2InstanceDetail> {
  const client = createEc2Client(profile, region);
  await client.send(new DeleteTagsCommand({ Resources: [instanceId], Tags: [{ Key: key }] }));
  return getInstanceDetail(profile, region, instanceId);
}

export async function listKeyPairs(profile: string, region: string): Promise<Ec2KeyPair[]> {
  const client = createEc2Client(profile, region);
  const response = await client.send(new DescribeKeyPairsCommand({}));
  return (response.KeyPairs || []).map((k) => ({ keyName: k.KeyName || '', keyPairId: k.KeyPairId }));
}

// A minimal, power-user launch (AMI ID + instance type typed in by hand,
// not a guided wizard) - a full "Launch Instance" experience needs an AMI
// browser, VPC/subnet picker, storage config, etc. that's out of scope here.
export async function launchInstance(profile: string, region: string, params: Ec2LaunchParams): Promise<Ec2InstanceDetail> {
  const client = createEc2Client(profile, region);
  const response = await client.send(
    new RunInstancesCommand({
      ImageId: params.imageId,
      // The SDK types InstanceType as a huge closed enum; users type
      // whatever they need (e.g. "t3.micro") and AWS itself validates it.
      InstanceType: params.instanceType as ConstructorParameters<typeof RunInstancesCommand>[0]['InstanceType'],
      MinCount: 1,
      MaxCount: 1,
      KeyName: params.keyName || undefined,
      SecurityGroupIds: params.securityGroupIds?.length ? params.securityGroupIds : undefined,
      SubnetId: params.subnetId || undefined,
      TagSpecifications: params.name
        ? [{ ResourceType: 'instance', Tags: [{ Key: 'Name', Value: params.name }] }]
        : undefined,
    })
  );
  const instanceId = response.Instances?.[0]?.InstanceId;
  if (!instanceId) {
    throw new Error('RunInstances did not return an instance ID');
  }
  return getInstanceDetail(profile, region, instanceId);
}
