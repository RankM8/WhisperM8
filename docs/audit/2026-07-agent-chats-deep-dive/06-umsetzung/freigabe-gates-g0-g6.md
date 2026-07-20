---
status: technisch-abgenommen-user-go-ausstehend
updated: 2026-07-20
description: Unabhängige technische Abnahme der Gates G0–G6 mit Evidenz, geschlossenen Dokumentations-P0s, fail-closed Live-Probe und weiterhin gesperrtem Produkt-Go bis zur User-Abnahme.
---

# Formale Freigabe-Gates G0–G6

## Entscheidung

**Technische G6-Abnahme bestanden; User-Go ausstehend.** G0–G5 erfüllen nach dem Paket-F-Nachtrag ihre dokumentierten Kriterien, damit ist auch G6 technisch erfüllt und die fünf Dokumentations-/Spezifikations-P0s sind geschlossen. Das ist ausdrücklich noch **kein Produkt-Go**: P0.3/P0.4 und W0.1 bleiben bis zur formalen User-Abnahme gesperrt; offene rote Oracles und Produktdefekte gelten nicht als umgesetzt.

Geprüfter Stand: `75cd5a9` plus der uncommittete Paket-F-Nachtrag. Die Paket-Commits wurden nicht als Beweis ihrer eigenen Vollständigkeit übernommen, sondern gegen die Gate-Kriterien aus der [Abschlusskritik § „Konkreter Restweg“](../02-findings/runde4-abschlusskritik.md#antwort-2-konkreter-restweg-bis-zur-freigabe-von-welle-01) geprüft. G4/G5 wurden zusätzlich über einen vollständigen ID-/Vertragsabgleich, G6 über den unten dokumentierten Referenzcheck verifiziert.

## Gate-Tabelle

| Gate | Erledigt, wenn | Evidenz | Unabhängiges Prüfergebnis |
|---|---|---|---|
| **G0 — Identitätsstrategie** | Beide Specs verwenden dieselbe capability-gegattete Tabelle und dieselben Begriffe; Roadmap und Test-Spec verweisen darauf. | Commit `786d012`; [Identitätsspec § 2.2](identitaetsmodell-spec.md#22-gemeinsamer-normativer-vertrag-g0g2), [Recovery-Spec § 2.2](verlorene-chats-spec.md#22-gemeinsamer-normativer-vertrag-g0g2), [Test-Spec A02](test-specs-welle0-1.md#a02-capability-gate-und-atomare-claim-api-sind-der-einzige-bindungsweg-w0-zunächst-rot), [Roadmap-Nachtrag](../05-roadmap/refactor-roadmap.md#nachtrag-runde-4). | **Erfüllt.** Die normativen §-2.2-Abschnitte sind wortgleich; `hostAssignedUnsupported`/`hostAssignedVerified` sowie Fresh/Resume/Fork sind konsistent. Die blockierte Live-Probe hält korrekt Weg B als Baseline und macht G0 nicht rot. |
| **G1 — Launch-Korrelation und Claims** | Hook, Indexer und Control-CLI prüfen dieselbe aktuelle Launchgeneration und denselben gescopten Provider-Key; unklare Claims mutieren keine Row. | Commit `786d012`; [Bridge-Envelope und Claim-API](identitaetsmodell-spec.md#per-launch-korrelation-und-bridge-envelope), [Chats-CLI-Revisionsvertrag](identitaetsmodell-spec.md#chats-cli-revisionsvertrag), [R4-WAIT-01-Oracle](test-specs-welle0-1.md#r4-wait-01-new-wait---ref-lädt-spätes-binding-nach-w0-oraclew1-fix-rot). | **Erfüllt mit Vorbehalt.** Der Vertrag beschreibt Generation, Root, atomare Outcomes und Re-Load je Workspace-Revision. Das schließt den Spezifikationsanteil von P0 2; der produktive R4-WAIT-01-Fix ist weiterhin offen und darf nicht als umgesetzt gelten. |
| **G2 — Laufzeit-Übergänge** | Jede Operation hat eine deterministische Transition und einen negativen Mehrdeutigkeitsfall; `SessionStart.source` ist Parser- und Testvertrag. | Commit `786d012`; [Transitionsmatrix](identitaetsmodell-spec.md#23-vollständige-laufzeit-übergangsmatrix), [A02-S01–S08](test-specs-welle0-1.md#a02-s01-bis-a02-s08-normative-source-transitionsoracles). | **Erfüllt.** `/branch`, `/rewind`, `/clear`, `/resume`, `/compact` und Prozessende sind getrennt; negative Fälle erhalten die alte Bindung und führen kontrolliert in Recovery/Diagnose. |
| **G3 — Inventar als Oracle** | AC-30/41/52 trennen Ist, Lücke und Soll; R4-AS-11 besitzt einen konkreten Testanker; rote Soll-Eigenschaften erscheinen nicht als bestehende Invarianten. | Commit `4a78f3d`; [R4-AS-11](feature-inventar-agentchats.md#r4-as-11-doppelte-lokale-session-ids-beim-load), [AC-30](feature-inventar-agentchats.md#ac-30-terminal-endsnapshot-und-offline-fallback), [AC-41](feature-inventar-agentchats.md#ac-41-reale-session-id-bindung), [AC-52](feature-inventar-agentchats.md#ac-52-merge-adoption-und-deduplizierung). | **Erfüllt.** Die vier Stichproben unterscheiden den heutigen Code vom offenen Soll; Snapshot-Privacy/Retention ist ausdrücklich ein offenes Gate und R4-AS-11 verweist auf konkrete Tests. |
| **G4 — W0/W1-Test-Spec** | Jede W0/W1-Maßnahme besitzt ausführbaren Vertrag, minimale Naht, deterministische Zeit/Reihenfolge und Negativfall; W2/W3 sind separat. | Commit `b902d41` plus Paket-F-Nachtrag; [Wellenschnitt](test-specs-welle0-1.md#21-verbindlicher-wellenschnitt-und-vollständigkeit), [C07-Matrix](test-specs-welle0-1.md#22-c07-vollständige-atomare-claim-matrix-w0-zunächst-rot), [B18–B22](test-specs-welle0-1.md#23-fehlende-w1-gates-b18b22), [Runde-4-Oracles](test-specs-welle0-1.md#24-runde-4-hochbefund-oracles). | **Erfüllt.** B18–B22, C07, die Chats-CLI-Oracles und sämtliche weiteren W0/W1-gerouteten Runde-4-Hochbefunde besitzen Given/When/Then, Negativ-/Persistenzfall und minimale Naht. Zeit-/Reihenfolgeverträge verwenden `ManualClock`/`ManualGate`. Nur R4-RESUME-01 bleibt gemäß bestehender SwiftUI-/AppKit-Testgrenze bewusst als ausführbare manuelle View-QA gegatet; es wird kein künstlicher Produktionsharness erfunden. W2/W3 sind separat. |
| **G5 — Runde-4-Traceability** | Jede bestätigte kritische/hohe Runde-4-ID hat genau einen Roadmap-Link und einen realen Test-Gate-Link; nichts ist doppelt oder nur als Freitext vertreten. | Commits `cbf28cd`, `75cd5a9` plus Paket-F-Nachtrag; [Runde-4-Matrix](../05-roadmap/findings-matrix.md#runde-4-bestätigte-kritischehohe-findings), [Roadmap-Nachtrag](../05-roadmap/refactor-roadmap.md#nachtrag-runde-4), [Test-Spec-Oracles](test-specs-welle0-1.md#24-runde-4-hochbefund-oracles). | **Erfüllt.** 28 bestätigte Quell-IDs sind eindeutig in 27 kanonische Maßnahmen geroutet; nur `R4-CP-02`/`R4-DELTA-PROFILE-01` teilen bewusst eine deduplizierte Zeile. Jede Maßnahme besitzt genau eine Roadmap-Zuordnung und einen auflösbaren Testvertrag beziehungsweise bei bereits gefixten Zeilen einen konkreten Regressionstest. |
| **G6 — Referenzen und formale Abnahme** | Alle fünf Freigabedokumente zeigen widerspruchsfrei auf den finalen Branch und die Freigabe folgt ohne Interpretation aus der Tabelle. | Dieses Dokument; vollständiger Referenzcheck der fünf Freigabedokumente; Paket F ohne Commit. | **Technisch erfüllt.** 1.095 repo-interne Zeilenreferenzen und vier lokale Links sind gültig, der gemeinsame G0–G2-Block ist bytegleich und alle Statusdokumente zeigen auf diese Tabelle. Die technische Gate-Abnahme ersetzt nicht die ausstehende formale User-Freigabe. |

## Status der fünf P0-Blocker

| P0-Blocker aus der Abschlusskritik | Schließendes Gate | Status am geprüften Stand |
|---|---|---|
| **1 — Weg A gegen Weg B** | G0 | **Spezifikationsblocker geschlossen.** Weg B ist `hostAssignedUnsupported`-Baseline; Weg A bleibt ausschließlich nach positiver Capability-Probe erreichbar. |
| **2 — `launchID` fehlt im Hook-/Claim-Vertrag** | G1, einschließlich R4-WAIT-01 | **Spezifikationsblocker geschlossen, Produktdefekt offen.** Envelope, Generation und atomare Claim-API sind festgeschrieben; der rote R4-WAIT-01-Testvertrag existiert. Der Fix im produktiven `wait`-Pfad ist noch nicht umgesetzt. |
| **3 — Laufzeitwechsel `/branch`/`/rewind` fehlen** | G2 | **Spezifikationsblocker geschlossen.** Transitionen und negative Oracles sind definiert; die Produktimplementierung ist nicht Teil dieses Gates. |
| **4 — Agent-Chats-Inventar ist kein Oracle** | G3 | **Dokumentationsblocker geschlossen.** Ist/Lücke/Soll und R4-AS-11 sind getrennt. Offene Produktlücken bleiben absichtlich rot. |
| **5 — Test-Spec deckt W0/W1 nicht vollständig ab** | G4, anschließend G5 | **Dokumentationsblocker geschlossen.** Alle W0/W1-Maßnahmen und alle 27 kanonischen Runde-4-Hochmaßnahmen besitzen einen ausführbaren Testvertrag, konkreten bestehenden Regressionstest oder den ausdrücklich begründeten manuellen R4-RESUME-View-QA-Vertrag; die Traceability ist eindeutig. Die roten Oracles sind noch nicht als Produktfix umgesetzt. |

## Sonderstatus der Live-Probe

Paket B/Commit `9f7b13a` ist [blockiert](../04-verifikation/fork-hook-live-probe.md#ergebnis): Der isolierte Auth-Mini-Lauf endete mit Exit 1 und „Not logged in“, daher wurden Fresh-/Resume-/Fork-Arme nicht ausgeführt. Folgerichtig bleibt `hostAssignedVerified` **nicht freigeschaltet**. Das blockiert die Gate-Abnahme nicht eigenständig, weil der beschlossene Weg B als `hostAssignedUnsupported` fail-closed und vollständig spezifiziert ist; es verbietet lediglich jede Annahme, Weg A sei für die installierte CLI verifiziert.

## Sperrstatus und Freigabefolge

Die technische Dokumentationsabnahme ist abgeschlossen; die Identitäts-/Recovery-Produktimplementierung **P0.3/P0.4 bleibt dennoch bis zur formalen Abnahme durch den User gesperrt**. Nach diesem User-Go wird zuerst W0.1 als Oracle-Welle materialisiert und beobachtet; daraus folgt kein pauschales W1- oder Kernumbau-Go. `hostAssignedVerified` bleibt unabhängig davon deaktiviert, solange Paket B keine positive Live-Probe liefert. Bereits separat gegatete Phase-0-Fixes bleiben zulässig.

## Referenzprüfung

Die fünf Freigabedokumente sind die fünf von `verifikation-schluss.md` geprüften Spezifikationen:

1. `identitaetsmodell-spec.md`,
2. `verlorene-chats-spec.md`,
3. `feature-inventar-diktat.md`,
4. `feature-inventar-agentchats.md`,
5. `test-specs-welle0-1.md`.

Der vollständige mechanische HEAD-Check umfasst **1.095 repo-interne `Datei:Zeile`-Referenzen**: Ziel existiert, Start/Ende liegen im aktuellen Dateibereich, keine Referenz ist nach den Korrekturen außerhalb des Ziels. Die vier relativen Markdown-Links dieser fünf Dateien zeigen ebenfalls auf vorhandene Dateien. Zusätzlich wurden Referenzen auf seit dem Audit geänderte Zielpfade semantisch stichprobenartig gegen den beschriebenen Codebereich geprüft.

Nachgezogen wurden:

- der Worktree-Create-/Dirty-Guard-/Remove-Bereich auf `AgentWorktreeManager.swift:40-70`,
- die nach dem Settings-IA-Umbau getrennten Bereiche für Benachrichtigungen/Extra-Args und `ClaudeHooksSettingsPage`,
- sechs nicht portable Scratchpad-Verweise auf `agent-deck/docs/session-id-lifecycle.md`; sie zeigen jetzt ausschließlich auf die persistente Repo-Analyse `03-vergleich/code-analysen/agent-deck.md`.

Der gemeinsame normative G0–G2-Block ist weiterhin bytegleich (`identitaetsmodell-spec.md:54-180` gegen `verlorene-chats-spec.md:65-191`, SHA-256 `cc500b89b0508b9349e99833774af545687fe006eb5fa37a0a7a1ccf4135f6a1`). Seine frühere Zukunftsform „als B-Tests materialisiert“ wurde in beiden Kopien auf die tatsächlich vorhandenen `A02-S01` bis `A02-S08` nachgezogen.

Nicht ausgeführt wurden die vollständige Swift-Test-Suite, manuelle App-QA und die wegen Auth blockierten Live-Probe-Arme. Diese Punkte sind Produkt-/QA-Nachweise nach dem Dokumentationsgate; sie ändern weder die technische G0–G6-Abnahme noch die weiterhin notwendige User-Freigabe.
