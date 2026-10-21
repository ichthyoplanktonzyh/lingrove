import Darwin
import Foundation

/// SQLite locks protect SQL, while this short-lived advisory lock also covers external PNGs.
/// The archive-owned database keeps one descriptor. Nested access stays on its actor and never
/// awaits; a second app instance must finish metadata/media work before another writer proceeds.
nonisolated final class VocabularySQLiteFileLock {
    private let url: URL?
    private var descriptor: Int32 = -1
    private var held: Bool?

    init(database: URL?) throws {
        url = database.map { URL(fileURLWithPath: $0.path + ".lock") }
        if let url {
            descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else { throw VocabularyError.invalidArchive }
            do { try verify() } catch { Darwin.close(descriptor); descriptor = -1; throw error }
        }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func access<T>(write: Bool, _ operation: () throws -> T) throws -> T {
        if let held {
            guard held || !write else { throw VocabularyError.invalidContent }
            return try operation()
        }
        if descriptor < 0 {
            held = write; defer { held = nil }
            return try operation()
        }
        try verify()
        var acquired = false
        for _ in 0..<100 {
            if flock(descriptor, (write ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 { acquired = true; break }
            guard errno == EWOULDBLOCK || errno == EINTR else { throw VocabularyError.invalidArchive }
            usleep(20_000)
        }
        guard acquired else { throw VocabularyError.storageBusy }
        held = write
        defer { held = nil; _ = flock(descriptor, LOCK_UN) }
        try verify()
        return try operation()
    }

    private func verify() throws {
        guard let url else { return }
        var named = stat(), opened = stat()
        guard lstat(url.path, &named) == 0, fstat(descriptor, &opened) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else {
            throw VocabularyError.invalidArchive
        }
    }
}
