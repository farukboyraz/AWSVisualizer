import { t, type ServiceCards } from './types.js';

/** A free-text card - no AWS call, nothing to refresh. */
export const noteCards: ServiceCards = {
  service: 'note',
  templates: [
    {
      id: 'note.text',
      kind: 'note',
      name: t('Note', 'Not'),
      description: t('A note of your own on the dashboard.', 'Dashboard\'da kendi notun.'),
      icon: 'note.text',
      params: [{ key: 'text', label: t('Text', 'Metin'), type: 'textarea', required: true, maxLength: 2000 }],
    },
  ],
};
