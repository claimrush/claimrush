/**
 * Shared ESLint config bits for backend packages.
 *
 * Each package installs its own ESLint + plugins.
 * Package-local eslint.config.mjs files should import plugin modules from their
 * own node_modules, then reuse these plain-object exports.
 */

export const BACKEND_IGNORES = [
  '**/node_modules/**',
  '**/dist/**',
  '**/coverage/**',
  '**/.wrangler/**',
  '**/.turbo/**',
  '**/.next/**',
];

export const UNUSED_VARS_OPTIONS = {
  argsIgnorePattern: '^_',
  varsIgnorePattern: '^_',
  caughtErrorsIgnorePattern: '^_',
};

export const BACKEND_JS_RULES = {
  // Warning-level unused vars, but allow intentionally-unused `_foo`.
  'no-unused-vars': ['warn', UNUSED_VARS_OPTIONS],
};

export const BACKEND_TS_RULES = {
  // Relax no-explicit-any — this codebase predates strict typing.
  '@typescript-eslint/no-explicit-any': 'off',
  '@typescript-eslint/no-unused-vars': ['warn', UNUSED_VARS_OPTIONS],
};
