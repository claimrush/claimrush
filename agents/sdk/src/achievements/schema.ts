import { findRepoRoot } from '../repoRoot.js';
import path from 'node:path';

/**
 * Resolve the absolute path to the achievements.v1 JSON Schema file.
 *
 * Third-party dashboards can use this with any JSON Schema validator
 * (e.g. ajv) to validate achievements.jsonl lines without hard-coding paths.
 */
export const ACHIEVEMENT_SCHEMA_PATH: string = path.join(
  findRepoRoot(),
  'agents',
  'sdk',
  'schemas',
  'achievements.v1.schema.json',
);
