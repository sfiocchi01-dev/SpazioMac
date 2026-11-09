import Foundation
import Darwin

public struct DirectoryFile: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let relativePath: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let isSymbolicLink: Bool
    public func bytes(_ metric: SizeMetric) -> Int64 {
        metric == .allocated ? allocatedBytes : logicalBytes
    }
}

public struct DirectoryFileListing: Sendable {
    public let files: [DirectoryFile]
    public let issues: [ScanIssue]
    public let issueCount: Int
    public let excludedVolumes: Int
}

/// A fresh recursive metadata listing, restricted to the selected subtree.
/// Symbolic links are listed as entries, but their targets are never traversed.
public struct DirectoryFileReader {
    public init() {}

    public func list(_ directory: URL, stayOnVolume: Bool = true,
                     cancelled: () -> Bool = { false }) throws -> DirectoryFileListing {
        if cancelled() { throw CancellationError() }
        guard let canonical = directory.withUnsafeFileSystemRepresentation({ path -> UnsafeMutablePointer<CChar>? in
            guard let path else { return nil }
            return realpath(path, nil)
        }) else { throw ScannerError.invalidDirectory(directory.path) }
        let path = String(cString: canonical)
        free(canonical)
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var metadata = stat()
        guard root.withUnsafeFileSystemRepresentation({ p in
            guard let p else { return false }
            return lstat(p, &metadata) == 0
        }), metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw ScannerError.invalidDirectory(directory.path)
        }
        var files: [DirectoryFile] = []
        var issues: [ScanIssue] = []
        var issueCount = 0
        var excludedVolumes = 0
        let prefix = path == "/" ? "/" : path + "/"
        func issue(_ url: URL, _ message: String) {
            issueCount += 1
            if issues.count < 500 { issues.append(ScanIssue(path: url.path, message: message)) }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { url, error in issue(url, error.localizedDescription); return true }
        ) else { throw ScannerError.enumerationFailed(directory.path) }
        while let url = enumerator.nextObject() as? URL {
            if cancelled() { throw CancellationError() }
            var entry = stat()
            let ok = url.withUnsafeFileSystemRepresentation { p -> Bool in
                guard let p else { return false }
                return lstat(p, &entry) == 0
            }
            guard ok else {
                issue(url, String(cString: strerror(errno)))
                continue
            }
            let kind = entry.st_mode & mode_t(S_IFMT)
            if stayOnVolume && entry.st_dev != metadata.st_dev {
                excludedVolumes += 1
                if kind == mode_t(S_IFDIR) { enumerator.skipDescendants() }
                continue
            }
            guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK) else { continue }
            // DirectoryEnumerator does not follow symbolic links. Do not call
            // skipDescendants for a non-directory: it can skip a later subtree.
            let relativePath = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            files.append(DirectoryFile(
                url: url, relativePath: relativePath, logicalBytes: max(0, Int64(entry.st_size)),
                allocatedBytes: max(0, Int64(entry.st_blocks) * 512),
                isSymbolicLink: kind == mode_t(S_IFLNK)
            ))
        }
        if cancelled() { throw CancellationError() }
        return DirectoryFileListing(files: files, issues: issues, issueCount: issueCount, excludedVolumes: excludedVolumes)
    }
}
