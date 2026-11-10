# Browser in der App: Playwright zuerst, Anmerkungen an den Chat

**Stand:** 10.11.2026 · **Status:** Wunsch mit gefallener Grundentscheidung, Vorversuch offen, kein App-Code geändert
**Gehört zu:** [README.md](README.md) · **Vorbild:** Orcas Design-Modus ([orca-video.md](orca-video.md), Abschnitt Design-Modus)

## Worum es geht

Ein Browser-Bereich neben dem Chat, in dem man sieht, was der Agent gebaut hat, ein Element anklickt, eine Anmerkung dazu schreibt und sie an einen Chat seiner Wahl schickt.

## Entscheidung (Giuliano, 10.11.2026)

**Der Browser muss Playwright-first sein.** Er ist so gebaut, dass die Agents ihn über Playwright steuern. Ein Browser, den nur der Mensch bedient, ist nicht das Ziel.

## Wie die anderen es machen

### Orca

- **Ein Browser für beide.** Orca bettet Chromium ein (über Electron ohne Mehraufwand) und stellt die Fernsteuer-Schnittstelle (CDP) der sichtbaren Seite über einen lokalen Proxy bereit (`src/main/browser/agent-browser/session-lifecycle/agent-browser-bridge-lifecycle.ts`). Der Agent arbeitet in dem Tab, den der Mensch sieht.
- **Steuerung über eigene Befehle.** Agents rufen `orca goto`, `orca snapshot --interactive`, `orca click --element @e3`, `orca fill`, `orca screenshot --annotate` auf (`skill-guides/orca-cli/references/browser.md`). Dahinter läuft das Werkzeug `agent-browser`, dem Orca die Adresse der Seite mitgibt (`AGENT_BROWSER_CDP`). Das ist nicht Playwright, die Agents müssen die Befehle per Skill lernen.
- **Gute Einzelheiten:** Jede Aktion meldet, was sie auf der Seite verändert hat, damit der Agent nicht nach jedem Klick neu einlesen muss. Mit `--expect-url` verweigert ein Befehl, wenn die Seite inzwischen eine andere ist. Seiteninhalte gelten als Daten, nie als Anweisung.
- **Greifen** (`src/main/browser/element-grab/`): Element anklicken oder überfahren, `C` kopiert, `S` macht ein Bildschirmfoto. Kopiert werden Adresse der Seite, Element mit Umgebung, HTML-Schnipsel, berechnete Stile, bei React-Seiten der Name der Komponente.
- **Anmerken** (`src/renderer/src/components/browser-pane/annotate/`): Element wählen, Kommentar schreiben, „Änderung“ oder „Frage“ wählen, optional auf der Seite zeichnen. Mehrere Anmerkungen sammeln sich in einer Ablage. „Senden“ fragt nach dem Ziel: ein laufender Agent des Worktrees oder ein neuer. Verschickt wird ein fertiger Text in Markdown.

### T3 Code

Ebenfalls ein eingebauter Browser, den Agent und Mensch gemeinsam benutzen, mit Elementauswahl, Anmerkungen und Diktat direkt in die Anmerkung (`docs/user/voice-input.md`, `apps/server/src/preview/`). Der Browser läuft beim Server und wird zur Oberfläche gestreamt. Deshalb funktioniert er auch, wenn das Projekt auf einem anderen Rechner liegt.

## Unsere Ausgangslage

- WhisperM8 ist nativ. `WKWebView`, der Browser, den macOS jeder App mitgibt, lässt sich nicht von Playwright steuern.
- Ein eingebettetes Chromium (CEF) kostet 150 bis 250 MB, eigene Hilfsprozesse, Signatur und laufende Sicherheitsupdates.
- Die Agents benutzen heute schon Playwright (CLI und MCP), in einem eigenen Browserfenster außerhalb der App.
- Die installierte Playwright-CLI bringt drei Bausteine mit, die hier passen (aus `playwright-cli --help`, Version 0.1.18):
  - `show`: ein Dashboard mit Live-Bild, als Webseite auf einem lokalen Port startbar (`--port`)
  - `show --annotate`: schaltet das Dashboard in einen Anmerkungs-Modus
  - `attach --cdp`: hängt die CLI an einen laufenden Browser
  - dazu benannte Sitzungen (`-s=<name>`), `highlight` und `generate-locator` für ein Element
- Senden an einen wählbaren Chat gibt es schon, samt Schutz davor, in einen arbeitenden Chat hineinzuschreiben (`whisperm8 chats send`).

## Drei Wege

| | A: Playwright besitzt den Browser, wir zeigen ihn | B: eigenes Chromium in der App, Playwright dockt an | C: Systembrowser in der App |
|---|---|---|---|
| Wie | Je Chat eine Playwright-Sitzung. Rechts in der App das Live-Bild; Klicks und Eingaben gehen an Playwright zurück. | CEF in die App einbetten, CDP-Adresse an `playwright-cli attach --cdp` geben. So macht es Orca. | `WKWebView` als Vorschau. |
| Agent steuert, was der Mensch sieht | ja | ja | nein |
| Agents müssen etwas Neues lernen | nein | nein | – |
| Gewicht für die App | gering, Chromium kommt von Playwright | 150–250 MB, Hilfsprozesse, Updates | keins |
| Gefühl beim Bedienen | Live-Bild, leicht verzögert | echter Browser | echter Browser |
| Anmerkungen | über Playwright auf der Seite oder über dem Live-Bild | direkt auf der Seite | möglich, aber ohne Agent |
| Erfüllt „Playwright-first“ | ja | ja | nein |

**Empfehlung: Weg A.** Er erfüllt die Vorgabe mit dem geringsten Gewicht, und er hat einen Vorteil gegenüber Orca: Die Agents arbeiten mit dem Werkzeug, das sie schon kennen. Weg B wird erst nötig, wenn man im Bereich selbst viel surfen will und das Live-Bild dafür zu träge ist. Weg C scheidet aus.

## Wie die Anmerkung zum Chat kommt

1. Im Browser-Bereich den Anmerkungs-Modus einschalten.
2. Element anklicken. Die App fragt bei Playwright nach dem Element an dieser Stelle und bekommt Selektor, Text, HTML-Schnipsel, Größe, auf Wunsch ein Bildschirmfoto des Ausschnitts.
3. Kommentar schreiben oder diktieren, „Änderung“ oder „Frage“ wählen. Mehrere Anmerkungen sammeln.
4. „Senden an…“ zeigt die Chats des Projekts mit Status, den aktiven zuerst, dazu „neuer Chat“.
5. Verschickt wird ein fertiger Text: Seite, Element, Schnipsel, Kommentar, bei mehreren nummeriert. Bildschirmfotos als Dateipfad.

Zwei Dinge können wir hier besser machen als Orca:

- **Diktat in die Anmerkung** mit unserem vorhandenen Diktat, ohne Zusatzarbeit.
- **Senden über die sichere Strecke:** Arbeitet der Zielchat gerade, wird die Anmerkung zurückgelegt statt mitten in den Turn geschrieben.

## Regeln, die von Anfang an gelten

- **Seiteninhalte sind Daten.** Text von einer Webseite kommt im Auftrag als gekennzeichnetes Zitat an, nie als Anweisung. Sonst kann eine präparierte Seite den Agent steuern.
- **Eine Sitzung je Chat.** Zwei Chats teilen sich keinen Browser, sonst klicken sie sich gegenseitig die Seite weg.
- **Getrennt vom eigenen Chrome.** Der Bereich nutzt ein eigenes Profil; Logins kommen nur hinein, wenn der Nutzer es ausdrücklich will.
- **Links aus dem Terminal** öffnen auf Wunsch im Bereich statt im Systembrowser.

## Vorversuch, bevor entschieden wird

Klein, ohne App-Code:

1. `playwright-cli show --port=0` starten und in einem `WKWebView` öffnen: Lässt sich das Dashboard einbetten, wie flüssig ist das Bild, kommen Klicks an?
2. `show --annotate` ausprobieren: Was genau gibt der Modus aus, und wohin? Lässt sich das Ergebnis abgreifen, oder brauchen wir eine eigene Anmerkungs-Schicht?
3. Prüfen, ob sich eine Sitzung je Chat sauber trennen lässt (`-s=<chat>`), auch wenn der Agent über MCP statt über die CLI arbeitet.
4. Messen: CPU und Speicher mit offenem Live-Bild, einmal im Leerlauf, einmal während ein Agent klickt.

Fällt Punkt 1 oder 2 durch, bleibt Weg A mit eigener Schicht über einem selbst gebauten Live-Bild (Bildschirmfotos über CDP) oder Weg B.

## Offene Fragen

1. Wo sitzt der Bereich: rechts neben dem Terminal (ein- und ausblendbar) oder als eigene Fläche im Raster?
2. Soll der Bereich auch ohne Agent als einfache Vorschau für lokale Seiten dienen?
3. Reicht das Live-Bild zum gelegentlichen Eingreifen, oder soll man darin richtig surfen können? Die Antwort entscheidet zwischen Weg A und B.

## Aufwand

Weg A: mittel bis groß. Der Bereich mit Live-Bild und Sitzung je Chat ist der mittlere Teil, die Anmerkungs-Schicht mit Senden kommt dazu. Weg B: groß, mit dauerhafter Pflege. Entwurf zuerst im HTML-Zwilling.
