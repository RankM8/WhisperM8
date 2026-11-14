# Linears Agent-Funktion: statt unseres Anhangs, daneben oder nicht

**Stand:** 2026-11-14 · **Status:** Giuliano hat am 14.11.2026 Weg A gewählt (jetzt nicht, der Anhang bleibt) · **Ticket:** WM8-84
**Betrifft:** Ticket-Board Stufe 2 (WM8-81), Chat-Verlauf am Ticket (WM8-83), Workspace DealSupply mit Kollegen
**Quellen:** Linears Entwickler-Doku (gelesen am 14.11.2026), Linears Schnittstelle (Schema gelesen, drei Aufrufe
versucht), Test-Ticket WM8-90 im Workspace WhisperM8. Jede Aussage ist als **gemessen** oder **gelesen** markiert.

## Ergebnis zuerst

1. **Mit unserem Schlüssel geht es nicht.** Linear sperrt alle drei Agent-Befehle für persönliche Schlüssel
   (gemessen: 403 „Using an unexpected authentication method (apiKey)“). Eine Agent-Sitzung gehört immer einer
   eigenen App mit eigener Identität („WhisperM8“ als App-Nutzer), die ein Admin im Workspace installiert.
2. **Ohne öffentlich erreichbare Adresse bliebe es halb.** Damit Linear Sitzungen anzeigt und jemand in Linear
   einen Chat ansprechen oder ihm ein Ticket übergeben kann, verlangt Linear einen Webhook unter einer
   öffentlichen https-Adresse, der binnen 5 Sekunden antwortet. WhisperM8 läuft auf dem Mac und hat keine. Ob
   Sitzungen ohne Webhook überhaupt in der Oberfläche erscheinen, lässt die Doku offen.
3. **Der Gewinn ist heute klein.** Die Ansichten „Mit Agent“ und „Ohne Agent“ gibt es schon, auf Basis unseres
   Anhangs. Linears Funktion brächte echte Filter und einen Verlauf je Sitzung, aber nur in groben Schritten,
   nicht den Chat-Verlauf, den WM8-83 braucht.

**Empfehlung:** Jetzt nicht. Der Anhang bleibt die Verknüpfung, Board-Stufe 2 und WM8-83 bauen darauf.
Linears Funktion lohnt sich erst, wenn Giuliano Tickets aus Linear heraus an WhisperM8 übergeben will. Dafür
braucht es einen Webhook-Dienst im Netz, und das ist ein eigenes Vorhaben.

## 1. Was Linears Agent-Funktion ist (gelesen)

| Frage | Antwort | Quelle |
|---|---|---|
| Was ist ein Agent? | Eine App, die sich im Workspace wie ein Nutzer verhält: Man kann ihr ein Ticket übergeben („delegate“, der Mensch bleibt Assignee) und sie per @ erwähnen | developers/agents, docs/agents-in-linear |
| Was ist eine Sitzung? | Ein Arbeitslauf der App an einem Ticket, mit eigenem Kommentar-Faden, Zustand, Plan, Zusammenfassung und Links nach außen | developers/agent-interaction |
| Zustände | `pending`, `active`, `stopping`, `awaitingInput`, `complete`, `error`, `stale` (Schema, gemessen). Linear setzt sie selbst aus dem letzten Eintrag; nach 30 Minuten ohne Eintrag wird eine Sitzung `stale` | Schema, developers/agent-best-practices |
| Einträge | `thought`, `action` (beide auch flüchtig, „ephemeral“), `elicitation` (Rückfrage), `response`, `error`; `prompt` schreibt nur ein Mensch | developers/agent-interaction |
| Filter „Dismissed“, „Merged“ | Dismissed: ein Mensch hat die Sitzung abgebrochen, die Übergabe fällt weg. Merged: ein mit der Sitzung verknüpfter Pull Request ist gemergt | Schema (`hasDismissedAgentSessions`, `hasMergedAgentPullRequests`), gelesen |
| Wem gehört eine Sitzung? | Dem App-Nutzer der App. „personal API keys cannot publish agent activities“ (Schema-Text zu `agentActivityCreate`) | Schema, developers/oauth-actor-authorization |
| Anmeldung der App | OAuth-App in Linear anlegen, Token mit `actor=app`. Ohne Browser geht es per „client credentials“: Token 30 Tage gültig, kein Refresh, vor Ablauf neu holen. Optional `app:assignable` (Übergabe) und `app:mentionable` (@) | developers/oauth-2-0-authentication, developers/agents |
| Wer installiert? | Ein Admin („admin permissions are required to complete the installation“). Die App selbst darf keinen Admin-Scope haben | developers/agents |
| Webhook | Für Übergabe, Erwähnung und Rückfragen aus Linear: `AgentSessionEvent` an eine öffentliche https-Adresse, Antwort binnen 5 s, erster Eintrag binnen 10 s. „Once you subscribe to AgentSessionEvent webhooks, customers will begin seeing Agent Session UI in Linear“ | developers/agent-interaction, developers/webhooks |
| Kosten | „agents installed in your workspace do not count as billable users“; im Free-Plan „Agent platform: Included“. Aber: „Third-party app management“ steht im Free-Plan als „Not included“; was das für eine eigene App heißt, steht nirgends | developers/agents, linear.app/pricing |
| Was Kollegen sehen | Jeder mit Zugriff auf die Teams sieht Zustand und Einträge der Sitzungen und kann die App erwähnen oder ihr Tickets übergeben | docs/agents-in-linear |
| Grenzen | OAuth-App: 5.000 Anfragen je Stunde je App-Nutzer, getrennt vom persönlichen Schlüssel (2.500) | developers/rate-limiting |
| Reife | Der Plan einer Sitzung ist „technology preview“; der Rest ohne Vorbehalt, aber `externalLink` ist schon abgelöst | developers/agent-interaction |

## 2. Der Versuch (gemessen)

Test-Ticket **WM8-90** „Test: Agent Session“ (Team WM8, Projekt Tickets, Label „Selbst erfasst“), am Ende auf
Canceled gesetzt. Aufrufe über `linear-api --ws whisperm8` mit dem persönlichen Schlüssel (Admin):

| Aufruf | Ergebnis |
|---|---|
| `agentSessionCreateOnIssue` (WM8-90, ein Link nach außen) | **403 FORBIDDEN**: „Using an unexpected authentication method (apiKey) for an operation“ |
| `agentActivityCreate` (Gedanke) | dieselbe Absage |
| `agentSessionUpdateExternalUrl` | dieselbe Absage |
| `agentSessions` (lesen) | geht, Ergebnis: keine einzige Sitzung im Workspace |
| App-Nutzer im Workspace (lesen) | nur „Linear“ selbst |

Damit war der Versuch an dieser Stelle zu Ende. Eine App anzulegen war ausgeschlossen. Ein Bildschirmfoto ging
nicht: Der Playwright-Browser ist nicht bei Linear angemeldet, und anmelden war nicht vorgesehen. Ohne Sitzung
gäbe es im Ticket ohnehin nichts Neues zu sehen.

**Was für einen echten Versuch einzurichten wäre (nicht eingerichtet):**

1. Giuliano legt als Admin im Workspace WhisperM8 in den Einstellungen (Bereich API, genauer Ort nicht
   geprüft) eine OAuth-App „WhisperM8“ an. Dazu gehören ein Name, ein Symbol und eine Redirect-Adresse; ob die Pflicht ist, sagt die
   Doku nicht. Dann schaltet er „client credentials“ ein und wählt die Scopes `read` und `write`, ohne
   `app:assignable` und `app:mentionable`, denn ohne Webhook könnte die App darauf nicht reagieren.
2. Er installiert die App für das Team WM8 und legt Client-ID und Secret in den Schlüsselbund, so wie den
   heutigen Schlüssel.
3. Ein Skript holt per client credentials ein App-Token, legt an WM8-90 eine Sitzung an, schreibt einen
   Gedanken, eine Rückfrage und eine Antwort und setzt einen Link.
4. Zu klären wäre dann: Erscheint die Sitzung ohne Webhook im Ticket und in den Filtern? Lässt Linear im
   Free-Plan eine eigene App zu? Nimmt `externalUrls` eine `whisperm8://`-Adresse an?
5. Danach App entfernen und Secret löschen, oder behalten, je nach Entscheidung.

Aufwand: etwa 30 Minuten für Giuliano, dazu eine Stunde Skript. Die Installation ist eine dauerhafte Änderung
am Workspace, bis sie wieder entfernt wird.

## 3. Abbildung auf unsere Chats (gelesen, abgeleitet)

**Ein Agent, viele Sitzungen.** Linear kennt je installierter App genau einen App-Nutzer. Es gäbe also einen
Agent „WhisperM8“ je Workspace. Jeder Chat, der an einem Ticket arbeitet, bekäme dort eine Sitzung. Der
Chat-Name stünde in der Zusammenfassung („Noa · Linear: Agent-Funktion prüfen“), der Link nach außen wäre
`whisperm8://chat/<id>`, falls Linear das annimmt. Einen Agent je Chat gibt es nicht. Dafür bräuchte jeder Chat
eine eigene App.

**Zustand:**

| WhisperM8 | Linear-Eintrag | Sitzung danach |
|---|---|---|
| arbeitet (Turn beginnt) | `thought` (flüchtig) | `active` |
| wartet auf Antwort | `elicitation` | `awaitingInput` |
| Turn fertig | `response` | `complete` |
| Fehler | `error` | `error` |
| am Limit | `error` mit „Limit, geht um HH:MM weiter“ | `error` |
| arbeitet länger als 30 Min | alle 20 Min ein flüchtiger `thought` | bleibt `active`, sonst `stale` |

Ein Chat, der nach seinem Turn auf den nächsten Auftrag wartet, stünde in Linear als `complete`. Das ist
richtig, Linear öffnet eine fertige Sitzung beim nächsten Eintrag wieder.

**Wer schriebe:** Die Zustände kennt nur die App (Status-Koordinator, Registry, Hooks). `CLAUDE.md` sagt (Stand main
14.11.2026): „Das Ticket-System liest die App nur bei `ticketBoardEnabled` (Ansicht und Einrichtung) …;
geschrieben wird nur über `whisperm8 tickets`.“ Für Agent-Sitzungen müsste die App schreiben, und zwar bei jedem
Statuswechsel. Über die
Kommandozeile hieße das ein Prozessstart je Wechsel. Beides ist eine neue Regel in `CLAUDE.md`, die bei
der Zeichengrenze von 15.000 steht.

**Wie oft:** Bei 10 bis 15 gleichzeitigen Chats mit je etwa 6 bis 10 Turns pro Stunde sind es je Turn zwei bis
drei Einträge plus Herzschlag. Das ergibt grob 300 bis 500 Anfragen je Stunde. Das App-Token hat eigene 5.000
je Stunde. Das Board (alle 30 s zwei Abfragen, also 240 je Stunde) bliebe beim persönlichen Schlüssel mit 2.500.
An der Grenze scheitert es nicht.

**Was fehlt trotzdem:** Linears Verlauf besteht aus Schritten, die der Agent selbst formuliert, nicht aus dem
Chat-Verlauf. Für WM8-83 („Verlauf ansehen“, „hier fortsetzen“) bleibt ein Anhang mit der Verlaufsdatei nötig.
Eine Sitzung könnte nur auf diese Datei verlinken.

## 4. Drei Wege

### A — nicht nutzen, der Anhang bleibt (empfohlen)

- **Besser wird:** nichts Neues, aber nichts geht kaputt. „Mit Agent“ und „Ohne Agent“ funktionieren schon.
- **Aufwand:** keiner. Linears eigenes Feld „Agent“ zeigt weiter „No agent“; die beiden Ansichten ersetzen es.
- **Board Stufe 2:** baut wie geplant auf dem Anhang. **WM8-83:** hängt die Verlaufsdatei als Anhang an.
- **DealSupply:** Kollegen sehen weiter nur „Chat: <Titel>“ als Anhang. Keine App im Workspace, kein Admin-Schritt.
- **Risiko:** gering. Ändert Linear die Anhänge, betrifft es nur `TicketChatLinkFormat`.

### B — daneben, nur schreiben, ohne Webhook

- Eine App „WhisperM8“ je Workspace, Token per client credentials. Die App legt beim `tickets link` zusätzlich eine
  Sitzung an und schreibt die Zustände aus der Tabelle oben. Der Anhang bleibt die Quelle der Wahrheit.
- **Besser wird:** Linears Filter nach Agent und Sitzung sind echt, am Ticket steht ein Zustand mit Verlauf in
  groben Schritten, Fehler und Limit sind in Linear sichtbar.
- **Aufwand:** App einrichten (Giuliano, 30 Min je Workspace), Bau 2 bis 3 Tage: Token holen und erneuern,
  Abbildung der Zustände, Drosselung, Herzschlag, Regel in `CLAUDE.md`, Tests.
- **Risiken:** Ungeklärt ist, ob Linear Sitzungen ohne Webhook-Abo überhaupt anzeigt; dann wäre der Bau wertlos.
  Ungeklärt ist auch, ob der Free-Plan eine eigene App zulässt. Dazu kommen ein zweites Geheimnis im
  Schlüsselbund, eine neue Schreibstelle in der App und ein sichtbarer Arbeitsverlauf für alle im Workspace
  (bei DealSupply lesen Kollegen mit, was Giulianos Chats tun). Alle Sitzungen erscheinen als „WhisperM8“, nicht
  als Giuliano.
- **Board Stufe 2:** unberührt, das Board liest weiter den Anhang. **WM8-83:** unberührt.
- **Vorher nötig:** der Versuch aus Abschnitt 2 mit einer Test-App.

### C — statt des Anhangs, mit Webhook und Übergabe aus Linear

- Wie B, dazu ein kleiner Dienst im Netz mit öffentlicher https-Adresse, etwa ein Cloudflare Worker. Er nimmt
  Linears Ereignisse an, antwortet binnen 5 s und gibt sie an die WhisperM8-App auf dem Mac weiter. Wer in Linear
  ein Ticket an „WhisperM8“ übergibt oder die App erwähnt, startet damit einen Chat; Rückfragen beantwortet man
  in Linear.
- **Besser wird:** Tickets lassen sich aus Linear an einen Chat geben, auch vom Handy.
- **Aufwand:** 1 bis 2 Wochen, dazu Betrieb eines Dienstes im Netz, Weiterleitung an den Mac (der schlafen kann)
  und Zuordnung bei mehreren WhisperM8-Nutzern in einem Workspace.
- **Risiken:** Sicherheit (jeder im Workspace kann Chats auf Giulianos Mac starten), ein Dienst außerhalb der App,
  Abhängigkeit von Linears Fristen. Der Anhang als Quelle der Wahrheit fiele weg, Board und `tickets` müssten
  umgebaut werden.
- **DealSupply:** Kollegen könnten Giulianos Agent Arbeit zuweisen. Das ist eine Produktentscheidung, keine
  technische.

## Empfehlung

**A jetzt.** Der Gewinn von B ist vor allem Linears eigener Filter, und den ersetzen unsere Ansichten schon.
Dafür kämen eine App je Workspace, eine neue Schreibstelle und eine offene Frage zur Anzeige ohne Webhook. C ist
der Weg mit echtem Mehrwert, aber ein eigenes Vorhaben. Es sollte erst kommen, wenn die Übergabe aus Linear
wirklich gewollt ist. Board Stufe 2 und WM8-83 können ohne Abhängigkeit weitergebaut werden. Will Giuliano B
oder C offenhalten, ist der Versuch mit einer Test-App (Abschnitt 2) der günstige nächste Schritt.
