import Foundation
import ImageIO
import MDictReader
import UniformTypeIdentifiers

/// The app graph owns one actor for imported files. It serializes the parser's mutable block
/// caches, keeps at most two dictionaries open, and releases security scopes on eviction. User
/// dictionaries stay in place; removing a source never deletes their original files.
actor MDictLibraryService {
    /// Import validation is short-lived and has no shared runtime state; the router alone owns
    /// the long-lived lookup cache. The UI never constructs an inference or observation service.
    nonisolated static func importedFile(_ url: URL) async throws -> MDictLibraryDescriptor {
        try await MDictLibraryService().importFile(url)
    }
    nonisolated static func attaching(_ urls: [URL], to library: MDictLibraryDescriptor) async throws -> MDictLibraryDescriptor {
        try await MDictLibraryService().attach(urls, to: library)
    }

    private func attach(_ urls: [URL], to library: MDictLibraryDescriptor) throws -> MDictLibraryDescriptor {
        guard urls.count <= 16, urls.allSatisfy({ $0.pathExtension.lowercased() == "mdd" }) else {
            throw DictionaryServiceFailure.invalidFile
        }
        var total: UInt64 = 0
        for url in [URL(fileURLWithPath: library.mdx.path)] + urls {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, UInt64(size) <= 16 * 1024 * 1024 * 1024 - total else { throw DictionaryServiceFailure.tooLarge }
            total += UInt64(size)
            _ = try MDictFile(url: url)
        }
        var copy = library
        copy.resources = try urls.map(Self.reference)
        copy.revision = UUID()
        return copy
    }
    private struct OpenBook {
        let descriptor: MDictLibraryDescriptor
        let file: MDictFile
        let resources: [MDictFile]
        let folder: URL
        let scopedURLs: [URL]
        let stamps: [FileStamp]
    }
    private struct FileStamp: Equatable { let size: Int; let modified: Date? }
    private var books: [UUID: OpenBook] = [:]
    private var order: [UUID] = []

    func importFile(_ url: URL) throws -> MDictLibraryDescriptor {
        try Task.checkCancellation()
        guard url.pathExtension.lowercased() == "mdx" else { throw DictionaryServiceFailure.invalidFile }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try MDictFile(url: url)
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let companions = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mdd" &&
                ($0.deletingPathExtension().lastPathComponent == stem || $0.lastPathComponent.hasPrefix(stem + ".")) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard companions.count <= 16 else { throw DictionaryServiceFailure.tooLarge }
        var totalSize: UInt64 = 0
        for file in [url] + companions {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, UInt64(size) <= 16 * 1024 * 1024 * 1024 - totalSize else {
                throw DictionaryServiceFailure.tooLarge
            }
            totalSize += UInt64(size)
        }
        // Validate companions at import, not on the first audio/image request from WebKit.
        for companion in companions { _ = try MDictFile(url: companion) }
        return .init(id: UUID(), name: file.title.isEmpty ? stem : String(file.title.prefix(200)),
                     mdx: try Self.reference(url), resources: try companions.map(Self.reference),
                     folder: try Self.reference(folder), entryCount: file.entryCount)
    }

    func lookup(_ query: String, library: MDictLibraryDescriptor) throws -> LearningDictionaryResult {
        let book = try open(library)
        var visited = Set<String>(), remaining = 8_000_000
        let records = try definitions(query, book: book, visited: &visited, remaining: &remaining, depth: 0)
        guard !records.isEmpty else { return .notFound }
        var html = records.joined(separator: "<hr>")
        if !book.file.isHTML { html = "<pre>" + DictionaryContentPolicy.escaped(html) + "</pre>" }
        // Companion styles use the same scoped resource route as image/font references.
        let stem = URL(fileURLWithPath: library.mdx.path).deletingPathExtension().lastPathComponent
        let css = book.folder.appendingPathComponent(stem + ".css")
        if FileManager.default.fileExists(atPath: css.path) {
            html = "<link rel=\"stylesheet\" href=\"" + DictionaryContentPolicy.escaped(css.lastPathComponent) + "\">" + html
        }
        return .article(.init(html: html, text: DictionaryContentPolicy.plainText(html),
                              sourceName: library.name, resourceLibrary: library.id))
    }

    private func definitions(_ query: String, book: OpenBook, visited: inout Set<String>,
                             remaining: inout Int, depth: Int) throws -> [String] {
        try Task.checkCancellation()
        guard depth < 8, visited.insert(query).inserted else { return [] }
        var result: [String] = []
        for record in try book.file.definitions(for: query) {
            remaining -= record.utf8.count
            guard remaining >= 0 else { throw DictionaryServiceFailure.tooLarge }
            if record.hasPrefix("@@@LINK=") {
                let target = String(record.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard DictionaryContentPolicy.validQuery(target) else { continue }
                result += try definitions(target, book: book, visited: &visited, remaining: &remaining, depth: depth + 1)
            } else { result.append(record) }
        }
        return result
    }

    func resource(_ path: String, library: MDictLibraryDescriptor) throws -> DictionaryResource? {
        guard let path = DictionaryContentPolicy.resourcePath(path), let mime = Self.mimeType(path) else { return nil }
        let book = try open(library)
        var data: Data?
        let key = "\\" + path.replacingOccurrences(of: "/", with: "\\")
        for resource in book.resources {
            if let value = try resource.resource(for: key) { data = value; break }
        }
        if data == nil {
            let root = book.folder.resolvingSymlinksInPath().standardizedFileURL
            let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root.path + "/") else { return nil }
            let size = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size?.isRegularFile == true, let count = size?.fileSize, count <= 8_000_000 else { return nil }
            data = try Data(contentsOf: file)
        }
        guard let data, data.count <= 8_000_000 else { return nil }
        if mime.hasPrefix("image/") {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width <= 16_000_000 / height else { return nil }
        }
        return .init(data: data, mimeType: mime)
    }

    private func open(_ descriptor: MDictLibraryDescriptor) throws -> OpenBook {
        guard descriptor.resources.count <= 16 else { throw DictionaryServiceFailure.tooLarge }
        let references = [descriptor.mdx, descriptor.folder] + descriptor.resources
        var scoped: [URL] = []
        do {
            let urls = try references.map { reference in
                var stale = false
                let url = try URL(resolvingBookmarkData: reference.bookmark, options: [.withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { scoped.append(url) }
                return url
            }
            var total: UInt64 = 0
            let files = [urls[0]] + Array(urls.dropFirst(2))
            let stamps = try files.map { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize,
                      size > 0, UInt64(size) <= 16 * 1024 * 1024 * 1024 - total else {
                    throw DictionaryServiceFailure.tooLarge
                }
                total += UInt64(size)
                return FileStamp(size: size, modified: values.contentModificationDate)
            }
            if let book = books[descriptor.id], book.descriptor == descriptor, book.stamps == stamps {
                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                return book
            }
            if let old = books.removeValue(forKey: descriptor.id) {
                old.scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            }
            let book = OpenBook(descriptor: descriptor, file: try MDictFile(url: urls[0]),
                resources: try urls.dropFirst(2).map { try MDictFile(url: $0) }, folder: urls[1], scopedURLs: scoped, stamps: stamps)
            order.removeAll { $0 == descriptor.id }
            while order.count >= 2 {
                if let old = books.removeValue(forKey: order.removeFirst()) {
                    old.scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                }
            }
            books[descriptor.id] = book
            order.append(descriptor.id)
            return book
        } catch {
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            throw DictionaryServiceFailure.invalidFile
        }
    }

    private static func reference(_ url: URL) throws -> DictionaryFileReference {
        // Lingrove is unsandboxed. Ordinary bookmarks follow moved files without requiring
        // sandbox-only entitlements; WebKit still receives no file-system access of its own.
        .init(path: url.path, bookmark: try url.bookmarkData(options: [],
                                                           includingResourceValuesForKeys: nil, relativeTo: nil))
    }
    private static func mimeType(_ path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "css": "text/css"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        default: nil
        }
    }
}
