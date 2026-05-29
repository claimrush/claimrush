/**
 * No-op strategy template.
 *
 * Use this as a starting point for testing strategy loading.
 */

export const strategies = [
  {
    id: 'template.noop',
    priority: 0,
    propose: () => {
      return {
        actions: [],
        notes: ['noop'],
      };
    },
  },
];
