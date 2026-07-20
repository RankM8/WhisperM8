#!/usr/bin/env bash
#
# Synchronisiert die gebündelten Agent-Skills und die Statusline aus
# WhisperM8/Resources/ nach ~/.claude/ (Claude Code liest von dort) — OHNE
# App-Build und ohne die laufende App anzufassen. Zusätzlich werden vorhandene
# Repo-Spiegel unter .claude/skills/<name>/ nachgezogen.
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
CLAUDE_HOME="${WHISPERM8_CLAUDE_HOME:-$HOME/.claude}"
REPO_MIRROR="$REPO_ROOT/.claude/skills"
APP_BUNDLE_RESOURCES="/Applications/WhisperM8.app/Contents/Resources/WhisperM8_WhisperM8.bundle"
STATUSLINE_SOURCE="$RESOURCES/whisperm8-statusline.sh"
STATUSLINE_TARGET="$CLAUDE_HOME/statusline-command.sh"
SUBAGENT_STATUSLINE_SOURCE="$RESOURCES/whisperm8-subagent-statusline.sh"
SUBAGENT_STATUSLINE_TARGET="$CLAUDE_HOME/subagent-statusline.sh"
STATUSLINE_STAMP="$CLAUDE_HOME/.whisperm8-statusline-state.json"

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

# Statuslines synchronisieren, ohne settings.json anzufassen. Markerlose Ziele
# gehören dem User und werden pro Datei bewusst nicht überschrieben.
statusline_skipped=0
statusline_changed=0
statusline_sources=("$STATUSLINE_SOURCE" "$SUBAGENT_STATUSLINE_SOURCE")
statusline_targets=("$STATUSLINE_TARGET" "$SUBAGENT_STATUSLINE_TARGET")

for index in 0 1; do
  source_path="${statusline_sources[$index]}"
  target_path="${statusline_targets[$index]}"
  if [[ ! -f "$source_path" ]]; then
    echo "FEHLER: Statusline-Ressource fehlt: $source_path" >&2
    exit 1
  fi

  if [[ -f "$target_path" ]] && ! grep -Fq "managed-by: whisperm8-statusline" "$target_path"; then
    echo "WARNUNG: statusline — fremdes Skript bleibt unverändert: $target_path" >&2
    statusline_skipped=1
    continue
  fi

  result="$(copy_if_changed "$source_path" "$target_path")"
  chmod 755 "$target_path"
  [[ "$result" == synced ]] && statusline_changed=1
done

# Install-Stempel schreiben (Format: StatuslineInstaller.InstallStamp). Auch
# geschützte Fremdziele werden als tatsächlich installierter Stand gehasht;
# die App erkennt sie weiterhin vorrangig über den fehlenden Marker.
statusline_installed="\"statusline-command.sh\": \"$(sha256 "$STATUSLINE_TARGET")\", \"subagent-statusline.sh\": \"$(sha256 "$SUBAGENT_STATUSLINE_TARGET")\""
statusline_bundled=""
bundled_statusline="$APP_BUNDLE_RESOURCES/whisperm8-statusline.sh"
bundled_subagent_statusline="$APP_BUNDLE_RESOURCES/whisperm8-subagent-statusline.sh"
if [[ -r "$bundled_statusline" && -r "$bundled_subagent_statusline" ]]; then
  statusline_bundled="\"statusline-command.sh\": \"$(sha256 "$bundled_statusline")\", \"subagent-statusline.sh\": \"$(sha256 "$bundled_subagent_statusline")\""
fi

mkdir -p "$CLAUDE_HOME"
{
  echo '{'
  echo '  "source": "resources",'
  echo "  \"updatedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"installed\": { $statusline_installed }$( [[ -n "$statusline_bundled" ]] && echo ',' )"
  [[ -n "$statusline_bundled" ]] && echo "  \"bundled\": { $statusline_bundled }"
  echo '}'
} >"$STATUSLINE_STAMP"

if [[ "$statusline_changed" == 1 ]]; then
  echo "✓ statuslines — synchronisiert"
  overall_changed=1
else
  echo "· statuslines — unverändert"
fi

if [[ "$statusline_skipped" == 1 ]]; then
  if [[ "$overall_changed" == 0 ]]; then
    echo "Alle Skills waren bereits aktuell; die fremde Statusline wurde übersprungen."
  else
    echo "Fertig. Die fremde Statusline wurde übersprungen."
  fi
elif [[ "$overall_changed" == 0 ]]; then
  echo "Alle Skills und die Statusline waren bereits aktuell."
else
  echo "Fertig. Neue Claude-Sessions laden die aktualisierten Skills automatisch."
fi
