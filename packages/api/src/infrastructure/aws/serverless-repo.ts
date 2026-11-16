import {
  ServerlessApplicationRepositoryClient,
  ListApplicationsCommand,
  GetApplicationCommand,
  ListApplicationVersionsCommand,
  GetApplicationPolicyCommand,
} from '@aws-sdk/client-serverlessapplicationrepository';
import { cachedCredentials } from './credential-cache.js';
import type { SarApplication, SarApplicationDetail, SarVersion } from '../../domain/entities/index.js';

function createClient(profile: string, region: string): ServerlessApplicationRepositoryClient {
  return new ServerlessApplicationRepositoryClient({ region, credentials: cachedCredentials(profile) });
}

/** SAR returns creation times as ISO strings already. */
function errorMessage(err: unknown): string {
  return (err as { message?: string })?.message || String(err);
}

/** Applications this account published (what the console's "Published applications" lists). */
export async function listSarApplications(profile: string, region: string): Promise<SarApplication[]> {
  const client = createClient(profile, region);
  const out: SarApplication[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new ListApplicationsCommand({ NextToken, MaxItems: 100 }));
    for (const a of res.Applications || []) {
      out.push({
        applicationId: a.ApplicationId || '',
        name: a.Name || '',
        author: a.Author,
        description: a.Description,
        creationTime: a.CreationTime,
        homePageUrl: a.HomePageUrl,
        labels: a.Labels || [],
        spdxLicenseId: a.SpdxLicenseId,
      });
    }
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

async function versions(client: ServerlessApplicationRepositoryClient, applicationId: string): Promise<SarVersion[]> {
  const out: SarVersion[] = [];
  let NextToken: string | undefined;
  do {
    const res = await client.send(new ListApplicationVersionsCommand({ ApplicationId: applicationId, NextToken, MaxItems: 100 }));
    for (const v of res.Versions || []) {
      out.push({ semanticVersion: v.SemanticVersion || '', creationTime: v.CreationTime, sourceCodeUrl: v.SourceCodeUrl });
    }
    NextToken = res.NextToken;
  } while (NextToken);
  return out.sort((a, b) => (b.creationTime || '').localeCompare(a.creationTime || ''));
}

export async function getSarApplicationDetail(profile: string, region: string, applicationId: string): Promise<SarApplicationDetail> {
  const client = createClient(profile, region);
  const [app, versionList, policyResult] = await Promise.all([
    client.send(new GetApplicationCommand({ ApplicationId: applicationId })),
    versions(client, applicationId),
    client.send(new GetApplicationPolicyCommand({ ApplicationId: applicationId })).then(
      (res) => ({ ok: true as const, res }),
      (err) => ({ ok: false as const, err })
    ),
  ]);
  const v = app.Version;

  return {
    applicationId: app.ApplicationId || applicationId,
    name: app.Name || '',
    author: app.Author,
    description: app.Description,
    creationTime: app.CreationTime,
    homePageUrl: app.HomePageUrl,
    labels: app.Labels || [],
    spdxLicenseId: app.SpdxLicenseId,
    isVerifiedAuthor: app.IsVerifiedAuthor ?? false,
    verifiedAuthorUrl: app.VerifiedAuthorUrl,
    licenseUrl: app.LicenseUrl,
    readmeUrl: app.ReadmeUrl,
    semanticVersion: v?.SemanticVersion,
    templateUrl: v?.TemplateUrl,
    sourceCodeUrl: v?.SourceCodeUrl,
    requiredCapabilities: v?.RequiredCapabilities || [],
    resourcesSupported: v?.ResourcesSupported,
    parameters: (v?.ParameterDefinitions || []).map((p) => ({
      name: p.Name || '',
      type: p.Type,
      defaultValue: p.DefaultValue,
      description: p.Description,
      allowedValues: p.AllowedValues || [],
    })),
    versions: versionList,
    policy: policyResult.ok
      ? (policyResult.res.Statements || []).map((s) => ({
          statementId: s.StatementId,
          principals: s.Principals || [],
          actions: s.Actions || [],
        }))
      : [],
    policyError: policyResult.ok ? undefined : errorMessage(policyResult.err),
  };
}
