import Combine
import Foundation

enum NotebookLibrarySort: String, CaseIterable, Identifiable {
    case lastOpened, created, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lastOpened: return "Last Opened"
        case .created: return "Date Created"
        case .name: return "Name (A–Z)"
        }
    }
}

struct NotebookLibraryProject: Codable, Identifiable, Equatable {
    var path: String
    var name: String?
    var created: Date?
    var lastOpened: Date?
    // The macOS history has an order but does not expose opening dates.
    var importedRecent = false
    var missing = false
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var title: String { name ?? url.deletingPathExtension().lastPathComponent }

    mutating func refresh() {
        if name == nil { name = url.deletingPathExtension().lastPathComponent }
        var directory: ObjCBool = false
        missing = !FileManager.default.fileExists(atPath: path, isDirectory: &directory) || !directory.boolValue
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let date = attributes?[.creationDate] as? Date { created = date }
    }
}

struct NotebookLibraryScan {
    var urls: [URL] = []
    var unreadableDirectories = 0

    static func directory(_ root: URL) throws -> Self {
        let manager = FileManager.default
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInvalidFileNameError,
                          userInfo: [NSLocalizedDescriptionKey: "Choose a directory to scan."])
        }
        if root.pathExtension.lowercased() == "sputnikbook" { return Self(urls: [root]) }
        _ = try manager.contentsOfDirectory(atPath: root.path)
        var result = Self()
        guard let enumerator = manager.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in
                result.unreadableDirectories += 1
                return true
            }) else { return result }
        for case let url as URL in enumerator {
            let metadata = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Never recurse through directory links or into notebook contents.
            if metadata?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if metadata?.isDirectory == true, url.pathExtension.lowercased() == "sputnikbook" {
                result.urls.append(url.standardizedFileURL.resolvingSymlinksInPath())
                enumerator.skipDescendants()
            }
        }
        result.urls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }
}

/// This catalog outlives AppKit's bounded recent-document history, including
/// paths on temporarily disconnected volumes. Only a successful open changes recency.
final class NotebookLibrary: ObservableObject {
    private static let storageKey = "NotebookProjectLibrary.v1"
    private static let sortKey = "NotebookProjectLibrary.sort"
    private static let expandedKey = "NotebookProjectLibrary.expanded"
    private let defaults: UserDefaults?
    @Published private(set) var projects: [NotebookLibraryProject] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanMessage: String?
    @Published var error: String?
    @Published var expandedProjects = Set<String>()
    @Published var sort: NotebookLibrarySort {
        didSet { defaults?.set(sort.rawValue, forKey: Self.sortKey) }
    }
    @Published var expanded: Bool {
        didSet { defaults?.set(expanded, forKey: Self.expandedKey) }
    }

    init(defaults: UserDefaults? = .standard, recentProjects: [URL] = []) {
        self.defaults = defaults
        sort = defaults?.string(forKey: Self.sortKey).flatMap(NotebookLibrarySort.init(rawValue:)) ?? .lastOpened
        expanded = defaults?.object(forKey: Self.expandedKey) as? Bool ?? true
        if let data = defaults?.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([NotebookLibraryProject].self, from: data) {
            projects = saved
        } else {
            var seen = Set<String>()
            projects = recentProjects.compactMap { url in
                guard let url = Self.projectURL(url), seen.insert(url.path).inserted else { return nil }
                return NotebookLibraryProject(path: url.path, importedRecent: true)
            }
        }
        refresh()
    }

    var sortedProjects: [NotebookLibraryProject] {
        projects.enumerated().sorted { left, right in
            switch sort {
            case .lastOpened:
                let lhs = left.element.lastOpened, rhs = right.element.lastOpened
                if lhs != rhs { return (lhs ?? .distantPast) > (rhs ?? .distantPast) }
                if left.element.importedRecent != right.element.importedRecent { return left.element.importedRecent }
                return left.offset < right.offset
            case .created:
                let lhs = left.element.created, rhs = right.element.created
                if lhs != rhs { return (lhs ?? .distantPast) > (rhs ?? .distantPast) }
            case .name: break
            }
            let order = left.element.title.localizedStandardCompare(right.element.title)
            return order == .orderedSame ? left.element.path < right.element.path : order == .orderedAscending
        }.map(\.element)
    }

    func refresh() {
        projects = projects.map { project in var value = project; value.refresh(); return value }
        save()
    }

    func recordOpened(_ url: URL, at date: Date = Date()) {
        guard let url = Self.projectURL(url) else { return }
        var project = projects.first { $0.path == url.path } ?? NotebookLibraryProject(path: url.path)
        project.lastOpened = date
        project.refresh()
        projects.removeAll { $0.path == url.path }
        projects.insert(project, at: 0)
        save()
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var known = Set(projects.map(\.path))
        var added: [NotebookLibraryProject] = []
        for candidate in urls {
            guard let url = Self.projectURL(candidate), known.insert(url.path).inserted else { continue }
            var project = NotebookLibraryProject(path: url.path)
            project.refresh()
            added.append(project)
        }
        projects.append(contentsOf: added)
        refresh()
        return added.count
    }

    func scan(directory: URL, completion: (() -> Void)? = nil) {
        guard !scanning else { return }
        scanning = true
        error = nil
        scanMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try NotebookLibraryScan.directory(directory) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                switch result {
                case .success(let scan):
                    let added = self.add(scan.urls)
                    self.scanMessage = "Found \(scan.urls.count) notebooks · Added \(added) to the library."
                    if scan.unreadableDirectories > 0 {
                        self.scanMessage! += " Skipped \(scan.unreadableDirectories) unreadable directories."
                    }
                case .failure(let error): self.error = error.localizedDescription
                }
                completion?()
            }
        }
    }

    private static func projectURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.pathExtension.lowercased() == "sputnikbook" else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults?.set(data, forKey: Self.storageKey)
    }
}
