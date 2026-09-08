#!/usr/bin/env node
// Config parsing/validation has one source of truth, shared with asdd-init.
try {
  const { loadConfig } = await import('../scripts/asdd/config.mjs');
  const config = await loadConfig(process.argv[2]);
  const feature = process.argv[3];
  if (config && (!config.features.hooks || (feature !== 'hooks' && !config.features[feature]))) {
    process.exitCode = 3;
  }
} catch {
  // Do not print invalid configuration values: they might contain secrets.
  console.error('ff-dev-toolkit: ASDD 設定を検証できないため任意Hookを停止しました。asdd-init --check で確認してください');
  process.exitCode = 2;
}
