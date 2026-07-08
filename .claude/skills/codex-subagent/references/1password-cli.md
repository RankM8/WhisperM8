# 1Password-CLI für Auth-States — Betriebswissen

Wie Login-Sessions für Browser-QA erzeugt werden, ohne dass der Agent je ein
Passwort sieht. Erarbeitet im AkquiseAI-Setup (Stand 07/2026).

## Grundprinzip

Der Haupt-Agent (und erst recht Subagents) tippt NIEMALS Passwörter und liest
sie NIEMALS in seinen Kontext. Der einzige zulässige Pfad: 1Password liefert
das Secret direkt in den Prozess, der es braucht — via `op run` mit
Secret-Referenzen in Umgebungsvariablen. Der User gibt jeden Zugriff per
Touch ID in der 1Password-eigenen Oberfläche frei.

- Erlaubt zu lesen: Item-Titel, Item-IDs, `username`-Felder (keine Secrets).
- Verboten: `op read .../password` mit Ausgabe nach stdout, `op item get`
  ohne Feld-Filter (dumpt Passwörter!), Secrets in Logs/Echo/Reports.
- Im sichtbaren Chrome (claude-in-chrome) geht dieser Weg NICHT — dort liefe
  die Eingabe durch den Agent-Kontext. Sichtbares Chrome = die Rolle, als die
  der User selbst eingeloggt ist; alles andere headless.

## Setup (einmalig)

1. `brew install --cask 1password-cli`
2. 1Password-App → Einstellungen → Entwickler → "In 1Password-CLI integrieren"
3. Test: `op vault list` (löst Touch-ID-Prompt aus)

## Items finden und mappen

```bash
# Titel-Suche ohne Secrets (926 Items → gefiltert):
op item list --format json | python3 -c "…filter auf title…"
# Username-Feld lesen ist ok (kein Secret):
op read "op://<Vault>/<item-id>/username"
```

Das konkrete Item-ID→Rollen-Mapping gehört NICHT in diesen Skill (er wird mit
der App gebündelt und verteilt) — pro Projekt lokal pflegen, z. B. in einer
gitignorten `.qa/README.md` im Ziel-Repo, und bei Bedarf dort nachschlagen.
Format-Beispiel:

- `<item-id>` → admin@<projekt-domain>
- `<item-id>` → kunde@<projekt-domain>

## State-Capture (der Kern)

Skript: `<repo>/.qa/scripts/capture-state.mjs` — headless Chrome
(playwright global via brew, ESM braucht `createRequire` +
`NODE_PATH=/opt/homebrew/lib/node_modules`), füllt die Keycloak-Maske aus
Env-Variablen, wartet auf eingeloggte App, speichert
`.qa/auth/akquise-<rolle>.storageState.json`.

```bash
export NODE_PATH=/opt/homebrew/lib/node_modules
cd <repo>
AKQ_USERNAME=admin@akquise.ai \
AKQ_PASSWORD="op://<Vault>/<item-id>/password" \
  op run -- node .qa/scripts/capture-state.mjs admin
```

`op run` löst die `op://`-Referenz erst im Kindprozess auf und maskiert
Secrets in dessen Stdout. Ausgabe des Skripts: nur "OK: <pfad> gespeichert".

## Betriebsregeln

- **Frisch capturen direkt vor jedem Verwendungs-Batch** — States sterben
  serverseitig binnen ~40 min (Details: `playwright-browser-qa.md`).
- Capture-Fehlerbild landet als Screenshot in
  `.qa/screenshots/capture-<rolle>-error.png` (Exit 2).
- **Credential-Drift:** 1Password-Items können hinter neu geseedete
  Dev-Umgebungen zurückfallen („Ungültiger Benutzername oder Passwort" im
  Fehler-Screenshot). Fix macht der USER (Item in der App auf das aktuelle
  Seed-Passwort aktualisieren) — der Agent tippt auch bekannte Seed-Passwörter
  NIEMALS selbst, selbst wenn sie im Repo stehen.
- Beim Kombinieren von Capture + Agent-Start in EINEM Background-Befehl
  landet Nicht-JSON-Stdout vor dem Job-JSON in der Output-Datei — beim Parsen
  ab dem ersten `{` lesen oder die Befehle trennen.
- `.qa/` MUSS gitignored sein — die States enthalten gültige Session-Cookies.
- Subagents bekommen die States read-only; Refresh macht ausschließlich der
  Haupt-Agent über das Capture-Skript.
- Für neue Projekte: Skript kopieren, Selektoren der Login-Maske anpassen
  (Keycloak-Standard: `input[name=username]`, `input[name=password]`,
  `#kc-login`), Items im Vault anlegen lassen (macht der User), IDs mappen.
