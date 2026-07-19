---
status: aktiv
updated: 2026-07-19
description: Finalrunden-Audit des Claude-Plugin-Managers mit Fokus auf CLI-Parser-Drift, Spawn- und Profilumgebung, destruktive Operationen, parallelen Model-State sowie Timeout- und Fehlerpfade.
---

# Runde 4: Claude-Plugin-Manager

## Gegenstand und Methode

Statisch geprüft wurden der CLI-Wrapper, Listen- und Detailparser, das Manager-Model, die Settings-Seite und die zugehörigen Tests aus Commit `2c8c508` auf dem aktuellen Stand einschließlich der Nachbesserung `9e4b9f4`. Ergänzend wurde für den tatsächlich verwendeten Timeout-Pfad `AgentHeadlessCLI` und für die Profilauflösung `ClaudeAccountProfiles` gelesen. Es wurden keine Builds, Tests oder Produktprozesse ausgeführt.

**Bilanz:** acht Findings — zwei hoch, fünf mittel, eines niedrig. Die wichtigsten Risiken sind Klartext-Plugin-Konfiguration in `argv`, ein Timeout, der nur den direkten CLI-Prozess statt seines Prozessbaums beendet, und mehrere Stellen, an denen Parser- oder Detailfehler als scheinbar vollständige Daten in der UI enden.

## R4-PLUG-01 — Plugin-Konfiguration einschließlich möglicher Secrets landet im Prozess-`argv`

**Schweregrad:** hoch

### Beleg

- Das Installations-Sheet nimmt freie `key=value`-Konfiguration entgegen und startet die Installation ohne Einschränkung auf nicht-sensitive Werte (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:466-479`).
- `ClaudePluginCLI.install` serialisiert jedes Paar wörtlich als `--config`, `key=value` in die Argumentliste (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:90-100`).
- Der Test schreibt diese Form sogar als erwarteten Vertrag fest; sein Fake-Runner prüft nur die Argumentliste und kann die Sichtbarkeit echter Prozessargumente nicht abdecken (`Tests/WhisperM8Tests/ClaudePluginCLITests.swift:236-252`).

### Konkretes Auslöse-Szenario

Ein Plugin verlangt etwa `api_key=...` oder `token=...`. Der User trägt den Wert in das ausdrücklich dafür angebotene Config-Feld ein. Während des Installationslaufs steht der Klartext in der Argumentliste des `claude`-Prozesses und ist damit für gleichberechtigte lokale Prozessinspektion, Diagnosewerkzeuge und gegebenenfalls Prozess-Crashberichte sichtbar. Die Profilumgebung ist korrekt aufgebaut, schützt aber keine Argumente (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:45-61`).

### Fix-Skizze

Secret-Werte nie per `argv` übertragen. Wenn das offizielle CLI einen stdin-, Datei- oder Secret-Store-Pfad anbietet, diesen mit einer nur für den User lesbaren Übergabe verwenden. Falls es keinen sicheren Kanal gibt, das GUI-Feld ausdrücklich auf nicht-sensitive Konfiguration begrenzen, secret-verdächtige Keys ablehnen und für Secrets auf den vom Plugin vorgesehenen Secret-/Environment-Mechanismus verweisen. Ein Integrationstest muss einen echten Kindprozess inspizieren und sicherstellen, dass der Marker weder in `argv` noch in Logs erscheint.

## R4-PLUG-02 — Timeout beendet nur den Eltern-PID und gibt die globale Serialisierung trotz möglicher Kindprozesse frei

**Schweregrad:** hoch

### Beleg

- Der Wrapper beansprucht als harte Garantie, dass nie zwei Plugin-Prozesse gleichzeitig an Claudes ungeschützten Config-Dateien arbeiten; alle Aufrufe laufen dafür durch einen globalen Serializer (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:13-30,162-174`).
- Der Default-Runner delegiert jeden Plugin-Aufruf mit 120 Sekunden Timeout an `AgentHeadlessCLI` (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:54-61`).
- Beim Timeout sendet dieser Runner `terminate()` nur an das direkte `Process` und fünf Sekunden später `SIGKILL` nur an `process.processIdentifier`; nach weiteren fünf Sekunden gibt der Failsafe die Continuation unabhängig vom Prozessbaum frei (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:78-111`).
- Der Serializer-Test simuliert ausschließlich acht Async-Closures. Die Wrapper-Tests ersetzen den echten Runner vollständig; weder Suite deckt einen CLI-Prozess mit Kindprozess und geerbten Pipes ab (`Tests/WhisperM8Tests/ClaudePluginCLITests.swift:92-125,219-233`).

### Konkretes Auslöse-Szenario

`claude plugin marketplace update` oder eine Installation startet einen Git-/Package-Kindprozess, der hängen bleibt. Nach 120 Sekunden stirbt zunächst nur der direkte `claude`-Prozess; das Kind kann weiterlaufen und die geerbten stdout/stderr-Pipes offenhalten. Spätestens der Failsafe beendet den Swift-Aufruf und damit das Serializer-Tail, obwohl das Kind noch Netzwerk- oder Config-Arbeit ausführt. Der nächste Plugin-Aufruf startet nun parallel zum verwaisten Kind — genau der Zustand, den die globale Serialisierung verhindern soll.

### Fix-Skizze

Den Aufruf in einer eigenen Prozessgruppe starten und bei Timeout die verifizierte Gruppe zuerst mit `SIGTERM`, dann mit `SIGKILL` beenden. Die Serialisierung erst freigeben, wenn Elternprozess, Gruppe und Pipes nachweislich quieszent sind; ein Failsafe darf zwar die UI lösen, muss den globalen Plugin-Lock aber bis zur Reaper-Bestätigung gesperrt halten. Integrationstest mit einem Helper, der einen signalresistenten Kindprozess erzeugt und die Pipe offenhält.

## R4-PLUG-03 — Profilwechsel kann einen alten Detail-Request nach dem Cache-Clear wieder in das neue Profil schreiben

**Schweregrad:** mittel

### Beleg

- Der Detail-Cache ist nur mit `plugin.id@version` adressiert; das Account-Profil ist kein Bestandteil des Keys (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:20-22,47-48`).
- `loadDetailsIfNeeded` prüft den Cache, wartet dann auf den profilierten CLI-Aufruf und schreibt das Ergebnis danach ohne Generation-/Profilprüfung in denselben Cache (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:67-82`).
- `switchAccountProfile` setzt das Profil, leert den Cache und lädt neu, storniert oder entwertet bereits laufende Detail-Requests aber nicht (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:156-160`).
- Detail-Loads setzen `isBusy` nicht; der Profil-Picker bleibt deshalb währenddessen bedienbar und löst den Wechsel in einer neuen `Task` aus (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:55-69,100-105,421-427`).
- Zusatzprofile werden aus beliebigen nicht versteckten Verzeichnissen unter `~/.claude-profiles` entdeckt; sie müssen daher nicht zwingend den von der App erzeugten gemeinsamen Plugin-Symlink besitzen (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:54-68`).
- Der einzige Profiltest führt Details-Laden und Profilwechsel strikt nacheinander aus und prüft nur den unmittelbar geleerten Cache (`Tests/WhisperM8Tests/ClaudePluginManagerModelTests.swift:152-164`).

### Konkretes Auslöse-Szenario

Im Profil A wird eine Plugin-Karte aufgeklappt; der Detail-Aufruf läuft. Noch vor seiner Antwort wechselt der User zu Profil B. B leert und befüllt seine Liste, danach kehrt der alte A-Aufruf zurück und schreibt unter demselben `id@version`-Key. Profil B zeigt nun Beschreibung beziehungsweise Token-Kosten aus A; ein eigener B-Load wird wegen des vorhandenen Cache-Eintrags unterdrückt.

### Fix-Skizze

Profilname oder eine monoton steigende Profilgeneration in Cache-Key und Request aufnehmen. Nach dem `await` nur schreiben, wenn Generation und `accountProfileName` noch dem Startzustand entsprechen. Alternativ laufende Detail-Tasks pro Profil verwalten und beim Wechsel canceln; die Generation-Prüfung bleibt als Schutz gegen nicht kooperative Cancellation nötig. Einen Test mit blockierendem A-Runner, Wechsel zu B und verspäteter A-Antwort ergänzen.

## R4-PLUG-04 — Uninstall, Marketplace-Remove und Prune laufen ohne Bestätigung sofort los

**Schweregrad:** mittel

### Beleg

- „Uninstall“ startet aus dem Kartenmenü direkt eine Task; es gibt keinen Confirmation-State oder Dialog (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:209-222`).
- „Remove“ startet die Marketplace-Löschung ebenfalls direkt über den destruktiven Button (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:395-405`).
- Auch „Prune“, das laut Wrapper verwaiste Auto-Dependencies entfernt, wird beim ersten Klick unmittelbar ausgeführt (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:125-139`; `WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:129-134`).
- Nur die Installation besitzt einen vorgeschalteten Sheet-Flow (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:440-487`). Die beiden angegebenen Testsuiten testen Model/CLI, nicht diese SwiftUI-Interaktionen.

### Konkretes Auslöse-Szenario

Ein fehlgeleiteter Klick auf „Uninstall“ oder „Remove“ startet sofort den Headless-Prozess. Das Menü verschwindet, es gibt weder eine Zusammenfassung des betroffenen Profils/Scopes noch einen zweiten Entscheidungspunkt. Bei „Prune“ ist vor dem Lauf nicht sichtbar, welche Abhängigkeiten entfernt werden; ein CLI-Fehler kommt erst nach möglicher Teilmutation zurück.

### Fix-Skizze

Für jede destruktive Aktion einen expliziten Bestätigungsdialog mit Plugin/Marketplace, Zielprofil und Wirkung anzeigen. Für Prune nach Möglichkeit zuerst einen Dry-Run/Plan darstellen; ohne CLI-Dry-Run mindestens die Nicht-Rücknehmbarkeit klar nennen. Die Bestätigung muss das Zielobjekt als immutable Snapshot halten, damit ein Profilwechsel zwischen Dialog und Ausführung nicht das Ziel ändert.

## R4-PLUG-05 — Ein einziges gedriftetes JSON-Feld verwirft die komplette Plugin- oder Marketplace-Liste

**Schweregrad:** mittel

### Beleg

- Bei installierten Plugins sind `id`, `version`, `scope`, `enabled` und `installPath` sämtlich strikt typisierte Pflichtfelder (`WhisperM8/Services/AgentChats/ClaudePluginListParser.swift:5-16`).
- Der Parser decodiert zuerst das komplette Array und danach den kompletten Combined-Container; ein fehlerhafter Eintrag lässt jeweils den gesamten Decode werfen (`WhisperM8/Services/AgentChats/ClaudePluginListParser.swift:88-105`).
- Marketplaces verlangen mindestens `name` und `source` und werden ebenfalls als vollständiges Array in einem Schritt decodiert (`WhisperM8/Services/AgentChats/ClaudePluginListParser.swift:64-74,107-109`).
- Die Tests decken die zwei bekannten Top-Level-Formen, unbekannte Zusatzkeys und genau einen strukturierten `available.source` ab, aber weder fehlende/geänderte Pflichtfelder noch ANSI-/Hinweistext vor dem JSON (`Tests/WhisperM8Tests/ClaudePluginCLITests.swift:8-90,127-145`).

### Konkretes Auslöse-Szenario

Eine neue CLI-Version lässt `installPath` weg, liefert `enabled` vorübergehend als `null`, oder ändert bei einem Marketplace `source` in ein Objekt. Alternativ steht trotz `NO_COLOR` ein ANSI-Hinweis vor dem JSON. Ein einziger solcher Eintrag lässt `listPlugins` oder `marketplaces` werfen; `reload` zeigt nur einen Seitenfehler und behält gegebenenfalls den alten Zustand statt alle weiterhin gültigen Einträge anzuzeigen (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:59-63,199-212`).

### Fix-Skizze

Wire-DTOs tolerant und separat von den UI-Modellen decodieren: nicht-identitätskritische Felder optional/defaultbar machen, heterogene Werte gezielt normalisieren und Einträge einzeln mit Diagnose sammeln. Vor JSON-Decoding ausschließlich einen klar erkannten JSON-Envelope extrahieren beziehungsweise ANSI-Sequenzen entfernen; niemals beliebigen Text „zurechtschneiden“. Fixture-Matrix für fehlende/null/type-geänderte Felder, gemischte gute/schlechte Einträge, BOM, ANSI und Prefix-Hinweise ergänzen.

## R4-PLUG-06 — Der Details-Parser hängt an englischen Labels und ungefiltertem Terminaltext

**Schweregrad:** mittel

### Beleg

- Der Wrapper setzt zwar `NO_COLOR=1` und `CLICOLOR=0`, fixiert aber keine Locale und bereinigt die Ausgabe selbst nicht (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:45-61,85-88`).
- Der Parser erkennt ausschließlich exakte englische Präfixe und Abschnittsnamen: `Source:`, fünf feste Inventory-Namen, `Always-on:` und `Per-component` (`WhisperM8/Services/AgentChats/ClaudePluginDetailsParser.swift:36-100,107-116`).
- Die Token-Normalisierung versteht nur Komma als Gruppentrenner, Punkt als Dezimaltrennzeichen und `k/K` als Suffix (`WhisperM8/Services/AgentChats/ClaudePluginDetailsParser.swift:140-154`).
- Die Tests verwenden genau eine englische, farblose Fixture und isolierte Werte derselben Zahlenschreibweise; Locale-, ANSI-, Warnungs- und alternative Tabellenfälle fehlen (`Tests/WhisperM8Tests/ClaudePluginCLITests.swift:147-209`).

### Konkretes Auslöse-Szenario

Eine CLI-Version färbt `Always-on:` trotz `NO_COLOR`, setzt davor einen Update-Hinweis oder lokalisiert Labels/Zahlen. Schon ein Escape-Präfix verhindert `hasPrefix`; ein Hinweis wird außerdem als Plugin-Kopf interpretiert. Der nicht werfende Parser liefert dann still `nil` statt eines Fehlers. Die UI meldet lediglich „Token cost not available in this Claude version“, obwohl die Daten vorhanden waren (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:234-250`).

### Fix-Skizze

Wenn verfügbar auf eine maschinenlesbare Details-Ausgabe wechseln. Bis dahin `LC_ALL=C`/`LANG=C` für diesen Prozess setzen, ANSI robust entfernen, bekannte Präambeln überspringen und Abschnitte strukturell statt nur über exakte sichtbare Labels erkennen. Parser-Ergebnis um Diagnose/Formatversion ergänzen, damit „nicht vorhanden“ von „nicht geparst“ unterscheidbar ist. Golden Fixtures für ANSI, CRLF, Prefix-Warnung und mehrere Locale-/Zahlvarianten hinzufügen.

## R4-PLUG-07 — Fehlgeschlagene oder unparsbare Details werden als „vollständige“ Token-Summe gewertet

**Schweregrad:** mittel

### Beleg

- `isTokenSumComplete` prüft bei enabled Plugins nur, ob irgendein Cache-Eintrag vorhanden ist, nicht ob `alwaysOnTokens` erfolgreich ermittelt wurde (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:31-44`).
- Bei jedem Details-Fehler wird absichtlich ein leerer Placeholder mit `alwaysOnTokens == nil` gecacht (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:67-83`). Auch ein erfolgreicher CLI-Aufruf mit Parser-Drift erzeugt einen solchen inhaltsleeren Details-Wert (`WhisperM8/Services/AgentChats/ClaudePluginDetailsParser.swift:31-33,103-105`).
- Die UI färbt die Summe bei `isTokenSumComplete == true` als OK und entfernt den „partial“-Zusatz (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:163-171`).
- Der Failure-Test verlangt nur, dass der Placeholder existiert und `alwaysOnTokens` nil ist; er prüft die dadurch fälschlich umschaltende Completeness nicht (`Tests/WhisperM8Tests/ClaudePluginManagerModelTests.swift:135-150`).

### Konkretes Auslöse-Szenario

Ein enabled Plugin hat 15.000 Always-on-Tokens, aber sein Details-Aufruf timed out oder das Label driftet. Der Placeholder landet im Cache; die Summe nutzt `compactMap`, lässt das Plugin also als null Beitrag weg, und `isTokenSumComplete` wird trotzdem wahr. Die UI zeigt eine grüne, angeblich vollständige Summe, die um 15.000 Tokens zu niedrig ist.

### Fix-Skizze

Cache-Zustände explizit modellieren (`loading`, `loaded(details)`, `unavailable`, `failed`). „Vollständig“ darf nur gelten, wenn jedes enabled Plugin entweder einen numerischen Wert oder einen vom CLI ausdrücklich bestätigten Nullwert besitzt. Fehler/unparsbar müssen die Summe partial/unknown halten und retrybar bleiben; dazu einen Regressionstest für Failure-Placeholder plus Completeness ergänzen.

## R4-PLUG-08 — Fehlerhafte Config-Zeilen werden vor der CLI-Validierung still verworfen

**Schweregrad:** niedrig

### Beleg

- `parseKeyValueLines` überspringt Zeilen ohne `=`, verwirft leere Keys und überschreibt doppelte Keys still mit dem letzten Wert (`WhisperM8/Views/Settings/Kit/SettingsLineParsing.swift:13-22`).
- Das Installations-Sheet behauptet, das CLI übernehme die Schema-Validierung, schließt sich aber sofort nach diesem verlustbehafteten Parse und startet die Installation (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:440-441,466-480`).
- Für `SettingsLineParsing.parseKeyValueLines` existiert in den angegebenen Plugin-Manager-Tests kein Test; die Suche findet nur Produktionsaufrufe.

### Konkretes Auslöse-Szenario

Der User trägt `endpoint https://...` ohne Gleichheitszeichen oder denselben Key zweimal ein. Die fehlerhafte beziehungsweise erste Zeile erreicht das CLI nie, kann dort also nicht validiert werden. Die Installation kann erfolgreich erscheinen, obwohl Konfiguration fehlt oder unbemerkt ersetzt wurde; weil das Sheet bereits geschlossen ist, ist der ursprüngliche Text verloren.

### Fix-Skizze

Der Parser sollte Werte plus strukturierte Diagnosen liefern. Leere Keys, fehlendes `=` und Duplikate als sichtbare Fehler markieren und Installation sowie Dismiss blockieren, bis der User korrigiert oder ausdrücklich bestätigt. Tests für malformed, duplicate, leere Werte und Werte mit weiteren `=` ergänzen.

## Testabdeckung: zentrale Blindstellen

Die vorhandenen Tests sind für bekannte Happy-Path-Fixtures und mehrere bereits behobene Fehler wertvoll: Top-Level-JSON-Formen, strukturierte `available.source`, globale Closure-Serialisierung, Argument-/Profilweitergabe, Mutation-vor-Reload-Semantik und das Beenden des Detail-Spinners (`Tests/WhisperM8Tests/ClaudePluginCLITests.swift:8-145,211-297`; `Tests/WhisperM8Tests/ClaudePluginManagerModelTests.swift:54-164`). Nicht abgedeckt sind jedoch echte Prozessbäume und Timeout-Reaping, Secret-Sichtbarkeit, überlappende Profil-/Detail-Tasks, SwiftUI-Bestätigungsflows, malformed/partiell gedriftete JSON-Einträge, ANSI/Locale/Präambeln sowie die semantische Korrektheit der Token-Completeness nach Details-Fehlern.

