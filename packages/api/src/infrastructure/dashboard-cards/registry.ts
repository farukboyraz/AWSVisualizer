import { s3Cards } from './s3.js';
import { dynamodbCards } from './dynamodb.js';
import { codecommitCards } from './codecommit.js';
import { sqsCards } from './sqs.js';
import { cloudwatchCards } from './cloudwatch.js';
import { noteCards } from './note.js';
import { genericOptions, genericTemplates } from './generic.js';
import { type CardTemplate, type OptionSource } from './types.js';
import { validateFields } from '../form-fields.js';

/**
 * Every card template, looked up by service. Adding cards for another
 * service = one new file exporting a `ServiceCards`, listed here.
 */
const SERVICE_CARDS = [s3Cards, dynamodbCards, codecommitCards, sqsCards, cloudwatchCards, noteCards];

const byService = new Map(SERVICE_CARDS.map((s) => [s.service, s]));

/** The service's own templates first, then the ones every service has. */
export function templatesFor(service: string): CardTemplate[] {
  if (service === 'note') return noteCards.templates;
  return [...(byService.get(service)?.templates ?? []), ...genericTemplates(service)];
}

export function findTemplate(service: string, id: string): CardTemplate | undefined {
  return templatesFor(service).find((tpl) => tpl.id === id);
}

export function optionSource(service: string, id: string): OptionSource | undefined {
  if (genericOptions[id]) return genericOptions[id](service);
  for (const s of SERVICE_CARDS) if (s.options?.[id]) return s.options[id];
  return undefined;
}

/** What the app needs to draw the form - no functions. */
export function describeTemplate(tpl: CardTemplate) {
  return { id: tpl.id, kind: tpl.kind, name: tpl.name, description: tpl.description, icon: tpl.icon, params: tpl.params, confirm: tpl.confirm, hasPreview: !!tpl.preview };
}

/**
 * Checks params against the template: required, length, pattern, choices.
 * `scope: 'card'` checks what is saved with the card; 'run' adds the
 * run-time params of an action. Unknown keys are dropped.
 */
export function validateParams(tpl: CardTemplate, raw: unknown, scope: 'card' | 'run'): Record<string, string> {
  return validateFields(tpl.params, raw, scope);
}
