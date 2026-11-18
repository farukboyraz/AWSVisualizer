/**
 * The dashboard's section layout: rows of section ids, top to bottom, left
 * to right (`display.dashboard.layout` in ~/.awsvisualizer), and each
 * section's size (`display.dashboard.sizes`). The app drags sections
 * around and resizes them in its layout editor; this file holds the rules
 * both sides share - keep it in step with `DashboardLayout.swift`.
 *
 * A row is 4 columns wide. Like macOS widgets a section is small (1
 * column), medium (2) or large (the whole row); `WIDGET_SIZES` lists the
 * sizes each section offers (the spend chart, My cards and Services have
 * no small size). A row may hold sections while their sizes add up to at
 * most 4 columns.
 */

export const LAYOUT_COLUMNS = 4;

export const SIZE_SPAN = { small: 1, medium: 2, large: 4 } as const;
export type WidgetSize = keyof typeof SIZE_SPAN;

/** The sizes each section offers (defaults in DEFAULT_SIZES). */
export const WIDGET_SIZES: Record<string, WidgetSize[]> = {
  resourcesKpi: ['small', 'medium', 'large'],
  activeKpi: ['small', 'medium', 'large'],
  costKpi: ['small', 'medium', 'large'],
  attentionKpi: ['small', 'medium', 'large'],
  customCards: ['medium', 'large'],
  distribution: ['small', 'medium', 'large'],
  topServices: ['small', 'medium', 'large'],
  costTrend: ['medium', 'large'],
  costByService: ['small', 'medium', 'large'],
  services: ['medium', 'large'],
};

export const DEFAULT_SIZES: Record<string, WidgetSize> = {
  resourcesKpi: 'small',
  activeKpi: 'small',
  costKpi: 'small',
  attentionKpi: 'small',
  customCards: 'large',
  distribution: 'medium',
  topServices: 'medium',
  costTrend: 'medium',
  costByService: 'medium',
  services: 'large',
};

/** The layout before the user changes anything (also the reset target). */
export const DEFAULT_LAYOUT: string[][] = [
  ['resourcesKpi', 'activeKpi', 'costKpi', 'attentionKpi'],
  ['customCards'],
  ['distribution', 'topServices'],
  ['costTrend', 'costByService'],
  ['services'],
];

/** Every section with a size it offers: unknown sections and sizes fall back to the default. */
export function readSizes(raw: unknown): Record<string, WidgetSize> {
  const sizes = { ...DEFAULT_SIZES };
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    for (const [w, s] of Object.entries(raw as Record<string, unknown>)) {
      if (w in WIDGET_SIZES && WIDGET_SIZES[w].includes(s as WidgetSize)) sizes[w] = s as WidgetSize;
    }
  }
  return sizes;
}

/** Why `sizes` sent by the app can't be saved (empty = fine). */
export function sizeProblems(raw: unknown): string[] {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return ['sizes must be an object of section id -> small / medium / large'];
  const problems: string[] = [];
  for (const [w, s] of Object.entries(raw as Record<string, unknown>)) {
    if (!(w in WIDGET_SIZES)) problems.push(`sizes: unknown section ${w}`);
    else if (!WIDGET_SIZES[w].includes(s as WidgetSize)) problems.push(`sizes.${w} must be one of ${WIDGET_SIZES[w].join(', ')}`);
  }
  return problems;
}

const span = (w: string, sizes: Record<string, WidgetSize>) => SIZE_SPAN[sizes[w] ?? DEFAULT_SIZES[w]] ?? LAYOUT_COLUMNS;
const rowSpan = (row: string[], sizes: Record<string, WidgetSize>) => row.reduce((sum, w) => sum + span(w, sizes), 0);

/**
 * Why a layout sent by the app can't be saved (empty = fine): not a list of
 * lists, unknown or repeated sections, or a row whose sections don't fit
 * at their sizes. Missing sections are allowed - they're added back when it's read.
 */
export function layoutProblems(raw: unknown, sizes: Record<string, WidgetSize> = DEFAULT_SIZES): string[] {
  if (!Array.isArray(raw) || raw.some((row) => !Array.isArray(row))) return ['layout must be a list of rows (lists of section ids)'];
  const problems: string[] = [];
  const seen = new Set<string>();
  (raw as unknown[][]).forEach((row, i) => {
    for (const w of row) {
      if (typeof w !== 'string' || !(w in WIDGET_SIZES)) problems.push(`layout[${i}]: unknown section ${String(w)}`);
      else if (seen.has(w)) problems.push(`layout: ${w} appears more than once`);
      else seen.add(w);
    }
    const known = row.filter((w): w is string => typeof w === 'string' && w in WIDGET_SIZES);
    if (rowSpan(known, sizes) > LAYOUT_COLUMNS) problems.push(`layout[${i}]: ${known.join(', ')} don't fit in one row`);
  });
  return problems;
}

/**
 * A saved layout made safe to draw: unknown and repeated ids dropped, an
 * overfull row split, empty rows removed, and sections missing from it
 * (new ones, or a hand-edited file) added back as their default rows.
 */
export function readLayout(raw: unknown, sizes: Record<string, WidgetSize> = DEFAULT_SIZES): string[][] {
  const source: unknown[] = Array.isArray(raw) ? raw : DEFAULT_LAYOUT;
  const seen = new Set<string>();
  const rows: string[][] = [];
  const add = (row: string[]) => {
    let line: string[] = [];
    for (const w of row) {
      if (rowSpan([...line, w], sizes) > LAYOUT_COLUMNS && line.length) {
        rows.push(line);
        line = [];
      }
      line.push(w);
    }
    if (line.length) rows.push(line);
  };
  for (const rawRow of source) {
    if (!Array.isArray(rawRow)) continue;
    const row: string[] = [];
    for (const w of rawRow) {
      if (typeof w !== 'string' || !(w in WIDGET_SIZES) || seen.has(w)) continue;
      seen.add(w);
      row.push(w);
    }
    add(row);
  }
  for (const defaultRow of DEFAULT_LAYOUT) {
    const missing = defaultRow.filter((w) => !seen.has(w));
    if (missing.length) {
      missing.forEach((w) => seen.add(w));
      add(missing);
    }
  }
  return rows.filter((row) => row.length);
}
