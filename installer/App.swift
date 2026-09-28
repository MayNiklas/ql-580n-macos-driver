import AppKit
import Foundation

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func appleScriptQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

final class SetupApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private let picker = NSPopUpButton(frame: .zero)
    private let address = NSTextField(string: "")
    private let printerName = NSTextField(string: "QL-580N macOS Driver")
    private let status = NSTextField(wrappingLabelWithString: "Looking for printers on your network...")
    private let spinner = NSProgressIndicator()
    private let checkButton = NSButton(title: "Check Connection", target: nil, action: nil)
    private let installButton = NSButton(title: "Install Printer", target: nil, action: nil)
    private let installedPicker = NSPopUpButton(frame: .zero)
    private let removeButton = NSButton(title: "Remove Selected Printer...", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let discovery = PrinterDiscovery()
    private var candidates: [PrinterCandidate] = []
    private var installedQueues: [InstalledQueue] = []
    private var busy = false
    private var userEdited = false
    private var operation = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let appMenu = NSMenu()
        let rootItem = NSMenuItem()
        let rootMenu = NSMenu()
        rootMenu.addItem(withTitle: "Quit QL-580N macOS Driver Setup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        rootItem.submenu = rootMenu
        appMenu.addItem(rootItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        appMenu.addItem(editItem)
        NSApp.mainMenu = appMenu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "QL-580N macOS Driver Setup"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28)
        ])

        let heading = NSTextField(labelWithString: "Set up your label printer")
        heading.font = .systemFont(ofSize: 25, weight: .semibold)
        stack.addArrangedSubview(heading)
        let intro = NSTextField(wrappingLabelWithString: "Choose a Brother QL-580N or enter its network address.")
        intro.textColor = .secondaryLabelColor
        stack.addArrangedSubview(intro)

        stack.addArrangedSubview(label("Available printers"))
        picker.addItem(withTitle: "Searching for printers...")
        picker.target = self
        picker.action = #selector(selectPrinter)
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        let discoveryRow = NSStackView(views: [picker, refreshButton])
        discoveryRow.orientation = .horizontal
        discoveryRow.spacing = 8
        stack.addArrangedSubview(discoveryRow)
        discoveryRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(label("IP address or hostname"))
        address.placeholderString = "For example: 192.168.1.25 or printer.local"
        address.delegate = self
        address.setAccessibilityIdentifier("PrinterAddress")
        stack.addArrangedSubview(address)
        address.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(label("Name in the print dialog"))
        printerName.delegate = self
        printerName.setAccessibilityIdentifier("PrinterDisplayName")
        stack.addArrangedSubview(printerName)
        printerName.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("PrinterSetupStatus")
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 8
        stack.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 55).isActive = true

        let note = NSTextField(wrappingLabelWithString: "Installation requires administrator authentication. Existing printer preferences are kept.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)

        checkButton.target = self
        checkButton.action = #selector(checkConnection)
        installButton.target = self
        installButton.action = #selector(installPrinter)
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [checkButton, installButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        stack.addArrangedSubview(buttons)

        stack.addArrangedSubview(label("Installed driver queues"))
        installedPicker.setAccessibilityIdentifier("InstalledPrinterQueues")
        stack.addArrangedSubview(installedPicker)
        installedPicker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        removeButton.target = self
        removeButton.action = #selector(confirmRemoval)
        stack.addArrangedSubview(removeButton)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        discovery.onUpdate = { [weak self] printers in self?.updateCandidates(printers) }
        discovery.start()
        refreshInstalledQueues()
        updateEnabled()
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func updateCandidates(_ printers: [PrinterCandidate]) {
        candidates = printers
        picker.removeAllItems()
        if printers.isEmpty {
            picker.addItem(withTitle: "No printers found yet. Enter an address below.")
        } else {
            for printer in printers {
                picker.addItem(withTitle: "\(printer.name) - \(printer.host)")
            }
            if let index = printers.firstIndex(where: { $0.host == address.stringValue }) {
                picker.selectItem(at: index)
            } else if !userEdited && !busy {
                let index = printers.firstIndex(where: { $0.queue != nil }) ?? 0
                picker.selectItem(at: index)
                useCandidate(printers[index])
            }
        }
        updateEnabled()
    }

    private func useCandidate(_ printer: PrinterCandidate) {
        address.stringValue = printer.host
        if printer.queue != nil { printerName.stringValue = printer.name }
        else { printerName.stringValue = "QL-580N macOS Driver" }
        status.stringValue = printer.queue == nil ? "Ready to check this printer." : "This printer is already installed. Installation will update its driver and keep its preferences."
    }

    @objc private func selectPrinter() {
        guard candidates.indices.contains(picker.indexOfSelectedItem) else { return }
        userEdited = true
        useCandidate(candidates[picker.indexOfSelectedItem])
        updateEnabled()
    }

    @objc private func refresh() {
        status.stringValue = "Searching for printers. You can also enter an address manually."
        discovery.stop()
        discovery.start()
        refreshInstalledQueues()
    }

    func controlTextDidChange(_ notification: Notification) {
        userEdited = true
        status.stringValue = "Check the connection or install to verify the printer."
        status.textColor = .secondaryLabelColor
        updateEnabled()
    }

    private func updateEnabled() {
        let valid = (try? PrinterNetwork.validateHost(address.stringValue)) != nil
        checkButton.isEnabled = !busy && valid
        installButton.isEnabled = !busy && valid && !printerName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        installedPicker.isEnabled = !busy && !installedQueues.isEmpty
        removeButton.isEnabled = !busy && !installedQueues.isEmpty
        picker.isEnabled = !busy && !candidates.isEmpty
        refreshButton.isEnabled = !busy
        address.isEnabled = !busy
        printerName.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func checkConnection() { begin(install: false) }
    @objc private func installPrinter() { begin(install: true) }

    private func begin(install: Bool) {
        guard !busy else { return }
        do {
            let host = try PrinterNetwork.validateHost(address.stringValue)
            let name = printerName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let queue = candidates.first(where: { $0.host.lowercased() == host.lowercased() && $0.queue != nil })?.queue
            operation += 1
            let current = operation
            busy = true
            status.textColor = .secondaryLabelColor
            status.stringValue = "Checking \(host)..."
            updateEnabled()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try PrinterNetwork.probe(host: host)
                    if install {
                        DispatchQueue.main.async {
                            self.status.stringValue = "\(result.summary)\nInstalling printer. Complete the macOS administrator prompt."
                        }
                        try self.performInstall(host: host, name: name, queue: queue)
                    }
                    DispatchQueue.main.async {
                        guard current == self.operation else { return }
                        self.busy = false
                        self.status.textColor = .labelColor
                        self.status.stringValue = install
                            ? "Installed successfully. Select “\(name)” in your application's print dialog."
                            : "\(result.summary)\nConnection verified. Ready to install."
                        self.updateEnabled()
                        if install {
                            self.discovery.stop()
                            self.discovery.start()
                            self.refreshInstalledQueues()
                            let alert = NSAlert()
                            alert.messageText = "Printer is ready"
                            alert.informativeText = "Select “\(name)” in your application's print dialog. Reopen any print dialog that was already open."
                            alert.addButton(withTitle: "Done")
                            alert.beginSheetModal(for: self.window)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard current == self.operation else { return }
                        self.busy = false
                        self.status.textColor = .systemRed
                        self.status.stringValue = error.localizedDescription
                        self.updateEnabled()
                    }
                }
            }
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    private func performInstall(host: String, name: String, queue: String?) throws {
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "Setup", code: 1, userInfo: [NSLocalizedDescriptionKey: "The installer payload is missing. Download a complete copy of the setup app."])
        }
        let staging = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ql580n-setup-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        for relative in ["scripts/install.sh", "build/rastertoql580n",
                         "ppd/Brother-QL-580N-Native.ppd", "assets/ql580n-native.icns"] {
            let target = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: resources.appendingPathComponent("payload").appendingPathComponent(relative), to: target)
        }
        var arguments = ["/bin/bash", staging.appendingPathComponent("scripts/install.sh").path,
                         "--host", host, "--name", name]
        if let queue = queue { arguments += ["--queue", queue] }
        try runAsAdministrator(arguments, action: "Installation")
    }

    private func refreshInstalledQueues() {
        let selectedQueue = installedQueues.indices.contains(installedPicker.indexOfSelectedItem)
            ? installedQueues[installedPicker.indexOfSelectedItem].queue : nil
        installedQueues = PrinterNetwork.installedQueues()
        installedPicker.removeAllItems()
        if installedQueues.isEmpty {
            installedPicker.addItem(withTitle: "No QL-580N driver queues installed")
        } else {
            for printer in installedQueues {
                installedPicker.addItem(withTitle: "\(printer.name) (\(printer.queue))")
            }
            if let selectedQueue, let index = installedQueues.firstIndex(where: { $0.queue == selectedQueue }) {
                installedPicker.selectItem(at: index)
            }
        }
        updateEnabled()
    }

    @objc private func confirmRemoval() {
        guard !busy, installedQueues.indices.contains(installedPicker.indexOfSelectedItem) else { return }
        let printer = installedQueues[installedPicker.indexOfSelectedItem]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(printer.name)?"
        alert.informativeText = "This removes the printer queue \(printer.queue) from this Mac. Shared driver files remain if another QL-580N driver queue uses them."
        alert.addButton(withTitle: "Remove Printer")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.removePrinter(printer) }
        }
    }

    private func removePrinter(_ printer: InstalledQueue) {
        guard !busy else { return }
        operation += 1
        let current = operation
        busy = true
        status.textColor = .secondaryLabelColor
        status.stringValue = "Removing \(printer.name). Complete the macOS administrator prompt."
        updateEnabled()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.performUninstall(queue: printer.queue)
                DispatchQueue.main.async {
                    guard current == self.operation else { return }
                    self.busy = false
                    self.status.textColor = .labelColor
                    self.status.stringValue = "Removed \(printer.name) from this Mac."
                    self.discovery.stop()
                    self.discovery.start()
                    self.refreshInstalledQueues()
                }
            } catch {
                DispatchQueue.main.async {
                    guard current == self.operation else { return }
                    self.busy = false
                    self.status.textColor = .systemRed
                    self.status.stringValue = error.localizedDescription
                    self.refreshInstalledQueues()
                }
            }
        }
    }

    private func performUninstall(queue: String) throws {
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "Setup", code: 1, userInfo: [NSLocalizedDescriptionKey: "The uninstaller payload is missing. Download a complete copy of the setup app."])
        }
        let staging = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ql580n-uninstall-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let script = staging.appendingPathComponent("uninstall.sh")
        try fm.copyItem(at: resources.appendingPathComponent("payload/scripts/uninstall.sh"), to: script)
        try runAsAdministrator(["/bin/bash", script.path, "--queue", queue], action: "Removal")
    }

    private func runAsAdministrator(_ arguments: [String], action: String) throws {
        let shellCommand = arguments.map(shellQuote).joined(separator: " ")
        let script = "do shell script \(appleScriptQuote(shellCommand)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8) ?? "\(action) failed."
            let explanation = message.contains("(-128)") ? "\(action) cancelled." : "\(action) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
            throw NSError(domain: "Setup", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: explanation])
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        busy ? .terminateCancel : .terminateNow
    }
}

@main
enum SetupLauncher {
    static func main() {
        let application = NSApplication.shared
        let delegate = SetupApp()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
