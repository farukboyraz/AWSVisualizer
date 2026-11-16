import {
  ServiceDiscoveryClient,
  ListNamespacesCommand,
  ListServicesCommand,
  GetNamespaceCommand,
  GetServiceCommand,
  ListInstancesCommand,
  GetInstancesHealthStatusCommand,
  ListTagsForResourceCommand,
  TagResourceCommand,
  UntagResourceCommand,
  type NamespaceSummary,
  type ServiceSummary,
} from '@aws-sdk/client-servicediscovery';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, tagList, httpError } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new ServiceDiscoveryClient({ region: r, credentials: cachedCredentials(p) });

const typeName = (t?: string) => (t === 'DNS_PUBLIC' ? 'Public DNS' : t === 'DNS_PRIVATE' ? 'Private DNS' : t === 'HTTP' ? 'API calls only' : t);

async function allNamespaces(c: ServiceDiscoveryClient): Promise<NamespaceSummary[]> {
  const out: NamespaceSummary[] = [];
  let NextToken: string | undefined;
  do {
    const res = await c.send(new ListNamespacesCommand({ NextToken }));
    out.push(...(res.Namespaces || []));
    NextToken = res.NextToken;
  } while (NextToken);
  return out;
}

async function servicesOf(c: ServiceDiscoveryClient, namespaceId?: string): Promise<ServiceSummary[]> {
  const out: ServiceSummary[] = [];
  let NextToken: string | undefined;
  do {
    const res = await c.send(new ListServicesCommand({ NextToken, Filters: namespaceId ? [{ Name: 'NAMESPACE_ID', Values: [namespaceId], Condition: 'EQ' }] : undefined }));
    out.push(...(res.Services || []));
    NextToken = res.NextToken;
  } while (NextToken);
  return out;
}

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const namespaces = await allNamespaces(c);
  const services = await Promise.all(namespaces.map((n) => servicesOf(c, n.Id).catch(() => [] as ServiceSummary[])));
  const out: PageSummary[] = [];
  namespaces
    .map((n, i) => [n, services[i]] as const)
    .sort(([a], [b]) => (a.Name || '').localeCompare(b.Name || ''))
    .forEach(([n, svcs]) => {
      out.push({ id: `ns:${n.Id}`, name: n.Name || '', group: n.Name, info: `Namespace · ${typeName(n.Type)} · ${n.ServiceCount ?? svcs.length} services` });
      for (const s of svcs.sort((a, b) => (a.Name || '').localeCompare(b.Name || ''))) {
        out.push({ id: `svc:${s.Id}`, name: s.Name || '', group: n.Name, info: `Service · ${s.InstanceCount ?? 0} instances` });
      }
    });
  return out;
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rid] = splitId(id);
  const errors: string[] = [];

  if (kind === 'ns') {
    const n = (await c.send(new GetNamespaceCommand({ Id: rid }))).Namespace;
    if (!n) throw httpError(`Namespace not found: ${rid}`, 404);
    const { svcs, tags } = await settle({ svcs: servicesOf(c, rid), tags: c.send(new ListTagsForResourceCommand({ ResourceARN: n.Arn })) }, errors);
    return {
      id,
      title: n.Name || rid,
      subtitle: `${typeName(n.Type)} namespace`,
      arn: n.Arn,
      tabs: [
        tab('Namespace', {
          sections: [
            section('Details', [
              ['Namespace ID', rid],
              ['Instance discovery', typeName(n.Type)],
              ['Description', n.Description],
              ['Route 53 hosted zone', n.Properties?.DnsProperties?.HostedZoneId],
              ['SOA TTL', n.Properties?.DnsProperties?.SOA?.TTL !== undefined ? `${n.Properties.DnsProperties.SOA.TTL} s` : undefined],
              ['HTTP name', n.Properties?.HttpProperties?.HttpName],
              ['Created', n.CreateDate],
            ]),
          ],
          tables: [
            table(['Service', 'Instances', 'DNS records', 'Health check'], (svcs || []).map((s) => [s.Name, s.InstanceCount, (s.DnsConfig?.DnsRecords || []).map((r) => `${r.Type} (TTL ${r.TTL})`), s.HealthCheckConfig?.Type ?? (s.HealthCheckCustomConfig ? 'Custom' : 'None')]), { title: 'Services', emptyMessage: 'No services in this namespace' }),
          ],
        }),
      ],
      tags: tags ? tagList(tags.Tags) : undefined,
      actions: [],
      errors,
    };
  }

  if (kind === 'svc') {
    const s = (await c.send(new GetServiceCommand({ Id: rid }))).Service;
    if (!s) throw httpError(`Service not found: ${rid}`, 404);
    const { instances, health, tags, ns } = await settle(
      {
        instances: (async () => {
          const out: { Id?: string; Attributes?: Record<string, string> }[] = [];
          let NextToken: string | undefined;
          do {
            const res = await c.send(new ListInstancesCommand({ ServiceId: rid, NextToken }));
            out.push(...(res.Instances || []));
            NextToken = res.NextToken;
          } while (NextToken && out.length < 1000);
          return out;
        })(),
        health: s.HealthCheckConfig || s.HealthCheckCustomConfig ? c.send(new GetInstancesHealthStatusCommand({ ServiceId: rid })) : Promise.resolve(undefined),
        tags: c.send(new ListTagsForResourceCommand({ ResourceARN: s.Arn })),
        ns: s.NamespaceId ? c.send(new GetNamespaceCommand({ Id: s.NamespaceId })) : Promise.resolve(undefined),
      },
      errors,
    );
    const nsName = ns?.Namespace?.Name;
    const hc = s.HealthCheckConfig;
    return {
      id,
      title: s.Name || rid,
      subtitle: nsName ? `${s.Name}.${nsName}` : undefined,
      arn: s.Arn,
      tabs: [
        tab('Service', {
          sections: [
            section('Details', [
              ['Service ID', rid],
              ['Namespace', nsName],
              ['Description', s.Description],
              ['Instances', s.InstanceCount],
              ['Routing policy', s.DnsConfig?.RoutingPolicy],
              ['DNS records', (s.DnsConfig?.DnsRecords || []).map((r) => `${r.Type} (TTL ${r.TTL})`)],
              ['Health check', hc ? `${hc.Type} ${hc.ResourcePath ?? ''} · failure threshold ${hc.FailureThreshold ?? '-'}`.trim() : s.HealthCheckCustomConfig ? 'Custom (reported by the client)' : 'None'],
              ['Created', s.CreateDate],
            ]),
            ...(nsName && s.DnsConfig ? [{ title: 'Discover', settings: [], copyable: [{ label: 'DNS name', value: `${s.Name}.${nsName}` }, { label: 'CLI', value: `aws servicediscovery discover-instances --namespace-name ${nsName} --service-name ${s.Name}` }] }] : []),
          ],
        }),
        tab('Service instances', {
          tables: [
            table(
              ['Instance ID', 'IPv4', 'Port', 'Other attributes', 'Health'],
              (instances || []).map((i) => {
                const { AWS_INSTANCE_IPV4: ip, AWS_INSTANCE_PORT: port, ...rest } = i.Attributes || {};
                return [i.Id, ip, port, Object.entries(rest).map(([k, v]) => `${k}=${v}`), health?.Status?.[i.Id || ''] ?? (health ? 'UNKNOWN' : 'No health check')];
              }),
              { statusColumn: 4, emptyMessage: 'No registered instances' },
            ),
          ],
        }),
      ],
      tags: tags ? tagList(tags.Tags) : undefined,
      actions: [],
      errors,
    };
  }
  throw httpError(`Unknown Cloud Map id: ${id}`, 400);
}

export const cloudMapAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, _id, arn, key, value) {
    await client(profile, region).send(new TagResourceCommand({ ResourceARN: arn, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, _id, arn, key) {
    await client(profile, region).send(new UntagResourceCommand({ ResourceARN: arn, TagKeys: [key] }));
  },
};
