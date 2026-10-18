---
status: beschlossen
updated: 2026-10-18
description: Welle W6 des Launch-Readiness-Plans — Sprache und Bedienbarkeit (E1), Barrierefreiheit. Befunde, Abnahmekriterien, Tests zuerst.
---

# W6 · Sprache und Bedienbarkeit (E1), Barrierefreiheit

Eine Sprache in der ganzen UI (Englisch Basis, Deutsch lokalisiert), Einstellungen nach Launch-Klassen geordnet (Labs/Erweitert getrennt vom Kern), Status nicht nur über Farbe, Bedienung per Tastatur und VoiceOver.

**Umfang:** 8 Befunde · P2 5, P3 3 · 1 Launch-Blocker · Aufwand S×2, M×4, L×2

## Abnahmekriterien der Welle

- [ ] Lokalisierungs-Guard ohne Ausnahmeliste für Kern-Views; App in Englisch und Deutsch per Snapshot-Galerie gerendert.
- [ ] Einstellungen: Labs (GPT-Backend, ChatGPT-Transkription, Voice Gate, Jarvis-Board) hinter „Labs“, Erweitert gekennzeichnet; Chat-Menüs ohne Entwicklerjargon im Standard.
- [ ] Status-Punkte mit Form/Symbol zusätzlich zur Farbe und accessibilityLabel; Schließen-Aktionen als Buttons, ohne Hover erreichbar.
- [ ] Informationstragende Texte ≥ 11 pt, Hilfetexte mit ausreichendem Kontrast.
- [ ] Kein Feature setzt `defaults write` voraus: jeder als Bedienweg gedachte Schalter hat einen UI-Weg (Guard-Test gegen die Liste in AppPreferences); Kill-Switches bleiben dokumentierte Notbremse.

## Lückenschluss zu Beginn (Kritiker Delta-Lauf)

- Barrierefreiheit von Grid, Ctrl+Tab-Switcher und Notiz-Karten (Tastatur, Fokus, VoiceOver) prüfen.

## Feature-Erhalt

Vor dem ersten Commit die Invarianten lesen und je Fix prüfen, welche berührt sind: [oracle/onboarding-shell.md](../../00-scope/oracle/onboarding-shell.md). Dazu die Zeilen der [Testmatrix](../anforderungs-testmatrix.md) für diese Features.

## Befunde

| ID | Schwere | Blocker | Aufwand | Risiko | Status | Titel |
|---|---|---|---|---|---|---|
| LR-ONB-011 | P2 | ja | L | mittel | geplant · bestätigt | Die UI bleibt hart codiert zweisprachig statt lokalisiert |
| LR-AU-009 | P2 | — | M | niedrig | geplant · unverifiziert | Chat-UI ist für VoiceOver und Farbfehlsichtigkeit kaum bedienbar: Status nur über Farbe plus Hover-Tooltip, Schließen-Aktionen als Image mit onTapGesture und nur bei Hover sichtbar |
| LR-AU-030 | P2 | — | L | niedrig | geplant · unverifiziert | Sprachmix Deutsch/Englisch (E1): konkrete Hotspots in Agent-Chats-UI und Settings |
| LR-AU-031 | P2 | — | M | niedrig | geplant · unverifiziert | Erweitert/Labs-Funktionen und Entwicklerjargon im Standard-UI der Chats |
| LR-ONB-012 | P2 | — | M | niedrig | geplant · bestätigt | Kern-Settings trennen Labs und Expertenfunktionen nicht vom normalen Setup |
| LR-AU-033 | P3 | — | M | niedrig | geplant · unverifiziert | Sehr kleine Schriften (8-10 pt) und Kontrastarmut in Chat-Chrome |
| LR-ONB-016 | P3 | — | S | niedrig | geplant · bestätigt | Zentrale Hilfetexte unterschreiten den normalen Textkontrast |
| LR-SH-017 | P3 | — | S | niedrig | geplant · unverifiziert | Voice-Callouts wählen immer eine deutsche Stimme, auch für englische Ansagen |

### LR-ONB-011 · Die UI bleibt hart codiert zweisprachig statt lokalisiert

*P2 · Launch-Blocker · onboarding / ux · Aufwand L · Risiko mittel*

**Beleg:** `WhisperM8/Views/OnboardingView.swift:191-203,381-403,614-620 — englischer Wizard.`, `WhisperM8/Models/TranscriptionProvider.swift:154-160 — deutsche Modellbeschreibungen innerhalb dieses Wizards.`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:89-91,130-140 — englischer Seitenrahmen mit deutschen Status-/Kontotexten.`, `WhisperM8/Views/AppUpdateViews.swift:44-72 — deutscher Update-Dialog in englischem About.` (Stand `a8e0f35`)

**Fehlerbild:** Auf einem englischen Mac durchläuft der Nutzer einen englischen Wizard, erhält aber deutsche Modellbeschreibungen, System-Begründungen und Update-Anweisungen. Auf einem deutschen Mac bleiben die meisten Settings englisch. Eine heuristische Zählung der geprüften UI-Dateien erfasste rund 390 direkt deklarierte UI-Literale, davon mindestens 25 mit deutschen Sprachmarkern; zahlreiche dynamische Texte sind darin noch nicht enthalten. Im App-Quellbaum wurden keine String-Kataloge oder Lokalisierungsressourcen gefunden. Das verletzt E1 und die DoD einer konsistenten Sprache.

**Fix:** Englisch als Basis und Deutsch als vollständige Lokalisierung über native String-Kataloge einschließlich InfoPlist-Texte einführen. Provider-/Modellmetadaten und Fehlermeldungen ebenfalls lokalisieren, nicht nur SwiftUI-Textliterale. Fachnamen und CLI-Befehle unverändert lassen; beide Sprachen über denselben Satz von Onboarding-/Settings-Fixtures prüfen.

**Test zuerst:** Test, der für alle TranscriptionModel.allCases, AppUsageProfile.allCases und TranscriptionProvider.allCases die nutzersichtbaren Texte unter Locale en auflöst. Er prüft, dass keine deutschen Marker (Umlaute, ' bei ', 'Qualität') vorkommen und dass im Bundle eine Localizable.xcstrings mit en und de existiert. Heute schlägt er schon bei openai_gpt4o.description fehl.

### LR-AU-009 · Chat-UI ist für VoiceOver und Farbfehlsichtigkeit kaum bedienbar: Status nur über Farbe plus Hover-Tooltip, Schließen-Aktionen als Image mit onTapGesture und nur bei Hover sichtbar

*P2 · agent-ui / ux · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentStatusIndicator.swift:35-77 (kein accessibilityLabel; Bedeutung working, awaiting, idle nur über Farbe und .help-Tooltip)`, `WhisperM8/Views/AgentChatsSidebarViews.swift:886-893 und 1103-1110 (Close/Archiv/Wiederherstellen als Image + onTapGesture, kein Button, keine Accessibility-Trait)`, `WhisperM8/Views/AgentChatsSidebarViews.swift:1101-1103 (Aktion nur bei isHovered sichtbar, nicht bei Selektion)`, `WhisperM8/Views/AgentChatChromeViews.swift:355-368 (Tab-Schließen-X nur bei Hover oder Selektion, ebenfalls onTapGesture)` (Stand `76256ad`)

**Fehlerbild:** Ein VoiceOver-Nutzer hört bei Sidebar-Zeilen und Tabs weder, ob ein Chat arbeitet, auf Eingabe wartet oder bereit ist, noch findet er die Schließen- oder Archivieren-Aktion, weil sie kein Button ist und nur bei Hover existiert. Auch ein Nutzer mit Rot-Grün-Schwäche kann „arbeitet“ (grün) und „wartet“ (Amber) nur am Puls unterscheiden, und der entfällt im kompakten Tab-Punkt. Das widerspricht der Projektregel „kein Hover-only-UI“ und der Barrierefreiheit-Dimension.

**Fix:** AgentStatusIndicator mit accessibilityLabel und -value (Arbeitet, Wartet auf dich, Bereit, Fehler) versehen. Einen Fallback ergänzen, der auch ohne Farbe unterscheidbar ist (Form oder Symbol für awaiting). Die Close-Aktionen als Button mit accessibilityLabel (z. B. closeHelp) umsetzen und per .accessibilityAction im Zeilenelement anbieten. Der Zeile ein zusammengefasstes accessibilityElement mit Titel, Status und Projekt geben.

**Test zuerst:** Accessibility-Inspector-Lauf und ein Snapshot-Test, der prüft, dass jede Zeile einen nicht leeren accessibilityLabel hat.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

**Zusammengeführt mit:** LR-AU-021, LR-AU-026, LR-AU-027

### LR-AU-030 · Sprachmix Deutsch/Englisch (E1): konkrete Hotspots in Agent-Chats-UI und Settings

*P2 · agent-ui / ux · Aufwand L · Risiko niedrig*

**Beleg:** `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:41-48`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:376-378`, `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:35`, `WhisperM8/Views/Settings/Pages/ClaudeHooksSettingsPage.swift:12-20` (Stand `76256ad`)

**Fehlerbild:** Hauptfenster (Sidebar, Dialoge, Menüs) ist Deutsch, die Agent-Chats-Settings komplett Englisch (Launch defaults, Rename chats automatically, Tabs Workspace/Notifications/Advanced). Der Systemdialog zum Projektwählen trägt Add Project. Die Test-Benachrichtigung hat den deutschen Titel Statusmaschine-Chat auf einer englischen Seite. Header-Buttons heißen Restart/Resume/Start. Die Zeitangaben sind 5m/3h/2d/3mo, der Tooltip Transkript von Claude gelöscht – nicht mehr resumebar mischt Deutsch und Jargon. Es gibt keine Localizable-Ressourcen; alle Strings sind hart codiert. Ergänzt LR-ONB-011 um die konkrete Fundliste.

**Fix:** E1 umsetzen: Strings in String Catalog (Englisch Basis, Deutsch Lokalisierung). Priorität: Agent-Chats-Settings, Header-/Sidebar-Aktionen, NSOpenPanel-Prompts, Test-Benachrichtigung. Relative Zeiten über RelativeDateTimeFormatter.

**Test zuerst:** Teil des Lokalisierungs-Guards (siehe W3.0/W6): betroffene Dateien enthalten keine unlokalisierten deutschen Literale mehr.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

**Zusammengeführt mit:** LR-AU-028

### LR-AU-031 · Erweitert/Labs-Funktionen und Entwicklerjargon im Standard-UI der Chats

*P2 · agent-ui / ux · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsView.swift:2962-2982`, `WhisperM8/Views/AgentChatsView.swift:3220-3237`, `WhisperM8/Views/AgentChatsSidebarViews.swift:845-855`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:98-106` (Stand `76256ad`)

**Fehlerbild:** Das Plus-Menü neben den Tabs stellt Neuer Hintergrund-Agent, Neuer Claude Agent View und Sub-Agent-Bibliothek anzeigen gleichrangig neben Neuer Claude Chat. Codex steht dabei vor Claude. Sidebar und Header zeigen BG/VIEW/SUB/TERM-Pillen mit Tooltips wie vom Claude-Supervisor gehostet, Multi-Session-TUI, Short-ID. In den Settings ist New chat starts with Claude Agents eine normale Option. Der Dialog Hintergrund-Agent nutzt Permission Mode und Worktree. Ein Laie kann nicht erkennen, was davon er braucht oder was Kosten/Risiko hat.

**Fix:** Erweitert/Labs-Einträge hinter einen Untermenüpunkt Erweitert oder eine Einstellung Erweiterte Agent-Funktionen anzeigen (Default aus). Tooltips ohne Jargon formulieren. Claude vor Codex sortieren oder nach Nutzung.

**Test zuerst:** Snapshot-Fixture der Kontextmenüs/Header mit „Erweiterte Agent-Funktionen“ aus: keine Labs/Erweitert-Einträge sichtbar; an: alle wie heute (Feature-Erhalt).

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-ONB-012 · Kern-Settings trennen Labs und Expertenfunktionen nicht vom normalen Setup

*P2 · onboarding / ux · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Views/SettingsView.swift:132-138,147-149 — identische ungefilterte Navigation für alle Profile; GPT-Backend steht regulär neben Accounts und Hooks.`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:42,94-99 — ChatGPT-Abo wird beim standardmäßig aktiven Feature-Schalter regulär angeboten, unabhängig von eingerichtetem Backend.`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:8-24,37-38 — Codex Voice Agent ist ein normaler Tab, nicht Labs.`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:53-61 — keine Kennzeichnung als experimenteller, inoffizieller Upstream.` (Stand `a8e0f35`)

**Fehlerbild:** Ein Diktat-only-Nutzer öffnet Settings und sieht alle 13 Seiten einschließlich Accounts, Hooks, CLI/Skills und GPT-Backend. In der normalen Providerwahl wirkt ChatGPT-Abo wie eine gleichwertige Standardoption, führt bei ausgeschaltetem Backend aber zunächst in dessen Einrichtung. Die beschlossene Kern/Erweitert/Labs-Trennung und E2 werden auf der zentralen Kernoberfläche nicht umgesetzt; die Profilwahl reduziert die Komplexität nicht.

**Fix:** Kern-Setup profilgerecht priorisieren, Erweitert ausdrücklich absetzen und Labs hinter einem klar beschrifteten experimentellen Bereich anbieten. Unfertige Labs-Abhängigkeiten nicht als regulären sofort nutzbaren Transkriptionsanbieter darstellen. Alle vorhandenen Funktionen und bestehende gespeicherte Auswahlen weiterhin erreichbar halten; kein Feature-Ausbau durch Verstecken.

**Test zuerst:** Die Provider-Optionen der Settings-Seite in eine pure Funktion auslagern: TranscriptionProvider.settingsOptions(killSwitch: true, backendEnabled: false, stored: .groq). Erwartung: ohne .chatgpt. Heute enthalten. Dazu SettingsView.pageGroups(for: .dictationRaw): darf .gptBackend nicht außerhalb einer Labs-Gruppe führen.

### LR-AU-033 · Sehr kleine Schriften (8-10 pt) und Kontrastarmut in Chat-Chrome

*P3 · agent-ui / ux · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsView.swift:3304-3306`, `WhisperM8/Views/AgentChatsView.swift:3156-3160`, `WhisperM8/Views/AgentChatsSidebarViews.swift:640-650`, `WhisperM8/Views/AgentChatsSidebarViews.swift:895-897` (Stand `76256ad`)

**Fehlerbild:** Konto-/Art-Badges (8 pt), Laufzahlen (8,5 pt), Tooltip-Hinweise und Header-Metadaten (9-10 pt), Zeitangaben (9,5 pt) in textTertiary. Für Nutzer mit Sehschwäche kaum lesbar; die Größen sind fest codiert und folgen keiner Systemeinstellung. Betrifft vor allem Status- und Konto-Information, die der Laie braucht.

**Fix:** Mindestgröße 11 pt für informationstragende Texte; Tertiärfarbe nur für rein dekorative Zusätze. Wichtige Zustände nicht ausschließlich in textTertiary.

**Test zuerst:** Source-Guard: informationstragende Texte in Views/AgentChats* nutzen keine Schriftgröße < 11 pt (Ausnahmeliste explizit).

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-ONB-016 · Zentrale Hilfetexte unterschreiten den normalen Textkontrast

*P3 · onboarding / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Support/AppTheme.swift:12-15,91-94 — textTertiary ist Schwarz mit 42 Prozent auf Weiß beziehungsweise Weiß mit 38 Prozent auf dunklem Hintergrund.`, `WhisperM8/Views/Settings/Kit/SettingsRow.swift:25-30 — normale erklärende Texte mit 11,5 pt verwenden textTertiary.`, `WhisperM8/Views/Settings/Kit/SettingsHelpText.swift:9-12,29-33 — derselbe Token ist Standard für Hilfetexte.`, `WhisperM8/Views/Settings/Kit/SettingsPageContainer.swift:36 — Seitenhintergrund ist AppTheme.background.` (Stand `a8e0f35`)

**Fehlerbild:** Ein Nutzer mit eingeschränkter Sehfähigkeit liest die kleinen Erklärungen zu Rechten, Profilen oder Datenschutz. Aus den deklarierten sRGB-Werten berechnet ergeben sich auf dem Seitenhintergrund ungefähr 3,04:1 im Light Mode und 3,56:1 im Dark Mode, unter 4,5:1 für normalen Text. Es handelt sich um Handlungsinformationen, nicht bloß deaktivierte Dekoration.

**Fix:** Für leserelevante Hilfetexte einen Token mit mindestens 4,5:1 in beiden Themes verwenden und den schwächeren Token auf nicht wesentliche Dekoration beschränken. Kontrastberechnung für Tokens sowie visuelle Prüfung mit Increase Contrast ergänzen; bestehende Light-/Dark-Umschaltung erhalten.

**Test zuerst:** Test, der AppTheme.textTertiary und AppTheme.background über NSAppearance(.aqua/.darkAqua) zu sRGB auflöst, die Transparenz verrechnet und den WCAG-Kontrast berechnet. Erwartung ≥ 4,5. Heute 3,04 (Light) bzw. 3,55 (Dark).

### LR-SH-017 · Voice-Callouts wählen immer eine deutsche Stimme, auch für englische Ansagen

*P3 · shared / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/Shared/SpeechCallouts.swift:120-128` (Stand `a8e0f35`)

**Fehlerbild:** Ohne explizit gewählte Stimme nimmt voice(identifier:) die beste installierte Stimme mit Sprachpräfix de, sonst de-DE. Bei englischer UI (E1 c) und englischen Ansagetexten liest eine deutsche Stimme Englisch vor, schwer verständlich.

**Fix:** Stimme nach Sprache des Ansagetexts (NLLanguageRecognizer) oder nach Locale.preferredLanguages wählen, Deutsch nur als Fallback.

**Test zuerst:** SpeechCallouts-Test mit Stimmen-Fake: englischer Text wählt eine englische Stimme, deutscher eine deutsche, unbekannte Sprache fällt auf die Systemsprache zurück.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.
