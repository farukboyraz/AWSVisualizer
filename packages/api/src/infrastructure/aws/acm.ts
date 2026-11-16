import {
  ACMClient,
  ListCertificatesCommand,
  DescribeCertificateCommand,
  ListTagsForCertificateCommand,
  AddTagsToCertificateCommand,
  RemoveTagsFromCertificateCommand,
  type KeyAlgorithm,
} from '@aws-sdk/client-acm';
import { cachedCredentials } from './credential-cache.js';
import type { ResourcePage, PageSummary } from '../../domain/entities/index.js';
import { section, table, tab, settle, httpError, pageAll, tagList } from './page-common.js';
import { singleKind, type PageServiceAdapter } from './page-adapter.js';

const client = (p: string, r: string) => new ACMClient({ region: r, credentials: cachedCredentials(p) });

/** ListCertificates returns only RSA-2048 certificates unless every key type is asked for. */
const ALL_KEY_TYPES: KeyAlgorithm[] = ['RSA_1024', 'RSA_2048', 'RSA_3072', 'RSA_4096', 'EC_prime256v1', 'EC_secp384r1', 'EC_secp521r1'];

const day = (d?: Date) => d?.toISOString().slice(0, 10);

async function list(profile: string, region: string): Promise<PageSummary[]> {
  const c = client(profile, region);
  const certs = await pageAll((NextToken) => c.send(new ListCertificatesCommand({ NextToken, Includes: { keyTypes: ALL_KEY_TYPES } })), (r) => r.CertificateSummaryList, (r) => r.NextToken);
  return certs
    .map((x) => ({
      id: x.CertificateArn || '',
      name: x.DomainName || x.CertificateArn || '',
      status: x.Status,
      info: [x.Type === 'AMAZON_ISSUED' ? 'Amazon issued' : x.Type === 'IMPORTED' ? 'Imported' : x.Type, x.NotAfter && `expires ${day(x.NotAfter)}`, x.InUse ? 'in use' : 'not in use'].filter(Boolean).join(' · '),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function detail(profile: string, region: string, arn: string): Promise<ResourcePage> {
  const c = client(profile, region);
  const cert = (await c.send(new DescribeCertificateCommand({ CertificateArn: arn }))).Certificate;
  if (!cert) throw httpError(`Certificate not found: ${arn}`, 404);
  const errors: string[] = [];
  const { tags } = await settle({ tags: c.send(new ListTagsForCertificateCommand({ CertificateArn: arn })) }, errors);
  const daysLeft = cert.NotAfter ? Math.floor((cert.NotAfter.getTime() - Date.now()) / 86_400_000) : undefined;
  const renewal = cert.RenewalSummary;
  return {
    id: arn,
    title: cert.DomainName || arn,
    subtitle: cert.Type === 'IMPORTED' ? 'Imported certificate' : cert.Type === 'PRIVATE' ? 'Private certificate' : 'Amazon-issued certificate',
    status: cert.Status,
    arn,
    tabs: [
      tab('Details', {
        sections: [
          section('Certificate', [
            ['Domain', cert.DomainName],
            ['Status', cert.Status],
            ['Failure reason', cert.FailureReason],
            ['Type', cert.Type],
            ['Key algorithm', cert.KeyAlgorithm],
            ['Signature algorithm', cert.SignatureAlgorithm],
            ['Serial number', cert.Serial],
            ['Issuer', cert.Issuer],
            ['Subject', cert.Subject],
            ['Not before', cert.NotBefore],
            ['Not after', cert.NotAfter],
            ['Days until expiry', daysLeft],
            ['Requested', cert.CreatedAt],
            ['Issued', cert.IssuedAt],
            ['Imported', cert.ImportedAt],
            ['Revoked', cert.RevokedAt && `${cert.RevokedAt.toISOString()} (${cert.RevocationReason})`],
            ['Certificate transparency logging', cert.Options?.CertificateTransparencyLoggingPreference],
            ['Extended key usages', (cert.ExtendedKeyUsages || []).map((u) => u.Name)],
            ['Key usages', (cert.KeyUsages || []).map((u) => u.Name)],
            ['Private CA', cert.CertificateAuthorityArn],
          ]),
          section('Renewal', [
            ['Renewal eligibility', cert.RenewalEligibility],
            ['Renewal status', renewal?.RenewalStatus],
            ['Renewal status reason', renewal?.RenewalStatusReason],
            ['Renewal updated', renewal?.UpdatedAt],
          ]),
        ],
        tables: [table(['Subject alternative name'], (cert.SubjectAlternativeNames || []).map((n) => [n]), { title: 'Domain names', emptyMessage: 'No alternative names' })],
      }),
      tab('Domain validation', {
        tables: [
          table(
            ['Domain', 'Status', 'Method', 'CNAME name', 'CNAME value'],
            (cert.DomainValidationOptions || []).map((d) => [d.DomainName, d.ValidationStatus, d.ValidationMethod, d.ResourceRecord?.Name, d.ResourceRecord?.Value]),
            { statusColumn: 1, emptyMessage: cert.Type === 'IMPORTED' ? 'Imported certificates have no ACM validation' : 'No validation records' },
          ),
        ],
      }),
      tab('Associated resources', {
        tables: [table(['Resource'], (cert.InUseBy || []).map((r) => [r]), { emptyMessage: 'Not used by any AWS resource' })],
      }),
    ],
    tags: tagList(tags?.Tags),
    actions: [],
    errors,
  };
}

export const acmAdapter: PageServiceAdapter = singleKind('cert', {
  list,
  detail,
  async addTag(profile, region, id, _arn, key, value) {
    await client(profile, region).send(new AddTagsToCertificateCommand({ CertificateArn: id, Tags: [{ Key: key, Value: value }] }));
  },
  async removeTag(profile, region, id, _arn, key) {
    // ACM removes a tag only when the value matches too (or is omitted) - omit it.
    await client(profile, region).send(new RemoveTagsFromCertificateCommand({ CertificateArn: id, Tags: [{ Key: key }] }));
  },
});
