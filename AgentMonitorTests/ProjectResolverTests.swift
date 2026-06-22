import XCTest
@testable import AgentMonitor

final class ProjectResolverTests: XCTestCase {
    func testFindsNearestPackageProjectAndUsesManifestName() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("{\"name\":\"dashboard-web\"}", to: root.appendingPathComponent("package.json"))
        let nested = root.appendingPathComponent("src/features", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let project = try XCTUnwrap(ProjectResolver().resolve(workingDirectory: nested))

        XCTAssertEqual(project.name, "dashboard-web")
        XCTAssertEqual(project.rootURL, root.resolvingSymlinksInPath())
    }

    func testUsesGoModuleName() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("module github.com/example/api-server\n\ngo 1.24\n", to: root.appendingPathComponent("go.mod"))

        let project = try XCTUnwrap(ProjectResolver().resolve(workingDirectory: root))

        XCTAssertEqual(project.name, "api-server")
    }

    func testUsesDirectoryNameForGitRepositoryWithoutManifest() throws {
        let root = try makeDirectory(named: "fallback-project")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let project = try XCTUnwrap(ProjectResolver().resolve(workingDirectory: root))

        XCTAssertEqual(project.name, "fallback-project")
    }

    func testReturnsNilWhenNoProjectMarkerExists() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(ProjectResolver().resolve(workingDirectory: root))
    }

    private func makeDirectory(named name: String = UUID().uuidString) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url)
    }
}

