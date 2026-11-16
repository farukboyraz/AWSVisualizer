import { S3Client, ListBucketsCommand, ListObjectsV2Command } from '@aws-sdk/client-s3';
import { clientConfig } from '../aws/page-common.js';
import { t, type ServiceCards, type CardContext, CardInputError } from './types.js';

/** S3 cards: object count / size of a folder, and a shortcut to a bucket. */

const client = (profile: string, region: string) => new S3Client({ ...clientConfig(profile, region || 'us-east-1'), followRegionRedirects: true });

const BUCKET_PATTERN = '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$';
/** ListObjectsV2 pages of 1,000 keys - at most 100,000 objects are counted. */
const MAX_PAGES = 100;
const PREVIEW_ROWS = 40;

const size = (bytes: number) => {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = bytes;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return `${value.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
};

/** "logs/2026/" -> "logs/" ; "logs/" -> "" */
const parentOf = (prefix: string) => {
  const trimmed = prefix.replace(/\/$/, '');
  const cut = trimmed.lastIndexOf('/');
  return cut < 0 ? '' : trimmed.slice(0, cut + 1);
};

function bucketOf(ctx: CardContext): string {
  const bucket = ctx.params.bucket || '';
  if (!new RegExp(BUCKET_PATTERN).test(bucket)) throw new CardInputError(t('Choose a bucket', 'Bir bucket seç'));
  return bucket;
}

export const s3Cards: ServiceCards = {
  service: 's3',
  options: {
    async 's3.buckets'({ profile, region }) {
      const res = await client(profile, region).send(new ListBucketsCommand({}));
      return (res.Buckets || []).map((b) => ({ value: b.Name || '', label: b.Name || '', detail: b.CreationDate?.toISOString().slice(0, 10) })).sort((a, b) => a.label.localeCompare(b.label));
    },
    /** Sub-folders of the current folder (plus "up one level"), so the field drills down level by level. */
    async 's3.folders'({ profile, region, deps }) {
      if (!new RegExp(BUCKET_PATTERN).test(deps.bucket || '')) return [];
      const prefix = deps.prefix || '';
      const res = await client(profile, region).send(new ListObjectsV2Command({ Bucket: deps.bucket, Prefix: prefix || undefined, Delimiter: '/', MaxKeys: 1000 }));
      const children = (res.CommonPrefixes || []).map((p) => ({ value: p.Prefix || '', label: (p.Prefix || '').slice(prefix.length) || p.Prefix || '', detail: p.Prefix }));
      const up = prefix ? [{ value: parentOf(prefix), label: '..', detail: parentOf(prefix) || '/' }] : [];
      return [...up, ...children];
    },
  },
  templates: [
    {
      id: 's3.folderStats',
      kind: 'metric',
      name: t('Folder size', 'Klasör boyutu'),
      description: t('How many objects a bucket folder holds and their total size.', 'Bir bucket klasöründeki nesne sayısı ve toplam boyutu.'),
      icon: 'folder.fill',
      params: [
        { key: 'bucket', label: t('Bucket', 'Bucket'), type: 'combo', source: 's3.buckets', required: true, pattern: BUCKET_PATTERN, patternMessage: t('3-63 characters: lowercase letters, digits, dots and hyphens', '3-63 karakter: küçük harf, rakam, nokta ve tire') },
        {
          key: 'prefix',
          label: t('Folder', 'Klasör'),
          type: 'combo',
          source: 's3.folders',
          // Its own key too: picking a folder reloads the list one level down.
          dependsOn: ['bucket', 'prefix'],
          maxLength: 1024,
          hint: t('Pick a folder to see its sub-folders; empty = the whole bucket. Counts at most 100,000 objects.', 'Alt klasörlerini görmek için bir klasör seç; boş = bütün bucket. En fazla 100.000 nesne sayılır.'),
        },
        {
          key: 'search',
          label: t('Name contains (optional)', 'Ad şunu içerir (isteğe bağlı)'),
          type: 'text',
          maxLength: 200,
          hint: t('Only objects whose name contains this text are counted; Run opens the folder with it in the search field.', 'Yalnızca adında bu metin geçen nesneler sayılır; Run klasörü bu metin arama alanında olacak şekilde açar.'),
        },
      ],
      async value(ctx) {
        const bucket = bucketOf(ctx);
        const c = client(ctx.profile, ctx.region);
        let objects = 0;
        let bytes = 0;
        let token: string | undefined;
        let pages = 0;
        do {
          const res = await c.send(new ListObjectsV2Command({ Bucket: bucket, Prefix: ctx.params.prefix || undefined, ContinuationToken: token }));
          const needle = (ctx.params.search || '').toLowerCase();
          for (const o of res.Contents || []) {
            if (needle && !(o.Key || '').slice((ctx.params.prefix || '').length).toLowerCase().includes(needle)) continue;
            objects++;
            bytes += o.Size ?? 0;
          }
          token = res.IsTruncated ? res.NextContinuationToken : undefined;
          pages++;
        } while (token && pages < MAX_PAGES);
        return { value: objects, unit: t('objects', 'nesne'), details: [t(size(bytes), size(bytes))], truncated: !!token };
      },
      link: (ctx) => ({ service: 's3', resource: ctx.params.bucket, prefix: ctx.params.prefix || '', filter: ctx.params.search || undefined }),
      async preview(ctx) {
        const bucket = bucketOf(ctx);
        const prefix = ctx.params.prefix || '';
        const res = await client(ctx.profile, ctx.region).send(new ListObjectsV2Command({ Bucket: bucket, Prefix: prefix || undefined, Delimiter: '/', MaxKeys: PREVIEW_ROWS }));
        const folders = (res.CommonPrefixes || []).map((p) => [`📁 ${(p.Prefix || '').slice(prefix.length)}`, '', '']);
        const files = (res.Contents || []).filter((o) => o.Key !== prefix).map((o) => [(o.Key || '').slice(prefix.length), size(o.Size ?? 0), o.LastModified?.toISOString().slice(0, 16).replace('T', ' ') ?? '']);
        const needle = (ctx.params.search || '').toLowerCase();
        const shown = [...folders, ...files].filter((row) => !needle || row[0].toLowerCase().includes(needle));
        return {
          title: t(`s3://${bucket}/${prefix}`, `s3://${bucket}/${prefix}`),
          columns: [t('Name', 'Ad'), t('Size', 'Boyut'), t('Modified', 'Değiştirilme')],
          rows: shown.slice(0, PREVIEW_ROWS),
          more: !!res.IsTruncated,
          emptyMessage: t('This folder is empty.', 'Bu klasör boş.'),
          note: res.IsTruncated ? t(`First ${PREVIEW_ROWS} entries.`, `İlk ${PREVIEW_ROWS} kayıt.`) : undefined,
        };
      },
    },
    {
      id: 's3.openBucket',
      kind: 'link',
      name: t('Open a bucket', 'Bucket aç'),
      description: t('Shortcut to a bucket in the S3 screen.', 'S3 ekranında bir bucket\'a kısayol.'),
      icon: 'archivebox.fill',
      params: [{ key: 'bucket', label: t('Bucket', 'Bucket'), type: 'combo', source: 's3.buckets', required: true, pattern: BUCKET_PATTERN }],
      link: (ctx) => ({ service: 's3', resource: ctx.params.bucket }),
    },
  ],
};
