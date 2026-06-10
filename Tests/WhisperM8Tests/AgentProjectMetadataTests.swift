import Foundation
import XCTest
@testable import WhisperM8

final class AgentProjectMetadataTests: XCTestCase {
    // MARK: - Project icon resolver

    func testProjectIconResolverPicksPublicFavicon() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let publicDir = projectURL.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        let favicon = publicDir.appendingPathComponent("favicon.png")
        try Data([0x89]).write(to: favicon)

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "public/favicon.png")
    }

    func testProjectIconResolverPrefersAppleTouchIconOverFavicon() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let publicDir = projectURL.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        try Data([0x89]).write(to: publicDir.appendingPathComponent("favicon.ico"))
        try Data([0x89]).write(to: publicDir.appendingPathComponent("apple-touch-icon.png"))

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "public/apple-touch-icon.png", "PNG mit hoher Auflösung muss vor .ico gewinnen")
    }

    func testProjectIconResolverFallsBackToRepoRoot() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "logo.png")
    }

    func testProjectIconResolverReturnsNilForEmptyRepo() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        XCTAssertNil(AgentProjectIconResolver.findIconRelativePath(in: projectURL.path))
    }

    // MARK: - Project metadata persistence

    func testRenameProjectPersistsTrimmedName() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "Old Name")
        try store.renameProject(id: project.id, name: "  New Name  ")
        let workspace = store.loadWorkspace()
        XCTAssertEqual(workspace.projects.first?.name, "New Name")
    }

    func testRenameProjectIgnoresEmptyName() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "Stable Name")
        try store.renameProject(id: project.id, name: "   ")
        XCTAssertEqual(store.loadWorkspace().projects.first?.name, "Stable Name")
    }

    func testSetProjectColorPersists() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.setProjectColor(id: project.id, color: "#FF453A")
        XCTAssertEqual(store.loadWorkspace().projects.first?.color, "#FF453A")
    }

    func testApplyAutoResolvedProjectIconStoresPathAndAttemptedFlag() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: "public/favicon.png")
        let updated = store.loadWorkspace().projects.first
        XCTAssertEqual(updated?.iconRelativePath, "public/favicon.png")
        XCTAssertEqual(updated?.iconAutoLookupAttempted, true)
    }

    func testApplyAutoResolvedWithNilStillMarksAttempted() throws {
        // Wenn kein Icon gefunden wurde, müssen wir trotzdem `attempted=true`
        // setzen, damit der nächste Reload nicht erneut scannt.
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: nil)
        let updated = store.loadWorkspace().projects.first
        XCTAssertNil(updated?.iconRelativePath)
        XCTAssertEqual(updated?.iconAutoLookupAttempted, true)
    }

    func testClearProjectIconResetsBothSlotsAndAttemptedFlag() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.setProjectCustomIcon(id: project.id, absolutePath: "/tmp/x.png")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: "public/favicon.png")
        try store.clearProjectIcon(id: project.id)
        let updated = store.loadWorkspace().projects.first
        XCTAssertNil(updated?.iconRelativePath)
        XCTAssertNil(updated?.customIconAbsolutePath)
        XCTAssertNil(updated?.iconAutoLookupAttempted)
    }

    func testProjectResolvedIconURLPrefersCustomOverRelative() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let custom = projectURL.appendingPathComponent("custom.png")
        try Data([0x89]).write(to: custom)
        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let project = AgentProject(
            name: "p",
            path: projectURL.path,
            iconRelativePath: "logo.png",
            customIconAbsolutePath: custom.path
        )
        XCTAssertEqual(project.resolvedIconURL?.lastPathComponent, "custom.png")
    }

    func testProjectResolvedIconURLFallsBackToRelativeWhenCustomMissing() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let project = AgentProject(
            name: "p",
            path: projectURL.path,
            iconRelativePath: "logo.png",
            customIconAbsolutePath: "/nonexistent/path.png"
        )
        XCTAssertEqual(project.resolvedIconURL?.lastPathComponent, "logo.png")
    }
}
