---
status: aktiv
updated: 2026-10-17
description: Manuelle Laufzeitprüfungen aus dem Red Team (O4) — nur an der laufenden App bzw. auf echter Hardware klärbar.
---

# Manuelle QA-Liste (Laufzeitprüfungen)

Ergänzt die QA-Checkliste am Ende der [Testmatrix](anforderungs-testmatrix.md). Ergebnis je Punkt hier eintragen.

1. [ ] Passwort-Manager: Diktat im Modus 'E-Mail' starten, während Transkription/Umformulierung läuft in 1Password oder im macOS-Passwörter-App ein Passwort kopieren. Danach im Reports-Archiv und im gerenderten Prompt prüfen, ob das Passwort als markierter Text auftaucht. Zusätzlich: Passwort kopieren, Diktat in Slack starten (Cmd+C-Fallback), prüfen ob 1Password die Zwischenablage nach 90 s noch leert.
2. [ ] Diktiersprache: frische Installation (defaults delete com.whisperm8.app language) auf einem englisch eingestellten Mac, Onboarding-Testdiktat auf Englisch sprechen, je mit OpenAI und Groq. Wird deutscher/übersetzter Text ausgegeben?
3. [ ] Tastaturlayout: Eingabequelle auf 'Dvorak' (und 'Workman', falls installiert) umstellen, in TextEdit und Slack diktieren mit Auto-Paste. Erscheint der Text, oder wird Cmd+K/Cmd+C ausgelöst? Gegenprobe mit 'Dvorak – QWERTY ⌘' und Deutsch/QWERTZ.
4. [ ] Mikrofon fest gewählt: in Einstellungen ein USB-Headset bzw. das eingebaute Mikrofon explizit auswählen, Aufnahme starten, nach 5 s Headset abziehen und weitersprechen, dann stoppen. Fehlt der zweite Teil ohne Hinweis? Zweiter Lauf: Aufnahme starten, Deckel 30 s schließen, öffnen, weitersprechen, stoppen.
5. [ ] Ruhezustand allgemein: mit laufendem Agent-Chat (working) Mac 10 min schlafen lassen; nach dem Aufwachen prüfen, ob der Status fälschlich auf idle springt (hook_silent_working_healed im Log) und ob der Chat danach korrekt weiterläuft.
6. [ ] Firmen-Proxy: HTTPS_PROXY in ~/.zprofile auf einen lokalen Proxy (z. B. mitmproxy mit eigener CA plus NODE_EXTRA_CA_CERTS) setzen, direkten Internetzugang sperren. claude im Terminal vs. Chat aus WhisperM8 starten; ebenso Codex-Nachbearbeitung im Diktat.
7. [ ] Große Zwischenablage: in Preview ein 6K-Bild bzw. in Excel/Numbers einen großen Bereich kopieren, dann in VS Code ohne Auswahl diktieren. Friert das Overlay ein (log stream: main_thread_blocked_ongoing, perf_budget_exceeded contextCapture)? Landet die aktuelle VS-Code-Zeile als markierter Kontext im Report?
8. [ ] Sichere Eingabe: Terminal.app 'Sichere Tastatureingabe' aktivieren bzw. Fokus in ein Passwortfeld setzen. Funktioniert der Diktat-Hotkey noch, und wohin wird beim Auto-Paste eingefügt? Erwartung klar dokumentieren.
9. [ ] Ultrawide/5K: Screen-Clip auf einem 5120x1440-Monitor bzw. 5K-Display im nativen Modus aufnehmen. Entsteht ein abspielbares Video?
10. [ ] Mehrere Monitore/Vollbild: Diktat-Overlay über einer Vollbild-App auf dem zweiten Monitor starten, danach den Monitor abziehen, während das Overlay sichtbar ist. Bleibt das Overlay erreichbar?
11. [ ] Mehrere macOS-Benutzer: zwei Benutzerkonten mit Schnellem Benutzerwechsel, beide mit WhisperM8 und aktivem GPT-Backend auf Standardport. Prüfen, ob Benutzer B unbemerkt den Proxy (und damit das ChatGPT-Konto) von Benutzer A verwendet.
12. [ ] Logging nach Absturz: absichtlich einen Info-Log erzeugen (z. B. Gerätewechsel während Aufnahme), App per kill -9 beenden, Mac neu starten, dann log show --info --last 1h --predicate 'subsystem == "com.whisperm8.app"'. Sind die Info-Zeilen noch da?
13. [ ] App Nap: App mit geschlossenen Fenstern 1 h im Hintergrund laufen lassen, danach log show nach main_thread_blocked_ongoing und main_thread_stall durchsuchen; Activity Monitor Spalte 'App Nap' und Energie-Wakeups beobachten.
14. [ ] Frischer Mac (macOS 14, ohne jq): Statusline in den Einstellungen installieren und in einem Claude-Chat die Statuszeile ansehen.
15. [ ] Voice-Callouts auf einem englisch eingestellten Mac mit englischem Ansagetext (whisperm8 speak "Build finished") anhören.
