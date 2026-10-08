#!/usr/bin/env bash
#
# Prüft die Mods des Plugins `whisperm8` ohne App-Build: legt das Gerüst aus
# WhisperM8/Resources/claude-plugin/ samt Tests in einen Temp-Ordner (Manifest
# nach .claude-plugin/, wie es WhisperM8ClaudePlugin.swift beim Ablegen tut)
# und ruft `claude plugin validate` und `claude plugin test` darauf auf.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKELETON="$REPO_ROOT/WhisperM8/Resources/claude-plugin"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/whisperm8-plugin-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PLUGIN="$WORK/whisperm8"
mkdir -p "$PLUGIN/.claude-plugin"
(cd "$SKELETON" && find . -type f ! -name '.DS_Store' ! -name 'plugin.json') | while IFS= read -r rel; do
  mkdir -p "$PLUGIN/$(dirname "$rel")"
  cp "$SKELETON/$rel" "$PLUGIN/$rel"
done
cp "$SKELETON/plugin.json" "$PLUGIN/.claude-plugin/plugin.json"

claude plugin validate "$PLUGIN"
claude plugin test "$PLUGIN"
