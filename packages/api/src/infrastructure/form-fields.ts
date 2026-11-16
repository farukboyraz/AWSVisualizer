import { t, CardInputError, type ParamSpec, type Text } from './dashboard-cards/types.js';

/**
 * Form fields shared by dashboard card templates and ResourcePage forms
 * (create / action forms, see domain/entities/resource-page.ts). The app
 * draws both with the same field view and checks the same rules before
 * sending; this is the sidecar's copy of those rules.
 */

export const isFieldVisible = (p: ParamSpec, params: Record<string, string>) =>
  !p.visibleWhen || p.visibleWhen.in.includes(params[p.visibleWhen.key] ?? '');

const labelled = (label: Text, message: Text): Text => t(`${label.en}: ${message.en}`, `${label.tr}: ${message.tr}`);

/**
 * Checks values against field specs: required, length, pattern, choices.
 * `scope: 'card'` checks fields saved with a card; 'run' adds run-time
 * fields (ResourcePage forms always use 'run' - every field counts).
 * Unknown keys are dropped; failures throw a `CardInputError` (400 with
 * English and Turkish text).
 */
export function validateFields(fields: ParamSpec[], raw: unknown, scope: 'card' | 'run'): Record<string, string> {
  const input = raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const params: Record<string, string> = {};
  for (const p of fields) {
    const value = input[p.key];
    if (value === undefined || value === null) continue;
    if (typeof value !== 'string') throw new CardInputError(t(`${p.label.en} must be text`, `${p.label.tr} metin olmalı`));
    params[p.key] = value;
  }
  for (const p of fields) {
    const checkRequired = (p.scope ?? 'card') === 'card' || scope === 'run';
    const value = params[p.key] ?? '';
    if (!isFieldVisible(p, params)) continue;
    if (p.required && checkRequired && !value.trim()) throw new CardInputError(t(`${p.label.en} is required`, `${p.label.tr} gerekli`));
    if (!value) continue;
    if (value.length > (p.maxLength ?? 1024)) throw new CardInputError(t(`${p.label.en} is too long (at most ${p.maxLength ?? 1024})`, `${p.label.tr} çok uzun (en fazla ${p.maxLength ?? 1024})`));
    if (p.pattern && !new RegExp(p.pattern).test(value)) throw new CardInputError(p.patternMessage ? labelled(p.label, p.patternMessage) : t(`${p.label.en} is not valid`, `${p.label.tr} geçerli değil`));
    if (p.type === 'select' && p.choices && !p.choices.some((c) => c.value === value)) throw new CardInputError(t(`${p.label.en}: unknown choice`, `${p.label.tr}: bilinmeyen seçim`));
  }
  return params;
}
