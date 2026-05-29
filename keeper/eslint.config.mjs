import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import { BACKEND_IGNORES, BACKEND_TS_RULES } from '../eslint.config.mjs';

export default [
  {
    ignores: BACKEND_IGNORES,
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['**/*.ts'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
    },
    rules: {
      ...BACKEND_TS_RULES,
    },
  },
];
