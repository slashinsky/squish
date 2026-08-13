import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Drop target

final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func folder(from sender: NSDraggingInfo) -> URL? {
        guard
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
            let first = urls.first
        else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folder(from: sender) != nil else { return [] }
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let url = folder(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)

        (highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.clear).setFill()
        path.fill()

        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = highlighted ? 2 : 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }
}

// MARK: - Main window

final class MainController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let dropView = DropView(frame: .zero)
    private let dropLabel = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(string: "2.0")
    private let chooseButton = NSButton()
    private let compressButton = NSButton()
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")

    private var inputFolder: URL?
    private var running = false

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()

        window.title = "Squish"
        window.delegate = self
        window.center()
        buildUI()
        setFolder(nil)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window.contentView else { return }

        dropView.frame = NSRect(x: 20, y: 176, width: 400, height: 128)
        dropView.onDrop = { [weak self] url in self?.setFolder(url) }
        content.addSubview(dropView)

        dropLabel.frame = NSRect(x: 32, y: 220, width: 376, height: 40)
        dropLabel.alignment = .center
        dropLabel.font = .systemFont(ofSize: 13)
        dropLabel.textColor = .secondaryLabelColor
        dropLabel.maximumNumberOfLines = 2
        dropLabel.lineBreakMode = .byTruncatingMiddle
        content.addSubview(dropLabel)

        chooseButton.frame = NSRect(x: 145, y: 188, width: 150, height: 24)
        chooseButton.title = "Choose Folder…"
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)
        content.addSubview(chooseButton)

        let sizeLabel = NSTextField(labelWithString: "Max size")
        sizeLabel.frame = NSRect(x: 20, y: 138, width: 62, height: 20)
        sizeLabel.alignment = .right
        content.addSubview(sizeLabel)

        sizeField.frame = NSRect(x: 90, y: 136, width: 56, height: 22)
        sizeField.alignment = .right
        content.addSubview(sizeField)

        let mbLabel = NSTextField(labelWithString: "MB")
        mbLabel.frame = NSRect(x: 152, y: 138, width: 40, height: 20)
        content.addSubview(mbLabel)

        compressButton.frame = NSRect(x: 290, y: 130, width: 130, height: 32)
        compressButton.title = "Compress"
        compressButton.bezelStyle = .rounded
        compressButton.keyEquivalent = "\r"
        compressButton.target = self
        compressButton.action = #selector(startCompression)
        content.addSubview(compressButton)

        progress.frame = NSRect(x: 20, y: 96, width: 400, height: 12)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.controlSize = .small
        progress.isHidden = true
        content.addSubview(progress)

        status.frame = NSRect(x: 20, y: 24, width: 400, height: 64)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 4
        status.lineBreakMode = .byWordWrapping
        content.addSubview(status)
    }

    // MARK: Folder selection

    private func setFolder(_ url: URL?) {
        inputFolder = url
        guard let url else {
            dropLabel.stringValue = "Drop a folder of photos here"
            compressButton.isEnabled = false
            return
        }
        let count = FolderScanner.images(in: url).count
        dropLabel.stringValue =
            "\(url.lastPathComponent)\n\(count) JPEG\(count == 1 ? "" : "s")"
        compressButton.isEnabled = count > 0
        status.stringValue =
            count > 0
            ? "Output: \(FolderScanner.outputFolder(for: url).lastPathComponent)"
            : "No .jpg or .jpeg files in that folder."
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the folder of photos to compress"
        if panel.runModal() == .OK, let url = panel.url {
            setFolder(url)
        }
    }

    // MARK: Run

    @objc private func startCompression() {
        guard !running, let input = inputFolder else { return }

        let megabytes = Double(sizeField.stringValue.replacingOccurrences(of: ",", with: "."))
        guard let megabytes, megabytes > 0 else {
            status.stringValue = "Enter a max size greater than 0."
            return
        }
        let maxBytes = Int(megabytes * 1024 * 1024)

        let files = FolderScanner.images(in: input)
        guard !files.isEmpty else { return }

        let output = FolderScanner.outputFolder(for: input)
        do {
            try FileManager.default.createDirectory(
                at: output, withIntermediateDirectories: true)
        } catch {
            status.stringValue = "Could not create output folder: \(error.localizedDescription)"
            return
        }

        running = true
        compressButton.isEnabled = false
        chooseButton.isEnabled = false
        sizeField.isEnabled = false
        progress.isHidden = false
        progress.maxValue = Double(files.count)
        progress.doubleValue = 0
        status.stringValue = "Compressing \(files.count) images…"

        let started = Date()
        var results = [Compressor.FileResult?](repeating: nil, count: files.count)
        let lock = NSLock()
        var completed = 0

        // Cap concurrency well below the core count. Each in-flight decode holds a
        // full 30 MP+ bitmap, and measurement showed 4 is actually faster than 6
        // here — past that, memory pressure and contention cost more than the
        // extra parallelism wins, while the fans work harder for nothing.
        let limit = max(2, min(ProcessInfo.processInfo.activeProcessorCount - 2, 4))
        let semaphore = DispatchSemaphore(value: limit)
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "compress.work", qos: .userInitiated, attributes: .concurrent)

        // The scheduling loop itself has to run off the main thread: semaphore.wait()
        // blocks once `limit` files are in flight, which would freeze the UI for the
        // entire run.
        DispatchQueue.global(qos: .userInitiated).async {
            for (index, file) in files.enumerated() {
                semaphore.wait()
                group.enter()
                queue.async {
                    let result = autoreleasepool {
                        Compressor.compress(
                            source: file,
                            destination: output.appendingPathComponent(file.lastPathComponent),
                            maxBytes: maxBytes)
                    }

                    lock.lock()
                    results[index] = result
                    completed += 1
                    let done = completed
                    lock.unlock()

                    DispatchQueue.main.async {
                        self.progress.doubleValue = Double(done)
                        self.status.stringValue =
                            "\(done) of \(files.count) — \(result.name)"
                    }

                    semaphore.signal()
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                self.finish(
                    results: results.compactMap { $0 }, output: output,
                    elapsed: Date().timeIntervalSince(started))
            }
        }
    }

    private func finish(
        results: [Compressor.FileResult], output: URL, elapsed: TimeInterval
    ) {
        running = false
        compressButton.isEnabled = true
        chooseButton.isEnabled = true
        sizeField.isEnabled = true
        progress.isHidden = true

        let failures = results.filter { $0.error != nil }
        let written = results.filter { $0.error == nil }
        let totalBytes = written.reduce(0) { $0 + $1.outputBytes }
        let overCap = written.filter(\.overCap)

        var lines = [
            "Done in \(String(format: "%.1f", elapsed))s — "
                + "\(written.count) image\(written.count == 1 ? "" : "s"), "
                + ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        ]
        let resized = written.filter(\.wasResized)
        if !resized.isEmpty {
            lines.append(
                "\(resized.count) scaled down to fit the cap (quality alone wasn't enough).")
        }
        if !overCap.isEmpty {
            lines.append("\(overCap.count) could not be brought under the cap.")
        }
        if !failures.isEmpty {
            lines.append("\(failures.count) failed: \(failures.prefix(3).map(\.name).joined(separator: ", "))")
        }
        status.stringValue = lines.joined(separator: "\n")

        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainController()
        controller.show()
        self.controller = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

let menu = NSMenu()
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(
    withTitle: "Quit Squish", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
menu.addItem(appMenuItem)

let editMenuItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(
    withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
menu.addItem(editMenuItem)

app.mainMenu = menu
app.run()
