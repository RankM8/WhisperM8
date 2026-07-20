#!/usr/bin/env bash
#
# Synchronisiert die gebündelten Agent-Skills aus WhisperM8/Resources/ nach
# ~/.claude/skills/ (Claude Code liest von dort) — OHNE App-Build und ohne
# die laufende App anzufassen. Zusätzlich werden vorhandene Repo-Spiegel
# unter .claude/skills/<name>/ nachgezogen.
#
# Für jeden Skill wird ein Install-Stempel (.whisperm8-state.json) mit
# SHA-256-Hashes geschrieben. Die App nutzt ihn für den Drei-Wege-Status
# (Aktuell / Update verfügbar / Lokal geändert / Repo-Sync) in den Settings:
# CLISkillExporter.installState().
#
# Die Skill-Tabelle unten muss CLISkillExporter.SkillDefinition.all spiegeln.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES="$REPO_ROOT/WhisperM8/Resources"
SKILLS_HOME="${WHISPERM8_SKILLS_HOME:-$HOME/.claude/skills}"
REPO_MIRROR="$REPO_ROOT/.claude/skills"
APP_BUNDLE_RESOURCES="/Applications/WhisperM8.app/Contents/Resources/WhisperM8_WhisperM8.bundle"

# <skill-name>|<resource>|<ref-datei>=<ref-resource>,…
SKILLS=(
  "whisperm8-transcription|whisperm8-cli-skill|"
  "codex-subagent|whisperm8-agent-skill|playwright-browser-qa.md=whisperm8-agent-skill-ref-playwright-browser-qa,1password-cli.md=whisperm8-agent-skill-ref-1password-cli,claude-workflows.md=whisperm8-agent-skill-ref-claude-workflows"
  "whisperm8-chats|whisperm8-chats-skill|"
  "gpt-coworker|whisperm8-gpt-coworker-skill|"
)

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

# Kopiert nur bei Inhaltsunterschied; meldet "synced" oder "unchanged".
copy_if_changed() {
  local src="$1" dst="$2"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    echo unchanged
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo synced
  fi
}

overall_changed=0

for entry in "${SKILLS[@]}"; do
  IFS='|' read -r name resource refs <<<"$entry"
  src_skill="$RESOURCES/$resource.md"
  if [[ ! -f "$src_skill" ]]; then
    echo "FEHLER: Ressource fehlt: $src_skill" >&2
    exit 1
  fi

  target_dir="$SKILLS_HOME/$name"
  changed=0

  [[ "$(copy_if_changed "$src_skill" "$target_dir/SKILL.md")" == synced ]] && changed=1

  # Stempel-Hashes über den installierten Stand aufsammeln.
  stamp_installed="\"SKILL.md\": \"$(sha256 "$target_dir/SKILL.md")\""
  stamp_bundled=""
  if [[ -f "$APP_BUNDLE_RESOURCES/$resource.md" ]]; then
    stamp_bundled="\"SKILL.md\": \"$(sha256 "$APP_BUNDLE_RESOURCES/$resource.md")\""
  fi

  if [[ -n "$refs" ]]; then
    IFS=',' read -ra ref_entries <<<"$refs"
    for ref in "${ref_entries[@]}"; do
      ref_file="${ref%%=*}"
      ref_resource="${ref#*=}"
      src_ref="$RESOURCES/$ref_resource.md"
      if [[ ! -f "$src_ref" ]]; then
        echo "FEHLER: Referenz-Ressource fehlt: $src_ref" >&2
        exit 1
      fi
      [[ "$(copy_if_changed "$src_ref" "$target_dir/references/$ref_file")" == synced ]] && changed=1
      stamp_installed+=", \"references/$ref_file\": \"$(sha256 "$target_dir/references/$ref_file")\""
      if [[ -n "$stamp_bundled" && -f "$APP_BUNDLE_RESOURCES/$ref_resource.md" ]]; then
        stamp_bundled+=", \"references/$ref_file\": \"$(sha256 "$APP_BUNDLE_RESOURCES/$ref_resource.md")\""
      fi
    done
  fi

  # Install-Stempel schreiben (Format: CLISkillExporter.InstallStamp).
  {
    echo '{'
    echo '  "source": "resources",'
    echo "  \"updatedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"installed\": { $stamp_installed }$( [[ -n "$stamp_bundled" ]] && echo ',' )"
    [[ -n "$stamp_bundled" ]] && echo "  \"bundled\": { $stamp_bundled }"
    echo '}'
  } >"$target_dir/.whisperm8-state.json"

  # Repo-Spiegel nur pflegen, wenn er bereits existiert.
  if [[ -d "$REPO_MIRROR/$name" ]]; then
    [[ "$(copy_if_changed "$src_skill" "$REPO_MIRROR/$name/SKILL.md")" == synced ]] && changed=1
    if [[ -n "$refs" ]]; then
      IFS=',' read -ra ref_entries <<<"$refs"
      for ref in "${ref_entries[@]}"; do
        ref_file="${ref%%=*}"
        ref_resource="${ref#*=}"
        [[ "$(copy_if_changed "$RESOURCES/$ref_resource.md" "$REPO_MIRROR/$name/references/$ref_file")" == synced ]] && changed=1
      done
    fi
  fi

  if [[ "$changed" == 1 ]]; then
    echo "✓ $name — synchronisiert"
    overall_changed=1
  else
    echo "· $name — unverändert"
  fi
done

if [[ "$overall_changed" == 0 ]]; then
  echo "Alle Skills waren bereits aktuell."
else
  echo "Fertig. Neue Claude-Sessions laden die aktualisierten Skills automatisch."
fi
