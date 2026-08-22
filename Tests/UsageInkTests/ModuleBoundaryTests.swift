import XCTest

final class ModuleBoundaryTests: XCTestCase {
    func testSourcesImportOnlyAllowedAppleModules() throws {
        let allowed: [String: Set<String>] = [
            "App": ["AppKit", "Foundation"],
            "Runtime": ["Foundation"],
            "Domain": ["Foundation"],
            "Activity": ["Foundation", "Darwin", "SQLite3", "CryptoKit"],
            "Persistence": ["Foundation", "Darwin"],
            "BLE": ["CoreBluetooth", "Foundation"],
            "Render": ["Foundation", "CoreGraphics", "CoreText", "CryptoKit"],
        ]
        let src = RepoRoot.url().appendingPathComponent("src")

        for (module, allowedImports) in allowed {
            let files = try swiftFiles(in: src.appendingPathComponent(module))
            XCTAssertFalse(files.isEmpty, "missing \(module) sources")
            for file in files {
                let imports = try importLines(in: file)
                let unexpected = imports.subtracting(allowedImports)
                XCTAssertEqual(
                    unexpected,
                    [],
                    "\(file.lastPathComponent) imports \(unexpected.sorted())"
                )
            }
        }
    }

    func testAppAndRuntimeSourcesDoNotOwnBLEOrSourceParsing() throws {
        let forbidden = [
            "CoreBluetooth",
            "CBCentralManager",
            "CBPeripheral",
            "SQLite3",
            "sqlite3",
            "URLSession",
            "NWConnection",
            "MenuBarExtra",
            "SwiftUI",
            "codex app-server",
        ]
        let src = RepoRoot.url().appendingPathComponent("src")
        let scoped = ["App", "Runtime"].map { src.appendingPathComponent($0) }
        for directory in scoped {
        for file in try swiftFiles(in: directory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(
                    text.contains(token),
                    "\(file.lastPathComponent) contains out-of-scope token \(token)"
                )
            }
        }
        }
    }

    func testProjectHasNoThirdPartyRuntimeDependencies() throws {
        let project = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("UsageInk.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertFalse(project.contains("XCRemoteSwiftPackageReference"))
        XCTAssertFalse(project.contains("repositoryURL"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: RepoRoot.url().appendingPathComponent("Package.resolved").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: RepoRoot.url().appendingPathComponent("Package.swift").path
        ))
    }

    func testRenderSourcesRemainRAMOnly() throws {
        let forbidden = [
            "writeToFile",
            "write(to:",
            "Data.write",
            "FileManager",
            "FileHandle",
            "OutputStream",
            "createFile",
            "replaceItemAt",
            "pngData",
            "tiffRepresentation",
            "CGImageDestination",
            "NSBitmapImageRep",
            "NSImage",
        ]
        let files = try swiftFiles(in: RepoRoot.url().appendingPathComponent("src/Render"))
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(
                    text.contains(token),
                    "\(file.lastPathComponent) contains \(token)"
                )
            }
        }
    }

    func testProjectKeepsSandboxAndHardenedRuntimeOff() throws {
        let project = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("UsageInk.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("ENABLE_HARDENED_RUNTIME = NO"))
        XCTAssertFalse(project.contains("com.apple.security.app-sandbox"))
        XCTAssertFalse(project.contains("com.apple.security.files.all"))
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else {
                return nil
            }
            return url
        }
    }

    private func importLines(in file: URL) throws -> Set<String> {
        let lines = try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: .newlines)
        var modules: Set<String> = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("import ") {
                let name = trimmed.dropFirst("import ".count)
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init) ?? ""
                if !name.isEmpty {
                    modules.insert(name)
                }
            }
        }
        return modules
    }
}
