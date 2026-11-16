import { EC2Client, CreateTagsCommand, DeleteTagsCommand } from '@aws-sdk/client-ec2';
import { cachedCredentials } from './credential-cache.js';
import { splitId } from './page-adapter.js';

export const ec2 = (profile: string, region: string) => new EC2Client({ region, credentials: cachedCredentials(profile) });

/**
 * Pages any EC2 Describe* call: `call(token)` returns the response and
 * `pick` the item array.
 */
export async function describeAll<R extends { NextToken?: string }, T>(
  call: (NextToken?: string) => Promise<R>,
  pick: (r: R) => T[] | undefined,
  limit = 5000,
): Promise<T[]> {
  const out: T[] = [];
  let token: string | undefined;
  do {
    const res = await call(token);
    out.push(...(pick(res) || []));
    token = res.NextToken;
  } while (token && out.length < limit);
  return out;
}

export const nameTag = (tags?: { Key?: string; Value?: string }[]) => tags?.find((t) => t.Key === 'Name')?.Value;

/** EC2 tags by resource id; page ids look like `kind:resource-id`. */
export const ec2TagFns = {
  async addTag(profile: string, region: string, id: string, _arn: string, key: string, value: string) {
    await ec2(profile, region).send(new CreateTagsCommand({ Resources: [splitId(id)[1]], Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile: string, region: string, id: string, _arn: string, key: string) {
    await ec2(profile, region).send(new DeleteTagsCommand({ Resources: [splitId(id)[1]], Tags: [{ Key: key }] }));
  },
};

/** "tcp 443", "All traffic", "icmp" - the console's Type/Port column. */
export function portText(protocol?: string, from?: number, to?: number): string {
  if (!protocol || protocol === '-1') return 'All traffic';
  const p = protocol === '6' ? 'tcp' : protocol === '17' ? 'udp' : protocol === '1' ? 'icmp' : protocol;
  if (from === undefined || from === -1) return p;
  return from === to ? `${p} ${from}` : `${p} ${from}-${to}`;
}
