#!/usr/bin/env bash
# Prüft an der installierten Claude-Code-CLI, worauf WhisperM8 beim nativen
# Sitzungs-Messaging (ListAgents/SendMessage) baut (WM8-79,
# docs/plans/chat-kommunikation.md). Bei jeder neuen Claude-Code-Version fahren:
#
#   scripts/claude-peer-messaging-check.sh [konto-a] [konto-b]   # Standard: ai ai2
#
# Läuft außerhalb der App mit drei Wegwerf-Sitzungen (tmux -L wm8peer, fester
# Ordner $TMPDIR/wm8-peer-messaging-check), kostet rund sechs kurze Anfragen
# (Sonnet) auf den beiden Konten und fasst keinen echten Chat an. Geprüft wird:
#   1. ListAgents zeigt eine Sitzung desselben Kontos, aber nicht die des anderen.
#   2. SendMessage an die uds:-Adresse erreicht das andere Konto.
#   3. Die Nachricht löst beim Empfänger UserPromptSubmit aus, Prompt in
#      <cross-session-message from="uds:…" from-name="…">.
#   4. Eine offene Rückfrage (AskUserQuestion) bleibt unberührt; die Nachricht
#      kommt erst nach der Antwort.
# Ergebnis: OK/FEHLER je Punkt, Rückgabe 1 bei einem Fehler.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v tmux >/dev/null || { echo "tmux fehlt (brew install tmux)" >&2; exit 2; }
command -v claude >/dev/null || { echo "claude fehlt im PATH" >&2; exit 2; }
source scripts/claude-peer-messaging-lib.sh

A_ACC="${1:-ai}" B_ACC="${2:-ai2}"
FAILED=0
trap peer_stop_all EXIT

check() {
    if [[ "$2" == ok ]]; then echo "OK      $1"; else echo "FEHLER  $1"; FAILED=1; fi
}
hooks_of() { cat "$PEER_DIR/logs/$1.hooks.jsonl" 2>/dev/null; }

claude --version 2>/dev/null | head -1
rm -f "$PEER_DIR"/logs/{s1,s2,r}.hooks.jsonl
peer_start s1 "$A_ACC" default "$(peer_hook_settings s1)"
peer_start s2 "$A_ACC" default "$(peer_hook_settings s2)"
peer_start r "$B_ACC" default "$(peer_hook_settings r)"
sleep 3
R_ADDR="uds:$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["messagingSocketPath"])' "$(peer_registry r "$B_ACC")")"

# 1. Sichtbarkeit
peer_prompt s1 'Rufe ListAgents auf und gib nur die Namen der gefundenen Sitzungen aus, je Zeile einer, mit dem Präfix NAME: davor.'
sleep 3; peer_wait_status s1 "$A_ACC" idle 60; sleep 1
check "ListAgents sieht Sitzung im selben Konto ($A_ACC)" "$(peer_screen s1 | grep -q 'NAME: s2' && echo ok)"
check "ListAgents sieht das andere Konto ($B_ACC) nicht" "$(peer_screen s1 | grep -q 'NAME: r$' || echo ok)"

# 2./3. Zustellung über Konten, Hook
peer_prompt s1 "Rufe SendMessage auf: to = \"$R_ADDR\", message = \"WM8CHECK-1\". Sonst nichts."
for _ in $(seq 1 60); do hooks_of r | grep -q 'WM8CHECK-1' && break; sleep 1; done
check "SendMessage an uds:-Adresse erreicht Konto $B_ACC" "$(hooks_of r | grep -q 'WM8CHECK-1' && echo ok)"
check "UserPromptSubmit mit <cross-session-message from=\"uds:" "$(hooks_of r | grep 'WM8CHECK-1' | grep -q 'cross-session-message from=\\"uds:' && echo ok)"

# 4. Offene Rückfrage
peer_wait_status r "$B_ACC" idle 60
peer_prompt r 'Nutze sofort das Tool AskUserQuestion mit genau einer Frage "Welche Farbe?" und den Optionen Rot, Gruen, Blau. Sonst nichts.'
if peer_wait_for r 'Enter to select' 90; then
    peer_prompt s1 "Rufe SendMessage auf: to = \"$R_ADDR\", message = \"WM8CHECK-2 Blau\". Sonst nichts."
    sleep 20
    check "Rückfrage bleibt offen, während die Nachricht wartet" "$(peer_screen r | grep -q 'Enter to select' && echo ok)"
    check "Nachricht nicht vor der Antwort an Claude gegeben" "$(hooks_of r | grep -q 'WM8CHECK-2' || echo ok)"
    "${PEER_TMUX[@]}" send-keys -t r Enter   # Option 1 (Rot)
    for _ in $(seq 1 40); do hooks_of r | grep -q 'WM8CHECK-2' && break; sleep 1; done
    check "Antwort des Users bleibt (Rot)" "$(peer_screen r | grep -q '→ Rot' && echo ok)"
    check "Nachricht kommt nach der Antwort an" "$(hooks_of r | grep -q 'WM8CHECK-2' && echo ok)"
else
    check "Rückfrage-Dialog erschienen" fail
fi

exit "$FAILED"
