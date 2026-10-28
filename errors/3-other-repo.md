- The project is located at `/workspace/XCorner/drive-gallery`.
- It uses pnpm with `package.json` and `pnpm-lock.yaml`.
- Dependencies were initially attempted with `pnpm install`, but pnpm was not installed globally.
- Corepack provided pnpm successfully.
- The default pnpm linker failed because the workspace filesystem does not support symbolic links.
- Dependencies were installed successfully with:
  ```bash
  corepack pnpm install --node-linker=hoisted
  ```
- All 83 packages installed, including Wrangler, Vitest, TypeScript, and the project dependency.
- No tracked files were modified.