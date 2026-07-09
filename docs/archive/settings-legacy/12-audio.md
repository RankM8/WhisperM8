---
description: Settings-Seite „Audio" — Referenz des Mikrofon-Pickers und der verwandten Audio-Optionen
description_long: |
  Vollständige Referenz der Settings-Seite „Audio": aktueller UI-Aufbau,
  der einzelne persistierte Eingabegeräte-Picker, Laufzeitwirkung im Recorder,
  Querverweise zu Audio-Ducking auf „Behavior" sowie UX-Beobachtungen als
  Grundlage für das Settings-Redesign.
updated: 2026-07-06 14:05
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, 0 Mängel)
---

> ⚠️ HISTORISCH (Stand vor Refactor 2026-07-06) — Inhalte beschreiben die alte Seite; neue Seite: `RecordingSettingsPage.swift` + Doku-Verweis [ARCHITEKTUR: Pages](../../features/settings/ARCHITECTURE.md#pages).

# Settings: Audio

> **Sidebar-Gruppe:** App · **View:** `WhisperM8/Views/Settings/AudioSettingsView.swift` · **Enum-Case:** `ControlCenterSection.audio` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `AudioSettingsView.swift`, `Services/Dictation/AudioRecorder*`

## 1. Zweck & Überblick

Die Settings-Seite „Audio" ist in der Sidebar-Gruppe „App" registriert und wird über `ControlCenterSection.audio` mit dem Titel „Audio" gerendert. (`WhisperM8/Views/SettingsView.swift:15`, `WhisperM8/Views/SettingsView.swift:104`, `WhisperM8/Views/SettingsView.swift:235`, `WhisperM8/Views/SettingsView.swift:237`)

Ihr aktueller Zweck ist eng gefasst: User wählen hier das Mikrofon für kommende Diktataufnahmen oder lassen WhisperM8 beim macOS-Systemstandard. (`WhisperM8/Views/Settings/AudioSettingsView.swift:10`, `WhisperM8/Views/Settings/AudioSettingsView.swift:11`, `WhisperM8/Views/Settings/AudioSettingsView.swift:20`)

Die Seite enthält keine Ducking-, Pegel-, Format- oder Transkriptionsoptionen; Audio-Ducking liegt auf „Behavior" in einer eigenen Section, und der Recorder setzt Format, Pegelmessung und Datei-Encoding intern. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:98`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:103`, `WhisperM8/Services/Dictation/AudioRecorder.swift:20`, `WhisperM8/Services/Dictation/AudioRecorder.swift:121`, `WhisperM8/Services/Dictation/AudioRecorder.swift:135`, `WhisperM8/Services/Dictation/AudioRecorder.swift:362`)

## 2. UI-Aufbau

Die View ist eine gruppierte SwiftUI-`Form` mit genau einer unbenannten `Section`. (`WhisperM8/Views/Settings/AudioSettingsView.swift:7`, `WhisperM8/Views/Settings/AudioSettingsView.swift:8`, `WhisperM8/Views/Settings/AudioSettingsView.swift:9`, `WhisperM8/Views/Settings/AudioSettingsView.swift:25`)

Oben steht ein `Picker` mit Label „Input Device"; die erste Auswahl ist „System Default" mit leerem Tag, danach folgt je ein Eintrag für jedes aktuell bekannte Input-Device aus `deviceManager.availableDevices`. (`WhisperM8/Views/Settings/AudioSettingsView.swift:10`, `WhisperM8/Views/Settings/AudioSettingsView.swift:11`, `WhisperM8/Views/Settings/AudioSettingsView.swift:12`, `WhisperM8/Views/Settings/AudioSettingsView.swift:13`)

Unter dem Picker steht ein statischer Caption-Hinweis: „Select which microphone to use. Changes apply to the next recording." (`WhisperM8/Views/Settings/AudioSettingsView.swift:20`, `WhisperM8/Views/Settings/AudioSettingsView.swift:21`, `WhisperM8/Views/Settings/AudioSettingsView.swift:22`)

Es gibt keine bedingten UI-Zustände innerhalb der Audio-Seite; die Device-Liste wird beim Anzeigen aktualisiert, und die lokale Picker-Auswahl wird aus `deviceManager.selectedDeviceUID` übernommen. (`WhisperM8/Views/Settings/AudioSettingsView.swift:26`, `WhisperM8/Views/Settings/AudioSettingsView.swift:27`, `WhisperM8/Views/Settings/AudioSettingsView.swift:28`)

## 3. Optionen im Detail

### Input Device

| Aspekt | Wert |
|---|---|
| Control | `Picker("Input Device", selection: $selectedDeviceUID)` mit „System Default" plus dynamischen Einträgen aus `AudioDeviceManager.availableDevices`. (`WhisperM8/Views/Settings/AudioSettingsView.swift:10`, `WhisperM8/Views/Settings/AudioSettingsView.swift:11`, `WhisperM8/Views/Settings/AudioSettingsView.swift:12`, `WhisperM8/Views/Settings/AudioSettingsView.swift:13`) |
| Default | Systemstandard: Beim Öffnen wird ein fehlender gespeicherter Wert auf `""` gemappt, und die „System Default"-Option nutzt ebenfalls `""` als Tag. (`WhisperM8/Views/Settings/AudioSettingsView.swift:11`, `WhisperM8/Views/Settings/AudioSettingsView.swift:26`, `WhisperM8/Views/Settings/AudioSettingsView.swift:28`, `WhisperM8/Support/AppPreferences.swift:64`, `WhisperM8/Support/AppPreferences.swift:65`) |
| Persistenz | UserDefaults-Key `selectedAudioDeviceUID`; die View schreibt über `AudioDeviceManager.selectedDeviceUID`, der an `AppPreferences.shared.selectedAudioDeviceUID` delegiert, und der exakte Key ist `PreferenceKeys.selectedAudioDeviceUID`. (`WhisperM8/Views/Settings/AudioSettingsView.swift:16`, `WhisperM8/Views/Settings/AudioSettingsView.swift:17`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:55`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:60`, `WhisperM8/Support/AppPreferences.swift:64`, `WhisperM8/Support/AppPreferences.swift:66`, `WhisperM8/Support/AppPreferences.swift:366`) |
| Gelesen von | `AudioDeviceManager.selectedDeviceUID` liest `AppPreferences.shared.selectedAudioDeviceUID`; `AudioRecorder.startRecording()` liest zu Beginn `AudioDeviceManager.shared.selectedDeviceID`. (`WhisperM8/Services/Dictation/AudioDeviceManager.swift:55`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:56`, `WhisperM8/Services/Dictation/AudioRecorder.swift:66`, `WhisperM8/Services/Dictation/AudioRecorder.swift:67`, `WhisperM8/Services/Dictation/AudioRecorder.swift:68`) |
| Wirkung | Bei einem konkreten, unterstützten Gerät setzt der Recorder das CoreAudio-Input-Device auf der `AVAudioEngine`; bei System Default oder nicht auflösbarem Gerät setzt er kein spezifisches Device und verwendet den aktuellen macOS-Standard. (`WhisperM8/Services/Dictation/AudioRecorder.swift:74`, `WhisperM8/Services/Dictation/AudioRecorder.swift:75`, `WhisperM8/Services/Dictation/AudioRecorder.swift:77`, `WhisperM8/Services/Dictation/AudioRecorder.swift:79`, `WhisperM8/Services/Dictation/AudioRecorder.swift:80`, `WhisperM8/Services/Dictation/AudioRecorder.swift:81`, `WhisperM8/Services/Dictation/AudioRecorder.swift:463`, `WhisperM8/Services/Dictation/AudioRecorder.swift:471`) |
| Abhängigkeiten | Die verfügbaren Werte kommen aus CoreAudio-Geräten mit Input-Kanälen; Hotplug und Änderungen des System-Default-Input lösen Refreshes aus. Bluetooth-Geräte werden im `selectedDeviceID`-Pfad bewusst auf System Default zurückgeführt, weil sie laut Code macOS Aggregate Device/HFP-Verhalten benötigen. (`WhisperM8/Services/Dictation/AudioDeviceManager.swift:113`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:156`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:157`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:173`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:178`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:187`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:30`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:31`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:34`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:84`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:85`) |

## 4. Datenfluss & Persistenz

Beim Anzeigen der Seite ruft `onAppear` zuerst `refreshDevices()` auf und übernimmt danach den gespeicherten UID-Wert in den lokalen `@State selectedDeviceUID`. (`WhisperM8/Views/Settings/AudioSettingsView.swift:4`, `WhisperM8/Views/Settings/AudioSettingsView.swift:5`, `WhisperM8/Views/Settings/AudioSettingsView.swift:26`, `WhisperM8/Views/Settings/AudioSettingsView.swift:27`, `WhisperM8/Views/Settings/AudioSettingsView.swift:28`)

Jede Picker-Änderung wird sofort persistiert: ein leerer Wert wird zu `nil`, ein Geräte-UID-String wird gespeichert. (`WhisperM8/Views/Settings/AudioSettingsView.swift:16`, `WhisperM8/Views/Settings/AudioSettingsView.swift:17`, `WhisperM8/Support/AppPreferences.swift:332`, `WhisperM8/Support/AppPreferences.swift:334`, `WhisperM8/Support/AppPreferences.swift:336`)

Die Device-Liste selbst ist nicht persistiert; `AudioDeviceManager.refreshDevices()` liest die aktuellen CoreAudio-Geräte, filtert auf Input-Kanäle und setzt `availableDevices` auf dem MainActor. (`WhisperM8/Services/Dictation/AudioDeviceManager.swift:113`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:116`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:156`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:157`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:173`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:174`)

Die Laufzeitwirkung tritt bei der nächsten Aufnahme ein, nicht mitten in einer laufenden Aufnahme: `AudioRecorder.startRecording()` liest `selectedDeviceID` beim Start, bindet danach den `inputNode` und installiert den Recording-Tap. (`WhisperM8/Views/Settings/AudioSettingsView.swift:20`, `WhisperM8/Services/Dictation/AudioRecorder.swift:33`, `WhisperM8/Services/Dictation/AudioRecorder.swift:66`, `WhisperM8/Services/Dictation/AudioRecorder.swift:68`, `WhisperM8/Services/Dictation/AudioRecorder.swift:86`, `WhisperM8/Services/Dictation/AudioRecorder.swift:88`, `WhisperM8/Services/Dictation/AudioRecorder.swift:135`, `WhisperM8/Services/Dictation/AudioRecorder.swift:138`)

Ein Neustart der App ist für die Auswahl nicht nötig; der Manager startet beim Initialisieren Geräte- und Default-Input-Listener und aktualisiert die Liste bei Hotplug beziehungsweise Default-Input-Änderungen. (`WhisperM8/Services/Dictation/AudioDeviceManager.swift:98`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:102`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:103`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:104`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:178`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:187`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:218`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:225`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:30`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:31`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:34`)

## 5. Querverweise

„Behavior" enthält die Audio-Ducking-Optionen, obwohl sie fachlich ebenfalls Audio betreffen: `audioDuckingEnabled` wird als Toggle „Reduce system volume while recording" angezeigt, und `audioDuckingFactor` wird als „Target volume"-Slider nur bei aktivem Ducking eingeblendet. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:6`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:7`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:98`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:100`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:103`)

`AudioDuckingManager` liest die Ducking-Preferences aus `AppPreferences`, senkt die Systemlautstärke in `beginCapture()` nur bei aktivem Feature und nutzt den gespeicherten Faktor als Zielvolumen. (`WhisperM8/Services/Dictation/AudioDuckingManager.swift:78`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:80`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:83`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:85`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:95`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:97`)

`RecordingCoordinator` ruft Ducking vor dem Recorder-Start auf und beendet beziehungsweise restauriert es beim Stop oder Fehlerpfad; diese Audio-Funktion hängt daher am Aufnahme-Lifecycle, aber nicht an der Audio-Settings-Seite. (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:140`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:145`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:146`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:147`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:151`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:307`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:308`)

Die separate Datei `docs/AUDIO_DUCKING.md` beschreibt Ducking als Settings unter „Settings → Behavior → Audio Ducking" und nennt die Keys `audioDuckingEnabled` und `audioDuckingFactor`. (`docs/AUDIO_DUCKING.md:48`, `docs/AUDIO_DUCKING.md:52`, `docs/AUDIO_DUCKING.md:53`, `docs/AUDIO_DUCKING.md:55`)

Die Settings-Seite „Behavior" dokumentiert dieselbe Platzierung bereits als UX-Spannung: Audio-Ducking und Target Volume liegen dort, obwohl „Audio" eine eigene Sidebar-Sektion ist. (`docs/features/settings/13-behavior.md:236`, `docs/features/settings/13-behavior.md:246`)

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

Die Seite wirkt leer, weil ihre Implementierung nur eine einzige Section mit einem Picker und einem Caption-Text enthält. (`WhisperM8/Views/Settings/AudioSettingsView.swift:8`, `WhisperM8/Views/Settings/AudioSettingsView.swift:9`, `WhisperM8/Views/Settings/AudioSettingsView.swift:10`, `WhisperM8/Views/Settings/AudioSettingsView.swift:20`)

Die inhaltlich naheliegenden Audio-Ducking-Regler liegen nicht hier, sondern unter „Behavior"; dort steuern sie Systemlautstärke und Zielvolumen während der Aufnahme, während „Audio" nur das Eingabegerät steuert. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:98`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:103`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:80`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:85`, `WhisperM8/Views/Settings/AudioSettingsView.swift:10`)

Die Platzierung trennt Input-Audio und Output-Audio semantisch: Mikrofon-Auswahl ist auf „Audio", Systemlautstärke-Ducking ist auf „Behavior". (`WhisperM8/Views/SettingsView.swift:15`, `WhisperM8/Views/SettingsView.swift:16`, `WhisperM8/Views/SettingsView.swift:235`, `WhisperM8/Views/SettingsView.swift:239`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`)

Die UI-Sprache ist gemischt: Die Audio-Seite verwendet englische Labels und Hilfetexte („Input Device", „System Default", „Select which microphone to use..."), während andere App-Settings wie „Erscheinungsbild", „Hell" und „Dunkel" deutsch sind. (`WhisperM8/Views/Settings/AudioSettingsView.swift:10`, `WhisperM8/Views/Settings/AudioSettingsView.swift:11`, `WhisperM8/Views/Settings/AudioSettingsView.swift:20`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:37`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:50`)

Der Hinweis „Changes apply to the next recording" ist fachlich korrekt, aber minimal; er erklärt nicht, dass Bluetooth-Geräte intern auf System Default zurückfallen können. (`WhisperM8/Views/Settings/AudioSettingsView.swift:20`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:79`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:84`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:85`)

Es gibt keinen sichtbaren Status für „gespeichertes Gerät nicht mehr vorhanden"; der Code fällt in diesem Fall beim Auflösen von `selectedDeviceID` auf System Default zurück. (`WhisperM8/Services/Dictation/AudioDeviceManager.swift:71`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:74`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:75`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:76`)

## 7. Offene Fragen

Soll Audio-Ducking im Redesign auf die Audio-Seite umziehen oder bleibt „Behavior" die bewusst gemischte Sammelseite für laufzeitnahes Aufnahmeverhalten? (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`, `WhisperM8/Views/SettingsView.swift:15`, `WhisperM8/Views/SettingsView.swift:16`)

Soll die Audio-Seite Bluetooth-Fallbacks und verschwundene gespeicherte Geräte sichtbar erklären, statt nur beim Recording still auf System Default zurückzufallen? (`WhisperM8/Services/Dictation/AudioDeviceManager.swift:74`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:75`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:84`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:85`)

Soll die Settings-Sprache vereinheitlicht werden, insbesondere für „Input Device", „System Default" und den englischen Audio-Hilfetext? (`WhisperM8/Views/Settings/AudioSettingsView.swift:10`, `WhisperM8/Views/Settings/AudioSettingsView.swift:11`, `WhisperM8/Views/Settings/AudioSettingsView.swift:20`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:37`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:50`)
