import { CodeCommitClient, GetBranchCommand, GetCommitCommand, ListBranchesCommand, ListPullRequestsCommand, ListRepositoriesCommand } from '@aws-sdk/client-codecommit';
import { clientConfig } from '../aws/page-common.js';
import { createPullRequest, createRepository, getCommitsAhead, listPullRequests } from '../aws/codecommit.js';
import { t, type ServiceCards, type CardContext, CardInputError } from './types.js';

/**
 * CodeCommit cards:
 * - Create pull request (action): from one branch to another, every time
 *   it is run - title / description asked on each run.
 * - Open pull requests (metric).
 * - Create repository (action): name asked on each run.
 * - Open repository (link): straight to a tab, e.g. its commit history.
 */

const client = (profile: string, region: string) => new CodeCommitClient(clientConfig(profile, region));

const REPO_PATTERN = '^[A-Za-z0-9_.-]{1,100}$';
const REPO_MESSAGE = t('1-100 characters: letters, digits, . _ and -', '1-100 karakter: harf, rakam, . _ ve -');
const BRANCH_MAX = 256;
const PREVIEW_ROWS = 20;

function repoOf(ctx: CardContext): string {
  const repo = ctx.params.repository || '';
  if (!new RegExp(REPO_PATTERN).test(repo)) throw new CardInputError(t('Choose a repository', 'Bir repository seç'));
  return repo;
}

function branchesOf(ctx: CardContext): { source: string; destination: string } {
  const source = ctx.params.source || '';
  const destination = ctx.params.destination || '';
  if (!source || !destination) throw new CardInputError(t('Choose the source and destination branches', 'Kaynak ve hedef dalları seç'));
  if (source === destination) throw new CardInputError(t('Source and destination must be different branches', 'Kaynak ve hedef farklı dallar olmalı'));
  return { source, destination };
}

/** "{source} → {destination} ({date})" placeholders in run-time texts. */
function fill(template: string, ctx: CardContext): string {
  const date = new Date().toISOString().slice(0, 10);
  return template.replace(/\{source\}/g, ctx.params.source || '').replace(/\{destination\}/g, ctx.params.destination || '').replace(/\{date\}/g, date).replace(/\{repository\}/g, ctx.params.repository || '');
}

const short = (text: string, max = 70) => (text.length > max ? `${text.slice(0, max - 1)}…` : text);

/** The newest commit of a branch: first line (title) and the rest (body). */
async function lastCommit(profile: string, region: string, repository: string, branch: string): Promise<{ title: string; body: string } | undefined> {
  const c = client(profile, region);
  const commitId = (await c.send(new GetBranchCommand({ repositoryName: repository, branchName: branch }))).branch?.commitId;
  if (!commitId) return undefined;
  const message = (await c.send(new GetCommitCommand({ repositoryName: repository, commitId }))).commit?.message ?? '';
  const [first, ...rest] = message.trim().split('\n');
  return { title: (first ?? '').trim().slice(0, 150), body: rest.join('\n').trim().slice(0, 10_000) };
}

export const codecommitCards: ServiceCards = {
  service: 'codecommit',
  options: {
    async 'codecommit.repositories'({ profile, region }) {
      const names: string[] = [];
      let nextToken: string | undefined;
      do {
        const res = await client(profile, region).send(new ListRepositoriesCommand({ nextToken }));
        names.push(...(res.repositories || []).map((r) => r.repositoryName || ''));
        nextToken = res.nextToken;
      } while (nextToken);
      return names.filter(Boolean).sort((a, b) => a.localeCompare(b)).map((n) => ({ value: n, label: n }));
    },
    /** Branch names only (no per-branch GetBranch calls). */
    async 'codecommit.branches'({ profile, region, deps }) {
      if (!new RegExp(REPO_PATTERN).test(deps.repository || '')) return [];
      const names: string[] = [];
      let nextToken: string | undefined;
      do {
        const res = await client(profile, region).send(new ListBranchesCommand({ repositoryName: deps.repository, nextToken }));
        names.push(...(res.branches || []));
        nextToken = res.nextToken;
      } while (nextToken);
      return names.sort((a, b) => a.localeCompare(b)).map((n) => ({ value: n, label: n }));
    },
    /** The source branch's newest commit - value = message title, detail = message body (PR title / description). */
    async 'codecommit.lastCommit'({ profile, region, deps }) {
      if (!new RegExp(REPO_PATTERN).test(deps.repository || '') || !deps.source) return [];
      const commit = await lastCommit(profile, region, deps.repository, deps.source);
      return commit ? [{ value: commit.title, label: commit.title, detail: commit.body }] : [];
    },
  },
  templates: [
    {
      id: 'codecommit.createPullRequest',
      kind: 'action',
      name: t('Create pull request', 'Pull request oluştur'),
      description: t('Opens a pull request from one branch to another each time you run it (e.g. develop → main).', 'Her çalıştırıldığında bir daldan diğerine pull request açar (ör. develop → main).'),
      icon: 'arrow.triangle.pull',
      confirm: t('Open a pull request in {repository}: {source} → {destination}?', '{repository} içinde {source} → {destination} pull request açılsın mı?'),
      params: [
        { key: 'repository', label: t('Repository', 'Repository'), type: 'combo', source: 'codecommit.repositories', required: true, pattern: REPO_PATTERN, patternMessage: REPO_MESSAGE },
        { key: 'source', label: t('Source branch', 'Kaynak dal'), type: 'combo', source: 'codecommit.branches', dependsOn: ['repository'], required: true, maxLength: BRANCH_MAX },
        { key: 'destination', label: t('Destination branch', 'Hedef dal'), type: 'combo', source: 'codecommit.branches', dependsOn: ['repository'], required: true, maxLength: BRANCH_MAX },
        {
          key: 'title',
          label: t('Title', 'Başlık'),
          type: 'text',
          scope: 'run',
          required: true,
          maxLength: 150,
          prefill: { source: 'codecommit.lastCommit', use: 'value' },
          hint: t("Left empty: the source branch's last commit message, fetched each time you run it (you can still change it then). {source}, {destination} and {date} are filled in.", 'Boş bırakılırsa: kaynak dalın son commit mesajı her çalıştırmada getirilir (o anda yine değiştirebilirsin). {source}, {destination} ve {date} doldurulur.'),
        },
        {
          key: 'description',
          label: t('Description', 'Açıklama'),
          type: 'textarea',
          scope: 'run',
          maxLength: 10_000,
          prefill: { source: 'codecommit.lastCommit', use: 'detail' },
          hint: t("Left empty: the rest of that commit message.", 'Boş bırakılırsa: aynı commit mesajının devamı.'),
        },
      ],
      async preview(ctx) {
        const repo = repoOf(ctx);
        const { source, destination } = branchesOf(ctx);
        const [ahead, open] = await Promise.all([
          getCommitsAhead(ctx.profile, ctx.region, repo, source, destination, PREVIEW_ROWS + 1),
          listPullRequests(ctx.profile, ctx.region, repo, 'OPEN'),
        ]);
        const same = open.filter((pr) => pr.sourceReference?.endsWith(`/${source}`) && pr.destinationReference?.endsWith(`/${destination}`));
        return {
          title: t(`Commits in ${source} that are not in ${destination}`, `${source} dalında olup ${destination} dalında olmayan commit'ler`),
          columns: [t('Commit', 'Commit'), t('Message', 'Mesaj'), t('Author', 'Yazar'), t('Date', 'Tarih')],
          rows: ahead.slice(0, PREVIEW_ROWS).map((c) => [c.shortId, short(c.message.split('\n')[0] || ''), c.authorName ?? '', (c.date ?? '').slice(0, 10)]),
          more: ahead.length > PREVIEW_ROWS,
          emptyMessage: t(`No differences - ${source} has nothing to merge into ${destination}; AWS would refuse the pull request.`, `Fark yok - ${source} dalında ${destination} dalına birleştirilecek bir şey yok; AWS pull request'i reddeder.`),
          note: same.length
            ? t(`Already open between these branches: ${same.map((p) => `#${p.pullRequestId}`).join(', ')}`, `Bu dallar arasında zaten açık: ${same.map((p) => `#${p.pullRequestId}`).join(', ')}`)
            : undefined,
        };
      },
      async run(ctx) {
        const repo = repoOf(ctx);
        const { source, destination } = branchesOf(ctx);
        // No title given: the source branch's last commit message (same as the run sheet prefills).
        const title = fill(ctx.params.title || '', ctx).trim() || (await lastCommit(ctx.profile, ctx.region, repo, source))?.title || '';
        if (!title) throw new CardInputError(t('Enter a title', 'Bir başlık gir'));
        const pr = await createPullRequest(ctx.profile, ctx.region, {
          repositoryName: repo,
          title,
          description: ctx.params.description ? fill(ctx.params.description, ctx) : undefined,
          sourceReference: source,
          destinationReference: destination,
        });
        return {
          message: t(`Pull request #${pr.pullRequestId} opened: ${source} → ${destination}`, `#${pr.pullRequestId} numaralı pull request açıldı: ${source} → ${destination}`),
          link: { service: 'codecommit', resource: repo, tab: 'pullRequests' },
        };
      },
      link: (ctx) => ({ service: 'codecommit', resource: ctx.params.repository, tab: 'pullRequests' }),
    },
    {
      id: 'codecommit.openPullRequests',
      kind: 'metric',
      name: t('Open pull requests', 'Açık pull request\'ler'),
      description: t('How many pull requests are open in a repository.', 'Bir repository\'de kaç pull request açık.'),
      icon: 'arrow.triangle.branch',
      params: [{ key: 'repository', label: t('Repository', 'Repository'), type: 'combo', source: 'codecommit.repositories', required: true, pattern: REPO_PATTERN, patternMessage: REPO_MESSAGE }],
      async value(ctx) {
        const repo = repoOf(ctx);
        let count = 0;
        let nextToken: string | undefined;
        do {
          const res = await client(ctx.profile, ctx.region).send(new ListPullRequestsCommand({ repositoryName: repo, pullRequestStatus: 'OPEN', nextToken }));
          count += (res.pullRequestIds || []).length;
          nextToken = res.nextToken;
        } while (nextToken);
        return { value: count, unit: t('open', 'açık') };
      },
      link: (ctx) => ({ service: 'codecommit', resource: ctx.params.repository, tab: 'pullRequests' }),
      async preview(ctx) {
        const repo = repoOf(ctx);
        const prs = await listPullRequests(ctx.profile, ctx.region, repo, 'OPEN');
        const branch = (ref?: string) => (ref || '').replace('refs/heads/', '');
        return {
          title: t(`Open pull requests in ${repo}`, `${repo} içindeki açık pull request'ler`),
          columns: [t('#', '#'), t('Title', 'Başlık'), t('Branches', 'Dallar'), t('Updated', 'Güncellendi')],
          rows: prs.slice(0, PREVIEW_ROWS).map((p) => [p.pullRequestId, short(p.title), `${branch(p.sourceReference)} → ${branch(p.destinationReference)}`, (p.lastActivityDate ?? '').slice(0, 10)]),
          more: prs.length > PREVIEW_ROWS,
          emptyMessage: t('No open pull requests.', 'Açık pull request yok.'),
        };
      },
    },
    {
      id: 'codecommit.createRepository',
      kind: 'action',
      name: t('Create repository', 'Repository oluştur'),
      description: t('Creates a new repository; its name is asked each time you run it.', 'Yeni bir repository oluşturur; adı her çalıştırmada sorulur.'),
      icon: 'plus.rectangle.on.folder.fill',
      confirm: t('Create the repository {name}?', '{name} repository\'si oluşturulsun mu?'),
      params: [
        { key: 'name', label: t('Repository name', 'Repository adı'), type: 'text', scope: 'run', required: true, pattern: REPO_PATTERN, patternMessage: REPO_MESSAGE, maxLength: 100 },
        { key: 'description', label: t('Description', 'Açıklama'), type: 'textarea', scope: 'run', maxLength: 1000 },
      ],
      async preview(ctx) {
        const repos = await codecommitCards.options!['codecommit.repositories']({ profile: ctx.profile, region: ctx.region, deps: {} });
        return {
          title: t('Existing repositories', 'Mevcut repository\'ler'),
          columns: [t('Name', 'Ad')],
          rows: repos.slice(0, 40).map((r) => [r.label]),
          more: repos.length > 40,
          emptyMessage: t('No repositories yet in this account and region.', 'Bu hesap ve bölgede henüz repository yok.'),
          note: t('A name that already exists is refused by AWS.', 'Var olan bir ad AWS tarafından reddedilir.'),
        };
      },
      async run(ctx) {
        const name = (ctx.params.name || '').trim();
        if (!new RegExp(REPO_PATTERN).test(name) || name.endsWith('.git')) throw new CardInputError(t('Enter a valid repository name', 'Geçerli bir repository adı gir'));
        await createRepository(ctx.profile, ctx.region, name, ctx.params.description || undefined);
        return { message: t(`Repository ${name} created`, `${name} repository'si oluşturuldu`), link: { service: 'codecommit', resource: name, tab: 'files' } };
      },
      link: () => ({ service: 'codecommit' }),
    },
    {
      id: 'codecommit.openRepository',
      kind: 'link',
      name: t('Open a repository', 'Repository aç'),
      description: t('Shortcut to a repository tab - e.g. straight to its commit history.', 'Bir repository sekmesine kısayol - ör. doğrudan commit geçmişine.'),
      icon: 'clock.arrow.circlepath',
      params: [
        { key: 'repository', label: t('Repository', 'Repository'), type: 'combo', source: 'codecommit.repositories', required: true, pattern: REPO_PATTERN, patternMessage: REPO_MESSAGE },
        {
          key: 'tab',
          label: t('Opens on', 'Açılacak sekme'),
          type: 'select',
          required: true,
          defaultValue: 'commits',
          choices: [
            { value: 'files', label: t('Files', 'Dosyalar') },
            { value: 'commits', label: t('Commit history', 'Commit geçmişi') },
            { value: 'branches', label: t('Branches', 'Dallar') },
            { value: 'pullRequests', label: t('Pull requests', 'Pull request\'ler') },
          ],
        },
      ],
      link: (ctx) => ({ service: 'codecommit', resource: ctx.params.repository, tab: ctx.params.tab || 'commits' }),
    },
  ],
};
