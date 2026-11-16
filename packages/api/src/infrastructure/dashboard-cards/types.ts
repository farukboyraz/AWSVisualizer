/**
 * Dashboard card templates - the building blocks of "My cards".
 *
 * A saved card is `{ service, template, profile, region, params }`. The
 * template (one per kind of card, defined in the service's own file next
 * to this one) says:
 * - what the card is (`kind`): a **metric** shows a number and is
 *   refreshed with the dashboard; an **action** changes something on AWS
 *   and only ever runs when the user clicks Run and confirms; a **link**
 *   opens a screen of the app;
 * - which parameters it takes (`params`) - rendered by the app as a form,
 *   with dropdowns filled from `options` sources and fields that depend on
 *   each other (bucket -> folder, repository -> branch);
 * - how to show a preview of the selected data under the form (`preview`),
 *   and how to compute / run / open it.
 *
 * Everything user-facing carries English and Turkish text; the app picks
 * by its language.
 */

export interface Text {
  en: string;
  tr: string;
}

export const t = (en: string, tr: string): Text => ({ en, tr });

/** note = free text, no AWS call. */
export type CardKind = 'metric' | 'action' | 'link' | 'note';

export type ParamType =
  /** One line of text. */
  | 'text'
  /** Several lines. */
  | 'textarea'
  /** One of `choices`. */
  | 'select'
  /** Text with a dropdown filled from `source` (the value can also be typed). */
  | 'combo'
  /** DynamoDB search: Query / Filter Builder scan / PartiQL (JSON, see dynamodb.ts). */
  | 'dynamoSearch';

export interface ParamSpec {
  key: string;
  label: Text;
  type: ParamType;
  required?: boolean;
  /** `card`: fixed when the card is made. `run`: asked every time an action runs (prefilled with the saved value). */
  scope?: 'card' | 'run';
  hint?: Text;
  placeholder?: string;
  maxLength?: number;
  /** Checked on save, preview and run (JavaScript regex source). */
  pattern?: string;
  patternMessage?: Text;
  choices?: { value: string; label: Text }[];
  /** Option source id (combo / dynamoQuery) - see `OptionSource`. */
  source?: string;
  /**
   * Params the source needs: the field waits until they are filled and
   * reloads its choices when they change. Its own key = reload when the
   * field's own value changes (drilling into folders), not a requirement.
   */
  dependsOn?: string[];
  /** Only shown (and validated) when another param has one of these values. */
  visibleWhen?: { key: string; in: string[] };
  /** Default for new cards. Supports {source}/{destination}/{date} placeholders in run params. */
  defaultValue?: string;
  /**
   * Filled from an option source when empty (run params: when the run
   * sheet opens) - e.g. a pull request's title from the source branch's
   * last commit message. `use`: the first option's value or its detail.
   */
  prefill?: { source: string; use: 'value' | 'detail' };
}

export interface CardContext {
  profile: string;
  region: string;
  params: Record<string, string>;
}

export interface MetricResult {
  value: number;
  /** Shown after the number ("objects", "messages"). */
  unit: Text;
  /** Extra lines under the number. */
  details?: Text[];
  /** The count stopped early - `value` is a lower bound. */
  truncated?: boolean;
  /** AWS's own figure, refreshed by AWS on its own schedule. */
  approximate?: boolean;
}

export interface ActionResult {
  message: Text;
  /** Where the result can be seen in the app. */
  link?: LinkTarget;
}

/** A screen of the app: a service, optionally one resource and one tab. */
export interface LinkTarget {
  service: string;
  resource?: string;
  tab?: string;
  /** S3: the folder to open in the bucket. */
  prefix?: string;
  /** DynamoDB: the card's query JSON - the table opens with it run in the Query form. */
  query?: string;
  /** Lists with a filter field: text to filter by. */
  filter?: string;
}

/** Data shown under the editor for the current selection. */
export interface Preview {
  title: Text;
  columns: Text[];
  rows: string[][];
  /** Rows exist beyond the ones shown. */
  more?: boolean;
  /** Shown when `rows` is empty. */
  emptyMessage: Text;
  note?: Text;
}

export interface OptionItem {
  value: string;
  label: string;
  detail?: string;
  /** Extra data for special fields (DynamoDB key schema). */
  meta?: unknown;
}

/** Fills a dropdown. Read-only AWS calls only. */
export type OptionSource = (ctx: { profile: string; region: string; deps: Record<string, string> }) => Promise<OptionItem[]>;

export interface CardTemplate {
  /** `<service>.<name>`, stable - saved in ~/.awsvisualizer. */
  id: string;
  kind: CardKind;
  name: Text;
  description: Text;
  /** SF Symbol for the card. */
  icon: string;
  params: ParamSpec[];
  /** What the confirm dialog says an action will do (placeholders: {param}). */
  confirm?: Text;
  /** Read-only look at what the card works on. */
  preview?: (ctx: CardContext) => Promise<Preview>;
  value?: (ctx: CardContext) => Promise<MetricResult>;
  run?: (ctx: CardContext) => Promise<ActionResult>;
  /** Link cards: where they go. Metric / action cards: what clicking the card opens. */
  link?: (ctx: CardContext) => LinkTarget;
}

/** One service's templates and option sources (one file per service). */
export interface ServiceCards {
  service: string;
  templates: CardTemplate[];
  options?: Record<string, OptionSource>;
}

export class CardInputError extends Error {
  constructor(readonly text: Text) {
    super(text.en);
    this.name = 'CardInputError';
  }
}
