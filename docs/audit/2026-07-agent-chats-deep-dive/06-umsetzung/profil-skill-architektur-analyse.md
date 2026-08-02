---
status: entwurf
updated: 2026-07-26
description: Read-only Architektur- und Risikoanalyse der Claude-Code-Profile, Skill-Ladewege und Modellrouten mit Optionsvergleich, Roadmap und Entscheidungspunkten zur Reduktion von Context-Overflow.
---

# Profile, Skills und Modellrouten — Architekturanalyse

Rein lesende Analyse. Es wurden keine Settings, Profile, Skills, Plugins oder
Modelle verändert. Ziel: Context-Overflow bei GPT-gestützten Agenten senken,
ohne native Claude-, Opus- oder Fable-Workflows zu verschlechtern.

Anlass ist der Vorfall vom 2026-07-22 (drei Workflow-Agenten gestorben) und
seine **live reproduzierte** Wiederholung am 2026-07-25 im Review-Workflow
`wf_16773dfe-c2c`.

## 1. Der Messwert, um den es geht

Im Review-Workflow sollte ein Agent `AgentControlServer.swift` prüfen — einen
Unix-Socket-Server in Swift. Er lud stattdessen zuerst den mitgelieferten Skill
`claude-api`. Aus seiner eigenen Begründung:

> „Code-Review eines lokalen Swift-Controlservers; keine API-Frage. Nur
> relevante Vorgaben laden."

Der Agent stellte selbst fest, dass es keine API-Frage ist, und lud trotzdem:

| Zeitpunkt | Kontext |
|---|---|
| vor der Skill-Ladung | 14.982 Tokens |
| unmittelbar danach | 222.753 Tokens (**+207.771 in einem Schritt**) |
| Ende des Reviews | 239.661 Tokens, zwölf Turns mitgeschleppt |

Ursache ist die Trigger-Beschreibung des Skills: Er verlangt, gelesen zu werden,
„wann immer der Prompt Claude, Anthropic, Opus, Sonnet oder Haiku nennt — auch
wenn es nach einer Kleinigkeit aussieht". In einem Repository, das vom Hosten
der Claude-CLI handelt, trifft das praktisch immer zu. Der Agent war gehorsam,
der Trigger war falsch.

**Wichtig für die Bewertung:** Der Lauf am 2026-07-25 ist nicht gestorben. Das
experimentelle 372k-Sol-Profil fing den Sprung auf, 11 von 11 Agenten liefen
durch. Der Schaden ist heute Verschwendung, nicht Ausfall — bei kleinerem
Fenster oder größerer Aufgabe wird daraus wieder ein Ausfall.

## 2. Befunde zur Profil-Architektur

### 2.1 Es gibt keine echte Profil-Isolation

Sechs Zusatzprofile existieren unter `~/.claude-profiles/`: `Claude2`,
`PowerUser`, `PowerUser2`, `RankM8`, `ai`, `ai2`. Ihre zentralen Dateien sind
**Symlinks** auf das Hauptverzeichnis:

```
<profil>/settings.json -> ~/.claude/settings.json
<profil>/skills        -> ~/.claude/skills
<profil>/plugins       -> ~/.claude/plugins
<profil>/CLAUDE.md     -> ~/.claude/CLAUDE.md
```

Nachweis über Inode-Auflösung: Alle `settings.json`-Pfade zeigen auf Inode
`193305265` — **eine einzige Datei für alle Profile**. Das ist das
dokumentierte Sollmodell (`ClaudeAccountProfiles.swift:218-224,250-263`), nicht
ein Versehen.

Tatsächlich getrennt sind nur: Credentials, `.claude.json` (und damit die
MCP-Auswahl — Main hat `atlassian`, `chrome`, `gooseworks`, die Zusatzprofile
nur `chrome`), sowie `projects/` mit Historien und Transcripts.

**Konsequenz für die Overflow-Frage:** Ein `skillOverrides`-Eintrag wirkt
sofort für **alle** Profile. Es sind nicht sieben Änderungen, sondern eine. Eine
frühere gegenteilige Einschätzung in der Chat-Beratung war falsch — sie ging von
eigenständigen Profil-Settings aus.

**Konsequenz für die Produktarchitektur:** Die Profilauswahl in WhisperM8
suggeriert getrenntes Verhalten für Skills, Plugins und Settings, das es nicht
gibt. Die Einstellungsseite sagt das selbst
(`ClaudePluginsSettingsPage.swift:251`), aber die Auswahl-UI legt anderes nahe.
Wer künftig profilabhängiges Skill- oder Plugin-Verhalten will, kann nicht auf
dieser Datenstruktur aufbauen.

### 2.2 `chrome-shared` ist kein Profil, wird aber als solches behandelt

Dieses Verzeichnis besitzt keine `settings.json`, keine `skills`, keine
`plugins` und keine `.claude.json` — nur Chrome-Bridge-Dateien. WhisperM8
behandelt jeden nicht versteckten Unterordner pauschal als Account
(`ClaudeAccountProfiles.swift:45-59`) und hat deshalb bereits
`chrome-shared/agents/gpt.md` dort hineingeschrieben.

Das ist heute harmlos, aber es ist eine Typ- und Discovery-Lücke: Der
Statusline-Installer behandelt jeden entdeckten Root als beschreibbar
(`StatuslineInstaller.swift:328-358`) und könnte dort eine `settings.json`
anlegen, die niemand erwartet.

### 2.3 Modellrouten sind über Profile hinweg einheitlich

Alle sechs Profile besitzen `agents/gpt.md` mit `model: gpt-5.6-sol`, aktuell
bytegleich. Die Dateien sind eine Mischform: Main, `ai` und `ai2` teilen einen
Inode, die übrigen sind eigene Kopien — historisch gewachsen, funktional nicht
differenziert.

Die Routenwahl selbst hängt nicht am Profil, sondern am injizierten
Router-Env pro Session (`ANTHROPIC_BASE_URL` auf den lokalen Mix-Router,
`CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`). Native
Claude-, Opus- und Fable-Sessions laufen über denselben Router, werden aber
anhand des Modellnamens an Anthropic weitergeleitet und bleiben vom
GPT-Kontextfenster unberührt (der 1M-Auto-Compact-Deckel ist bewusst getrennt
vom 372k-GPT-Fenster).

**Damit gilt:** Eine Skill-Maßnahme ist modellneutral. Sie kann native
Workflows nur dann verschlechtern, wenn sie einen Skill entfernt, den diese
Workflows brauchen — nicht durch Routing-Nebenwirkungen.

## 3. Befunde zur Skill-Ladefläche

### 3.1 Umfang

- **39 Standalone-Skills** zentral unter `~/.claude/skills`, identischer Inode
  in allen Profilen — genau eine physische Kopie, keine Profil-Drift.
- **mindestens 130 Skills aus aktivierten Plugins** (18 Install-Records, 14 von
  15 Plugin-Schaltern aktiv).
- **15 mitgelieferte Skills** von Claude Code: `claude-api`, `claude-in-chrome`,
  `dataviz`, `artifact-design`, `artifact-capabilities`, `run`, `review`,
  `security-review`, `simplify`, `loop`, `schedule`, `update-config`,
  `keybindings-help`, `fewer-permission-prompts`, `init`.

Jeder Subagent erhält daraus eine Aufstellung von rund **220 Einträgen samt
Beschreibungen (~17 KB)**. Das ist die eigentliche Triggerfläche — sie kommt
automatisch und ist nicht konfigurierbar.

### 3.2 Die riskantesten Trigger

Breite oder mehrdeutige Beschreibungen, die auf viele Aufträge passen:

| Skill | Problematische Formulierung |
|---|---|
| `gooseworks` | „Use this for **ANY** data lookup, web scraping, people search, lead gen, GTM, or research task" |
| `frontend-design` | „when the user asks to build web components, pages, artifacts, posters, **or applications**" |
| `higgsfield-product-photoshoot` | „**any** product, brand, or paid-social creative" |
| `codex-imagegen` | Beschreibung sagt selbst „**VERALTET** — migriert ins marketing-engine-Plugin", feuert aber weiter auf Bild-Trigger |
| `polish`, `audit`, `optimize` | generische Phasennamen, kollidieren mit jeder Aufgabe, die das Wort enthält |

Dazu **Pflichtketten**: Neun Skills (`animate`, `audit`, `bolder`, `colorize`,
`critique`, `delight`, `distill`, `polish`, `quieter`) ziehen `frontend-design`
nach, mehrere mit der Formulierung „Do NOT proceed until it has executed"
(z. B. `animate/SKILL.md:26-28`). `gpt-coworker` verlangt zwingend
`codex-subagent`. Ein einzelner Fehltrigger kann damit mehrere Skills aktivieren
— genau das ist am 2026-07-22 beim Governance-Agenten passiert (`audit` →
`frontend-design`).

Zusätzlich existieren **drei unterschiedliche Fassungen** von
`frontend-design`: standalone, im offiziellen Plugin und im Leadgenjay-Plugin,
alle mit verschiedenen Prüfsummen. Welche greift, entscheidet Heuristik.

### 3.3 `claude-api` im Besonderen

Der Skill existiert **nirgends** als Profil- oder Plugin-Skill — er ist
ausschließlich mitgeliefert, 840 KB in 64 Dateien, Anthropic-SDK-Dokumentation
in neun Programmiersprachen. Er richtet sich an Projekte, die Anwendungen gegen
die Claude-API bauen. WhisperM8 tut das nicht; es hostet die CLI.

Er ist damit der einzige Skill im System, bei dem hohe Größe, breiter Trigger
und fehlender Nutzen für dieses Projekt zusammenfallen.

## 4. Befunde zum Lebenszyklus

- **Kein einheitlicher Sollstand.** Vier Mechanismen parallel: WhisperM8-Skills
  nutzen Hash-Stempel (`CLISkillExporter.swift:203-304`), die Statusline
  Marker plus Stempel, die GPT-Agent-Definition nur einen Marker, Plugins die
  Claude-Manifeste, die übrigen 34 Standalone-Skills gar nichts. Nur 7 von 39
  Skills haben überhaupt ein `version:`-Feld.
- **Kein Uninstall.** Weder `CLISkillExporter` noch `StatuslineInstaller` haben
  einen Entfernungspfad. Nur die GPT-Agent-Definition wird beim Deaktivieren
  gelöscht (`ClaudeGPTAgentDefinition.swift:103-106`).
- **Verwaiste Einträge existieren bereits.** `marketing-plugin@marketing-plugin`
  in `installed_plugins.json` zeigt auf einen nicht existierenden Cache-Pfad.
  `codex-imagegen` bleibt als Skill installiert, obwohl er sich selbst als
  veraltet bezeichnet.
- **Installierter Stand hinter dem Repo.** `whisperm8-chats` ist installiert mit
  SHA `91fa9280…`, die Repo-Ressource hat `41a9418b…`. Kein Drift zwischen
  Profilen, aber die Installation ist älter als der Code.
- **Kein Drift- oder Konfliktcheck.** Es gibt keine Stelle, die doppelte
  Skill-Namen, kollidierende Trigger oder Abhängigkeitsketten prüft.

Bei einem Claude-Code-Update bleiben die zentralen Symlinks und die
WhisperM8-Dateien bestehen; Plugin-Updates laufen sauber über die offizielle
CLI. Das Risiko ist deshalb weniger „ein Update löscht alles", sondern eine
**stille Format- oder Semantikverschiebung ohne Abgleich** — plus Altlasten, die
liegen bleiben.

## 5. Optionsvergleich

### A — Nichts global ändern

Alles bleibt wie es ist; Überläufe werden über das 372k-Fenster und die
Ausfallbilanz aus E29 aufgefangen.

- **Für:** kein Eingriff, kein Risiko für native Workflows, keine
  Wartungslast.
- **Gegen:** ~208.000 Tokens pro betroffenem Agent bleiben. In diesem Repo
  trifft es fast jeden Agenten. Bei größeren Aufgaben oder kleinerem Fenster
  werden daraus wieder Ausfälle. Der Effekt skaliert mit der Fächerungsbreite.
- **Reversibel:** trivial (nichts getan).

### B — Gezielt einen Skill entschärfen (`skillOverrides`)

`skillOverrides` kennt vier Stufen, am Binary 2.1.220 verifiziert
(`name-only` 37 Fundstellen, `user-invocable-only` 24):

| Wert | Modell sieht | Slash-Menü | Aufrufbar |
|---|---|---|---|
| `on` (Default) | Name **und Trigger-Beschreibung** | ja | ja |
| `name-only` | nur den Namen | ja | ja |
| `user-invocable-only` | nichts | ja | nur durch den User |
| `off` | nichts | nein | nein |

**`name-only` ist für diesen Fall die treffendere Stufe als `off`.** Die Ursache
des Fehlgriffs ist nicht die Existenz des Skills, sondern seine
Trigger-Beschreibung in der 17-KB-Aufstellung („lies mich, wann immer Sonnet
vorkommt"). `name-only` entfernt genau diesen Satz aus dem Blickfeld des
Modells, lässt den Skill aber vollständig nutzbar — falls jemand doch einmal
gegen die Claude-API entwickelt.

- **Für:** kleinster wirksamer Eingriff, trifft die belegte Ursache statt das
  Symptom. Wirkt wegen der Symlink-Struktur sofort für alle sieben Profile.
  Greift auch auf den `skills:`-Preload-Pfad von Subagenten. Über `/skills` zur
  Laufzeit umschaltbar (schreibt nach `.claude/settings.local.json`). Keine
  Auswirkung auf native Claude-, Opus- oder Fable-Workflows.
- **Gegen:** löst nur diesen Fall; `audit` → `frontend-design` und die übrigen
  breiten Trigger bleiben. Bei `name-only` bleibt theoretisch möglich, dass ein
  Agent den Skill trotz fehlender Beschreibung beim Namen aufruft — praktisch
  unwahrscheinlich, weil ihm dann die Aufforderung fehlt.
- **Reversibel:** ja. Eintrag entfernen, auf `on` setzen oder `/skills`. Wichtig:
  Bereits injizierter Skill-Inhalt bleibt bis Sessionende beziehungsweise bis
  zur nächsten Kompaktierung im Kontext — das Abschalten wirkt nicht rückwirkend.

### B2 — Zielgenauer Env-Schalter (undokumentiert)

Im Binary existiert `CLAUDE_CODE_DISABLE_CLAUDE_API_SKILL` (verifiziert, drei
Fundstellen, in derselben Env-Registry wie `CLAUDE_CODE_DISABLE_BUNDLED_SKILLS`).
Er entfernt genau diesen Registry-Eintrag, ohne andere mitgelieferte Skills.

- **Für:** wirkt profilübergreifend, sobald jeder Launcher die Variable
  exportiert; keine Settings-Datei nötig.
- **Gegen:** **nicht dokumentiert**, also nicht versionsstabil — er kann mit
  jedem CLI-Update verschwinden. Wird nur bei der einmaligen
  Registry-Initialisierung gelesen, gilt also erst für neue Sessions. WhisperM8
  müsste ihn in die Prozessumgebung jeder gespawnten CLI injizieren, was den
  Umweg über `LoginShellEnvironment` bedeutet.
- **Bewertung:** als Fallback interessant, aber `skillOverrides` ist der
  dokumentierte Weg und damit vorzuziehen.

### C — Getrennte schlanke und vollständige Profile

Ein Profil mit minimalem Skill-Satz für Fächerungsläufe, ein vollständiges für
interaktive Arbeit.

- **Für:** konzeptionell die sauberste Trennung. Fächerungsagenten sehen eine
  kleine, kuratierte Fläche.
- **Gegen:** **heute nicht umsetzbar.** Die Symlink-Struktur macht
  Profil-Isolation für Skills und Settings prinzipiell unmöglich — alle Profile
  teilen dieselben Dateien. Das wäre ein Umbau von `ClaudeAccountProfiles`,
  `CLISkillExporter` und `StatuslineInstaller` samt Migration bestehender
  Profile. Zusätzlich müsste die Profilauswahl-UI erklären, was jetzt wirklich
  getrennt ist.
- **Reversibel:** nur mit Migrationsaufwand.

### D — Kontextabhängige Skill-Policy pro Projekt

Overrides in den Projekt-Settings des jeweiligen Repos
(`<repo>/.claude/settings.json` versioniert, `settings.local.json` lokal).

- **Für:** trifft die Natur des Problems am genauesten. Der Fehltrigger ist eine
  Eigenschaft des Projektvokabulars — in WhisperM8 feuert er, weil das Repo von
  Claude handelt; in akquise-ai, weil die Confluence-Inhalte Sonnet nennen. Die
  versionierte Variante gilt für jeden, der im Repo arbeitet, profilunabhängig.
- **Gegen:** muss pro Repo gesetzt werden; neue Repos sind erst nach dem ersten
  Vorfall geschützt. Bei der versionierten Variante wird die Entscheidung
  mitcommittet.
- **Reversibel:** ja, Eintrag entfernen.

### Bewertung

B und D schließen sich nicht aus, sondern sind dieselbe Maßnahme an
unterschiedlichen Orten. D ist präziser, B ist wirksamer bei geringerem
Pflegeaufwand — weil die geteilte Settings-Datei ohnehin alle Profile abdeckt,
verliert D seinen ursprünglichen Vorteil („nur dort, wo nötig") teilweise, denn
auch B ist ein einziger Eintrag.

C ist die richtige Zielarchitektur, wenn profilabhängiges Verhalten je gebraucht
wird — aber kein Mittel gegen das akute Problem.

A ist vertretbar, solange das 372k-Fenster trägt, verschenkt aber messbar
Kontext bei jedem Fächerungslauf.

## 6. Risiken

| Risiko | Bewertung |
|---|---|
| **Isolationstäuschung** | Die Profilauswahl suggeriert Trennung, die für Skills, Plugins und Settings nicht existiert. Eine Änderung wirkt unerwartet auf alle Accounts. Höchstes strukturelles Risiko, weil künftige Features darauf aufbauen würden. |
| **Unkontrollierte Trigger- und Namensfläche** | ~220 Einträge, drei `frontend-design`-Fassungen, neun Pflichtketten, ein selbsterklärt veralteter Router. Verhalten entsteht aus Heuristik statt aus expliziter Priorität. |
| **Lebenszyklus- und Drift-Lücke** | Kein gemeinsamer Sollstand, kaum Versionen, kein Skill-/Statusline-Uninstall, falsche Root-Erkennung, bereits ein verwaister Plugin-Record. |
| **Regression bei nativen Workflows** | Gering für Option B/D: `claude-api` wird von Claude-, Opus- und Fable-Workflows in diesem Repo nicht gebraucht. Der Grobschalter `disableBundledSkills` wäre hier gefährlich, weil er auch `dataviz`, `run`, `review`, `security-review`, `loop` und `schedule` entfernt. |
| **Externe Wiederkehr** | `claude-api` wird bei jedem Claude-Code-Update neu ausgeliefert. Eine Anpassung seiner Beschreibung wäre nicht haltbar; nur ein Override in eigenen Settings überlebt Updates. |

## 7. Priorisierte Roadmap

**Stufe 1 — akut, reversibel, klein.** `skillOverrides` für `claude-api`
setzen. Danach ein Fächerungslauf zur Kontrolle: Der Skill darf nicht mehr
geladen werden, die Agenten müssen normal durchlaufen. Erwarteter Gewinn:
~208.000 Tokens pro betroffenem Agent.

**Stufe 2 — eigene Trigger entschärfen.** `audit` umbenennen beziehungsweise
seine Beschreibung schärfen, damit er nicht bei jeder Aufgabe mit dem Wort
„Audit" feuert und `frontend-design` nachzieht. Betrifft nur eigene Dateien,
überlebt Updates. Entspricht W1-SKILLTRIGGER im Umsetzungsplan.

**Stufe 3 — Altlasten bereinigen.** Verwaisten `marketing-plugin`-Record
entfernen, `codex-imagegen` deinstallieren (er bezeichnet sich selbst als
veraltet), `frontend-design`-Dreifachbelegung auf eine Fassung reduzieren,
`whisperm8-chats` auf den Repo-Stand aktualisieren.

**Stufe 4 — Werkzeugergebnisse begrenzen.** Der verbleibende Haupthebel gegen
Überläufe, unabhängig von Skills: Ein einzelner MCP- oder Read-Rückgabewert von
100k+ Tokens ist gegen jede Kompaktierung immun, weil Auto-Compact zwischen
Turns läuft. Entspricht W1-TOOLCAP.

**Stufe 5 — Managementschicht gezielt umbauen.** Gemeinsamer Ownership- und
Sollstand-Katalog für Skills, Statusline, Agent-Definitionen und Plugins;
Uninstall-Pfade; Drift- und Duplikatprüfung; korrekte Root-Klassifikation
(`chrome-shared` ist kein Account). Erst danach ist echtes profilabhängiges
Verhalten (Option C) sinnvoll baubar.

## 8. Bewertung: Verbesserung oder Rebuild

**Gezielter Rebuild der Profil-, Skill- und Plugin-Managementschicht — nicht
der App.**

Die Installer und der serialisierte Wrapper um das offizielle `claude
plugin`-CLI sind solide und wiederverwendbar. Punktuelle Nachbesserungen
genügen aber nicht, wenn zuverlässiges profilabhängiges Verhalten das Ziel ist:
Das Symlink-Modell macht Isolation prinzipiell unmöglich, Ownership, Version und
Uninstall sind über vier Mechanismen fragmentiert, und die effektive
Triggerfläche umfasst rund 220 Einträge ohne Konflikt- oder
Abhängigkeitsmodell.

Für das akute Overflow-Problem ist der Rebuild jedoch **nicht erforderlich**.
Stufe 1 und 2 lösen die belegten Ursachen mit zwei kleinen, reversiblen
Eingriffen.

## 9. Entscheidungspunkte

| # | Entscheidung | Empfehlung |
|---|---|---|
| P1 | `skillOverrides` für `claude-api` setzen? | **Ja.** Ein Eintrag, wirkt für alle Profile, über `/skills` rücknehmbar, trifft die gemessene Ursache. |
| P1a | Welche Stufe — `name-only` oder `off`? | **`name-only`.** Es entfernt die Trigger-Beschreibung aus der Skill-Aufstellung, also genau die Ursache, und lässt den Skill nutzbar. `off` nur, wenn er auch nie manuell gebraucht werden soll. |
| P2 | Wo platzieren — geteilte Settings oder Projekt-Settings? | Geteilte Settings, weil sie ohnehin alle Profile abdecken. Projekt-Settings (`.claude/settings.local.json`) nur, wenn die Entscheidung bewusst repo-lokal und uncommittet bleiben soll. |
| P3 | Eigene breite Trigger entschärfen? | **Ja**, mindestens `audit`. Kleiner Aufwand, beseitigt die zweite belegte Fehlgriffkette. |
| P4 | Altlasten bereinigen? | Ja, aber ohne Eile. Kein akuter Schaden, nur unnötige Triggerfläche. |
| P5 | Profil-Isolation echt herstellen? | **Offen.** Nur nötig, wenn profilabhängiges Skill-/Plugin-Verhalten gewünscht ist. Vorher entscheiden, ob die Profilauswahl-UI stattdessen ehrlich benennt, was heute wirklich getrennt ist (Accounts, MCPs, Historien — nicht Skills). |
| P6 | `disableBundledSkills` als Alternative? | **Nein.** Entfernt auch `dataviz`, `run`, `review`, `security-review`, `loop`, `schedule` und `artifact-*`. Unverhältnismäßig. |

## 10. Geklärte Mechanik

Am Binary 2.1.220 und an der offiziellen Dokumentation belegt:

- **Präzedenz der Settings-Quellen:** `userSettings` → `projectSettings` →
  `localSettings` → `flagSettings` → `policySettings`. Die höhere Ebene gewinnt,
  **nicht** die restriktivere. Ein Managed-`on` schlägt also ein lokales `off`.
  Fundstelle im Binary: die Quellenliste in genau dieser Reihenfolge.
- **Objekte werden tief gemergt**, nicht ersetzt. Unterschiedliche Skill-Namen
  aus mehreren Ebenen bleiben erhalten; bei gleichem Namen gewinnt die höhere
  Ebene.
- **Subagenten erben die Auflösung.** Es gibt keinen Settings-Reload pro Spawn —
  die Sichtbarkeitsprüfung liest denselben globalen Zustand für Hauptagent und
  Subagent. Das gilt auch für Workflow-Agenten mit `agentType` und für deren
  `skills:`-Preload.
- **Unbekannte Skill-Namen** in `skillOverrides` sind schema-gültig und still
  wirkungslos; erscheint später ein gleichnamiger Nicht-Plugin-Skill, greift der
  Eintrag dann. **Unbekannte Werte** machen die Settings-Datei ungültig (bei
  Managed wird nur der Eintrag verworfen).
- **Plugin-Skills sind ausdrücklich nicht betroffen.** `skillOverrides` wirkt auf
  mitgelieferte sowie User-, Projekt- und Enterprise-Skills.

### Ein scheinbarer Widerspruch, aufgelöst

Die allgemeine Regel lautet: Ein Eintrag in `<profil>/settings.json` gilt nur für
Sessions mit dem entsprechenden `CLAUDE_CONFIG_DIR`. Das ist korrekt — und
trotzdem wirkt hier ein Eintrag für alle sieben Profile. Grund: In diesem Setup
**ist** `<profil>/settings.json` in jedem Profil ein Symlink auf dieselbe
physische Datei (Inode `193305265`). Die Regel wird nicht umgangen, sie greift
nur auf eine Datei, die alle Profile gemeinsam lesen.

Wer später echte Profil-Isolation herstellt (Option C), verliert damit
automatisch diesen Nebeneffekt und braucht dann pro Profil einen Eintrag.

## 11. Offene Punkte dieser Analyse

- Der reale Auto-Compact bei ~339k ist weiterhin unbelegt (E31).
- Ob die Liste der mitgelieferten Skills zwischen 2.1.217 und 2.1.220 identisch
  ist, ist unklar. Der Extraktionscache unter
  `/private/tmp/claude-501/bundled-skills/` enthält nur bereits materialisierte
  Dateien — aktuell ausschließlich `claude-api` — und ist deshalb keine
  vollständige Registry.
