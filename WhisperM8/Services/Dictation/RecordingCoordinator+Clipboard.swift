import Foundation
import AppKit

/// Visuelle Kontext-Erfassung des RecordingCoordinator: Screen-Clip-Aufnahme
/// und die Clipboard-Screenshot-/Text-Uebernahme waehrend der Aufnahme
/// (Pasteboard-Polling, Import, Quota). Aus RecordingCoordinator.swift
/// ausgelagert (Phase-2-Split).
extension RecordingCoordinator {
    func startScreenClip() async {
        guard let appState else { return }

        do {
            try await visualContextCaptureService.startScreenClip(sourceApp: contextSourceApp)
            appState.isScreenClipRecording = true
            overlayController.update(appState: appState)
            scheduleScreenClipLimit()
        } catch {
            appState.lastError = error.localizedDescription
            Logger.permission.warning("Screen clip context failed: \(error.localizedDescription, privacy: .public)")
            if error as? VisualContextCaptureError == .missingPermission {
                _ = PermissionService.requestScreenRecordingPermission()
            }
            overlayController.update(appState: appState)
        }
    }

    func stopScreenClipAndAttach() async {
        guard let appState else { return }

        screenClipLimitTask?.cancel()
        screenClipLimitTask = nil

        do {
            let result = try await visualContextCaptureService.stopScreenClip()
            appState.contextBundle.screenClips.append(result.clip)
            appState.contextBundle.visualFrames.append(contentsOf: result.visualFrames)
            appState.lastContextBundle = appState.contextBundle
        } catch {
            appState.lastError = error.localizedDescription
            Logger.permission.warning("Screen clip stop failed: \(error.localizedDescription, privacy: .public)")
        }

        appState.isScreenClipRecording = false
        overlayController.update(appState: appState)
    }

    func scheduleScreenClipLimit() {
        screenClipLimitTask?.cancel()
        let maxDuration = AppPreferences.shared.maxScreenRecordingDuration
        screenClipLimitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(maxDuration))
            guard !Task.isCancelled, appState?.isRecording == true, appState?.isScreenClipRecording == true else { return }
            await stopScreenClipAndAttach()
        }
    }

    func startClipboardScreenshotMonitor() {
        stopClipboardScreenshotMonitor()
        observedPasteboardChangeCount = NSPasteboard.general.changeCount

        clipboardScreenshotTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.observeClipboardChange()
            }
        }
    }

    /// Reagiert auf Pasteboard-Aenderungen waehrend des Recordings. Versucht
    /// erst, einen Screenshot zu greifen (Bilddaten); wenn nichts dabei ist,
    /// faengt sie kopierten Text ein und haengt ihn an `selectedText` an.
    /// So landet alles, was der User waehrend des Sprechens kopiert,
    /// automatisch im Kontext — egal ob Markup oder Text.
    func observeClipboardChange() {
        guard let appState, appState.isRecording, !appState.isTranscribing, !appState.isPostProcessing else { return }

        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != observedPasteboardChangeCount else { return }
        let oldChangeCount = observedPasteboardChangeCount
        observedPasteboardChangeCount = changeCount

        let pasteboardHasImage = pasteboardContainsImage(pasteboard)
        let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ",")
        Logger.transcription.info(
            "clipboard_change_detected oldCount=\(oldChangeCount, privacy: .public) newCount=\(changeCount, privacy: .public) hasImage=\(pasteboardHasImage, privacy: .public) types=\(types, privacy: .public)"
        )

        if pasteboardHasImage, AppPreferences.shared.isVisualContextCaptureEnabled {
            if importClipboardScreenshot(from: pasteboard, changeCount: changeCount) {
                return
            }
        }

        let textAdded = importClipboardText(from: pasteboard)
        if !textAdded {
            Logger.transcription.info(
                "clipboard_text_skipped settingEnabled=\(AppPreferences.shared.isSelectedContextCaptureEnabled, privacy: .public) hasString=\(pasteboard.string(forType: .string) != nil, privacy: .public)"
            )
        }
    }

    /// Prueft, ob die Zwischenablage einen echten Bildtyp enthaelt. `NSImage(pasteboard:)`
    /// allein ist zu permissiv — bei reinen Text-Inhalten liefert es manchmal trotzdem
    /// ein Bild (z. B. wenn Apps RTF mit Style-Info hinterlegen). Wir verlassen uns
    /// daher auf die deklarierten Pasteboard-Typen.
    func pasteboardContainsImage(_ pasteboard: NSPasteboard) -> Bool {
        let imageTypes: Set<String> = [
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
            "public.png",
            "public.tiff",
            "public.jpeg",
            "public.heic",
            "public.image",
            "com.adobe.pdf"
        ]
        let types = pasteboard.types?.map(\.rawValue) ?? []
        return types.contains(where: { imageTypes.contains($0) })
    }

    @discardableResult
    /// Gemeinsamer Rumpf von `importClipboardScreenshot` und
    /// `importClipboardScreenshotIfNeeded`: Quota-Pruefung, Capture und Append
    /// in das Context-Bundle. Die unterschiedlichen Vorbedingungen
    /// (Guards/Polling) liegen bewusst in den Aufrufern.
    func appendClipboardScreenshot(from pasteboard: NSPasteboard, changeCount: Int) -> Bool {
        guard let appState else { return false }
        guard appState.contextBundle.screenshots.count < AppPreferences.shared.maxScreenshotsPerRecording else {
            appState.lastError = "Maximum screenshots for this recording reached."
            overlayController.update(appState: appState)
            return false
        }

        do {
            guard let screenshot = try visualContextCaptureService.captureClipboardScreenshot(
                from: pasteboard,
                changeCount: changeCount,
                sourceApp: contextSourceApp
            ) else {
                return false
            }

            appState.contextBundle.screenshots.append(screenshot)
            appState.lastContextBundle = appState.contextBundle
            appState.lastError = nil
            overlayController.update(appState: appState)
            return true
        } catch {
            appState.lastError = error.localizedDescription
            Logger.permission.warning("Clipboard screenshot context failed: \(error.localizedDescription, privacy: .public)")
            overlayController.update(appState: appState)
            return false
        }
    }

    func importClipboardScreenshot(from pasteboard: NSPasteboard, changeCount: Int) -> Bool {
        appendClipboardScreenshot(from: pasteboard, changeCount: changeCount)
    }

    @discardableResult
    func importClipboardText(from pasteboard: NSPasteboard) -> Bool {
        guard let appState else { return false }
        guard AppPreferences.shared.isSelectedContextCaptureEnabled else { return false }

        guard let rawText = pasteboard.string(forType: .string),
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let normalized = TextNormalizer.normalizeTranscriptionText(rawText)
        guard !normalized.isEmpty else { return false }

        let frontApp = NSWorkspace.shared.frontmostApplication
        var bundle = appState.contextBundle

        if bundle.selectedText.isEmpty {
            bundle.selectedText = SelectedContext(
                text: normalized,
                sourceAppName: frontApp?.localizedName ?? contextSourceApp?.localizedName,
                sourceBundleIdentifier: frontApp?.bundleIdentifier ?? contextSourceApp?.bundleIdentifier
            )
        } else {
            if bundle.selectedText.text.contains(normalized) {
                return false
            }
            bundle.selectedText.text += "\n\n" + normalized
        }

        appState.contextBundle = bundle
        appState.selectedContext = bundle.selectedText
        appState.lastContextBundle = bundle
        appState.lastSelectedContext = bundle.selectedText
        appState.lastError = nil
        overlayController.update(appState: appState)

        Logger.transcription.info(
            "clipboard_text_added_to_context chars=\(normalized.count, privacy: .public) app=\(frontApp?.bundleIdentifier ?? "unknown", privacy: .public)"
        )
        return true
    }

    func stopClipboardScreenshotMonitor() {
        clipboardScreenshotTask?.cancel()
        clipboardScreenshotTask = nil
    }

    @discardableResult
    func importClipboardScreenshotIfNeeded(force: Bool = false) -> Bool {
        guard let appState, appState.isRecording, !appState.isTranscribing, !appState.isPostProcessing else { return false }
        guard AppPreferences.shared.isVisualContextCaptureEnabled else { return false }

        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard force || changeCount != observedPasteboardChangeCount else { return false }
        observedPasteboardChangeCount = changeCount

        return appendClipboardScreenshot(from: pasteboard, changeCount: changeCount)
    }
}
