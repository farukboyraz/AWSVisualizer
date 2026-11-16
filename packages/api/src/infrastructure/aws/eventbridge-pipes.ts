import type { Target } from '@aws-sdk/client-eventbridge';
import {
  PipesClient,
  ListPipesCommand,
  DescribePipeCommand,
  TagResourceCommand as PpTag,
  UntagResourceCommand as PpUntag,
} from '@aws-sdk/client-pipes';
import type { PageSummary, PageTab } from '../../domain/entities/index.js';
import { section, tab, httpError, pageAll, tagMap, lastPart, clientConfig, byName } from './page-common.js';
import { splitId, type PageServiceAdapter } from './page-adapter.js';


/** EventBridge Pipes. */
const pp = (p: string, r: string) => new PipesClient(clientConfig(p, r));

export const pipesAdapter: PageServiceAdapter = {
  async list(profile, region) {
    const pipes = await pageAll((NextToken) => pp(profile, region).send(new ListPipesCommand({ NextToken })), (r) => r.Pipes, (r) => r.NextToken);
    return pipes.map((x) => ({ id: `pipe:${x.Name}`, name: x.Name || '', status: x.CurrentState, info: `${lastPart(x.Source)} → ${lastPart(x.Target)}${x.Enrichment ? ` (via ${lastPart(x.Enrichment)})` : ''}` })).sort(byName);
  },
  async detail(profile, region, id) {
    const [kind, name] = splitId(id);
    if (kind !== 'pipe') throw httpError(`Unknown Pipes page: ${id}`, 400);
    const x = await pp(profile, region).send(new DescribePipeCommand({ Name: name }));
    // Source / target parameters hold ARNs and settings (credentials are Secrets Manager ARNs).
    const tabs: PageTab[] = [
      tab('Details', {
        sections: [
          section('Pipe', [
            ['Current state', x.CurrentState],
            ['Desired state', x.DesiredState],
            ['State reason', x.StateReason],
            ['Description', x.Description],
            ['Source', x.Source],
            ['Enrichment', x.Enrichment],
            ['Target', x.Target],
            ['Role', x.RoleArn],
            ['Logging', x.LogConfiguration?.Level],
            ['KMS key', x.KmsKeyIdentifier],
            ['Created', x.CreationTime],
            ['Modified', x.LastModifiedTime],
          ]),
        ],
      }),
    ];
    if (x.SourceParameters) tabs.push(tab('Source settings', { json: JSON.stringify(x.SourceParameters, null, 2) }));
    if (x.TargetParameters) tabs.push(tab('Target settings', { json: JSON.stringify(x.TargetParameters, null, 2) }));
    return { id, title: name, subtitle: 'EventBridge pipe', status: x.CurrentState, arn: x.Arn, tabs, tags: tagMap(x.Tags), actions: [], errors: [] };
  },
  async addTag(profile, region, _id, arn, key, value) {
    if (!arn) throw httpError('Missing ARN', 400);
    await pp(profile, region).send(new PpTag({ resourceArn: arn, tags: { [key]: value } }));
  },
  async removeTag(profile, region, _id, arn, key) {
    if (!arn) throw httpError('Missing ARN', 400);
    await pp(profile, region).send(new PpUntag({ resourceArn: arn, tagKeys: [key] }));
  },
};
