#!/usr/bin/env bash
#
# Synchronisiert die gebündelten Agent-Skills und die Statusline aus
# WhisperM8/Resources/ nach ~/.claude/ (Claude Code liest von dort) — OHNE
# App-Build und ohne die laufende App anzufassen. Zusätzlich werden vorhandene
# Repo-Spiegel unter .claude/skills/<name>/ nachgezogen.
#
# Für jeden Skill wird ein Install-Stempel (.whisperm8-state.json) mit
# SHA-256-Hashes geschrieben. Die App nutzt ihn für den Drei-Wege-Status
# (Aktuell / Lokal geändert / Repo-Sync / Richtung unklar) in den Settings:
# CLISkillExporter.installState().
#
# Die Skill-Tabelle unten muss CLISkillExporter.SkillDefinition.all spiegeln.

set -euo pipefail

force=0
if [[ "${1:-}" == "--force" ]]; then
  force=1
  shift
fi
if [[ "$#" -ne 0 ]]; then
  echo "Verwendung: $0 [--force]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES="$REPO_ROOT/WhisperM8/Resources"
SKILLS_HOME="${WHISPERM8_SKILLS_HOME:-$HOME/.claude/skills}"
CLAUDE_HOME="${WHISPERM8_CLAUDE_HOME:-$HOME/.claude}"
REPO_MIRROR="${WHISPERM8_REPO_MIRROR:-$REPO_ROOT/.claude/skills}"
APP_BUNDLE_RESOURCES="${WHISPERM8_APP_BUNDLE_RESOURCES:-/Applications/WhisperM8.app/Contents/Resources/WhisperM8_WhisperM8.bundle}"
CP_BIN="${WHISPERM8_CP_BIN:-cp}"
STATUSLINE_SOURCE="$RESOURCES/whisperm8-statusline.sh"
STATUSLINE_TARGET="$CLAUDE_HOME/statusline-command.sh"
SUBAGENT_STATUSLINE_SOURCE="$RESOURCES/whisperm8-subagent-statusline.sh"
SUBAGENT_STATUSLINE_TARGET="$CLAUDE_HOME/subagent-statusline.sh"
STATUSLINE_STAMP="$CLAUDE_HOME/.whisperm8-statusline-state.json"

# <skill-name>|<resource>|<ref-datei>=<ref-resource>,…|<asset-pfad>=<asset-ressource>,…
SKILLS=(
  "whisperm8-transcription|whisperm8-cli-skill||"
  "codex-subagent|whisperm8-agent-skill|playwright-browser-qa.md=whisperm8-agent-skill-ref-playwright-browser-qa,1password-cli.md=whisperm8-agent-skill-ref-1password-cli,claude-workflows.md=whisperm8-agent-skill-ref-claude-workflows|"
  "whisperm8-chats|whisperm8-chats-skill||"
  "gpt-coworker|whisperm8-gpt-coworker-skill||"
  "gpt-workflow|whisperm8-gpt-workflow-skill||examples/wf-code-review.js=whisperm8-gpt-workflow-example-code-review.js,examples/wf-docs-review.js=whisperm8-gpt-workflow-example-docs-review.js"
)

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

# Liest einen Datei-Hash aus dem installed-Dictionary eines Stempels. plutil
# ist Bestandteil von macOS; ungültige oder fremde Stempel gelten nicht als
# Ownership-Nachweis.
stamp_hash_for() {
  local stamp="$1" key="$2" xml
  [[ -f "$stamp" && ! -L "$stamp" ]] || return 1
  xml="$(/usr/bin/plutil -extract installed xml1 -o - "$stamp" 2>/dev/null)" || return 1
  printf '%s\n' "$xml" | awk -v key="$key" '
    index($0, "<key>" key "</key>") {
      if (getline <= 0) exit 1
      sub(/^[[:space:]]*<string>/, "")
      sub(/<\/string>[[:space:]]*$/, "")
      print
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  '
}

# Abweichende Dateien dürfen nur überschrieben werden, wenn ihr aktueller Hash
# dem zuletzt von WhisperM8 gestempelten installierten Hash entspricht. Symlinks
# werden auch mit --force nie beschrieben.
check_managed_target() {
  local src="$1" dst="$2" stamp="$3" key="$4" expected current
  if [[ -L "$dst" ]]; then
    echo "WARNUNG: $dst ist ein Symlink und wird nicht überschrieben." >&2
    return 3
  fi
  if [[ ! -e "$dst" ]]; then
    return 0
  fi
  if [[ ! -f "$dst" ]]; then
    echo "WARNUNG: $dst ist keine reguläre Datei und wird nicht überschrieben." >&2
    return 3
  fi
  if cmp -s "$src" "$dst" || [[ "$force" == 1 ]]; then
    return 0
  fi
  expected="$(stamp_hash_for "$stamp" "$key")" || {
    echo "WARNUNG: Fremder oder nicht gestempelter Skill bleibt unverändert: $dst" >&2
    echo "          Nach manueller Prüfung kann mit --force ersetzt werden." >&2
    return 3
  }
  current="$(sha256 "$dst")"
  if [[ "$current" != "$expected" ]]; then
    echo "WARNUNG: Lokal geänderter Skill bleibt unverändert: $dst" >&2
    echo "          Nach manueller Prüfung kann mit --force ersetzt werden." >&2
    return 3
  fi
}

# Kopiert nur bei Inhaltsunterschied. COPY_RESULT vermeidet Command-Substitution,
# damit Kopierfehler nicht durch Bash-errexit-Sonderregeln verschluckt werden.
COPY_RESULT=unchanged
copy_if_changed() {
  local src="$1" dst="$2"
  COPY_RESULT=unchanged
  if [[ -L "$dst" ]]; then
    echo "FEHLER: Symlink-Ziel wird nicht überschrieben: $dst" >&2
    return 3
  fi
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    return 0
  fi
  if ! mkdir -p "$(dirname "$dst")"; then
    echo "FEHLER: Zielordner konnte nicht erstellt werden: $(dirname "$dst")" >&2
    return 1
  fi
  if ! "$CP_BIN" "$src" "$dst"; then
    echo "FEHLER: Kopieren fehlgeschlagen: $src -> $dst" >&2
    return 1
  fi
  COPY_RESULT=synced
}

overall_changed=0

for entry in "${SKILLS[@]}"; do
  IFS='|' read -r name resource refs assets <<<"$entry"
  src_skill="$RESOURCES/$resource.md"
  if [[ ! -f "$src_skill" ]]; then
    echo "FEHLER: Ressource fehlt: $src_skill" >&2
    exit 1
  fi

  target_dir="$SKILLS_HOME/$name"
  stamp_url="$target_dir/.whisperm8-state.json"
  changed=0

  if [[ -L "$target_dir" ]]; then
    echo "WARNUNG: Skill-Ordner ist ein Symlink und wird nicht überschrieben: $target_dir" >&2
    exit 3
  fi
  if [[ -L "$stamp_url" ]]; then
    echo "WARNUNG: Install-Stempel ist ein Symlink und wird nicht überschrieben: $stamp_url" >&2
    exit 3
  fi

  check_managed_target "$src_skill" "$target_dir/SKILL.md" "$stamp_url" "SKILL.md" || exit $?

  ref_entries=()
  if [[ -n "$refs" ]]; then
    if [[ -L "$target_dir/references" ]]; then
      echo "WARNUNG: references-Ordner ist ein Symlink und wird nicht überschrieben: $target_dir/references" >&2
      exit 3
    fi
    IFS=',' read -ra ref_entries <<<"$refs"
    for ref in "${ref_entries[@]}"; do
      ref_file="${ref%%=*}"
      ref_resource="${ref#*=}"
      src_ref="$RESOURCES/$ref_resource.md"
      if [[ ! -f "$src_ref" ]]; then
        echo "FEHLER: Referenz-Ressource fehlt: $src_ref" >&2
        exit 1
      fi
      check_managed_target \
        "$src_ref" "$target_dir/references/$ref_file" "$stamp_url" \
        "references/$ref_file" || exit $?
    done
  fi

  asset_entries=()
  if [[ -n "$assets" ]]; then
    IFS=',' read -ra asset_entries <<<"$assets"
    for asset in "${asset_entries[@]}"; do
      asset_path="${asset%%=*}"
      asset_resource="${asset#*=}"
      if [[ -z "$asset_path" || "$asset_path" == /* || "$asset_path" == *".."* ]]; then
        echo "FEHLER: Ungültiger relativer Asset-Pfad: $asset_path" >&2
        exit 1
      fi
      src_asset="$RESOURCES/$asset_resource"
      if [[ ! -f "$src_asset" ]]; then
        echo "FEHLER: Asset-Ressource fehlt: $src_asset" >&2
        exit 1
      fi
      asset_parent="$target_dir/$(dirname "$asset_path")"
      if [[ -L "$asset_parent" ]]; then
        echo "WARNUNG: Asset-Ordner ist ein Symlink und wird nicht überschrieben: $asset_parent" >&2
        exit 3
      fi
      check_managed_target \
        "$src_asset" "$target_dir/$asset_path" "$stamp_url" \
        "$asset_path" || exit $?
    done
  fi

  copy_if_changed "$src_skill" "$target_dir/SKILL.md" || exit $?
  [[ "$COPY_RESULT" == synced ]] && changed=1

  # Stempel-Hashes über den installierten Stand aufsammeln.
  stamp_installed="\"SKILL.md\": \"$(sha256 "$target_dir/SKILL.md")\""
  stamp_bundled=""
  if [[ -f "$APP_BUNDLE_RESOURCES/$resource.md" ]]; then
    stamp_bundled="\"SKILL.md\": \"$(sha256 "$APP_BUNDLE_RESOURCES/$resource.md")\""
  fi

  if [[ -n "$refs" ]]; then
    for ref in "${ref_entries[@]}"; do
      ref_file="${ref%%=*}"
      ref_resource="${ref#*=}"
      src_ref="$RESOURCES/$ref_resource.md"
      copy_if_changed "$src_ref" "$target_dir/references/$ref_file" || exit $?
      [[ "$COPY_RESULT" == synced ]] && changed=1
      stamp_installed+=", \"references/$ref_file\": \"$(sha256 "$target_dir/references/$ref_file")\""
      if [[ -n "$stamp_bundled" && -f "$APP_BUNDLE_RESOURCES/$ref_resource.md" ]]; then
        stamp_bundled+=", \"references/$ref_file\": \"$(sha256 "$APP_BUNDLE_RESOURCES/$ref_resource.md")\""
      fi
    done
  fi

  if [[ -n "$assets" ]]; then
    for asset in "${asset_entries[@]}"; do
      asset_path="${asset%%=*}"
      asset_resource="${asset#*=}"
      copy_if_changed "$RESOURCES/$asset_resource" "$target_dir/$asset_path" || exit $?
      [[ "$COPY_RESULT" == synced ]] && changed=1
      stamp_installed+=", \"$asset_path\": \"$(sha256 "$target_dir/$asset_path")\""
      if [[ -n "$stamp_bundled" && -f "$APP_BUNDLE_RESOURCES/$asset_resource" ]]; then
        stamp_bundled+=", \"$asset_path\": \"$(sha256 "$APP_BUNDLE_RESOURCES/$asset_resource")\""
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
  } >"$stamp_url"

  # Repo-Spiegel nur pflegen, wenn er bereits existiert. Symlinks werden auch
  # hier nie verfolgt, damit ein Spiegel keine externen Dateien überschreibt.
  if [[ -d "$REPO_MIRROR/$name" ]]; then
    mirror_dir="$REPO_MIRROR/$name"
    if [[ -L "$mirror_dir" ]]; then
      echo "WARNUNG: Repo-Spiegel ist ein Symlink und wird nicht überschrieben: $mirror_dir" >&2
      exit 3
    fi
    if [[ -n "$refs" && -L "$mirror_dir/references" ]]; then
      echo "WARNUNG: Referenz-Ordner im Repo-Spiegel ist ein Symlink: $mirror_dir/references" >&2
      exit 3
    fi
    if [[ -n "$assets" ]]; then
      for asset in "${asset_entries[@]}"; do
        asset_path="${asset%%=*}"
        mirror_parent="$mirror_dir/$(dirname "$asset_path")"
        if [[ -L "$mirror_parent" ]]; then
          echo "WARNUNG: Asset-Ordner im Repo-Spiegel ist ein Symlink: $mirror_parent" >&2
          exit 3
        fi
      done
    fi

    copy_if_changed "$src_skill" "$mirror_dir/SKILL.md" || exit $?
    [[ "$COPY_RESULT" == synced ]] && changed=1
    if [[ -n "$refs" ]]; then
      for ref in "${ref_entries[@]}"; do
        ref_file="${ref%%=*}"
        ref_resource="${ref#*=}"
        copy_if_changed \
          "$RESOURCES/$ref_resource.md" \
          "$REPO_MIRROR/$name/references/$ref_file" || exit $?
        [[ "$COPY_RESULT" == synced ]] && changed=1
      done
    fi
    if [[ -n "$assets" ]]; then
      for asset in "${asset_entries[@]}"; do
        asset_path="${asset%%=*}"
        asset_resource="${asset#*=}"
        copy_if_changed \
          "$RESOURCES/$asset_resource" \
          "$REPO_MIRROR/$name/$asset_path" || exit $?
        [[ "$COPY_RESULT" == synced ]] && changed=1
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

  if [[ -L "$target_path" ]]; then
    echo "WARNUNG: statusline — Symlink bleibt unverändert: $target_path" >&2
    statusline_skipped=1
    continue
  fi
  if [[ -f "$target_path" ]] && ! grep -Fq "managed-by: whisperm8-statusline" "$target_path"; then
    echo "WARNUNG: statusline — fremdes Skript bleibt unverändert: $target_path" >&2
    statusline_skipped=1
    continue
  fi

  copy_if_changed "$source_path" "$target_path" || exit $?
  chmod 755 "$target_path"
  [[ "$COPY_RESULT" == synced ]] && statusline_changed=1
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
