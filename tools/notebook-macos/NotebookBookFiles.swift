import Foundation

enum NotebookBookPage: Equatable {
    case markdown(String)
    case attachments
}

struct NotebookMarkdownDraft {
    let saved: String
    var source: String

    var modified: Bool { !source.utf8.elementsEqual(saved.utf8) }
}

struct NotebookBookFiles {
    struct Item: Identifiable {
        let path: String
        let directory: Bool
        var id: String { path }
        var name: String { String(path.split(separator: "/").last ?? "") }
    }

    static let markdownLimit = 1_048_576
    let root: URL
    private let fm = FileManager.default

    private func components(_ path: String) throws -> [String] {
        let parts = path.components(separatedBy: "/")
        guard path.utf8.count <= 1024,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0 == ":" || $0 == "\\" }) else {
            throw NotebookFailure(message: "Choose a relative notebook path without traversal or control characters.")
        }
        return parts
    }

    private func type(at url: URL) throws -> FileAttributeType? {
        do {
            return try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
    }

    func url(_ path: String, createParents: Bool = false) throws -> URL {
        let parts = try components(path)
        guard try type(at: root) == .typeDirectory else {
            throw NotebookFailure(message: "This notebook folder is unavailable.")
        }
        var current = root
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(part)
            let kind = try type(at: current)
            if index < parts.count - 1 {
                if kind == nil && createParents {
                    try fm.createDirectory(at: current, withIntermediateDirectories: false)
                } else if kind != nil && kind != .typeDirectory {
                    throw NotebookFailure(message: "A parent folder is not a regular directory.")
                }
            } else if let kind, kind != .typeRegular && kind != .typeDirectory {
                throw NotebookFailure(message: "This item is not a regular file or folder.")
            }
        }
        return current
    }

    func list(_ folder: String) throws -> [Item] {
        let directory = try url(folder)
        guard try type(at: directory) != nil else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { entry in
                let kind = try type(at: entry)
                guard kind == .typeDirectory || kind == .typeRegular else { return nil }
                let path = folder + "/" + entry.lastPathComponent
                guard (try? components(path)) != nil else { return nil }
                return Item(path: path, directory: kind == .typeDirectory)
            }
            .sorted {
                if $0.directory != $1.directory { return $0.directory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func markdownFiles(in folder: String = "docs") throws -> [String] {
        try list(folder).flatMap { item in
            if item.directory { return try markdownFiles(in: item.path) }
            return item.path.lowercased().hasSuffix(".md") ? [item.path] : []
        }
    }

    func newMarkdown(_ name: String) throws -> String {
        guard try components(name).count == 1 else { throw NotebookFailure(message: "Enter a Markdown filename.") }
        let path = "docs/" + (name.lowercased().hasSuffix(".md") ? name : name + ".md")
        try Data().write(to: url(path, createParents: true), options: .withoutOverwriting)
        return path
    }

    func readMarkdown(_ path: String) throws -> String {
        let file = try url(path)
        guard try type(at: file) == .typeRegular else { throw NotebookFailure(message: "This Markdown file is unavailable.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.markdownLimit + 1) ?? Data()
        guard bytes.count <= Self.markdownLimit,
              let source = String(data: bytes, encoding: .utf8), !source.utf8.contains(0) else {
            throw NotebookFailure(message: "Markdown documents must be UTF-8 text up to 1 MiB.")
        }
        return source
    }

    func saveMarkdown(_ path: String, draft: NotebookMarkdownDraft) throws {
        let bytes = Data(draft.source.utf8)
        guard bytes.count <= Self.markdownLimit, !bytes.contains(0) else {
            throw NotebookFailure(message: "Markdown documents must be UTF-8 text up to 1 MiB.")
        }
        guard try readMarkdown(path).utf8.elementsEqual(draft.saved.utf8) else {
            throw NotebookFailure(message: "This document changed on disk. Your edits are still in the editor.")
        }
        try bytes.write(to: url(path), options: .atomic)
    }

    func importItem(_ source: URL, into folder: String) throws {
        let path = folder + "/" + source.lastPathComponent
        let target = try url(path)
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
        let book = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard book != resolvedSource, !book.hasPrefix(resolvedSource + "/"), !resolvedSource.hasPrefix(book + "/") else {
            throw NotebookFailure(message: "Choose a file or folder outside this notebook.")
        }
        guard try type(at: target) == nil else { throw NotebookFailure(message: "An attachment already uses this name.") }
        let kind = try type(at: source)
        try validateImportType(kind)
        if kind == .typeDirectory {
            var failure: Error?
            guard let contents = fm.enumerator(at: source, includingPropertiesForKeys: nil, errorHandler: { _, error in
                failure = error
                return false
            }) else { throw NotebookFailure(message: "Could not read the chosen folder.") }
            for case let member as URL in contents {
                let relative = member.path.dropFirst(source.path.count).drop(while: { $0 == "/" })
                _ = try components(path + "/" + relative)
                try validateImportType(type(at: member))
            }
            if let failure { throw failure }
        }
        _ = try url(path, createParents: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        try fm.moveItem(at: temporary, to: target)
    }

    private func validateImportType(_ kind: FileAttributeType?) throws {
        guard kind == .typeRegular || kind == .typeDirectory else {
            throw NotebookFailure(message: "Attachments can only contain regular files and folders.")
        }
    }

    func makeFolder(_ path: String) throws {
        try fm.createDirectory(at: url(path, createParents: true), withIntermediateDirectories: false)
    }

    func move(_ from: String, to: String) throws {
        if from == to { return }
        guard !to.lowercased().hasPrefix(from.lowercased() + "/") else {
            throw NotebookFailure(message: "Choose a destination outside the folder.")
        }
        let source = try url(from)
        let target = try url(to)
        guard try type(at: source) != nil else { throw NotebookFailure(message: "This item is unavailable.") }
        try fm.moveItem(at: source, to: target)
    }

    func trash(_ path: String) throws { try fm.trashItem(at: url(path), resultingItemURL: nil) }
}

