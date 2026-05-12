# Subagent 07 - Menues, Commands, Context Menus und Sidebar/Tab-UX

## Kurzbefund

Die App nutzt viele lokale Buttons und Kontextmenues, aber keine zentrale macOS-Command-Schicht. Wichtige Aktionen sind dadurch schlecht ueber Menueleiste/Tastatur entdeckbar und mehrfach dupliziert.

## Befunde

- `WhisperM8/WhisperM8App.swift:26`: keine `.commands`; Aktionen wie New Chat, Scan Sessions, Sidebar/Inspector Toggle, Rename, Settings, Output und Agent Chats haengen an lokalen Buttons.
- `WhisperM8/Views/AgentChatsView.swift:749`, `1386`, `1783`: Session-Menues sind dreifach dupliziert. Header-Ellipsis enthaelt Start/Restart, Tab- und Sidebar-Kontextmenues nicht vollstaendig identisch.
- `WhisperM8/Views/AgentChatsView.swift:1897`: Projekt-Aktionen sind fast nur per Rechtsklick erreichbar; sichtbar ist im Hover primär `+`.
- `WhisperM8/Views/AgentChatsView.swift:60` und `579`: Tab-Leiste und Sidebar teilen Reorder-Semantik. Nutzer koennten unabhängige Tab-Reihenfolge erwarten.
- `WhisperM8/Services/WindowRequestCenter.swift:59` und `WhisperM8/WhisperM8App.swift:43`: Window-Routing haengt indirekt am `WindowRequestHandler` im `MenuBarIcon`-Label.
- `WhisperM8/Services/WindowRequestCenter.swift:12`: `.outputDashboard` mappt auf `"settings"`, waehrend `SettingsView` mit `.api` startet. Der Menuepunkt `Output & Templates...` fuehrt vermutlich nicht direkt zum erwarteten Bereich.
- `WhisperM8/Views/SettingsView.swift:107` und `177`: Settings-Zeile `Agent Chats` oeffnet direkt Agent Chats und zeigt zusaetzlich einen Open-Button.
- `WhisperM8/Views/MenuBarView.swift:87`: `Open WhisperM8...` oeffnet Settings; daneben gibt es `Agent Chats...`. Benennung sollte eindeutiger werden.
- `WhisperM8/Views/RecordingOverlayView.swift:194` und `234`: Overlay-Menues sind funktional, aber isoliert; keine parallele Command-/Settings-Route fuer dieselben Aktionen.
- Window/Settings/Onboarding-Routing ist ueber MenuBar, AgentChats-Footer, Settings-Sidebar, AppDelegate und Onboarding verteilt.

## No-Breaking Refactors

- `AppRoute`/`AppCommand` zentralisieren.
- `.commands` fuer Settings, Agent Chats, New Chat, Scan, Sidebar/Inspector und ggf. Rename einführen.
- Session-/Projekt-Menues als gemeinsame ViewBuilder oder Action-Modelle konsolidieren.
- `WindowRequest.outputDashboard` explizit mit Settings-Selection oder eigenem Window verbinden.
