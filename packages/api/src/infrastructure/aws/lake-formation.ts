import {
  LakeFormationClient,
  GetDataLakeSettingsCommand,
  ListResourcesCommand,
  ListPermissionsCommand,
  ListLFTagsCommand,
  type Resource,
  type DataLakePrincipal,
} from '@aws-sdk/client-lakeformation';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, httpError, pageAll, lastPart } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

/**
 * Lake Formation is account-level settings rather than resources, so the
 * list is four fixed pages: settings, registered locations, permissions
 * and LF-Tags. Read-only.
 */
const client = (p: string, r: string) => new LakeFormationClient({ region: r, credentials: cachedCredentials(p) });

const PERMISSION_LIMIT = 500;
const principal = (p?: DataLakePrincipal) => {
  const id = p?.DataLakePrincipalIdentifier;
  if (!id) return '-';
  if (id === 'IAM_ALLOWED_PRINCIPALS') return 'IAMAllowedPrincipals';
  return id.startsWith('arn:') ? `${id.split(':')[5]?.split('/')[0] ?? ''}/${lastPart(id)}` : id;
};

function resourceText(r?: Resource): [string, string] {
  if (!r) return ['-', '-'];
  if (r.Catalog) return ['Catalog', 'Data Catalog'];
  if (r.Database) return ['Database', r.Database.Name ?? '-'];
  if (r.Table) return ['Table', `${r.Table.DatabaseName}.${r.Table.Name ?? (r.Table.TableWildcard ? '*' : '-')}`];
  if (r.TableWithColumns) return ['Columns', `${r.TableWithColumns.DatabaseName}.${r.TableWithColumns.Name} (${(r.TableWithColumns.ColumnNames || []).join(', ') || (r.TableWithColumns.ColumnWildcard ? 'all columns' : '-')})`];
  if (r.DataLocation) return ['Data location', r.DataLocation.ResourceArn ?? '-'];
  if (r.DataCellsFilter) return ['Data filter', `${r.DataCellsFilter.DatabaseName}.${r.DataCellsFilter.TableName}: ${r.DataCellsFilter.Name}`];
  if (r.LFTag) return ['LF-Tag', `${r.LFTag.TagKey}=${(r.LFTag.TagValues || []).join('|')}`];
  if (r.LFTagPolicy) return ['LF-Tag expression', `${r.LFTagPolicy.ResourceType}: ${(r.LFTagPolicy.Expression || []).map((e) => `${e.TagKey}=${(e.TagValues || []).join('|')}`).join(' & ')}`];
  return ['Other', '-'];
}

const PAGES: Record<string, { name: string; info: string }> = {
  settings: { name: 'Data lake settings', info: 'Administrators and default permissions' },
  locations: { name: 'Data lake locations', info: 'Registered S3 locations' },
  permissions: { name: 'Data permissions', info: `Grants (first ${PERMISSION_LIMIT})` },
  tags: { name: 'LF-Tags', info: 'Tag keys and values' },
};

async function list(profile: string, region: string): Promise<PageSummary[]> {
  // One cheap call so a region without access shows an error instead of four empty pages.
  await client(profile, region).send(new GetDataLakeSettingsCommand({}));
  return Object.entries(PAGES).map(([k, p]) => ({ id: `${k}:`, name: p.name, info: p.info }));
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind] = splitId(id);
  const page = PAGES[kind];
  if (!page) throw httpError(`Unknown Lake Formation page: ${id}`, 400);
  const base = { id, title: page.name, subtitle: 'Lake Formation', actions: [], errors: [] as string[] };

  if (kind === 'settings') {
    const s = (await c.send(new GetDataLakeSettingsCommand({}))).DataLakeSettings;
    const defaults = (list?: { Principal?: DataLakePrincipal; Permissions?: string[] }[]) => (list || []).map((p) => `${principal(p.Principal)}: ${(p.Permissions || []).join(', ')}`);
    return {
      ...base,
      tabs: [
        tab('Settings', {
          sections: [
            section('Administrators', [['Data lake administrators', (s?.DataLakeAdmins || []).map(principal)], ['Read-only administrators', (s?.ReadOnlyAdmins || []).map(principal)]]),
            section('Defaults for new databases and tables', [['New databases', defaults(s?.CreateDatabaseDefaultPermissions)], ['New tables', defaults(s?.CreateTableDefaultPermissions)]], {
              note: 'IAMAllowedPrincipals with ALL here means new resources still use IAM-only access control.',
            }),
            section('External access', [['Trusted resource owners', s?.TrustedResourceOwners], ['External data filtering', s?.AllowExternalDataFiltering], ['Full table external access', s?.AllowFullTableExternalDataAccess], ['Session tag values', s?.AuthorizedSessionTagValueList]]),
          ],
          tables: [table(['Parameter', 'Value'], Object.entries(s?.Parameters || {}), { title: 'Parameters', emptyMessage: 'No parameters' })],
        }),
      ],
    };
  }
  if (kind === 'locations') {
    const rows = await pageAll((NextToken) => c.send(new ListResourcesCommand({ NextToken })), (r) => r.ResourceInfoList, (r) => r.NextToken);
    return {
      ...base,
      tabs: [tab('Locations', { tables: [table(['Location', 'Role', 'Hybrid access', 'Federation', 'Modified'], rows.map((r) => [r.ResourceArn, r.RoleArn, r.HybridAccessEnabled, r.WithFederation, r.LastModified]), { emptyMessage: 'No registered locations' })] })],
    };
  }
  if (kind === 'permissions') {
    const rows = await pageAll((NextToken) => c.send(new ListPermissionsCommand({ NextToken, MaxResults: 100 })), (r) => r.PrincipalResourcePermissions, (r) => r.NextToken, PERMISSION_LIMIT);
    return {
      ...base,
      tabs: [
        tab('Permissions', {
          tables: [
            table(['Principal', 'Resource type', 'Resource', 'Permissions', 'Grantable'], rows.map((p) => [principal(p.Principal), ...resourceText(p.Resource), (p.Permissions || []).join(', '), (p.PermissionsWithGrantOption || []).join(', ')]), {
              title: rows.length >= PERMISSION_LIMIT ? `First ${PERMISSION_LIMIT} grants` : `${rows.length} grants`,
              emptyMessage: 'No permissions',
            }),
          ],
        }),
      ],
    };
  }
  const tags = await pageAll((NextToken) => c.send(new ListLFTagsCommand({ NextToken })), (r) => r.LFTags, (r) => r.NextToken);
  return { ...base, tabs: [tab('LF-Tags', { tables: [table(['Key', 'Values', 'Catalog'], tags.map((t) => [t.TagKey, t.TagValues, t.CatalogId]), { emptyMessage: 'No LF-Tags' })] })] };
}

export const lakeFormationAdapter: PageServiceAdapter = { list, detail, uncounted: true };
