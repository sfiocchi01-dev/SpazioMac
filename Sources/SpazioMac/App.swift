import SwiftUI
import AppKit
import SpazioCore

private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

@MainActor
final class ScanModel: ObservableObject {
    @Published var result: ScanResult?
    @Published var selected: DirectoryNode? {
        didSet { if oldValue?.id != selected?.id { loadSelectedFiles() } }
    }
    @Published var selectedFiles: [DirectoryFile] = []
    @Published var loadingFiles = false
    @Published var fileListStatus = "Seleziona una cartella nell'albero."
    @Published var fileListDetails = ""
    @Published var running = false
    @Published var status = "Scegli una cartella o un volume da analizzare."
    @Published var progressPath = ""
    @Published var currentURL: URL?
    @Published var metric = SizeMetric.allocated {
        didSet { if oldValue != metric { selectedFiles = sortedFiles(selectedFiles) } }
    }
    @Published var search = ""
    @Published var stayOnVolume = true
    @Published var showIssues = false
    private var worker: Task<ScanResult, Error>?
    private var generation = UUID()
    private var fileWorker: Task<DirectoryFileListing, Error>?
    private var fileGeneration = UUID()
    private var scanStaysOnVolume = true

    private func sortedFiles(_ files: [DirectoryFile]) -> [DirectoryFile] {
        files.sorted {
            let left = $0.bytes(metric), right = $1.bytes(metric)
            if left != right { return left > right }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private func loadSelectedFiles() {
        fileWorker?.cancel()
        let token = UUID()
        fileGeneration = token
        selectedFiles = []
        fileListDetails = ""
        guard let directory = selected?.url else {
            fileWorker = nil
            loadingFiles = false
            fileListStatus = "Seleziona una cartella nell'albero."
            return
        }
        loadingFiles = true
        fileListStatus = "Lettura dei file della cartella e delle sottocartelle…"
        // Reacquire the selected root's scope for this independent, on-demand read.
        let scopeURL = currentURL ?? directory
        let scoped = scopeURL.startAccessingSecurityScopedResource()
        let stayOnVolume = scanStaysOnVolume
        let task = Task.detached(priority: .userInitiated) {
            defer { if scoped { scopeURL.stopAccessingSecurityScopedResource() } }
            return try DirectoryFileReader().list(directory, stayOnVolume: stayOnVolume, cancelled: { Task.isCancelled })
        }
        fileWorker = task
        Task {
            do {
                let listing = try await task.value
                guard fileGeneration == token else { return }
                selectedFiles = sortedFiles(listing.files)
                fileListStatus = "\(listing.files.count.formatted()) file/link · incluse tutte le sottocartelle"
                if listing.excludedVolumes > 0 {
                    fileListStatus += " · \(listing.excludedVolumes) voci di altri volumi escluse"
                }
                if listing.issueCount > 0 {
                    fileListStatus += " · \(listing.issueCount) errori di lettura"
                    fileListDetails = listing.issues.map { $0.path + ": " + $0.message }.joined(separator: "\n")
                }
            } catch {
                guard fileGeneration == token else { return }
                fileListStatus = error is CancellationError ? "Lettura annullata." : "Impossibile leggere i file: \(error.localizedDescription)"
            }
            guard fileGeneration == token else { return }
            loadingFiles = false
            fileWorker = nil
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Scegli cosa analizzare"
        panel.prompt = "Analizza"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    func scan(_ url: URL) {
        worker?.cancel()
        let token = UUID()
        generation = token
        currentURL = url
        result = nil
        selected = nil
        search = ""
        running = true
        progressPath = url.path
        status = "Scansione in corso…"
        scanStaysOnVolume = stayOnVolume
        let options = ScannerOptions(stayOnVolume: stayOnVolume, largestFileCount: 0)
        let scoped = url.startAccessingSecurityScopedResource()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try DiskScanner().scan(url, options: options, cancelled: { Task.isCancelled }) { update in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.running else { return }
                    self.status = "\(update.visited.formatted()) voci esaminate"
                    self.progressPath = update.path
                }
            }
        }
        worker = task
        Task {
            do {
                let scanned = try await task.value
                guard generation == token else { return }
                result = scanned
                selected = scanned.root
                status = "\(scanned.root.directoryCount.formatted()) cartelle · \(scanned.root.fileCount.formatted()) file/link · \(String(format: "%.1f", scanned.elapsed)) s"
            } catch is CancellationError {
                guard generation == token else { return }
                status = "Scansione annullata. Nessun file modificato."
            } catch {
                guard generation == token else { return }
                status = error.localizedDescription
            }
            guard generation == token else { return }
            running = false
            worker = nil
            progressPath = ""
        }
    }
    func cancel() { worker?.cancel() }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

@main
struct SpazioMacApp: App {
    @StateObject private var model = ScanModel()
    var body: some Scene {
        WindowGroup("SpazioMac") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 640)
        }
        .defaultSize(width: 1160, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Analizza cartella…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Aggiorna scansione") {
                    if let url = model.currentURL { model.scan(url) }
                }.keyboardShortcut("r").disabled(model.currentURL == nil || model.running)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: ScanModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                Image(systemName: "internaldrive.fill").font(.system(size: 36)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.currentURL?.lastPathComponent.isEmpty == false
                         ? model.currentURL!.lastPathComponent : "Analisi spazio su disco")
                        .font(.title2.bold())
                    Text(model.currentURL?.path ?? "Scansione locale, solo lettura, nessuna telemetria")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if let result = model.result {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(bytes(result.root.bytes(model.metric))).font(.title.monospacedDigit().bold())
                        Text(model.metric == .allocated ? "allocati nella scansione" : "dimensione logica contabilizzata")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(20)
            Divider()
            HStack {
                Picker("Dimensione", selection: $model.metric) {
                    ForEach(SizeMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 210)
                Toggle("Resta sul volume selezionato", isOn: $model.stayOnVolume)
                    .toggleStyle(.checkbox).disabled(model.running)
                    .help("Si applica alla prossima scansione. Esclude gli altri volumi montati.")
                Spacer()
                TextField("Cerca una cartella…", text: $model.search)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .disabled(model.result == nil)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            if model.running {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.status).font(.headline)
                    Text(model.progressPath).font(.caption.monospaced())
                        .foregroundStyle(.secondary).lineLimit(2)
                    Text("Leggo i metadati, non il contenuto dei file.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
            } else if let result = model.result {
                if result.incomplete {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Risultato parziale: \(result.issueCount) errori, \(result.excludedVolumes) voci di altri volumi escluse\(result.directoryLimitReached ? ", limite cartelle raggiunto" : "").")
                            .font(.caption)
                        Spacer()
                        Button("Dettagli") { model.showIssues = true }
                    }.padding(10).background(Color.orange.opacity(0.08))
                }
                DirectoryOutline(root: result.root, allNodes: result.directories,
                                 metric: model.metric, search: model.search) { model.selected = $0 }
                    .frame(minHeight: 200)
                Divider()
                HStack {
                    Text(model.selected?.url.path ?? "")
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Mostra nel Finder") {
                        if let node = model.selected { model.reveal(node.url) }
                    }.disabled(model.selected == nil)
                }.padding(10)
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.selected.map { "File in \($0.name) e sottocartelle" } ?? "File della cartella selezionata")
                            .font(.caption.bold())
                        if model.loadingFiles { ProgressView().controlSize(.mini) }
                        Spacer()
                        Text(model.fileListStatus).font(.caption).foregroundStyle(.secondary)
                            .help(model.fileListDetails.isEmpty ? model.fileListStatus : model.fileListDetails)
                    }.padding(.horizontal, 12)
                    Table(model.selectedFiles) {
                        TableColumn("File") { file in
                            HStack {
                                if file.isSymbolicLink { Image(systemName: "arrow.turn.up.right").foregroundStyle(.secondary) }
                                Text(file.url.lastPathComponent)
                            }.help(file.url.path)
                        }
                        TableColumn("Percorso relativo") { file in
                            Text(file.relativePath).lineLimit(1).truncationMode(.middle).help(file.url.path)
                        }
                        TableColumn("Su disco") { Text(bytes($0.allocatedBytes)).monospacedDigit() }.width(110)
                        TableColumn("Logica") { Text(bytes($0.logicalBytes)).monospacedDigit() }.width(110)
                        TableColumn("Finder") { file in
                            Button { model.reveal(file.url) } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless).help("Mostra nel Finder")
                        }.width(50)
                    }.frame(height: 160)
                    if !model.loadingFiles && model.selected != nil && model.selectedFiles.isEmpty {
                        Text("Nessun file disponibile nella cartella selezionata o nelle sue sottocartelle.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }
                }.padding(.top, 8)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.magnifyingglass").font(.system(size: 60)).foregroundStyle(.secondary)
                    Text("Scopri quali cartelle occupano più spazio").font(.title2)
                    Button("Scegli una cartella…") { model.chooseFolder() }.controlSize(.large)
                    Text("Nessun file viene eliminato. Le cartelle protette richiedono i permessi di macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(model.status).lineLimit(1)
                Spacer()
                Text("APFS: spazio allocato ≠ spazio liberabile").help("Cloni, snapshot e dati condivisi non sono attribuibili esattamente a ogni directory.")
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .toolbar {
            Button { model.chooseFolder() } label: { Label("Scegli cartella", systemImage: "folder.badge.plus") }
                .disabled(model.running)
            Button {
                if let url = model.currentURL { model.scan(url) }
            } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }
                .disabled(model.currentURL == nil || model.running)
            if model.running {
                Button("Annulla", role: .cancel) { model.cancel() }
            }
        }
        .sheet(isPresented: $model.showIssues) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Limiti della scansione").font(.title2.bold())
                Text("I risultati includono solo ciò che è stato possibile leggere. Per le cartelle protette puoi concedere Accesso completo al disco a SpazioMac nelle Impostazioni di Sistema, quindi riaprire l'app.")
                Text("Con “Resta sul volume” attivo, una scansione di / può escludere i dati utente su APFS. Seleziona direttamente la tua cartella utente o /System/Volumes/Data. Attraversare tutti i volumi può invece contare più volte percorsi condivisi.")
                Text("Gli hard link sono contabilizzati una sola volta: i byte vengono attribuiti alla prima directory incontrata. I link simbolici non vengono seguiti. I file cloud non scaricati riflettono i metadati disponibili, non uno scaricamento del contenuto.")
                if let result = model.result {
                    Text("\(result.duplicateHardLinks) hard link già conteggiati · \(result.symbolicLinks) link simbolici")
                    List(result.issues) { issue in
                        VStack(alignment: .leading) {
                            Text(issue.path).font(.caption.monospaced()).textSelection(.enabled)
                            Text(issue.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if result.issueCount > result.issues.count {
                        Text("Mostrati i primi \(result.issues.count) errori su \(result.issueCount).")
                    }
                }
                Button("Chiudi") { model.showIssues = false }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 760, height: 500)
        }
    }
}

struct DirectoryOutline: NSViewRepresentable {
    let root: DirectoryNode
    let allNodes: [DirectoryNode]
    let metric: SizeMetric
    let search: String
    let onSelection: (DirectoryNode?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let outline = NSOutlineView()
        outline.rowHeight = 28
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .fullWidth
        for (id, title, width) in [("name", "Cartella", 450.0), ("size", "Dimensione", 130.0),
                                   ("percent", "Quota del totale", 180.0), ("files", "File / link", 100.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 240 : 90
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.reveal)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        context.coordinator.outline = outline
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.configure(root: root, nodes: allNodes, metric: metric, search: search)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outline: NSOutlineView?
        var root: DirectoryNode?
        var metric = SizeMetric.allocated
        var children: [UUID: [DirectoryNode]] = [:]
        var signature = ""
        var reloading = false
        var onSelection: ((DirectoryNode?) -> Void)?

        func configure(root: DirectoryNode, nodes: [DirectoryNode], metric: SizeMetric, search: String) {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = root.id.uuidString + metric.rawValue + query
            guard signature != key, let outline else { return }
            let previous = outline.item(atRow: outline.selectedRow) as? DirectoryNode
            reloading = true
            defer { reloading = false }
            signature = key
            self.root = root
            self.metric = metric
            var visible = Set<UUID>()
            if !query.isEmpty {
                for node in nodes where node.name.localizedCaseInsensitiveContains(query) {
                    var current: DirectoryNode? = node
                    while let item = current, visible.insert(item.id).inserted { current = item.parent }
                }
            }
            children.removeAll(keepingCapacity: true)
            for node in nodes {
                children[node.id] = node.children.filter { query.isEmpty || visible.contains($0.id) }.sorted {
                    let left = $0.bytes(metric), right = $1.bytes(metric)
                    return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left > right
                }
            }
            outline.reloadData()
            outline.expandItem(root)
            if !query.isEmpty && visible.count < 500 { outline.expandItem(nil, expandChildren: true) }
            let target: DirectoryNode
            if let previous, (query.isEmpty || visible.contains(previous.id)),
               nodes.contains(where: { $0.id == previous.id }) {
                target = previous
                var ancestors: [DirectoryNode] = []
                var parent = previous.parent
                while let item = parent { ancestors.append(item); parent = item.parent }
                for ancestor in ancestors.reversed() { outline.expandItem(ancestor) }
            } else { target = root }
            let row = outline.row(forItem: target)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            // Avoid publishing SwiftUI state in updateNSView, and use the latest selection.
            DispatchQueue.main.async { [weak self, weak outline] in
                guard let self, let outline, self.signature == key else { return }
                self.onSelection?(outline.item(atRow: outline.selectedRow) as? DirectoryNode)
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let node = item as? DirectoryNode { return children[node.id]?.count ?? 0 }
            return root == nil ? 0 : 1
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? DirectoryNode { return children[node.id]![index] }
            return root!
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? DirectoryNode else { return false }
            return !(children[node.id] ?? []).isEmpty
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !reloading, let outline else { return }
            onSelection?(outline.item(atRow: outline.selectedRow) as? DirectoryNode)
        }
        @objc func reveal() {
            guard let outline, let node = outline.item(atRow: outline.clickedRow) as? DirectoryNode else { return }
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let column = tableColumn, let node = item as? DirectoryNode else { return nil }
            if column.identifier.rawValue == "percent" {
                let total = root?.bytes(metric) ?? 0
                let fraction = total > 0 ? Double(node.bytes(metric)) / Double(total) : 0
                let box = NSView(frame: NSRect(x: 0, y: 0, width: column.width, height: 28))
                let label = NSTextField(labelWithString: String(format: "%.1f %%", fraction * 100))
                label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                label.frame = NSRect(x: 4, y: 6, width: 65, height: 17)
                let bar = NSProgressIndicator(frame: NSRect(x: 74, y: 11, width: max(15, column.width - 84), height: 7))
                bar.isIndeterminate = false
                bar.maxValue = 1
                bar.doubleValue = min(1, max(0, fraction))
                box.addSubview(label)
                box.addSubview(bar)
                return box
            }
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: column.width, height: 28))
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: 13)
            switch column.identifier.rawValue {
            case "name":
                label.stringValue = node.name
                label.frame = NSRect(x: 27, y: 5, width: max(50, column.width - 55), height: 19)
                label.autoresizingMask = [.width]
                let image = NSImageView(frame: NSRect(x: 3, y: 6, width: 18, height: 18))
                image.image = NSImage(named: NSImage.folderName)
                cell.addSubview(image)
                cell.toolTip = node.url.path
            case "size":
                label.stringValue = bytes(node.bytes(metric))
                label.frame = NSRect(x: 4, y: 5, width: column.width - 12, height: 19)
                label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            default:
                label.stringValue = node.fileCount.formatted()
                label.frame = NSRect(x: 4, y: 5, width: column.width - 12, height: 19)
            }
            cell.textField = label
            cell.addSubview(label)
            return cell
        }
    }
}
