#!/usr/bin/env bash
# Prüft an der installierten Claude-Code-CLI, worauf WhisperM8 beim nativen
# Sitzungs-Messaging (ListAgents/SendMessage) baut (WM8-79,
# docs/plans/chat-kommunikation.md). Bei jeder neuen Claude-Code-Version fahren:
#
#   scripts/claude-peer-messaging-check.sh [konto-a] [konto-b]   # Standard: ai ai2
#
# Läuft außerhalb der App mit drei Wegwerf-Sitzungen (tmux -L wm8peer, fester
# Ordner $TMPDIR/wm8-peer-messaging-check), kostet rund zehn kurze Anfragen
# (Sonnet) auf den beiden Konten und fasst keinen echten Chat an. Claude legt
# dabei in beiden Konten Verläufe und die Ordner-Freigabe an; die App zeigt den
# Ordner als Projekt „wm8-peer-messaging-check“. Aufräumen je Konto:
#   CLAUDE_CONFIG_DIR=~/.claude-profiles/<konto> claude purge --dry-run "$(cd "$TMPDIR/wm8-peer-messaging-check" && pwd -P)"
#   (danach dasselbe mit --yes statt --dry-run)
#
# Geprüft wird:
#   1. ListAgents zeigt eine Sitzung desselben Kontos, aber nicht die des anderen.
#   2. SendMessage an die uds:-Adresse erreicht das andere Konto.
#   3. Die Nachricht löst beim Empfänger UserPromptSubmit aus, Prompt in
#      <cross-session-message from="uds:…" from-name="…">.
#   4. Arbeitet der Empfänger, kommt die Nachricht mitten im Turn an
#      (UserPromptSubmit vor dem Stop desselben Turns).
#   5. Eine offene Rückfrage (AskUserQuestion) bleibt unberührt; die Nachricht
#      kommt erst nach der Antwort.
#   6. Eine offene Freigabe bleibt unberührt (Datei bleibt); die Nachricht
#      kommt erst, nachdem die Freigabe abgelehnt wurde.
# Ergebnis: OK/FEHLER je Punkt, Rückgabe 1 bei einem Fehler, 2 bei fehlendem Werkzeug/Konto.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v tmux >/dev/null || { echo "tmux fehlt (brew install tmux)" >&2; exit 2; }
command -v claude >/dev/null || { echo "claude fehlt im PATH" >&2; exit 2; }
source scripts/claude-peer-messaging-lib.sh

A_ACC="${1:-ai}" B_ACC="${2:-ai2}"
peer_require_account "$A_ACC" || exit 2
peer_require_account "$B_ACC" || exit 2
FAILED=0
trap peer_stop_all EXIT

check() {
    if [[ "$2" == ok ]]; then echo "OK      $1"; else echo "FEHLER  $1"; FAILED=1; fi
}
hooks_of() { cat "$PEER_DIR/logs/$1.hooks.jsonl" 2>/dev/null; }
wait_hook() {  # wait_hook <sitzung> <text> <sekunden>
    for _ in $(seq 1 "$3"); do hooks_of "$1" | grep -q -- "$2" && return 0; sleep 1; done
    return 1
}
send_from_s1() { peer_prompt s1 "Rufe SendMessage auf: to = \"$R_ADDR\", message = \"$1\". Sonst nichts."; }

# Empfänger: eine Warte-Anweisung erlaubt (sleep blockiert Claude selbst), rm fragt nach.
WAIT_CMD='python3 -c "import time; time.sleep(30)"'
R_EXTRA="$(python3 -c 'import json,sys; print(json.dumps({"permissions": {"allow": ["SendMessage", "ListAgents", "Bash(%s)" % sys.argv[1]], "ask": ["Bash(rm:*)"]}}))' "$WAIT_CMD")"

claude --version 2>/dev/null | head -1
rm -f "$PEER_DIR"/logs/{s1,s2,r}.hooks.jsonl
peer_start s1 "$A_ACC" default "$(peer_hook_settings s1)" || exit 2
peer_start s2 "$A_ACC" default "$(peer_hook_settings s2)" || exit 2
peer_start r "$B_ACC" default "$(peer_hook_settings r "$R_EXTRA")" || exit 2
sleep 3
R_ADDR="uds:$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["messagingSocketPath"])' "$(peer_registry r "$B_ACC")")"

# 1. Sichtbarkeit
peer_prompt s1 'Rufe ListAgents auf und gib nur die Namen der gefundenen Sitzungen aus, je Zeile einer, mit dem Präfix NAME: davor.'
sleep 3; peer_wait_status s1 "$A_ACC" idle 60; sleep 1
check "ListAgents sieht Sitzung im selben Konto ($A_ACC)" "$(peer_screen s1 | grep -q 'NAME: s2' && echo ok)"
check "ListAgents sieht das andere Konto ($B_ACC) nicht" "$(peer_screen s1 | grep -q 'NAME: r$' || echo ok)"

# 2./3. Zustellung über Konten, Hook
send_from_s1 WM8CHECK-1
wait_hook r WM8CHECK-1 60
check "SendMessage an uds:-Adresse erreicht Konto $B_ACC" "$(hooks_of r | grep -q 'WM8CHECK-1' && echo ok)"
check "UserPromptSubmit mit <cross-session-message from=\"uds:" "$(hooks_of r | grep 'WM8CHECK-1' | grep -q 'cross-session-message from=\\"uds:' && echo ok)"

# 4. Mitten im Turn
peer_wait_status r "$B_ACC" idle 60
peer_prompt r "Führe per Bash im Vordergrund (nicht im Hintergrund) genau diesen Befehl aus: $WAIT_CMD . Danach antworte mit WM8CHECK-EIGEN."
if peer_wait_status r "$B_ACC" busy 30; then
    sleep 6
    send_from_s1 WM8CHECK-3
    sleep 5; peer_wait_status r "$B_ACC" idle 120; sleep 2   # Turn zu Ende
    check "Nachricht an arbeitenden Empfänger: UserPromptSubmit vor dem Stop desselben Turns" "$(hooks_of r | python3 -c '
import json, sys
ev = [json.loads(l) for l in sys.stdin]
txt = lambda d: d.get("prompt") or d.get("last_assistant_message") or ""
start = max(i for i, d in enumerate(ev) if d["hook_event_name"] == "UserPromptSubmit" and "WM8CHECK-EIGEN" in txt(d))
rest = [d for d in ev[start + 1:] if d["hook_event_name"] in ("UserPromptSubmit", "Stop")]
print("ok" if rest and rest[0]["hook_event_name"] == "UserPromptSubmit" and "WM8CHECK-3" in txt(rest[0]) else "")
' 2>/dev/null)"
else
    check "Empfänger arbeitet (Warte-Befehl läuft)" fail
fi

# 5. Offene Rückfrage
peer_wait_status r "$B_ACC" idle 60
peer_prompt r 'Nutze sofort das Tool AskUserQuestion mit genau einer Frage "Welche Farbe?" und den Optionen Rot, Gruen, Blau. Sonst nichts.'
if peer_wait_for r 'Enter to select' 90; then
    send_from_s1 "WM8CHECK-2 Blau"
    sleep 20
    check "Rückfrage bleibt offen, während die Nachricht wartet" "$(peer_screen r | grep -q 'Enter to select' && echo ok)"
    check "Nachricht nicht vor der Antwort an Claude gegeben" "$(hooks_of r | grep -q 'WM8CHECK-2' || echo ok)"
    "${PEER_TMUX[@]}" send-keys -t r Enter   # Option 1 (Rot)
    wait_hook r WM8CHECK-2 40
    check "Antwort des Users bleibt (Rot)" "$(peer_screen r | grep -q '→ Rot' && echo ok)"
    check "Nachricht kommt nach der Antwort an" "$(hooks_of r | grep -q 'WM8CHECK-2' && echo ok)"
else
    check "Rückfrage-Dialog erschienen" fail
fi

# 6. Offene Freigabe
peer_wait_status r "$B_ACC" idle 60
touch "$PEER_DIR/wm8check-probe.txt"
peer_prompt r 'Führe per Bash genau diesen Befehl aus: rm wm8check-probe.txt'
if peer_wait_for r 'Do you want to proceed' 90; then
    send_from_s1 WM8CHECK-4
    sleep 20
    check "Freigabe bleibt offen, Datei bleibt" "$(peer_screen r | grep -q 'Do you want to proceed' && [[ -f "$PEER_DIR/wm8check-probe.txt" ]] && echo ok)"
    check "Nachricht nicht vor der Entscheidung an Claude gegeben" "$(hooks_of r | grep -q 'WM8CHECK-4' || echo ok)"
    "${PEER_TMUX[@]}" send-keys -t r Escape   # ablehnen
    wait_hook r WM8CHECK-4 40
    check "Nachricht kommt nach der Ablehnung an, Datei bleibt" "$(hooks_of r | grep -q 'WM8CHECK-4' && [[ -f "$PEER_DIR/wm8check-probe.txt" ]] && echo ok)"
else
    check "Freigabe-Dialog erschienen" fail
fi
rm -f "$PEER_DIR/wm8check-probe.txt"

exit "$FAILED"
