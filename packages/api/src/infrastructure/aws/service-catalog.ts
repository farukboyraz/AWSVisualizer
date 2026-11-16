import {
  ServiceCatalogClient,
  ListPortfoliosCommand,
  DescribePortfolioCommand,
  SearchProductsAsAdminCommand,
  ListPrincipalsForPortfolioCommand,
  ListConstraintsForPortfolioCommand,
  DescribePortfolioSharesCommand,
  DescribeProductAsAdminCommand,
  ListPortfoliosForProductCommand,
  SearchProvisionedProductsCommand,
  DescribeProvisionedProductCommand,
  GetProvisionedProductOutputsCommand,
  ListRecordHistoryCommand,
  UpdatePortfolioCommand,
  UpdateProductCommand,
} from '@aws-sdk/client-service-catalog';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new ServiceCatalogClient({ region: r, credentials: cachedCredentials(p) });

const products = (c: ServiceCatalogClient, PortfolioId?: string) =>
  pageAll((PageToken) => c.send(new SearchProductsAsAdminCommand({ PageToken, PortfolioId })), (r) => r.ProductViewDetails, (r) => r.NextPageToken);

const provisioned = (c: ServiceCatalogClient) =>
  pageAll((PageToken) => c.send(new SearchProvisionedProductsCommand({ PageToken, AccessLevelFilter: { Key: 'Account', Value: 'self' } })), (r) => r.ProvisionedProducts, (r) => r.NextPageToken);

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const [portfolios, prods, pps] = await Promise.all([
    pageAll((PageToken) => c.send(new ListPortfoliosCommand({ PageToken })), (r) => r.PortfolioDetails, (r) => r.NextPageToken),
    products(c).catch(() => []),
    provisioned(c).catch(() => []),
  ]);
  const byName = (a: PageSummary, b: PageSummary) => a.name.localeCompare(b.name);
  return [
    ...portfolios.map((p) => ({ id: `pf:${p.Id}`, name: p.DisplayName || p.Id || '', group: 'Portfolios', info: [p.ProviderName, p.Description].filter(Boolean).join(' · ') })).sort(byName),
    ...prods.map((p) => ({ id: `prod:${p.ProductViewSummary?.ProductId}`, name: p.ProductViewSummary?.Name || '', group: 'Products', status: p.Status, info: [p.ProductViewSummary?.Type, p.ProductViewSummary?.Owner].filter(Boolean).join(' · ') })).sort(byName),
    ...pps.map((p) => ({ id: `pp:${p.Id}`, name: p.Name || p.Id || '', group: 'Provisioned products', status: p.Status, info: [p.ProductName, p.ProvisioningArtifactName].filter(Boolean).join(' · ') })).sort(byName),
  ];
}

async function portfolioPage(c: ServiceCatalogClient, id: string, portfolioId: string): Promise<ResourcePage> {
  const d = await c.send(new DescribePortfolioCommand({ Id: portfolioId }));
  const p = d.PortfolioDetail;
  if (!p) throw httpError(`Portfolio not found: ${portfolioId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      products: products(c, portfolioId),
      principals: pageAll((PageToken) => c.send(new ListPrincipalsForPortfolioCommand({ PortfolioId: portfolioId, PageToken })), (r) => r.Principals, (r) => r.NextPageToken),
      constraints: pageAll((PageToken) => c.send(new ListConstraintsForPortfolioCommand({ PortfolioId: portfolioId, PageToken })), (r) => r.ConstraintDetails, (r) => r.NextPageToken),
      accountShares: pageAll((PageToken) => c.send(new DescribePortfolioSharesCommand({ PortfolioId: portfolioId, Type: 'ACCOUNT', PageToken })), (r) => r.PortfolioShareDetails, (r) => r.NextPageToken),
    },
    errors,
  );
  return {
    id,
    title: p.DisplayName || portfolioId,
    subtitle: p.Description || 'Portfolio',
    arn: p.ARN,
    tabs: [
      tab('Details', {
        sections: [section('Portfolio', [['Portfolio ID', p.Id], ['Name', p.DisplayName], ['Provider', p.ProviderName], ['Description', p.Description], ['Created', p.CreatedTime], ['Budgets', (d.Budgets || []).map((b) => b.BudgetName)]])],
        tables: [table(['Key', 'Value', 'Active'], (d.TagOptions || []).map((t) => [t.Key, t.Value, t.Active]), { title: 'TagOptions', emptyMessage: 'No TagOptions' })],
      }),
      tab('Products', {
        tables: [table(['Product', 'Type', 'Owner', 'Status'], (parts.products || []).map((x) => [x.ProductViewSummary?.Name, x.ProductViewSummary?.Type, x.ProductViewSummary?.Owner, x.Status]), { statusColumn: 3, emptyMessage: 'No products' })],
      }),
      tab('Access', {
        tables: [
          table(['Principal', 'Type'], (parts.principals || []).map((x) => [x.PrincipalARN, x.PrincipalType]), { title: 'Principals', emptyMessage: 'No principals' }),
          table(['Account', 'Accepted', 'Share TagOptions', 'Share principals'], (parts.accountShares || []).map((x) => [x.PrincipalId, x.Accepted, x.ShareTagOptions, x.SharePrincipals]), { title: 'Shared with accounts', emptyMessage: 'Not shared' }),
        ],
      }),
      tab('Constraints', {
        tables: [table(['Type', 'Owner', 'Product', 'Description'], (parts.constraints || []).map((x) => [x.Type, x.Owner, x.ProductId, x.Description]), { emptyMessage: 'No constraints' })],
      }),
    ],
    tags: tagList(d.Tags),
    actions: [],
    errors,
  };
}

async function productPage(c: ServiceCatalogClient, id: string, productId: string): Promise<ResourcePage> {
  const d = await c.send(new DescribeProductAsAdminCommand({ Id: productId }));
  const v = d.ProductViewDetail;
  const s = v?.ProductViewSummary;
  if (!v) throw httpError(`Product not found: ${productId}`, 404);
  const errors: string[] = [];
  const { portfolios } = await settle({ portfolios: pageAll((PageToken) => c.send(new ListPortfoliosForProductCommand({ ProductId: productId, PageToken })), (r) => r.PortfolioDetails, (r) => r.NextPageToken) }, errors);
  return {
    id,
    title: s?.Name || productId,
    subtitle: s?.ShortDescription || `${s?.Type ?? ''} product`,
    status: v.Status,
    arn: v.ProductARN,
    tabs: [
      tab('Details', {
        sections: [
          section('Product', [
            ['Product ID', productId],
            ['Name', s?.Name],
            ['Owner', s?.Owner],
            ['Distributor', s?.Distributor],
            ['Type', s?.Type],
            ['Status', v.Status],
            ['Support email', s?.SupportEmail],
            ['Support URL', s?.SupportUrl],
            ['Created', v.CreatedTime],
            ['Source connection', v.SourceConnection?.Type],
          ]),
        ],
      }),
      tab('Versions', {
        tables: [table(['Version', 'Description', 'Created', 'ID'], (d.ProvisioningArtifactSummaries || []).map((a) => [a.Name, a.Description, a.CreatedTime, a.Id]), { emptyMessage: 'No versions' })],
      }),
      tab('Portfolios', {
        tables: [table(['Portfolio', 'Provider', 'ID'], (portfolios || []).map((p) => [p.DisplayName, p.ProviderName, p.Id]), { emptyMessage: 'Not in any portfolio' })],
      }),
    ],
    tags: tagList(d.Tags),
    actions: [],
    errors,
  };
}

async function provisionedPage(c: ServiceCatalogClient, id: string, ppId: string): Promise<ResourcePage> {
  const p = (await c.send(new DescribeProvisionedProductCommand({ Id: ppId }))).ProvisionedProductDetail;
  if (!p) throw httpError(`Provisioned product not found: ${ppId}`, 404);
  const errors: string[] = [];
  const parts = await settle(
    {
      outputs: pageAll((PageToken) => c.send(new GetProvisionedProductOutputsCommand({ ProvisionedProductId: ppId, PageToken })), (r) => r.Outputs, (r) => r.NextPageToken),
      history: c.send(new ListRecordHistoryCommand({ SearchFilter: { Key: 'provisionedproduct', Value: ppId }, PageSize: 25 })),
    },
    errors,
  );
  return {
    id,
    title: p.Name || ppId,
    subtitle: 'Provisioned product',
    status: p.Status,
    arn: p.Arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Provisioned product', [
            ['ID', p.Id],
            ['Name', p.Name],
            ['Type', p.Type],
            ['Status', p.Status],
            ['Status message', p.StatusMessage],
            ['Product', p.ProductId],
            ['Version', p.ProvisioningArtifactId],
            ['Launch role', p.LaunchRoleArn],
            ['Created', p.CreatedTime],
            ['Last record', p.LastRecordId],
          ]),
        ],
      }),
      tab('Outputs', {
        tables: [table(['Key', 'Value', 'Description'], (parts.outputs || []).map((o) => [o.OutputKey, o.OutputValue, o.Description]), { emptyMessage: 'No outputs' })],
      }),
      tab('History', {
        tables: [table(['Record', 'Type', 'Status', 'Created', 'Updated'], (parts.history?.RecordDetails || []).map((r) => [r.RecordId, r.RecordType, r.Status, r.CreatedTime, r.UpdatedTime]), { statusColumn: 2, emptyMessage: 'No history' })],
      }),
    ],
    actions: [],
    errors,
  };
}

async function detail(profile: string, region: string, id: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const [kind, rest] = splitId(id);
  if (kind === 'pf') return portfolioPage(c, id, rest);
  if (kind === 'prod') return productPage(c, id, rest);
  if (kind === 'pp') return provisionedPage(c, id, rest);
  throw httpError(`Unknown Service Catalog page: ${id}`, 400);
}

export const serviceCatalogAdapter: PageServiceAdapter = {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    const [kind, rest] = splitId(id);
    const c = client(profile, region);
    const AddTags = [{ Key: key, Value: value }];
    if (kind === 'pf') await c.send(new UpdatePortfolioCommand({ Id: rest, AddTags }));
    else if (kind === 'prod') await c.send(new UpdateProductCommand({ Id: rest, AddTags }));
    else throw httpError('Provisioned products are tagged through an update in the console', 400);
  },
  async removeTag(profile, region, id, _arn, key) {
    const [kind, rest] = splitId(id);
    const c = client(profile, region);
    if (kind === 'pf') await c.send(new UpdatePortfolioCommand({ Id: rest, RemoveTags: [key] }));
    else if (kind === 'prod') await c.send(new UpdateProductCommand({ Id: rest, RemoveTags: [key] }));
    else throw httpError('Provisioned products are tagged through an update in the console', 400);
  },
  countable: (row) => !row.id.startsWith('pp:'),
};
