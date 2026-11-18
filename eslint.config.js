// typescript-eslint needs TypeScript's JS API, which TypeScript 7 doesn't ship, so lint
// runs on its own TypeScript 6 here while the services typecheck with 7.
import js from '@eslint/js';
import { defineConfig } from 'eslint/config';
import tseslint from 'typescript-eslint';

export default defineConfig(
  { ignores: ['**/node_modules/', 'apps/', 'docs/'] },
  { files: ['services/**/*.ts'], extends: [js.configs.recommended, tseslint.configs.recommended] },
);
