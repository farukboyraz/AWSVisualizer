// Shared resource page model for the services listed in PAGE_SERVICES
// (infrastructure/aws/page-services.ts) - the Database, Networking and
// Security headings so far. These services share one page model: the backend builds the console's tabs as sections of
// label/value settings, tables and JSON documents, and the Mac app renders
// any service from it with one view.

import type { StorageSetting, StorageTag } from './storage.js';
import type { MetricQuery } from './metrics.js';

export interface PageSummary {
  id: string;
  name: string;
  /** List-panel section the row belongs to ("Clusters", keyspace name...). */
  group?: string;
  status?: string;
  /** One-line secondary text under the name. */
  info?: string;
}

export interface PageSection {
  title: string;
  settings: StorageSetting[];
  /** Copyable monospaced lines (endpoints, commands). */
  copyable?: StorageSetting[];
  /** Free text shown under the grid. */
  note?: string;
}

export interface PageTable {
  title?: string;
  columns: string[];
  rows: string[][];
  /** Index of the column rendered as a status badge. */
  statusColumn?: number;
  emptyMessage?: string;
}

export interface PageTab {
  title: string;
  sections: PageSection[];
  tables: PageTable[];
  /** A JSON document (policy, task settings) rendered full-size. */
  json?: string;
  /** Plain text document (config file) rendered full-size. */
  text?: string;
  /** CloudWatch graphs drawn above the sections (the console's Monitoring tab). */
  charts?: PageChart[];
  emptyMessage?: string;
}

/** One graph: one or more metric series fetched through /api/cloudwatch/metric-data. */
export interface PageChart {
  title: string;
  /** Shown on the axis ("%", "Count", "Bytes", "ms"). */
  unit?: string;
  queries: MetricQuery[];
}

/** English and Turkish text - the app picks by its language. */
export interface PageText {
  en: string;
  tr: string;
}

/**
 * One field of a page form. Same shape as a dashboard card template's
 * `ParamSpec` (infrastructure/dashboard-cards/types.ts), so the app draws it
 * with the same field view and both sides check it with the same rules
 * (infrastructure/form-fields.ts).
 */
export interface PageFormField {
  key: string;
  label: PageText;
  /** combo = text with a dropdown filled from the adapter's `options[source]`. */
  type: 'text' | 'textarea' | 'select' | 'combo';
  required?: boolean;
  hint?: PageText;
  placeholder?: string;
  maxLength?: number;
  /** JavaScript regex source; checked in the app and again in the sidecar. */
  pattern?: string;
  patternMessage?: PageText;
  choices?: { value: string; label: PageText }[];
  source?: string;
  dependsOn?: string[];
  visibleWhen?: { key: string; in: string[] };
  defaultValue?: string;
}

export interface PageAction {
  id: string;
  title: string;
  systemImage: string;
  confirmTitle: string;
  confirmMessage: string;
  destructive: boolean;
  /**
   * Fields asked before the action runs (snapshot name, new size...). Without
   * a form the action is a plain confirm button; with one the app opens a
   * form sheet and sends the values as `params`.
   */
  form?: PageFormField[];
}

export interface ResourcePage {
  id: string;
  title: string;
  subtitle?: string;
  status?: string;
  arn?: string;
  tabs: PageTab[];
  /** Present when the resource supports tagging - the app adds a Tags tab. */
  tags?: StorageTag[];
  actions: PageAction[];
  errors: string[];
}
