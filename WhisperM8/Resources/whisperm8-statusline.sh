#!/bin/bash
# managed-by: whisperm8-statusline
#
# WhisperM8-Statusline für Claude Code — installiert über die WhisperM8-App
# (Einstellungen → CLI & Skills). Zeigt Repo/Branch, Kontext-Füllstand mit
# exaktem Token-Wert (auch für GPT-Sessions über den WhisperM8-Mix-Router),
# Modell und aktives Account-Profil (CLAUDE_CONFIG_DIR-Switcher), Effort-Level,
# Account-Usage-Limits, Kosten sowie aktive Subagents und MCP-Server.
# Benötigt: jq, git; Usage-Limits optional (curl + macOS-Keychain).
input=$(cat)

# jq ist eine harte Voraussetzung (macOS < 15 liefert es nicht mit) —
# ohne jq lieber eine klare Zeile als ein Schwall "command not found".
if ! command -v jq >/dev/null 2>&1; then
    echo "whisperm8-statusline: jq fehlt (brew install jq)"
    exit 0
fi

# ── Profil-Kontext (Account-Switcher via CLAUDE_CONFIG_DIR) ──────────────
# Läuft die Session mit CLAUDE_CONFIG_DIR (Zusatz-Account), zeigen alle
# account-bezogenen Teile (Usage-Limits, Profilname) DIESES Profil.
cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "$CLAUDE_CONFIG_DIR" ]; then
    ccs_profile=$(basename "$CLAUDE_CONFIG_DIR")
else
    ccs_profile="main"
fi

# ── Tuning ────────────────────────────────────────────────────────────────
# Schwellenwert (% des vollen Fensters), ab dem Claude Code automatisch
# komprimiert. Hier justieren, falls Compaction früher/später auslöst.
COMPACT_AT=85
# ──────────────────────────────────────────────────────────────────────────

# Model Name
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')

# Projektname (Hauptrepo-Name, kein Pfad/Ordner)
# --git-common-dir stellt sicher, dass auch Worktrees den echten Repo-Namen zeigen
repo_root=$(git --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
if [ -n "$repo_root" ]; then
    common_dir=$(git --no-optional-locks rev-parse --git-common-dir 2>/dev/null)
    case "$common_dir" in
        /*) ;;
        *) common_dir="$(cd "$common_dir" 2>/dev/null && pwd)" ;;
    esac
    if [ -n "$common_dir" ]; then
        repo_name=$(basename "$(dirname "$common_dir")")
    else
        repo_name=$(basename "$repo_root")
    fi
else
    repo_name=$(basename "$(pwd)")
fi
repo_display="\033[1;35m${repo_name}\033[0m"  # Bold magenta

# Git Branch — Format: (branch) statt git:(branch)
branch=$(git --no-optional-locks branch --show-current 2>/dev/null || echo "")
if [ -n "$branch" ]; then
    if git --no-optional-locks diff --quiet 2>/dev/null && git --no-optional-locks diff --cached --quiet 2>/dev/null; then
        # Clean: (roter Branch)
        branch_display="(\033[31m${branch}\033[0m)"
    else
        # Dirty: (roter Branch) + gelbes ✗
        branch_display="(\033[31m${branch}\033[0m) \033[33m✗\033[0m"
    fi
else
    branch_display=""
fi

# Ahead/Behind Remote
ahead_behind=$(git --no-optional-locks rev-list --left-right --count HEAD...@{upstream} 2>/dev/null)
if [ -n "$ahead_behind" ]; then
    ahead=$(echo "$ahead_behind" | cut -f1)
    behind=$(echo "$ahead_behind" | cut -f2)
    ab_display=""
    if [ "$ahead" -gt 0 ]; then
        ab_display="↑${ahead}"
    fi
    if [ "$behind" -gt 0 ]; then
        # Orange wenn behind (sollte pullen)
        ab_display="${ab_display}\033[33m↓${behind}\033[0m"
    fi
else
    ab_display=""
fi

# Kosten (LANG=C für korrektes Zahlenformat)
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
cost_display=$(LANG=C awk -v c="$cost" 'BEGIN {printf "$%.2f", c}')

# API Usage Limits - async Background-Fetch mit Cache
hourly_display=""
weekly_display=""

# Pro Profil eigener Cache — sonst zeigt Account B die Limits von Account A.
# Bewusst $TMPDIR (macOS: privates per-User-Verzeichnis) statt /tmp:
# weltschreibbare, vorhersagbare /tmp-Pfade wären auf Multi-User-Macs
# lesbar für andere und via vorab platzierter Symlinks angreifbar.
tmp_base="${TMPDIR:-/tmp/}"
usage_cache="${tmp_base}claude-usage-cache-${ccs_profile}.json"
usage_lock="${tmp_base}claude-usage-fetch-${ccs_profile}.lock"
usage_cooldown="${tmp_base}claude-usage-cooldown-${ccs_profile}"
usage_cache_ttl=1800  # 30 Minuten
usage_cooldown_ttl=600  # 10 Min Cooldown nach fehlgeschlagenem Fetch

# Background-Fetch starten wenn Cache abgelaufen (non-blocking)
if [ -f "$usage_cache" ]; then
    cache_age=$(( $(date +%s) - $(stat -f %m "$usage_cache" 2>/dev/null || echo 0) ))
else
    cache_age=999999
fi

# Cooldown prüfen (nach Rate-Limit nicht sofort wieder versuchen)
in_cooldown=false
if [ -f "$usage_cooldown" ]; then
    cooldown_age=$(( $(date +%s) - $(stat -f %m "$usage_cooldown" 2>/dev/null || echo 0) ))
    if [ "$cooldown_age" -lt "$usage_cooldown_ttl" ]; then
        in_cooldown=true
    fi
fi

# Stale Lock entfernen (>30s alt)
if [ -f "$usage_lock" ]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$usage_lock" 2>/dev/null || echo 0) ))
    if [ "$lock_age" -gt 30 ]; then
        rm -f "$usage_lock"
    fi
fi

if [ "$cache_age" -ge "$usage_cache_ttl" ] && [ "$in_cooldown" = false ] && ! [ -f "$usage_lock" ]; then
    # Lock setzen und im Hintergrund fetchen
    (
        echo $$ > "$usage_lock"
        trap 'rm -f "$usage_lock"' EXIT
        # Keychain-Service je Profil: main = Standardname, Zusatzprofile =
        # Suffix sha256(<config-dir>)[0:8] (verifiziert, claude v2.1.207).
        # Hinterlegte .keychain-service-Datei gewinnt, sonst wird berechnet.
        if [ -z "$CLAUDE_CONFIG_DIR" ]; then
            keychain_service="Claude Code-credentials"
        elif [ -f "$cfg_dir/.keychain-service" ]; then
            keychain_service=$(cat "$cfg_dir/.keychain-service")
        else
            keychain_service="Claude Code-credentials-$(echo -n "$cfg_dir" | shasum -a 256 | cut -c1-8)"
        fi
        access_token=""
        [ -n "$keychain_service" ] && access_token=$(security find-generic-password -s "$keychain_service" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty')
        if [ -n "$access_token" ]; then
            # Token via stdin-Header (-H @-) statt Prozessargument — Argumente
            # sind in der Prozessliste für lokale Beobachter sichtbar.
            resp=$(printf 'Authorization: Bearer %s\n' "$access_token" | \
                curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
                -H @- \
                -H "Content-Type: application/json" \
                -H "User-Agent: claude-code/2.1.71" \
                -H "anthropic-version: 2023-06-01" \
                -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
            if echo "$resp" | jq -e '.five_hour or .seven_day' >/dev/null 2>&1; then
                echo "$resp" > "$usage_cache"
                rm -f "$usage_cooldown"
            else
                # Rate-Limited: Cooldown setzen
                touch "$usage_cooldown"
            fi
        else
            # Kein Token (ausgeloggtes Profil): ebenfalls Cooldown — sonst
            # spawnt jeder Statusline-Refresh erneut security+jq.
            touch "$usage_cooldown"
        fi
    ) &
fi

# Immer vom Cache lesen (non-blocking)
if [ -f "$usage_cache" ]; then
    usage_response=$(cat "$usage_cache")

    # 5-Stunden-Limit extrahieren
    five_hour_util=$(echo "$usage_response" | jq -r '.five_hour.utilization // empty')
    if [ -n "$five_hour_util" ]; then
        hourly_pct=$(LANG=C awk -v u="$five_hour_util" 'BEGIN {printf "%.0f", u}')
        if [ "$hourly_pct" -ge 80 ]; then
            hourly_color="\033[31m"  # Rot
        elif [ "$hourly_pct" -ge 50 ]; then
            hourly_color="\033[33m"  # Orange
        else
            hourly_color=""
        fi
        if [ -n "$hourly_color" ]; then
            hourly_display="${hourly_color}${hourly_pct}%\033[0m/5h"
        else
            hourly_display="${hourly_pct}%/5h"
        fi
    fi

    # 7-Tage-Limit extrahieren
    seven_day_util=$(echo "$usage_response" | jq -r '.seven_day.utilization // empty')
    if [ -n "$seven_day_util" ]; then
        weekly_pct=$(LANG=C awk -v u="$seven_day_util" 'BEGIN {printf "%.0f", u}')

        # Reset-Zeitpunkt des Weekly-Limits (resets_at ist UTC -> lokaler Wochentag)
        weekly_reset=""
        reset_raw=$(echo "$usage_response" | jq -r '.seven_day.resets_at // empty')
        if [ -n "$reset_raw" ]; then
            # Fractional Seconds + TZ-Offset abschneiden, Rest als UTC parsen
            reset_clean=$(echo "$reset_raw" | sed -E 's/\.[0-9]+.*//; s/\+.*//; s/Z$//')
            reset_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$reset_clean" "+%s" 2>/dev/null)
            if [ -n "$reset_epoch" ]; then
                # In lokaler Zeit formatieren, Wochentag auf Deutsch
                reset_fmt=$(date -r "$reset_epoch" "+%a" 2>/dev/null | \
                    sed 's/^Mon/Mo/; s/^Tue/Di/; s/^Wed/Mi/; s/^Thu/Do/; s/^Fri/Fr/; s/^Sat/Sa/; s/^Sun/So/')
                [ -n "$reset_fmt" ] && weekly_reset=" ↻${reset_fmt}"
            fi
        fi

        if [ "$weekly_pct" -ge 80 ]; then
            weekly_color="\033[31m"  # Rot
        elif [ "$weekly_pct" -ge 50 ]; then
            weekly_color="\033[33m"  # Orange
        else
            weekly_color=""
        fi
        if [ -n "$weekly_color" ]; then
            weekly_display="${weekly_color}${weekly_pct}%\033[0m/w${weekly_reset}"
        else
            weekly_display="${weekly_pct}%/w${weekly_reset}"
        fi
    fi
fi

# Beide Usage-Limits bilden gemeinsam ein Segment.
limits_display=""
if [ -n "$hourly_display" ] && [ -n "$weekly_display" ]; then
    limits_display="${hourly_display} \033[2m·\033[0m ${weekly_display}"
elif [ -n "$hourly_display" ]; then
    limits_display="$hourly_display"
elif [ -n "$weekly_display" ]; then
    limits_display="$weekly_display"
fi

# MCP Server Information
mcp_display=""
mcp_servers=$(echo "$input" | jq -r '.mcp_servers // [] | length')
if [ "$mcp_servers" -gt 0 ]; then
    # Build MCP display string with server names and context percentages
    mcp_list=$(echo "$input" | jq -r '.mcp_servers // [] | map("\(.name):\(.context_percentage // 0)%") | join(" ")')

    # Calculate total MCP context usage
    total_mcp_pct=$(echo "$input" | jq -r '[.mcp_servers // [] | .[].context_percentage // 0] | add // 0')

    # Color based on total usage
    if [ $(echo "$total_mcp_pct >= 50" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
        mcp_color="\033[33m"  # Orange for high usage
    else
        mcp_color="\033[36m"  # Cyan for normal
    fi

    mcp_display="${mcp_color}MCP:${mcp_servers} ${mcp_list}\033[0m"
fi

# Effort Level
effort_level=$(echo "$input" | jq -r '.effort.level // empty')
if [ -n "$effort_level" ]; then
    case "$effort_level" in
        max|xhigh)
            effort_color="\033[31m"  # Rot
            ;;
        high)
            effort_color="\033[33m"  # Orange
            ;;
        medium)
            effort_color="\033[32m"  # Grün
            ;;
        *)
            effort_color="\033[2m"   # Dim für low
            ;;
    esac
    effort_display="${effort_color}${effort_level}\033[0m"
else
    effort_display=""
fi

# Context: Rest bis Auto-Compact
# Quelle: echte Token-Werte des Harness, gemessen gegen das Compact-Budget
# (= COMPACT_AT % des vollen Fensters).
reset="\033[0m"
dim="\033[2m"
usage=$(echo "$input" | jq '.context_window.current_usage')
if [ "$usage" = "null" ]; then
    remaining=100
    used_of_budget=0
    ctx_exact=""
else
    current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
    size=$(echo "$input" | jq '.context_window.context_window_size')
    compact_budget=$((size * COMPACT_AT / 100))
    if [ "$compact_budget" -le 0 ]; then compact_budget=1; fi
    used_of_budget=$((current * 100 / compact_budget))
    if [ $used_of_budget -gt 100 ]; then used_of_budget=100; fi
    remaining=$((100 - used_of_budget))
    if [ $remaining -lt 0 ]; then remaining=0; fi
    # Exakter Kontext-Wert: verbrauchte Token / volles Modellfenster.
    # Wichtig für GPT-Sessions (272k-Fenster via CLAUDE_CODE_AUTO_COMPACT_WINDOW).
    ctx_exact="$((current / 1000))k/$((size / 1000))k"
fi

# Farbe basierend auf Verbrauch (viel verbraucht = Warnung)
if [ $used_of_budget -ge 90 ]; then
    color="\033[31m"  # Rot: Compact steht unmittelbar bevor
elif [ $used_of_budget -ge 75 ]; then
    color="\033[33m"  # Orange: wird knapp
else
    color="\033[32m"  # Grün
fi

# Die Prozentzahl übernimmt die Warnfarbe des früheren Kontext-Balkens.

# Subagent-Erkennung via Session-eigene Subagent-Transcripts
# Das Statusline-JSON hat kein Subagent-Feld. Claude Code legt aber pro Session
# unter "<transcript-ohne-.jsonl>/subagents/agent-*.jsonl" je Subagent ein
# eigenes Transcript an. "Läuft gerade" hat keinen expliziten Marker — als
# Heuristik gilt ein Subagent als aktiv, wenn sein Transcript in den letzten
# SUBAGENT_WINDOW Sekunden geschrieben wurde (laufende Agents streamen ständig,
# fertige hören auf). Das Modell wird aus dem Transcript-Inhalt gelesen —
# inklusive GPT-Subagents (WhisperM8-GPT-Backend, Agent-Typ »gpt«).
# Diese Quelle ist sauber auf DIESE Session beschränkt — fremde Sessions/Tabs
# können nicht mitgezählt werden.
SUBAGENT_WINDOW=60
subagent_display=""
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
subagent_dir="${transcript_path%.jsonl}/subagents"
if [ -n "$transcript_path" ] && [ -d "$subagent_dir" ]; then
    now_ts=$(date +%s)
    subagent_count=0
    model_list=""

    while IFS= read -r sub_file; do
        # Nur kürzlich geschriebene Transcripts = aktuell laufende Subagents
        file_mtime=$(stat -f %m "$sub_file" 2>/dev/null || echo 0)
        sub_age=$((now_ts - file_mtime))
        [ "$sub_age" -gt "$SUBAGENT_WINDOW" ] && continue

        subagent_count=$((subagent_count + 1))

        # Modell aus dem Transcript lesen (erstes Vorkommen reicht — konstant je Agent)
        raw_model=$(grep -o -m1 -E '"model":"(claude|gpt)-[a-z0-9.-]+"' "$sub_file" 2>/dev/null | head -1)
        if [ -n "$raw_model" ]; then
            case "$raw_model" in
                *opus*)   short="Opus" ;;
                *sonnet*) short="Sonnet" ;;
                *haiku*)  short="Haiku" ;;
                *fable*)  short="Fable" ;;
                *gpt*)    short="GPT" ;;
                *)        short=$(echo "$raw_model" | sed -E 's/.*"(claude|gpt)-([a-z]+).*/\2/') ;;
            esac
            # Deduplizieren (gleiche Modelle nur einmal listen)
            if [ -n "$short" ] && ! echo "$model_list" | grep -qw "$short"; then
                [ -n "$model_list" ] && model_list="${model_list}, ${short}" || model_list="$short"
            fi
        fi
    done < <(find "$subagent_dir" -maxdepth 1 -name 'agent-*.jsonl' 2>/dev/null)

    if [ "$subagent_count" -gt 0 ]; then
        if [ -n "$model_list" ]; then
            subagent_display="\033[36m⚡${subagent_count} sub (${model_list})\033[0m"
        else
            subagent_display="\033[36m⚡${subagent_count} sub\033[0m"
        fi
    fi
fi

# Account-Anzeige direkt hinter dem Modell: main dezent, Zusatzprofile auffällig.
if [ "$ccs_profile" != "main" ]; then
    # Zusatz-Account: Profilname auffällig (gelb) — falscher Account ist der teuerste Bedienfehler
    account_display="\033[1;33m⇄${ccs_profile}\033[0m"
else
    account_display="\033[2m⇄main\033[0m"
fi

# Ausgabe zusammenbauen
# Format: repo (branch) ✗ ↑3 | 30% 258k/1000k | [Fable 5] ⇄PowerUser | high | 32%/5h · 42%/w ↻Sa | $16.20 | ⚡2 sub (Fable, GPT) | MCP:1 server:4%
output="${repo_display}"

if [ -n "$branch_display" ]; then
    output="${output} ${branch_display}"
fi

if [ -n "$ab_display" ]; then
    output="${output} ${ab_display}"
fi

if [ -n "$ctx_exact" ]; then
    output="${output} ${dim}|${reset} ${color}${used_of_budget}%${reset} ${dim}${ctx_exact}${reset} ${dim}|${reset} [${model}] ${account_display}"
else
    output="${output} ${dim}|${reset} ${color}${used_of_budget}%${reset} ${dim}|${reset} [${model}] ${account_display}"
fi

if [ -n "$effort_display" ]; then
    output="${output} ${dim}|${reset} ${effort_display}"
fi

if [ -n "$limits_display" ]; then
    output="${output} ${dim}|${reset} ${limits_display}"
fi

if [ -n "$cost_display" ]; then
    output="${output} ${dim}|${reset} ${dim}${cost_display}${reset}"
fi

if [ -n "$subagent_display" ]; then
    output="${output} ${dim}|${reset} ${subagent_display}"
fi

if [ -n "$mcp_display" ]; then
    output="${output} ${dim}|${reset} ${mcp_display}"
fi

echo -e "${output}"
