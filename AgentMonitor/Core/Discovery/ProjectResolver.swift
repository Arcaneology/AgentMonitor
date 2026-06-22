import Foundation

struct ProjectInfo: Equatable, Sendable {
    let rootURL: URL
    let name: String
}

protocol ProjectResolving: Sendable {
    func resolve(workingDirectory: URL) -> ProjectInfo?
}

struct ProjectResolver: ProjectResolving {
    private let markers = [".git", "package.json", "pyproject.toml", "go.mod", "Cargo.toml"]

    func resolve(workingDirectory: URL) -> ProjectInfo? {
        var directory = workingDirectory.resolvingSymlinksInPath()

        while true {
            if markers.contains(where: { markerExists($0, in: directory) }) {
                return ProjectInfo(
                    rootURL: directory,
                    name: projectName(in: directory) ?? directory.lastPathComponent
                )
            }

            guard directory.path != "/" else { return nil }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    private func markerExists(_ marker: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(marker, isDirectory: false).path
        )
    }

    private func projectName(in directory: URL) -> String? {
        packageName(in: directory)
            ?? tomlName(in: directory, file: "pyproject.toml", sections: ["project", "tool.poetry"])
            ?? goModuleName(in: directory)
            ?? tomlName(in: directory, file: "Cargo.toml", sections: ["package"])
    }

    private func packageName(in directory: URL) -> String? {
        let url = directory.appendingPathComponent("package.json", isDirectory: false)
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["name"] as? String,
            !name.isEmpty
        else {
            return nil
        }
        return name
    }

    private func goModuleName(in directory: URL) -> String? {
        let url = directory.appendingPathComponent("go.mod", isDirectory: false)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0] == "module" else { continue }
            let module = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return module.split(separator: "/").last.map(String.init)
        }
        return nil
    }

    private func tomlName(
        in directory: URL,
        file: String,
        sections: Set<String>
    ) -> String? {
        let url = directory.appendingPathComponent(file, isDirectory: false)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var currentSection = ""
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                continue
            }

            guard sections.contains(currentSection) else { continue }
            let pair = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2, pair[0] == "name" else { continue }

            let value = pair[1]
                .split(separator: "#", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
