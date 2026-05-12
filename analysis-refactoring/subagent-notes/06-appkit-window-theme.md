# Subagent 06 - AppKit-Interop, Window und Theming

## Kurzbefund

AppKit-Interop ist funktional, aber ueber mehrere Views und Services verteilt. Theming hat zwei Autoritaeten: globales `NSApp.appearance` und SwiftUI `.preferredColorScheme`. Farbwerte fuer Window, Terminal und Agent-Theme sind teilweise dupliziert.

## Befunde

- `WhisperM8/Support/ThemeManager.swift:20`: `resolvedColorScheme` startet hart auf `.dark`; bei fruehem `NSApp == nil` kann Light-System falsch initialisiert werden.
- `WhisperM8/Support/ThemeManager.swift:42`: KVO wird nur gesetzt, wenn `NSApp` im Init existiert; kein spaeterer Retry.
- `WhisperM8/Support/ThemeManager.swift:63` und `WhisperM8/WhisperM8App.swift:32`: globale AppKit-Appearance plus Scene-Override koennen spaeter driften.
- `WhisperM8/Views/AgentTerminalView.swift:224`: Terminal-Theming laeuft per String-Notification statt typisiertem Kanal.
- `WhisperM8/Views/AgentTerminalView.swift:30`: `AgentTerminalRegistry` entfernt Controller nur bei explizitem `terminate`, nicht bei natuerlichem Prozessende.
- `WhisperM8/Views/AgentTerminalView.swift:151`: jeder Controller besitzt einen lokalen Key-Monitor; bei vielen alten Controllern steigt Event-Overhead.
- `WhisperM8/Windows/RecordingPanel.swift:124`: nicht-aktivierendes Panel ist passend, aber Keyboard-/Textfeld-Erweiterungen waeren riskant.
- `WhisperM8/Windows/RecordingPanel.swift:132`: Panel-Hintergrund verlaesst sich auf globales `NSApp.appearance`.
- `WhisperM8/Views/AgentChatsView.swift:2381`: `AgentChatsWindowAccessor` mutiert `NSWindow` aus einer Background-View heraus und laeuft bei Updates erneut.
- `WhisperM8/Views/AgentChatsView.swift:2406`: Window-Background dupliziert Farbwerte aus `AgentTheme.background`.
- `WhisperM8/Views/AgentTerminalPalette.swift:63`: Light-Terminal nutzt `NSColor.white` statt explizitem sRGB.
- `WhisperM8/Views/AgentChatsView.swift:3184`: `Color.dynamic` wandelt `Color` zu `NSColor` im dynamicProvider; robustere Tokens waeren direkt sRGB/NSColor.
- `WhisperM8/Views/AgentChatsView.swift:2300`: `NSColor(Color(hex:))` fuer Swatches kann anders konvertieren als erwartetes sRGB.
- `WhisperM8/WhisperM8App.swift:36`: `.hiddenTitleBar` plus `AgentChatsWindowAccessor`-Mutation verteilt Window-Chrome-Verantwortung.
