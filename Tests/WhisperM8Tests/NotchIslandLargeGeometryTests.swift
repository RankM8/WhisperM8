import SwiftUI
import XCTest
@testable import WhisperM8

/// Die aufgeklappte Anzeige an der Kamera-Insel als EINE Form: Maße, Lage,
/// Kopfzeile um Apples Insel, Umrisse für die Bewegung, Fenster und
/// Klickflächen. Maße des Bildschirms wie in `NotchIslandGeometryTests`
/// (MacBook Pro mit Insel, 18.11.2026); Apples aufgeklappte Insel gemessen
/// am 19.11.2026 (6 pt unter der Kante, Ecken rund 36 pt).
final class NotchIslandLargeGeometryTests: XCTestCase {
    private func islandScreen(scale: CGFloat = 1, height: CGFloat = 1133, width: CGFloat = 1736) -> NotchScreenInfo {
        let side = (width - 59) / 2
        return NotchScreenInfo(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: width * scale, height: height * scale),
            visibleFrame: CGRect(x: 0, y: 0, width: width * scale, height: (height - 45) * scale),
            safeAreaTop: 40 * scale, auxiliaryLeftWidth: side * scale, auxiliaryRightWidth: side * scale,
            isBuiltIn: true)
    }

    private var notchScreen: NotchScreenInfo {
        NotchScreenInfo(
            displayID: 2, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaTop: 38, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, isBuiltIn: true)
    }

    private var plainScreen: NotchScreenInfo {
        NotchScreenInfo(
            displayID: 3, frame: CGRect(x: 1736, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1736, y: 0, width: 2560, height: 1415),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false)
    }

    // MARK: Form

    /// Auf die Kamera zentriert, Oberkante dort, wo Apples Insel mit Inhalt
    /// beginnt (6 pt), sehr runde Ecken. Abgenommene Maße: Hinweis
    /// 380 × 108, Liste 420 breit, Diktat 420 × 178.
    func testFormsAreCenteredOnTheCameraAtApplesTop() {
        let screen = islandScreen()
        XCTAssertEqual(NotchIslandLargeGeometry.topInset(screen), 6, accuracy: 0.001)
        XCTAssertEqual(NotchIslandLargeGeometry.topGap(screen), 2, accuracy: 0.001)
        XCTAssertEqual(NotchIslandLargeGeometry.headerHeight(screen), 42, accuracy: 0.001)

        let alert = NotchIslandLargeGeometry.form(screen: screen, kind: .alert)
        XCTAssertEqual(alert.frame, CGRect(x: 868 - 190, y: 1133 - 6 - 108, width: 380, height: 108))
        XCTAssertEqual(alert.cornerRadius, 36)
        XCTAssertEqual(alert.headerHeight, 42, accuracy: 0.001)

        let dictation = NotchIslandLargeGeometry.form(screen: screen, kind: .dictation)
        XCTAssertEqual(dictation.frame, CGRect(x: 868 - 210, y: 1133 - 6 - 178, width: 420, height: 178))

        let list = NotchIslandLargeGeometry.form(screen: screen, kind: .list(rowCount: 4, sectionCount: 3))
        XCTAssertEqual(list.frame.width, 420)
        XCTAssertEqual(list.frame.midX, 868, accuracy: 0.001)
        XCTAssertEqual(list.frame.maxY, 1133 - 6)
        XCTAssertEqual(list.listHeight, 4 * 56 + 3 * 28)
        XCTAssertEqual(list.frame.height, 42 + list.listHeight + 30 + 16)
        for form in [alert, dictation, list] {
            XCTAssertTrue(screen.frame.contains(form.frame))
            XCTAssertLessThanOrEqual(form.cornerRadius, form.frame.height / 2)
        }
    }

    /// Lange Listen scrollen: höchstens 420 pt, und nie unten aus dem
    /// Bildschirm. Eine leere Liste hat Platz für „Keine aktiven Chats“.
    func testListHeightIsBounded() {
        let screen = islandScreen()
        let long = NotchIslandLargeGeometry.form(screen: screen, kind: .list(rowCount: 40, sectionCount: 4))
        XCTAssertEqual(long.listHeight, NotchIslandLargeGeometry.maxListHeight)
        XCTAssertTrue(screen.visibleFrame.union(long.frame).height <= screen.frame.height)

        let low = islandScreen(height: 420)
        let squeezed = NotchIslandLargeGeometry.form(screen: low, kind: .list(rowCount: 40, sectionCount: 4))
        XCTAssertLessThan(squeezed.listHeight, NotchIslandLargeGeometry.maxListHeight)
        XCTAssertGreaterThanOrEqual(squeezed.frame.minY, low.visibleFrame.minY + NotchIslandLargeGeometry.screenMargin - 0.001)
        XCTAssertGreaterThanOrEqual(squeezed.listHeight, NotchIslandLargeGeometry.rowHeight)

        let empty = NotchIslandLargeGeometry.form(screen: screen, kind: .list(rowCount: 0, sectionCount: 0))
        XCTAssertEqual(empty.listHeight, NotchIslandLargeGeometry.emptyListHeight)
    }

    /// Schmaler Bildschirm: Die Form bleibt auf die Kamera zentriert und
    /// ganz im Bild, statt über den Rand zu ragen.
    func testFormStaysOnANarrowScreen() {
        let narrow = islandScreen(width: 400)
        let form = NotchIslandLargeGeometry.form(screen: narrow, kind: .list(rowCount: 2, sectionCount: 1))
        XCTAssertEqual(form.frame.midX, narrow.notchCenterX, accuracy: 0.001)
        XCTAssertEqual(form.frame.width, 400 - 2 * NotchIslandLargeGeometry.screenMargin, accuracy: 0.001)
        XCTAssertTrue(narrow.frame.contains(form.frame))
    }

    /// Andere Auflösung: Oberkante und Kopfzeile folgen dem Sicherheitsrand.
    func testFormFollowsTheResolution() {
        let screen = islandScreen(scale: 1.18)
        let form = NotchIslandLargeGeometry.form(screen: screen, kind: .alert)
        XCTAssertEqual(form.frame.maxY, screen.frame.maxY - 6 * 1.18, accuracy: 0.01)
        XCTAssertEqual(form.headerHeight, 34 * 1.18 + 8, accuracy: 0.01)
        XCTAssertEqual(form.frame.midX, screen.notchCenterX, accuracy: 0.001)
    }

    // MARK: Kopfzeile um Apples Insel

    /// Apples Insel liegt über unserem Fenster: Die Kopfzeile lässt ihr
    /// Platz. In Ruhe ihre Kapsel (65 pt), mit Inhalt so weit, wie die
    /// Messung sie zeigt (mit Musik 802 bis 945 pt, nicht symmetrisch), beim
    /// Diktat der Mikrofon-Hinweis schon vor der Messung.
    func testHeaderLeavesRoomForApplesIsland() {
        let screen = islandScreen()
        let rest = NotchIslandLargeGeometry.slot(screen: screen, occupancy: NotchMenuBarOccupancy(frames: []))
        XCTAssertEqual(rest.leading, 29.5 + 3 + 8, accuracy: 0.001)
        XCTAssertEqual(rest.trailing, rest.leading, accuracy: 0.001)
        XCTAssertEqual(NotchIslandLargeGeometry.slot(screen: screen, occupancy: nil).leading, rest.leading)

        var music = NotchMenuBarOccupancy(frames: [])
        music.systemIsland = 802...945
        let active = NotchIslandLargeGeometry.slot(screen: screen, occupancy: music)
        XCTAssertEqual(active.leading, 868 - 802 + 8, accuracy: 0.001)
        XCTAssertEqual(active.trailing, 945 - 868 + 8, accuracy: 0.001)

        let reserve = NotchIslandGeometry.dictationReserve(screen: screen, occupancy: nil)
        let dictation = NotchIslandLargeGeometry.form(screen: screen, kind: .dictation, occupancy: nil, reserve: reserve)
        XCTAssertEqual(dictation.slotLeading, 29.5 + 36.5 + 8, accuracy: 0.001)
        XCTAssertEqual(dictation.slotTrailing, 29.5 + 47.5 + 8, accuracy: 0.001)
        // Links und rechts davon bleibt Platz für eigene Zähler.
        for form in [dictation, NotchIslandLargeGeometry.form(screen: screen, kind: .alert, occupancy: music)] {
            let padding = NotchIslandLargeGeometry.headerInset
            XCTAssertGreaterThan(form.frame.width / 2 - padding - form.slotLeading, 70)
            XCTAssertGreaterThan(form.frame.width / 2 - padding - form.slotTrailing, 70)
        }
    }

    // MARK: Umrisse der Bewegung

    /// Die Form wächst aus dem, was in Ruhe dasteht: der Kapsel mit Zeichen
    /// und Zahl, dem abgesetzten Kreis, oder Apples Insel selbst.
    func testFormGrowsFromWhatIsThere() {
        let screen = islandScreen()
        let free = NotchMenuBarOccupancy(frames: [])
        let compact = NotchIslandGeometry.band(screen: screen, occupancy: free, presentation: .compact(.leading))
        let capsule = NotchIslandLargeGeometry.seedFrame(
            screen: screen, band: compact, presentation: .compact(.leading), occupancy: free)
        XCTAssertEqual(capsule, NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 1), islandBand: compact).frame)
        let outline = NotchIslandLargeGeometry.outline(of: capsule, screen: screen)
        XCTAssertEqual(outline.top, 2, accuracy: 0.001, "die Kapsel beginnt 2 pt unter der Form")
        XCTAssertEqual(outline.height, 32)
        XCTAssertEqual(outline.radius, 16)
        XCTAssertEqual(outline.centerOffset, compact.centerOffset, accuracy: 0.001)
        XCTAssertEqual(outline.width, compact.width)

        // Nichts in der Menüleiste: aus Apples Insel in Ruhe.
        let rest = NotchIslandLargeGeometry.seedFrame(
            screen: screen, band: NotchIslandGeometry.band(screen: screen), presentation: .hidden, occupancy: free)
        XCTAssertEqual(rest, CGRect(x: 868 - 32.5, y: 1133 - 40, width: 65, height: 32))

        // Apples Insel zeigt selbst etwas: aus dem Kreis daneben bzw. aus ihr.
        var music = free
        music.systemIsland = 802...945
        music.systemIslandInsets = 6...40
        let detached = NotchIslandGeometry.band(screen: screen, occupancy: music, presentation: .minimal(.leading))
        let circle = NotchIslandLargeGeometry.seedFrame(
            screen: screen, band: detached, presentation: .minimal(.leading), occupancy: music)
        XCTAssertEqual(circle, detached.detachedFrame)
        let system = NotchIslandLargeGeometry.seedFrame(
            screen: screen, band: NotchIslandGeometry.band(screen: screen, occupancy: music), presentation: .hidden,
            occupancy: music)
        XCTAssertEqual(system, CGRect(x: 802, y: 1133 - 40, width: 143, height: 34))
        XCTAssertEqual(NotchIslandLargeGeometry.outline(of: system, screen: screen).top, 0, accuracy: 0.001)

        // Jede Ausgangsform liegt in der offenen Form: Das Fenster der Form reicht für die ganze Bewegung.
        for form in [NotchIslandLargeGeometry.form(screen: screen, kind: .alert, occupancy: music),
                     NotchIslandLargeGeometry.form(screen: screen, kind: .list(rowCount: 1, sectionCount: 1))] {
            for seed in [capsule, rest, circle, system] {
                XCTAssertTrue(form.frame.contains(seed), "\(seed) in \(form.frame)")
            }
        }
    }

    /// Offen ist der Umriss die ganze Form; dazwischen gleiten alle Werte.
    func testOutlineInterpolatesBetweenCapsuleAndForm() {
        let screen = islandScreen()
        let form = NotchIslandLargeGeometry.form(screen: screen, kind: .alert)
        let open = NotchIslandLargeGeometry.openOutline(form)
        XCTAssertEqual(open, NotchIslandLargeOutline(centerOffset: 0, top: 0, width: 380, height: 108, radius: 36))
        let closed = NotchIslandLargeOutline(centerOffset: -20, top: 2, width: 100, height: 32, radius: 16)
        XCTAssertEqual(closed.interpolated(to: open, progress: 0), closed)
        XCTAssertEqual(closed.interpolated(to: open, progress: 1), open)
        let half = closed.interpolated(to: open, progress: 0.5)
        XCTAssertEqual(half.width, 240)
        XCTAssertEqual(half.height, 70)
        XCTAssertEqual(half.centerOffset, -10)
        // Im Fenster der Form: obere Mitte ist die Kamera.
        let bounds = CGRect(x: 0, y: 0, width: 380, height: 108)
        XCTAssertEqual(open.rect(in: bounds), bounds)
        XCTAssertEqual(closed.rect(in: bounds), CGRect(x: 190 - 20 - 50, y: 2, width: 100, height: 32))
    }

    /// Die Form der Ansicht folgt dem Umriss: zu eine Kapsel an ihrer
    /// Stelle, offen die ganze Fläche mit runden Ecken (eine Fläche, kein
    /// Hals: oben so breit wie unten).
    func testShapeFollowsTheOutline() {
        let bounds = CGRect(x: 0, y: 0, width: 412, height: 124)
        let closed = NotchIslandLargeOutline(centerOffset: -30, top: 2, width: 100, height: 32, radius: 16)
        let capsule = NotchIslandLargeShape(outline: closed).path(in: bounds)
        XCTAssertEqual(capsule.boundingRect.minX, 206 - 30 - 50, accuracy: 0.01)
        XCTAssertEqual(capsule.boundingRect.height, 32, accuracy: 0.01)
        XCTAssertFalse(capsule.contains(CGPoint(x: 206 - 30 - 50 + 1, y: 3)), "runde Enden")

        let open = NotchIslandLargeShape(
            outline: NotchIslandLargeOutline(centerOffset: 0, top: 0, width: 380, height: 108, radius: 36)).path(in: bounds)
        XCTAssertEqual(open.boundingRect, CGRect(x: 16, y: 0, width: 380, height: 108))
        for y in [4.0, 20, 54, 90, 104] as [CGFloat] {
            XCTAssertTrue(open.contains(CGPoint(x: 206 - 140, y: y)), "y \(y)")
            XCTAssertTrue(open.contains(CGPoint(x: 206 + 140, y: y)), "y \(y)")
        }
        XCTAssertFalse(open.contains(CGPoint(x: 18, y: 2)), "runde Ecke oben links")
        XCTAssertFalse(open.contains(CGPoint(x: 394, y: 106)), "runde Ecke unten rechts")
    }

    // MARK: Fenster und Klickfläche

    /// Das Fenster fasst die Form samt Rand für das Überschwingen; beim
    /// Wechsel von Form zu Form beide. Obere Mitte bleibt die Kamera.
    func testCanvasHoldsTheFormAndKeepsTheCameraOnTop() {
        let screen = islandScreen()
        let alert = NotchIslandLargeGeometry.form(screen: screen, kind: .alert).frame
        let list = NotchIslandLargeGeometry.form(screen: screen, kind: .list(rowCount: 3, sectionCount: 2)).frame
        XCTAssertEqual(NotchIslandLargeGeometry.canvas(alert), alert)
        let margin = NotchIslandLargeGeometry.overshootMargin
        let single = NotchIslandLargeGeometry.canvas(alert, margin: margin)
        XCTAssertEqual(single, CGRect(x: alert.minX - 16, y: alert.minY - 16, width: 380 + 32, height: 108 + 16))
        for (first, second) in [(alert, list), (list, alert)] {
            let both = NotchIslandLargeGeometry.canvas(first, second, margin: margin)
            XCTAssertEqual(both.midX, screen.notchCenterX, accuracy: 0.001)
            XCTAssertEqual(both.maxY, alert.maxY, "die Oberkante steht")
            XCTAssertTrue(both.contains(alert) && both.contains(list))
        }
    }

    /// Klicks nimmt das Fenster nur auf der Form an: Der Rand daneben und
    /// darunter gehört nicht dazu. Beim Schließen gilt sofort nur noch die
    /// Kapsel, die Menüleiste neben ihr ist wieder frei.
    func testOnlyTheFormTakesClicks() {
        let screen = islandScreen()
        let form = NotchIslandLargeGeometry.form(screen: screen, kind: .alert)
        let canvas = NotchIslandLargeGeometry.canvas(form.frame, margin: NotchIslandLargeGeometry.overshootMargin)
        let open = NotchIslandLargeGeometry.hitFrame(
            of: NotchIslandLargeGeometry.openOutline(form), inCanvasOfSize: canvas.size)
        XCTAssertEqual(open, CGRect(x: 16, y: 0, width: 380, height: 108))
        XCTAssertFalse(open.contains(CGPoint(x: 8, y: 20)), "Rand links")
        XCTAssertFalse(open.contains(CGPoint(x: 206, y: 116)), "Rand unten")

        let band = NotchIslandGeometry.band(
            screen: screen, occupancy: NotchMenuBarOccupancy(frames: []), presentation: .compact(.leading))
        let capsule = NotchGeometry.layout(screen: screen, mode: .compact(chipCount: 1), islandBand: band).frame
        let closing = NotchIslandLargeGeometry.hitFrame(
            of: NotchIslandLargeGeometry.outline(of: capsule, screen: screen), inCanvasOfSize: canvas.size)
        XCTAssertEqual(closing.size, capsule.size)
        XCTAssertEqual(closing.minY, 2, accuracy: 0.001)
        // Menüs links und rechts der Kapsel und alles unter der Menüleiste: frei.
        XCTAssertFalse(closing.contains(CGPoint(x: 40, y: 18)))
        XCTAssertFalse(closing.contains(CGPoint(x: 380, y: 18)))
        XCTAssertFalse(closing.contains(CGPoint(x: 206, y: 60)))
    }

    /// Die Ansicht des Fensters selbst hält sich daran.
    @MainActor
    func testHostingViewPassesClicksBesideTheForm() {
        let host = NotchHostingView(rootView: Color.black)
        host.frame = CGRect(x: 0, y: 0, width: 412, height: 124)
        XCTAssertTrue(host.takesClick(at: CGPoint(x: 4, y: 4)), "in Ruhe ist das Fenster genau die Kapsel")
        host.islandHitFrame = CGRect(x: 16, y: 0, width: 380, height: 108)
        // Koordinaten der Ansicht; `y` zählt je nach Ansicht von oben oder unten.
        func point(_ x: CGFloat, fromTop y: CGFloat) -> CGPoint { CGPoint(x: x, y: host.isFlipped ? y : 124 - y) }
        XCTAssertTrue(host.takesClick(at: point(206, fromTop: 50)))
        XCTAssertFalse(host.takesClick(at: point(6, fromTop: 50)), "Rand links")
        XCTAssertFalse(host.takesClick(at: point(206, fromTop: 118)), "Rand unten")
        XCTAssertNil(host.hitTest(point(6, fromTop: 50)))
        // Schließt sich die Form, gilt nur noch die Kapsel.
        host.islandHitFrame = CGRect(x: 125, y: 2, width: 102, height: 32)
        XCTAssertFalse(host.takesClick(at: point(206, fromTop: 80)))
        XCTAssertFalse(host.takesClick(at: point(60, fromTop: 18)), "Menü links der Kapsel")
        XCTAssertTrue(host.takesClick(at: point(170, fromTop: 18)))
        host.islandHitFrame = nil
        XCTAssertTrue(host.takesClick(at: point(6, fromTop: 50)))
    }

    // MARK: Hinweis

    /// Zweite Zeile des Hinweises: nur die ART des Wartens (Freigabe mit
    /// Werkzeugname, Frage, Plan), sonst das Projekt. Der Hinweis geht von
    /// selbst auf, auch bei einer Bildschirmfreigabe: Befehl, Dateiname,
    /// Fragetext und Antworttext stehen nie darin, nur in der Liste.
    func testAlertDetailNamesTheKindNeverTheContent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func input(_ status: AgentSessionRuntimeStatus, _ activity: AgentSessionActivity?) -> NotchChatInput {
            NotchChatInput(
                id: UUID(), title: "Chat A", project: "Projekt A", status: status, statusSince: now,
                lastTurnAt: now, lastActivityAt: now, activity: activity)
        }
        func detail(_ kind: NotchAlertKind, _ input: NotchChatInput?) -> String? {
            NotchStatusController.alertDetail(kind: kind, input: input)
        }
        let approval = AgentSessionActivity(
            detail: .tool(name: "Bash", argument: "git push origin geheim"), awaitingKind: .permission, awaitingToolName: "Bash")
        XCTAssertEqual(detail(.awaitingInput, input(.awaitingInput, approval)), String(localized: "Approval: \("Bash")"))
        // Die Liste zeigt weiter die volle Zeile.
        XCTAssertTrue(approval.line(for: .awaitingInput)?.contains("git push") == true)
        XCTAssertFalse(approval.awaitingKindLine?.contains("git") == true)

        let edit = AgentSessionActivity(detail: .tool(name: "Edit", argument: "Kunde.swift"), awaitingKind: .permission)
        XCTAssertEqual(detail(.awaitingInput, input(.awaitingInput, edit)), String(localized: "Approval: \("Edit")"))
        let mcp = AgentSessionActivity(awaitingKind: .permission, awaitingToolName: "mcp__server__lookup")
        XCTAssertEqual(detail(.awaitingInput, input(.awaitingInput, mcp)), String(localized: "Approval: \("lookup")"))
        let bare = AgentSessionActivity(awaitingKind: .permission)
        XCTAssertEqual(detail(.awaitingInput, input(.awaitingInput, bare)), String(localized: "Approval"))

        let question = AgentSessionActivity(detail: .question("Soll ich den Kunden anschreiben?"), awaitingKind: .question)
        XCTAssertEqual(detail(.awaitingInput, input(.awaitingInput, question)), String(localized: "Question"))
        XCTAssertTrue(question.line(for: .awaitingInput)?.contains("Kunden") == true)
        let plan = AgentSessionActivity(awaitingKind: .planApproval)
        XCTAssertEqual(detail(.awaitingInput, input(.awaitingInput, plan)), String(localized: "Plan awaiting approval"))

        // Ohne bekannte Art (Codex ohne Hooks, noch kein Stand) und bei
        // „fertig“ oder „Fehler“: nur das Projekt.
        let codexTool = AgentSessionActivity(detail: .tool(name: "shell", argument: "rm -rf build"))
        XCTAssertEqual(detail(.awaitingInput, input(.awaitingInput, codexTool)), "Projekt A")
        let codexQuestion = AgentSessionActivity(detail: .question("Welche Datei?"))
        XCTAssertEqual(detail(.awaitingInput, input(.awaitingInput, codexQuestion)), String(localized: "Question"))
        XCTAssertEqual(detail(.awaitingInput, input(.awaitingInput, nil)), "Projekt A")
        let reply = AgentSessionActivity(detail: .reply("Antworttext"))
        XCTAssertEqual(detail(.finished, input(.idle, reply)), "Projekt A", "kein Antworttext im Hinweis")
        XCTAssertEqual(detail(.errored, input(.errored, approval)), "Projekt A")
        XCTAssertNil(detail(.awaitingInput, nil))
    }

    /// Der Hinweis bleibt stehen, solange der Zeiger auf der großen Form
    /// ist (gleich kommt ein Klick); daneben und ohne Form läuft er ab.
    func testAlertStaysWhileThePointerIsOnTheForm() {
        let form = NotchIslandLargeGeometry.form(screen: islandScreen(), kind: .alert).frame
        XCTAssertTrue(NotchStatusController.alertHeldByPointer(form: form, mouse: CGPoint(x: form.midX, y: form.midY)))
        XCTAssertTrue(NotchStatusController.alertHeldByPointer(form: form, mouse: CGPoint(x: form.minX + 2, y: form.minY + 2)))
        XCTAssertFalse(NotchStatusController.alertHeldByPointer(form: form, mouse: CGPoint(x: form.minX - 4, y: form.midY)))
        XCTAssertFalse(NotchStatusController.alertHeldByPointer(form: form, mouse: CGPoint(x: form.midX, y: form.minY - 4)))
        XCTAssertFalse(NotchStatusController.alertHeldByPointer(form: nil, mouse: CGPoint(x: form.midX, y: form.midY)))
        XCTAssertLessThanOrEqual(NotchStatusController.alertPointerHoldLimit, .seconds(30), "nie unbegrenzt")
    }

    // MARK: Aufgehen nur per Klick

    /// „Liste beim Darüberfahren öffnen“ wirkt an Notch und Pille wie
    /// bisher, an der Kamera-Insel nie: Dort verdeckt die Liste Menüs und
    /// geht nur auf einen Klick auf.
    func testHoverNeverOpensTheLargeForm() {
        XCTAssertFalse(NotchStatusController.expandsOnHover(setting: true, screen: islandScreen()))
        XCTAssertTrue(NotchStatusController.expandsOnHover(setting: true, screen: notchScreen))
        XCTAssertTrue(NotchStatusController.expandsOnHover(setting: true, screen: plainScreen))
        XCTAssertTrue(NotchStatusController.expandsOnHover(setting: true, screen: nil))
        for screen in [islandScreen(), notchScreen, plainScreen] {
            XCTAssertFalse(NotchStatusController.expandsOnHover(setting: false, screen: screen))
        }
    }

    // MARK: Notch und Bildschirm ohne Aussparung bleiben, wie sie waren

    /// Die große Form gibt es nur an der Kamera-Insel. An der Notch hängen
    /// Hinweis und Liste weiter unter der Aussparung, ohne Aussparung bleibt
    /// die Pille.
    func testNotchAndPlainScreensKeepTheirLayout() {
        let alert = NotchGeometry.layout(screen: notchScreen, mode: .alert)
        XCTAssertEqual(alert.band, CGRect(x: 663.5, y: 982 - 38, width: 185, height: 38))
        XCTAssertEqual(alert.body, CGRect(x: 756 - 170, y: 982 - 38 - 24, width: 340, height: 24))
        let list = NotchGeometry.layout(screen: notchScreen, mode: .expanded(rowCount: 2, sectionCount: 1))
        XCTAssertEqual(list.body.width, NotchGeometry.expandedMinWidth)
        XCTAssertEqual(list.body.height, NotchGeometry.chinHeight + NotchGeometry.listHeight(rowCount: 2, sectionCount: 1))
        XCTAssertEqual(list.frame, list.band.union(list.body))

        let pill = NotchGeometry.layout(screen: plainScreen, mode: .alert)
        XCTAssertEqual(pill.frame.size, CGSize(width: NotchGeometry.pillAlertWidth, height: NotchGeometry.pillHeight))
        XCTAssertEqual(pill.band, .zero)

        XCTAssertEqual(NotchStatusController.displayStyle(screen: notchScreen), .notch(width: 185, height: 38))
        XCTAssertEqual(NotchStatusController.displayStyle(screen: plainScreen), .pill)
        // Die Liste dort behält ihre Maße.
        XCTAssertEqual(NotchListMetrics.standard.rowHeight, NotchGeometry.rowHeight)
        XCTAssertEqual(NotchListMetrics.standard.titleSize, 12.5)
        XCTAssertEqual(NotchListMetrics.islandLarge.rowHeight, 56)
        // Das Fenster des Diktats an der Notch ist unverändert.
        let panel = UnifiedPillGeometry.notchDictationPanelFrame(screen: notchScreen, panelWidth: 608)
        XCTAssertEqual(panel, CGRect(x: 756 - 304, y: 982 - 38 - 40 - 24, width: 608, height: 38 + 40 + 24))
    }

    /// Das Fenster des Diktats an der Insel beginnt auf Höhe der großen Form
    /// und fasst sie samt Rand, damit sie ohne Fensterwechsel aufgeht.
    func testDictationWindowHoldsTheLargeForm() {
        let screen = islandScreen()
        let panel = UnifiedPillGeometry.notchDictationPanelFrame(screen: screen, panelWidth: 608)
        let form = NotchIslandLargeGeometry.form(screen: screen, kind: .dictation)
        XCTAssertEqual(panel.maxY, form.frame.maxY)
        XCTAssertEqual(panel.midX, screen.notchCenterX, accuracy: 0.001)
        XCTAssertTrue(panel.contains(form.frame.insetBy(dx: -NotchIslandLargeGeometry.overshootMargin, dy: 0)))
        XCTAssertGreaterThanOrEqual(panel.height, form.frame.height + NotchIslandLargeGeometry.overshootMargin)
        // Auch die Zeile am Hals (Schnellaktion, Controller) passt hinein.
        let band = NotchIslandGeometry.band(screen: screen)
        XCTAssertGreaterThanOrEqual(panel.height, band.topGap + band.neckHeight + PillMetrics.height)
    }
}
