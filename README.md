# WhisperM8

Native macOS Diktier-App mit OpenAI Whisper / Groq Transkription.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Push-to-Talk**: Hotkey gedrückt halten → sprechen → loslassen → Text eingefügt
- **Auto-Paste**: Text wird automatisch in die aktive App eingefügt
- **Dual-Provider**: OpenAI Whisper oder Groq (schneller, günstiger)
- **Menu Bar App**: Läuft diskret in der Menüleiste

## Schnellstart

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
```

**Bei Problemen:**
```bash
make clean-install
```

## Make-Befehle

| Befehl | Beschreibung |
|--------|--------------|
| `make install` | Build + Installation nach `/Applications` |
| `make run` | Debug-Build + sofort starten |
| `make dmg` | DMG für Verteilung erstellen |
| `make clean-install` | **Alles zurücksetzen** + neu installieren |
| `make kill` | Laufende Instanzen beenden |

## Berechtigungen

Die App benötigt:
- **Mikrofon**: Für Sprachaufnahme
- **Accessibility**: Für Auto-Paste (Cmd+V senden)

## Dokumentation

**→ [Vollständige Dokumentation](docs/README.md)**

Enthält:
- Detaillierte Installation (DMG / Source)
- Ersteinrichtung (API-Keys, Hotkey, Berechtigungen)
- Verwendung und Einstellungen
- Troubleshooting (Crashes, Berechtigungsprobleme)
- Projektstruktur für Entwickler

## API-Provider

| Provider | Preis | Link |
|----------|-------|------|
| OpenAI | ~$0.006/min | [API-Key erstellen](https://platform.openai.com/api-keys) |
| Groq | Kostenlos* | [API-Key erstellen](https://console.groq.com/keys) |

*Rate-Limited

## Lizenz

Intern - nur für Team-Nutzung.
