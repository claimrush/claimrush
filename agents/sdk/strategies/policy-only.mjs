/**
 * Built-in policy strategy only.
 *
 * Equivalent to running the agent without strategies.
 */

import { createPolicyStrategy } from '@claimrush/agent-sdk';

export const strategies = [
  createPolicyStrategy({
    id: 'template.policyOnly',
    priority: 0,
    stopOnActions: true,
  }),
];
