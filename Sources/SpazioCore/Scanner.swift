import Foundation
import Darwin

public enum SizeMetric: String, CaseIterable, Sendable {
    case allocated = "Su disco"
    case logical = "Logica"
}

/// Mutated only during the scan; the completed tree is then handed to the UI.
public final class DirectoryNode: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let url: URL
    public weak var parent: DirectoryNode?
    public private(set) var children: [DirectoryNode] = []
    public private(set) var logicalBytes: Int64 = 0
    public private(set) var allocatedBytes: Int64 = 0
    public private(set) var fileCount = 0
    public private(set) var directoryCount = 0
    public var name: String { url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent }
    public func bytes(_ metric: SizeMetric) -> Int64 {
        metric == .allocated ? allocatedBytes : logicalBytes
    }
    fileprivate init(url: URL, parent: DirectoryNode? = nil, allocated: Int64 = 0) {
        self.url = url
        self.parent = parent
        self.allocatedBytes = allocated
    }
    fileprivate func add(_ child: DirectoryNode) { children.append(child) }
    fileprivate func addFile(logical: Int64, allocated: Int64) {
        logicalBytes += logical
        allocatedBytes += allocated
        fileCount += 1
    }
    fileprivate func aggregate() {
        for child in children {
            logicalBytes += child.logicalBytes
            allocatedBytes += child.allocatedBytes
            fileCount += child.fileCount
            directoryCount += 1 + child.directoryCount
        }
    }
}

public struct ScanIssue: Identifiable, Sendable {
    public let id = UUID()
    public let path: String
    public let message: String
}

public struct LargeFile: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
}

public struct ScanProgress: Sendable {
    public let visited: Int
    public let path: String
}

public struct ScanResult: Sendable {
    public let root: DirectoryNode
    public let directories: [DirectoryNode]
    public let largestFiles: [LargeFile]
    public let issues: [ScanIssue]
    public let issueCount: Int
    public let excludedVolumes: Int
    public let duplicateHardLinks: Int
    public let symbolicLinks: Int
    public let elapsed: TimeInterval
    public let visited: Int
    public let directoryLimitReached: Bool
    public var incomplete: Bool { issueCount > 0 || directoryLimitReached || excludedVolumes > 0 }
}

public struct ScannerOptions: Sendable {
    public var stayOnVolume = true
    public var maxDirectories = 200_000
    public var largestFileCount = 100
    public init(stayOnVolume: Bool = true, maxDirectories: Int = 200_000, largestFileCount: Int = 100) {
        self.stayOnVolume = stayOnVolume
        self.maxDirectories = maxDirectories
        self.largestFileCount = largestFileCount
    }
}

private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}

public enum ScannerError: LocalizedError {
    case invalidDirectory(String)
    case enumerationFailed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidDirectory(let p): return "La directory non è accessibile: \(p)"
        case .enumerationFailed(let p): return "Impossibile enumerare: \(p)"
        }
    }
}

public struct DiskScanner {
    public init() {}
    private func largerFile(_ a: LargeFile, _ b: LargeFile) -> Bool {
        if a.allocatedBytes != b.allocatedBytes { return a.allocatedBytes > b.allocatedBytes }
        if a.logicalBytes != b.logicalBytes { return a.logicalBytes > b.logicalBytes }
        return a.url.path < b.url.path
    }

    /// Metadata only: does not open file contents, follow symlinks, delete or change files.
    public func scan(
        _ selectedURL: URL,
        options: ScannerOptions = ScannerOptions(),
        cancelled: () -> Bool = { false },
        progress: (ScanProgress) -> Void = { _ in }
    ) throws -> ScanResult {
        let start = Date()
        // Foundation may shorten /private/var to /var while its enumerator emits
        // /private/var children. POSIX realpath keeps parent keys consistent.
        guard let canonical = selectedURL.withUnsafeFileSystemRepresentation({ path -> UnsafeMutablePointer<CChar>? in
            guard let path else { return nil }
            return realpath(path, nil)
        }) else { throw ScannerError.invalidDirectory(selectedURL.path) }
        let canonicalPath = String(cString: canonical)
        free(canonical)
        let rootURL = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        var rootStat = stat()
        guard rootURL.withUnsafeFileSystemRepresentation({ p in
            guard let p else { return false }
            return lstat(p, &rootStat) == 0
        }), (rootStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ScannerError.invalidDirectory(rootURL.path)
        }
        if cancelled() { throw CancellationError() }
        let root = DirectoryNode(url: rootURL, allocated: Int64(rootStat.st_blocks) * 512)
        var nodes: [String: DirectoryNode] = [rootURL.path: root]
        var ordered = [root]
        var hardLinks = Set<FileIdentity>()
        var issues: [ScanIssue] = []
        var issueCount = 0
        var excludedVolumes = 0
        var duplicates = 0
        var symlinks = 0
        var visited = 0
        var limited = false
        var largest: [LargeFile] = []
        let largestCount = max(0, options.largestFileCount)
        var lastProgress = Date.distantPast
        func issue(_ url: URL, _ message: String) {
            issueCount += 1
            if issues.count < 500 { issues.append(ScanIssue(path: url.path, message: message)) }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { url, error in
                issue(url, error.localizedDescription)
                return true
            }
        ) else { throw ScannerError.enumerationFailed(rootURL.path) }

        while let url = enumerator.nextObject() as? URL {
            if cancelled() { throw CancellationError() }
            visited += 1
            if Date().timeIntervalSince(lastProgress) > 0.15 {
                progress(ScanProgress(visited: visited, path: url.path))
                lastProgress = Date()
            }
            var metadata = stat()
            let ok = url.withUnsafeFileSystemRepresentation { p -> Bool in
                guard let p else { return false }
                return lstat(p, &metadata) == 0
            }
            if !ok {
                issue(url, String(cString: strerror(errno)))
                enumerator.skipDescendants()
                continue
            }
            let type = metadata.st_mode & mode_t(S_IFMT)
            // Cross-volume entries are excluded rather than counted twice through mounts.
            if options.stayOnVolume && metadata.st_dev != rootStat.st_dev {
                excludedVolumes += 1
                if type == mode_t(S_IFDIR) { enumerator.skipDescendants() }
                continue
            }
            guard let parent = nodes[url.deletingLastPathComponent().path] else {
                issue(url, "Directory padre non disponibile; voce esclusa.")
                if type == mode_t(S_IFDIR) { enumerator.skipDescendants() }
                continue
            }
            if type == mode_t(S_IFDIR) {
                if ordered.count >= max(1, options.maxDirectories) {
                    limited = true
                    enumerator.skipDescendants()
                    continue
                }
                let child = DirectoryNode(url: url, parent: parent, allocated: Int64(metadata.st_blocks) * 512)
                parent.add(child)
                nodes[url.path] = child
                ordered.append(child)
            } else if type == mode_t(S_IFLNK) {
                symlinks += 1
                // Count the link's own blocks, never the linked target's contents.
                parent.addFile(logical: 0, allocated: Int64(metadata.st_blocks) * 512)
                // DirectoryEnumerator already avoids following symbolic links.
            } else if type == mode_t(S_IFREG) {
                let identity = FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
                if metadata.st_nlink > 1 && !hardLinks.insert(identity).inserted {
                    duplicates += 1
                    parent.addFile(logical: 0, allocated: 0)
                    continue
                }
                let logical = max(0, Int64(metadata.st_size))
                let allocated = max(0, Int64(metadata.st_blocks) * 512)
                parent.addFile(logical: logical, allocated: allocated)
                if largestCount > 0 {
                    largest.append(LargeFile(url: url, logicalBytes: logical, allocatedBytes: allocated))
                    // Bounded candidate list; no need to keep every file in memory.
                    if largest.count >= max(200, largestCount * 2) {
                        largest.sort(by: largerFile)
                        largest = Array(largest.prefix(largestCount))
                    }
                }
            }
        }
        if cancelled() { throw CancellationError() }
        // Enumeration is parent-first. Aggregate descendants exactly once, bottom-up.
        for node in ordered.reversed() { node.aggregate() }
        largest.sort(by: largerFile)
        progress(ScanProgress(visited: visited, path: rootURL.path))
        return ScanResult(
            root: root, directories: ordered,
            largestFiles: Array(largest.prefix(largestCount)),
            issues: issues, issueCount: issueCount, excludedVolumes: excludedVolumes,
            duplicateHardLinks: duplicates, symbolicLinks: symlinks,
            elapsed: Date().timeIntervalSince(start), visited: visited,
            directoryLimitReached: limited
        )
    }
}
