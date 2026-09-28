import Foundation
import Darwin

struct PrinterCandidate {
    let name: String
    let host: String
    let queue: String?
}

struct InstalledQueue {
    let name: String
    let queue: String
}

struct PrinterProbe {
    let width: Int
    let length: Int
    let mediaType: Int
    let errors: UInt16

    var summary: String {
        if errors & 0x0004 != 0 { return "QL-580N found. Clear the cutter jam before printing." }
        if errors & 0x1000 != 0 { return "QL-580N found. Close the cover before printing." }
        if errors & 0x0003 != 0 || mediaType == 0 {
            return "QL-580N found. Load a label roll before printing."
        }
        if errors & 0x4000 != 0 { return "QL-580N found. Clear the media jam before printing." }
        if errors != 0 { return String(format: "QL-580N found. Printer reports error 0x%04X.", errors) }
        if length > 0 { return "QL-580N ready. \(width) x \(length) mm labels loaded." }
        return "QL-580N ready. \(width) mm continuous roll loaded."
    }
}

enum PrinterNetwork {
    private static let statusOID = ".1.3.6.1.4.1.2435.3.3.9.1.6.1.0"
    private static let deviceIDOID = ".1.3.6.1.4.1.2435.2.3.9.1.1.7.0"

    static func validateHost(_ raw: String) throws -> String {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 253,
              !host.contains(":"), !host.contains("/"), !host.contains("@"),
              !host.contains("?"), !host.contains("#"), !host.contains("%") else {
            throw NetworkError.message("Enter an IPv4 address or DNS name, such as printer.local.")
        }
        var address = in_addr()
        if inet_pton(AF_INET, host, &address) == 1 { return host }
        // Reject malformed dotted addresses rather than letting DNS interpret them.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            throw NetworkError.message("Enter a valid IPv4 address.")
        }
        let labels = host.hasSuffix(".") ? String(host.dropLast()).split(separator: ".", omittingEmptySubsequences: false) :
            host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            label.count >= 1 && label.count <= 63 &&
            label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { byte in
                (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
                (byte >= 48 && byte <= 57) || byte == 45
            }
        }) else {
            throw NetworkError.message("Enter a valid IPv4 address or DNS name.")
        }
        return host.hasSuffix(".") ? String(host.dropLast()).lowercased() : host.lowercased()
    }

    static func probe(host raw: String) throws -> PrinterProbe {
        let host = try validateHost(raw)
        let output: String
        do {
            output = try run("/usr/bin/snmpget", ["-v1", "-c", "public", "-t", "2", "-r", "0", "-Oqv", "-Ox", host, statusOID], timeout: 6)
        } catch {
            throw NetworkError.message("Could not read the printer at \(host) over SNMP (UDP 161). Allow Local Network access when macOS asks, then try again. Check the printer's address, power, and read-only 'public' community. \(error.localizedDescription)")
        }
        let data = try decodeHexStatus(output)
        guard data.count == 32, data[0] == 0x80, data[1] == 0x20,
              Array(data[2...5]) == Array("B430".utf8) else {
            throw NetworkError.message("The device at \(host) did not identify itself as a Brother QL-580N.")
        }
        let deviceIDOutput: String
        do {
            deviceIDOutput = try run("/usr/bin/snmpget", ["-v1", "-c", "public", "-t", "2", "-r", "0", "-Oqv", "-Ox", host, deviceIDOID], timeout: 6)
        } catch {
            throw NetworkError.message("Could not read the printer model at \(host) over SNMP. Check its address, network, and read-only 'public' community. \(error.localizedDescription)")
        }
        let deviceID = String(decoding: try decodeHexOctets(deviceIDOutput), as: UTF8.self)
            .split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard deviceID.split(separator: ";").contains(where: { $0 == "MDL:QL-580N" }) else {
            throw NetworkError.message("The device at \(host) is not a Brother QL-580N (reported: \(deviceID)).")
        }
        // An SNMP reply proves identity, but a disabled raw-print port would still fail installation.
        guard tcpPortOpen(host: host, port: 9100, timeout: 2) else {
            throw NetworkError.message("QL-580N found at \(host), but TCP port 9100 is closed or unreachable. Enable raw socket printing and check the network.")
        }
        return PrinterProbe(width: Int(data[10]), length: Int(data[17]),
                            mediaType: Int(data[11]),
                            errors: UInt16(data[8]) | UInt16(data[9]) << 8)
    }

    static func existingPrinters() -> [PrinterCandidate] {
        guard let output = try? run("/usr/bin/lpstat", ["-v"], timeout: 4) else { return [] }
        var printers: [PrinterCandidate] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.hasPrefix("device for "), let colon = text.range(of: ": "),
                  let url = URLComponents(string: String(text[colon.upperBound...])),
                  let host = url.host, let validatedHost = try? validateHost(host) else { continue }
            let name = String(text.dropFirst("device for ".count)[..<colon.lowerBound])
            let ppdPath = "/etc/cups/ppd/\(name).ppd"
            let ppd = (try? String(contentsOfFile: ppdPath, encoding: .utf8)) ?? ""
            let native = ppd.contains("*NickName: \"QL-580N macOS Driver CUPS Raster\"") ||
                ppd.contains("*NickName: \"Brother QL-580N Native CUPS Raster\"")
            guard native || name.localizedCaseInsensitiveContains("QL_580N") ||
                  name.localizedCaseInsensitiveContains("QL-580N") ||
                  ppd.localizedCaseInsensitiveContains("QL-580N") else { continue }
            let displayName = printerDescription(queue: name) ??
                (name == "Brother_QL_580N_Native" ? "Brother QL-580N (Native)" :
                    name.replacingOccurrences(of: "_", with: " "))
            printers.append(PrinterCandidate(name: displayName,
                                             host: validatedHost, queue: native ? name : nil))
        }
        return printers
    }

    static func installedQueues() -> [InstalledQueue] {
        guard let output = try? run("/usr/bin/lpstat", ["-v"], timeout: 4) else { return [] }
        var queues: [InstalledQueue] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.hasPrefix("device for "), let colon = text.range(of: ": ") else { continue }
            let queue = String(text.dropFirst("device for ".count)[..<colon.lowerBound])
            guard queue.count <= 127,
                  queue.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else { continue }
            let ppd = (try? String(contentsOfFile: "/etc/cups/ppd/\(queue).ppd", encoding: .utf8)) ?? ""
            guard ppd.contains("*NickName: \"QL-580N macOS Driver CUPS Raster\"") ||
                  ppd.contains("*NickName: \"Brother QL-580N Native CUPS Raster\"") else { continue }
            queues.append(InstalledQueue(name: printerDescription(queue: queue) ?? queue, queue: queue))
        }
        return queues.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func printerDescription(queue: String) -> String? {
        guard let details = try? run("/usr/bin/lpstat", ["-l", "-p", queue], timeout: 4) else { return nil }
        for line in details.split(whereSeparator: \.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard entry.hasPrefix("Description:") else { continue }
            let description = entry.dropFirst("Description:".count).trimmingCharacters(in: .whitespaces)
            if !description.isEmpty { return description }
        }
        return nil
    }

    private static func decodeHexStatus(_ output: String) throws -> [UInt8] {
        let bytes = try decodeHexOctets(output)
        guard bytes.count == 32 else {
            throw NetworkError.message("The printer returned an unexpected SNMP status response.")
        }
        return bytes
    }

    private static func decodeHexOctets(_ output: String) throws -> [UInt8] {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "\"", text.last == "\"" {
            text.removeFirst()
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.lowercased().hasPrefix("hex-string:") { text = String(text.dropFirst("hex-string:".count)) }
        let parts = text.split(whereSeparator: \.isWhitespace)
        let hex: String
        if parts.count == 1 {
            hex = String(parts[0]).replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        } else {
            let values = parts.map { String($0).replacingOccurrences(of: "0x", with: "", options: .caseInsensitive) }
            guard values.allSatisfy({ $0.count == 2 }) else {
                throw NetworkError.message("The printer returned an unexpected SNMP status format.")
            }
            hex = values.joined()
        }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.utf8.allSatisfy({ byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
        }) else {
            throw NetworkError.message("The printer returned an unexpected SNMP status response.")
        }
        let bytes = Array(hex.utf8)
        return stride(from: 0, to: bytes.count, by: 2).map { offset in
            UInt8(String(bytes: bytes[offset...offset + 1], encoding: .ascii)!, radix: 16)!
        }
    }

    private static func tcpPortOpen(host: String, port: UInt16, timeout: Int32) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &addresses) == 0 else { return false }
        defer { if let addresses { freeaddrinfo(addresses) } }
        var cursor = addresses
        while let item = cursor {
            let address = item.pointee
            let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            if fd >= 0 {
                let oldFlags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK)
                let result = connect(fd, address.ai_addr, address.ai_addrlen)
                if result == 0 { close(fd); return true }
                if errno == EINPROGRESS {
                    var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pollFD, 1, timeout * 1000) > 0 {
                        var socketError: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0 {
                            close(fd); return true
                        }
                    }
                }
                close(fd)
            }
            cursor = address.ai_next
        }
        return false
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume()
        process.waitUntilExit()
        timer.cancel()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NetworkError.message(text.isEmpty ? "Command failed or timed out." : text)
        }
        return text
    }

    private enum NetworkError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}

final class PrinterDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onUpdate: (([PrinterCandidate]) -> Void)?
    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private var candidates: [PrinterCandidate] = []

    func start() {
        stop()
        candidates = PrinterNetwork.existingPrinters()
        publish()
        for kind in ["_pdl-datastream._tcp.", "_printer._tcp.", "_ipp._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: kind, inDomain: "local.")
        }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        services.forEach { $0.stop() }
        browsers.removeAll()
        services.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var hints = sender.name
        if let record = sender.txtRecordData() {
            for (key, value) in NetService.dictionary(fromTXTRecord: record) {
                if ["ty", "product", "model", "usb_MDL"].contains(key),
                   let detail = String(data: value, encoding: .utf8) { hints += " \(detail)" }
            }
        }
        let normalized = hints.uppercased().replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        guard normalized.contains("QL580N") else { return }
        let resolved = sender.addresses?.compactMap { data -> String? in
            data.withUnsafeBytes { bytes in
                guard bytes.count >= MemoryLayout<sockaddr_in>.size,
                      let address = bytes.baseAddress?.assumingMemoryBound(to: sockaddr_in.self),
                      Int32(address.pointee.sin_family) == AF_INET else { return nil }
                var ip = address.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                return inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)).map { _ in String(cString: buffer) }
            }
        }.first ?? sender.hostName
        guard let host = resolved, let validatedHost = try? PrinterNetwork.validateHost(host) else { return }
        candidates.append(PrinterCandidate(name: sender.name, host: validatedHost, queue: nil))
        publish()
    }

    private func publish() {
        var unique: [String: PrinterCandidate] = [:]
        for candidate in candidates {
            let key = candidate.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if unique[key]?.queue == nil || candidate.queue != nil { unique[key] = candidate }
        }
        onUpdate?(unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}
