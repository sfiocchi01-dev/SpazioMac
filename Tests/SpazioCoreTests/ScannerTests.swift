import Foundation
import SpazioCore

struct CheckFailure: Error { let message: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}

@main
struct ScannerChecks {
    static func main() throws {
        let tests: [(String, (URL) throws -> Void)] = [
            ("Totali annidati e file nascosti", nested),
            ("Hard link senza doppio conteggio", hardLink),
            ("Link simbolico ciclico non seguito", symlink),
            ("File sparso: logica e allocazione", sparse),
            ("Annullamento e limite directory", cancellation),
            ("Top file e directory non valida", largest),
            ("File ricorsivi, percorsi relativi e nessun limite top 100", recursiveFiles),
            ("Link nella directory senza seguire i target", directLinks),
            ("Cambio cartella, errori e annullamento lettura", listingChanges)
        ]
        for (name, test) in tests {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            try test(folder)
            print("PASS: \(name)")
        }
        print("\(tests.count) verifiche superate")
    }
    static func file(_ root: URL, _ path: String, size: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: size).write(to: url)
    }
    static func nested(_ root: URL) throws {
        try file(root, "a/one", size: 10)
        try file(root, "a/b/two", size: 20)
        try file(root, ".hidden", size: 7)
        let result = try DiskScanner().scan(root)
        let details = result.issues.map { $0.path + ": " + $0.message }
        try expect(result.root.logicalBytes == 37, "Totale logico errato: \(result.root.logicalBytes); visite \(result.visited); errori \(details)")
        try expect(result.root.fileCount == 3, "Numero file errato")
        try expect(result.root.directoryCount == 2, "Numero cartelle errato")
        try expect(result.root.children.first?.logicalBytes == 30, "Aggregazione annidata errata")
        try expect(!result.incomplete, "Scansione segnalata incompleta")
    }
    static func hardLink(_ root: URL) throws {
        try file(root, "a", size: 4096)
        try FileManager.default.linkItem(at: root.appendingPathComponent("a"), to: root.appendingPathComponent("b"))
        let result = try DiskScanner().scan(root)
        try expect(result.root.logicalBytes == 4096 && result.root.fileCount == 2, "Hard link conteggiato due volte")
        try expect(result.duplicateHardLinks == 1, "Deduplicazione hard link errata")
    }
    static func symlink(_ root: URL) throws {
        try file(root, "nested/file", size: 11)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("nested/loop"), withDestinationURL: root)
        let result = try DiskScanner().scan(root)
        try expect(result.root.logicalBytes == 11, "Seguito link simbolico")
        try expect(result.symbolicLinks == 1 && result.root.directoryCount == 1, "Ciclo o conteggio errato")
    }
    static func sparse(_ root: URL) throws {
        let url = root.appendingPathComponent("sparse")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 16 * 1024 * 1024)
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        let result = try DiskScanner().scan(root)
        try expect(result.root.logicalBytes == 16 * 1024 * 1024 + 1, "Dimensione sparsa errata")
        try expect(result.root.allocatedBytes < result.root.logicalBytes, "Allocazione file sparso errata")
    }
    static func cancellation(_ root: URL) throws {
        do {
            _ = try DiskScanner().scan(root, cancelled: { true })
            throw CheckFailure(message: "Annullamento ignorato")
        } catch is CancellationError { }
        try file(root, "a/b/file", size: 20)
        let result = try DiskScanner().scan(root, options: ScannerOptions(maxDirectories: 1))
        try expect(result.directoryLimitReached && result.incomplete, "Limite non segnalato")
        try expect(result.directories.count == 1, "Limite non rispettato")
    }
    static func recursiveFiles(_ root: URL) throws {
        try file(root, "top", size: 10)
        try file(root, ".hidden", size: 7)
        try file(root, "nested/inside", size: 20)
        try file(root, "nested/deeper/deep", size: 30)
        let reader = DirectoryFileReader()
        let top = try reader.list(root)
        try expect(Set(top.files.map { $0.relativePath }) == ["top", ".hidden", "nested/inside", "nested/deeper/deep"], "La lista perde file annidati, nascosti o percorsi relativi")
        try expect(top.files.first { $0.relativePath == "nested/deeper/deep" }?.logicalBytes == 30, "Metadati del file annidato errati")
        try expect(top.issueCount == 0, "Errori inattesi nella lettura")
        let nested = try reader.list(root.appendingPathComponent("nested"))
        try expect(Set(nested.files.map { $0.relativePath }) == ["inside", "deeper/deep"], "La selezione non limita il sottoalbero o perde i discendenti")
        for i in 0..<125 { try file(root, "many/entry\(i)", size: 1) }
        let many = try reader.list(root.appendingPathComponent("many"))
        try expect(many.files.count == 125, "La lista è ancora limitata ai top 100")
        try file(root, "left/same.txt", size: 4)
        try file(root, "right/same.txt", size: 8)
        let repeatedNames = try reader.list(root)
        let same = repeatedNames.files.filter { $0.url.lastPathComponent == "same.txt" }
        try expect(Set(same.map { $0.relativePath }) == ["left/same.txt", "right/same.txt"], "I file omonimi non si distinguono")
        try expect(Set(same.map { $0.id }).count == 2, "Identità dei file annidati duplicate")
    }
    static func directLinks(_ root: URL) throws {
        try file(root, "original", size: 1024)
        try file(root, "sub/file", size: 5)
        try FileManager.default.linkItem(at: root.appendingPathComponent("original"), to: root.appendingPathComponent("hard"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("directory-link"), withDestinationURL: root.appendingPathComponent("sub"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("broken-link"), withDestinationURL: root.appendingPathComponent("missing"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sub/loop"), withDestinationURL: root)
        let listing = try DirectoryFileReader().list(root)
        let paths = Set(listing.files.map { $0.relativePath })
        try expect(paths == ["original", "hard", "directory-link", "broken-link", "sub/file", "sub/loop"], "Link seguiti, ciclo o file ricorsivi mancanti: \(paths.sorted())")
        try expect(listing.files.filter { $0.isSymbolicLink }.count == 3, "Tipo link errato")
        try expect(listing.files.first { $0.url.lastPathComponent == "hard" }?.logicalBytes == 1024, "La singola voce hard link non mostra la propria dimensione")
        let scanned = try DiskScanner().scan(root)
        try expect(scanned.root.logicalBytes == 1029, "Un link simbolico fa saltare una sottocartella durante la scansione")
    }
    static func listingChanges(_ root: URL) throws {
        let reader = DirectoryFileReader()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        for i in 0..<10 { try file(root, "full/file\(i)", size: 3) }
        try file(root, "sibling/other", size: 5)
        try file(root, "full/nested/deep", size: 7)
        let all = try reader.list(root)
        let full = try reader.list(root.appendingPathComponent("full"))
        try expect(all.files.count == 12 && full.files.count == 11, "Cambio selezione non limita il sottoalbero")
        try expect(!full.files.contains { $0.relativePath.contains("sibling") }, "File della directory sorella inclusi")
        let empty = try reader.list(root.appendingPathComponent("empty"))
        try expect(full.files.count == 11 && empty.files.isEmpty, "File della cartella precedente rimasti nella nuova lista")
        do {
            _ = try reader.list(root, cancelled: { true })
            throw CheckFailure(message: "Annullamento lettura ignorato")
        } catch is CancellationError { }
        var checks = 0
        do {
            _ = try reader.list(root.appendingPathComponent("full"), cancelled: { checks += 1; return checks > 3 })
            throw CheckFailure(message: "Annullamento durante lettura ignorato")
        } catch is CancellationError { }
        do {
            _ = try reader.list(root.appendingPathComponent("full/file0"))
            throw CheckFailure(message: "Accettato file come directory della lista")
        } catch is ScannerError { }
        do {
            _ = try reader.list(root.appendingPathComponent("removed"))
            throw CheckFailure(message: "Directory inesistente ignorata")
        } catch is ScannerError { }
    }
    static func largest(_ root: URL) throws {
        for i in 1...250 { try file(root, "file\(i)", size: i * 1024) }
        let result = try DiskScanner().scan(root, options: ScannerOptions(largestFileCount: 5))
        try expect(result.largestFiles.count == 5, "Limite top file errato")
        try expect(result.largestFiles.first?.url.lastPathComponent == "file250", "Top file errato")
        do {
            _ = try DiskScanner().scan(root.appendingPathComponent("file1"))
            throw CheckFailure(message: "Accettato file al posto di directory")
        } catch is ScannerError { }
    }
}
