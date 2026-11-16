import CryptoKit
import Foundation

struct NotebookPackageComponentReference: Codable, Equatable {
    var provider: String
    var type: String
    var properties: [String: String] = [:]
    var enabled: Bool = true

    init(provider: String, type: String) {
        self.provider = provider
        self.type = type
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        provider = try fields.decode(String.self, forKey: .provider)
        type = try fields.decode(String.self, forKey: .type)
        properties = try fields.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        enabled = try fields.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct NotebookPackageProperty: Decodable, Identifiable {
    enum Kind: String, Decodable { case text, integer, toggle, module, input }
    let id: String
    let title: String
    let kind: Kind
    let initial: String?
    let minimum: Int?
    let maximum: Int?
    let argument: String?
    let invoke: Bool?

    func value(in reference: NotebookPackageComponentReference) -> String {
        reference.properties[id] ?? initial ?? ""
    }
}

struct NotebookPackageComponentDefinition: Decodable, Identifiable {
    enum Kind: String, Decodable { case service, board }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let symbol: String?
    let properties: [NotebookPackageProperty]?
    let module: String?
    let entry: String?
    let listen_port: String?
    let board: String?
    let board_assets: [String: String]?

    var icon: String { symbol ?? (kind == .service ? "gearshape.2" : "rectangle.inset.filled") }
    var savedKind: String { kind == .service ? "package_service" : "package_board" }

    func settings(_ reference: NotebookPackageComponentReference) throws -> [String: String] {
        var settings: [String: String] = [:]
        for property in properties ?? [] {
            let value = property.value(in: reference)
            guard value.utf8.count <= 8192 else { throw NotebookFailure(message: "\(property.title) is too long.") }
            if property.kind == .integer {
                guard let number = Int(value), number >= property.minimum ?? Int.min, number <= property.maximum ?? Int.max else {
                    throw NotebookFailure(message: "\(property.title) is outside its allowed range.")
                }
            }
            if property.kind == .toggle, !["true", "false"].contains(value) {
                throw NotebookFailure(message: "\(property.title) must be on or off.")
            }
            settings[property.id] = value
        }
        return settings
    }
}

struct NotebookComponentPackage: Identifiable {
    private struct Descriptor: Decodable {
        let version: Int
        let components: [NotebookPackageComponentDefinition]
    }

    let id: String
    let name: String
    let version: String
    let digest: String
    let directory: URL
    let components: [NotebookPackageComponentDefinition]

    static let descriptor = "notebook/components.json"

    static func identifier(_ value: String) -> Bool {
        value.utf8.count <= 128 && value.range(of: #"^[A-Za-z_][A-Za-z_0-9]*$"#, options: .regularExpression) != nil
    }

    private static func read(_ file: URL, limit: Int) -> Data? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let info = try? file.resourceValues(forKeys: keys), info.isRegularFile == true,
              info.isSymbolicLink != true, let size = info.fileSize, size <= limit,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    static func safeRelativePath(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && relative.utf8.count <= 512 && !relative.contains("\0") && !relative.contains("\\") &&
            parts.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }

    private static func verifiedMember(_ relative: String, in directory: URL, limit: Int) -> Data? {
        guard safeRelativePath(relative) else { return nil }
        let file = directory.appendingPathComponent(relative)
        guard file.resolvingSymlinksInPath().path == file.path,
              let data = read(file, limit: limit),
              let inventory = read(directory.appendingPathComponent("checksums.sha256"), limit: 1_048_576) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard String(decoding: inventory, as: UTF8.self).split(separator: "\n").contains(Substring("\(digest)  \(relative)")) else { return nil }
        return data
    }

    func boardDocument(for definition: NotebookPackageComponentDefinition) throws -> Data {
        guard definition.kind == .board, let member = definition.board,
              let data = Self.verifiedMember(member, in: directory, limit: 524_288) else {
            throw NotebookFailure(message: "The package board definition is unavailable.")
        }
        return data
    }

    func copyBoardAssets(for definition: NotebookPackageComponentDefinition, to book: URL) throws {
        var remaining = 16 * 1024 * 1024
        for (path, member) in definition.board_assets ?? [:] {
            guard Self.safeRelativePath(path), !path.hasPrefix("."), path != "project.json", path != "packages",
                  !path.hasPrefix("packages/"),
                  let data = Self.verifiedMember(member, in: directory, limit: remaining) else {
                throw NotebookFailure(message: "A packaged board asset is unavailable or exceeds the asset limit.")
            }
            let destination = book.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            remaining -= data.count
        }
    }

    static func recommendations(in directory: URL) -> [String] {
        struct Manifest: Decodable { let notebook_packages: [String]? }
        guard let data = verifiedMember("sputnik.build.json", in: directory.resolvingSymlinksInPath(), limit: 524_288),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return (manifest.notebook_packages ?? []).prefix(16).filter {
            $0.utf8.count <= 257 && $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$"#,
                                            options: .regularExpression) != nil && !$0.contains("..")
        }
    }

    static func catalog(in home: URL) -> [Self] {
        let manager = FileManager.default
        let root = home.standardizedFileURL.resolvingSymlinksInPath()
        let requirements = read(root.appendingPathComponent("dependencies.index"), limit: 1_048_576)
        var versions: [String: String] = [:]
        if let requirements {
            for row in String(decoding: requirements, as: UTF8.self).split(separator: "\n") {
                let parts = row.split(separator: "\t")
                if parts.count == 2 { versions[String(parts[0])] = String(parts[1]) }
            }
        }
        var packages: [Self] = []
        var visited = 0

        func scan(_ path: URL, parts: [String]) {
            visited += 1
            guard visited <= 8192 else { return }
            let directory = path.resolvingSymlinksInPath()
            if let data = read(directory.appendingPathComponent("modules.index"), limit: 1_048_576) {
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                guard lines.count >= 4, ["sputnik.package.index.v1", "sputnik.package.index.v2"].contains(lines[0]) else { return }
                let name = String(lines[1]), version = String(lines[2])
                var expected = name.split(separator: "/").map(String.init) + [version]
                if lines[0] == "sputnik.package.index.v2" {
                    guard lines.count >= 5 else { return }
                    expected.append(String(lines[4]))
                }
                guard expected == parts, versions[name].map({ $0 == version }) ?? true,
                      let json = verifiedMember(descriptor, in: directory, limit: 131_072),
                      let manifest = try? JSONDecoder().decode(Descriptor.self, from: json), manifest.version == 1,
                      !manifest.components.isEmpty, manifest.components.count <= 64,
                      Set(manifest.components.map(\.id)).count == manifest.components.count,
                      manifest.components.allSatisfy(valid) else { return }
                packages.append(Self(id: name, name: name.split(separator: "/").last.map(String.init) ?? name,
                                     version: version, digest: String(lines[3]), directory: directory, components: manifest.components))
                return
            }
            guard parts.count < 4, (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let children = try? manager.contentsOfDirectory(at: path, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let info = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if info?.isDirectory == true || info?.isSymbolicLink == true {
                    scan(child, parts: parts + [child.lastPathComponent])
                }
            }
        }
        scan(root, parts: [])
        var selected: [String: Self] = [:]
        for package in packages {
            if let existing = selected[package.id],
               package.version.compare(existing.version, options: .numeric) != .orderedDescending { continue }
            selected[package.id] = package
        }
        return selected.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private static func valid(_ definition: NotebookPackageComponentDefinition) -> Bool {
        let properties = definition.properties ?? []
        guard identifier(definition.id), (1...128).contains(definition.title.count), definition.detail.count <= 512,
              properties.count <= 32, Set(properties.map(\.id)).count == properties.count,
              properties.allSatisfy({ identifier($0.id) && (1...128).contains($0.title.count) && ($0.argument.map(identifier) ?? true) }) else { return false }
        switch definition.kind {
        case .board: return definition.board.map(safeRelativePath) == true && (definition.board_assets?.count ?? 0) <= 128
        case .service:
            guard let module = definition.module, let entry = definition.entry, identifier(entry),
                  module.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ identifier(String($0)) }) else { return false }
            return definition.listen_port.map { id in properties.contains { $0.id == id && $0.kind == .integer } } ?? true
        }
    }
}

extension NotebookModel {
    var componentPackageHome: URL? {
        packageHomeOverride ?? snapshot.map { URL(fileURLWithPath: $0.path).appendingPathComponent("packages", isDirectory: true) }
    }

    func refreshComponentPackages() {
        componentPackages = !remote.isSelected ? componentPackageHome.map(NotebookComponentPackage.catalog) ?? [] : []
    }

    func packageDefinition(for component: NotebookBoardComponent) -> (NotebookComponentPackage, NotebookPackageComponentDefinition)? {
        guard let ref = component.package_component,
              let package = componentPackages.first(where: { $0.id == ref.provider }),
              let definition = package.components.first(where: { $0.id == ref.type && $0.savedKind == component.kind }) else { return nil }
        return (package, definition)
    }
}
