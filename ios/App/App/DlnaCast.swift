import Foundation
import Capacitor
import Network

// DLNA / UPnP AVTransport casting, driven from the phone. The mytvbox server
// only resolves the media URL; the TV pulls the final stream directly.
//
// Discovery uses manual targets first, then scans the phone's LAN /24 ranges for
// common UPnP description ports. SSDP multicast is intentionally not used here:
// iOS 14+ requires Apple's multicast networking entitlement for that path, while
// the TCP scan only needs the Local Network permission in Info.plist.
@objc(DlnaCastPlugin)
public class DlnaCastPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "DlnaCastPlugin"
    public let jsName = "DlnaCast"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "discover", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cast", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "state", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resume", returnType: CAPPluginReturnPromise),
    ]

    // 49152 first: Xiaomi/HyperOS renderers commonly listen there.
    private let primaryUPnPPorts: [UInt16] = [49152, 49153, 49154, 8200, 7676, 9197]
    private let secondaryUPnPPorts: [UInt16] = [2869, 1400, 5000, 8060, 1901]
    private var allUPnPPorts: [UInt16] { primaryUPnPPorts + secondaryUPnPPorts }

    private let descriptionPaths = [
        "/description.xml", "/dmr.xml", "/MediaRenderer/desc.xml", "/xml/device.xml",
        "/dlna/desc.xml", "/device.xml", "/upnp/dev/description.xml", "/rootDesc.xml",
        "/DeviceDescription.xml", "/ssdp/device-desc.xml", "/",
    ]

    private let workQueue = DispatchQueue(label: "dlna.work", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "dlna.scan", qos: .userInitiated, attributes: .concurrent)

    // MARK: - Discovery

    @objc func discover(_ call: CAPPluginCall) {
        let timeoutMs = call.getInt("timeoutMs") ?? 8000
        let includeSecondaryPorts = call.getBool("fullScan") ?? true

        workQueue.async {
            var seen = Set<String>()
            var devices: [[String: String]] = []

            for location in self.manualLocations(call) {
                if let dev = self.describe(location) {
                    self.addDevice(dev, to: &devices, seen: &seen)
                }
            }
            if !devices.isEmpty {
                call.resolve(["devices": devices])
                return
            }

            for hostPort in self.manualHostPorts(call) {
                if let dev = self.describeHostPort(hostPort) {
                    self.addDevice(dev, to: &devices, seen: &seen)
                }
            }
            if !devices.isEmpty {
                call.resolve(["devices": devices])
                return
            }

            let bases = self.lanBases24()
            guard !bases.isEmpty else {
                call.resolve(["devices": []])
                return
            }

            for base in bases {
                let open = self.scanOpen(base: base, ports: self.primaryUPnPPorts, deadlineMs: timeoutMs)
                for hostPort in open {
                    if let dev = self.describeHostPort(hostPort) {
                        self.addDevice(dev, to: &devices, seen: &seen)
                    }
                }
                if !devices.isEmpty {
                    call.resolve(["devices": devices])
                    return
                }
            }

            if includeSecondaryPorts {
                for base in bases {
                    let open = self.scanOpen(base: base, ports: self.secondaryUPnPPorts, deadlineMs: timeoutMs)
                    for hostPort in open {
                        if let dev = self.describeHostPort(hostPort) {
                            self.addDevice(dev, to: &devices, seen: &seen)
                        }
                    }
                    if !devices.isEmpty { break }
                }
            }

            call.resolve(["devices": devices])
        }
    }

    private func scanOpen(base: String, ports: [UInt16], deadlineMs: Int) -> [(String, UInt16)] {
        var tasks: [(String, UInt16)] = []
        for port in ports {
            for host in 1...254 {
                tasks.append(("\(base).\(host)", port))
            }
        }
        return scanOpen(tasks, deadlineMs: deadlineMs)
    }

    private func scanOpen(_ tasks: [(String, UInt16)], deadlineMs: Int) -> [(String, UInt16)] {
        let sem = DispatchSemaphore(value: 60)
        let group = DispatchGroup()
        let lock = NSLock()
        var open: [(String, UInt16)] = []
        let deadline = Date().addingTimeInterval(Double(deadlineMs) / 1000.0)

        for (host, port) in tasks {
            if Date() > deadline { break }
            sem.wait()
            group.enter()
            probeOpen(host, port, timeout: 0.6) { ok in
                if ok {
                    lock.lock()
                    open.append((host, port))
                    lock.unlock()
                }
                sem.signal()
                group.leave()
            }
        }

        _ = group.wait(timeout: .now() + Double(deadlineMs) / 1000.0 + 2)
        return open
    }

    private func probeOpen(_ host: String, _ port: UInt16, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(false)
            return
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let lock = NSLock()
        var done = false

        let finish: (Bool) -> Void = { ok in
            lock.lock()
            if done {
                lock.unlock()
                return
            }
            done = true
            lock.unlock()

            conn.cancel()
            completion(ok)
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        conn.start(queue: scanQueue)
        scanQueue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    private func describeHostPort(_ hostPort: (String, UInt16)) -> [String: String]? {
        let (ip, port) = hostPort
        for path in descriptionPaths {
            if let dev = describe("http://\(ip):\(port)\(path)") {
                return dev
            }
        }
        return nil
    }

    // Fetch + parse a device description; return a device dict if it has AVTransport.
    private func describe(_ location: String) -> [String: String]? {
        guard let (status, body) = httpGet(location), status == 200, !body.isEmpty else {
            return nil
        }
        guard let serviceRegex = try? NSRegularExpression(
            pattern: "<service>(.*?)</service>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let full = NSRange(body.startIndex..., in: body)
        var controlURL: String?
        for match in serviceRegex.matches(in: body, range: full) {
            guard let group = Range(match.range(at: 1), in: body) else { continue }
            let service = String(body[group])
            if service.range(of: "AVTransport", options: .caseInsensitive) != nil {
                controlURL = rx("<controlURL>([^<]*)</controlURL>", service)
                break
            }
        }

        guard var control = controlURL?.trimmingCharacters(in: .whitespacesAndNewlines), !control.isEmpty else {
            return nil
        }

        let urlBase = rx("<URLBase>([^<]*)</URLBase>", body)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (urlBase?.isEmpty == false) ? urlBase! : location
        guard let absoluteControl = URL(string: control, relativeTo: URL(string: base))?.absoluteString else {
            return nil
        }
        control = absoluteControl

        let name = rx("<friendlyName>([^<]*)</friendlyName>", body)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "DLNA 设备"
        let udn = rx("<UDN>([^<]*)</UDN>", body)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? location

        return ["name": name, "controlURL": control, "udn": udn, "location": location]
    }

    private func addDevice(_ dev: [String: String], to devices: inout [[String: String]], seen: inout Set<String>) {
        let key = dev["udn"] ?? dev["controlURL"] ?? dev["location"] ?? UUID().uuidString
        if !seen.contains(key) {
            seen.insert(key)
            devices.append(dev)
        }
    }

    private func manualLocations(_ call: CAPPluginCall) -> [String] {
        guard let location = call.getString("location")?.trimmingCharacters(in: .whitespacesAndNewlines),
              location.hasPrefix("http://") || location.hasPrefix("https://") else {
            return []
        }
        return [location]
    }

    private func manualHostPorts(_ call: CAPPluginCall) -> [(String, UInt16)] {
        guard let host = call.getString("host")?.trimmingCharacters(in: .whitespacesAndNewlines),
              isIPv4(host) else {
            return []
        }

        var ports = allUPnPPorts
        if let port = call.getInt("port"), port > 0, port < 65536 {
            ports.insert(UInt16(port), at: 0)
        }

        var out: [(String, UInt16)] = []
        var seen = Set<String>()
        for port in ports {
            let key = "\(host):\(port)"
            if !seen.contains(key) {
                seen.insert(key)
                out.append((host, port))
            }
        }
        return out
    }

    // MARK: - Control

    @objc func cast(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL"), let mediaUrl = call.getString("url") else {
            call.reject("controlURL and url required")
            return
        }

        let title = call.getString("title") ?? ""
        let isM3u8 = call.getBool("isM3u8") ?? mediaUrl.contains(".m3u8")
        let mime = isM3u8 ? "application/vnd.apple.mpegurl" : (mediaUrl.contains(".mp4") ? "video/mp4" : "video/*")

        workQueue.async {
            let metadata = self.didl(mediaUrl, title, mime)
            let body = "<InstanceID>0</InstanceID><CurrentURI>\(self.esc(mediaUrl))</CurrentURI>"
                + "<CurrentURIMetaData>\(metadata)</CurrentURIMetaData>"
            _ = self.soap(controlURL, "SetAVTransportURI", body)

            // Some renderers briefly enter TRANSITIONING and drop an immediate Play.
            Thread.sleep(forTimeInterval: 0.7)
            var response = self.soap(controlURL, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
            if response == nil {
                Thread.sleep(forTimeInterval: 0.5)
                response = self.soap(controlURL, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
            }

            call.resolve(["ok": true])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL") else {
            call.reject("controlURL required")
            return
        }
        workQueue.async {
            _ = self.soap(controlURL, "Stop", "<InstanceID>0</InstanceID>")
            call.resolve(["ok": true])
        }
    }

    @objc func state(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL") else {
            call.reject("controlURL required")
            return
        }
        workQueue.async {
            let transportInfo = self.soap(controlURL, "GetTransportInfo", "<InstanceID>0</InstanceID>") ?? ""
            let positionInfo = self.soap(controlURL, "GetPositionInfo", "<InstanceID>0</InstanceID>") ?? ""
            call.resolve([
                "transportState": self.rx("<CurrentTransportState>([^<]*)</CurrentTransportState>", transportInfo) ?? "",
                "transportStatus": self.rx("<CurrentTransportStatus>([^<]*)</CurrentTransportStatus>", transportInfo) ?? "",
                "relSeconds": self.secs(self.rx("<RelTime>([^<]*)</RelTime>", positionInfo) ?? ""),
                "durSeconds": self.secs(self.rx("<TrackDuration>([^<]*)</TrackDuration>", positionInfo) ?? ""),
            ])
        }
    }

    @objc func seek(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL") else {
            call.reject("controlURL required")
            return
        }
        let target = hms(call.getDouble("seconds") ?? 0)
        workQueue.async {
            _ = self.soap(controlURL, "Seek", "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(target)</Target>")
            call.resolve(["ok": true])
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL") else {
            call.reject("controlURL required")
            return
        }
        workQueue.async {
            _ = self.soap(controlURL, "Pause", "<InstanceID>0</InstanceID>")
            call.resolve(["ok": true])
        }
    }

    @objc func resume(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL") else {
            call.reject("controlURL required")
            return
        }
        workQueue.async {
            _ = self.soap(controlURL, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
            call.resolve(["ok": true])
        }
    }

    // MARK: - SOAP / HTTP

    private func soap(_ controlURL: String, _ action: String, _ inner: String) -> String? {
        guard let url = URL(string: controlURL) else { return nil }
        let payload = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\(inner)</u:\(action)></s:Body></s:Envelope>"

        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = payload.data(using: .utf8)

        let sem = DispatchSemaphore(value: 0)
        var out: String?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data {
                out = String(data: data, encoding: .utf8) ?? ""
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 7)
        return out
    }

    private func httpGet(_ urlString: String, timeout: TimeInterval = 4) -> (Int, String)? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"

        let sem = DispatchSemaphore(value: 0)
        var result: (Int, String)?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = (http.statusCode, String(data: data ?? Data(), encoding: .utf8) ?? "")
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return result
    }

    private func didl(_ url: String, _ title: String, _ mime: String) -> String {
        let raw = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\">"
            + "<dc:title>\(esc(title))</dc:title>"
            + "<upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(mime):DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000\">\(esc(url))</res>"
            + "</item></DIDL-Lite>"
        return esc(raw)
    }

    // MARK: - Helpers

    private func hms(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func secs(_ text: String) -> Int {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return 0
    }

    private func esc(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func rx(_ pattern: String, _ s: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              match.numberOfRanges > group,
              let groupRange = Range(match.range(at: group), in: s) else {
            return nil
        }
        return String(s[groupRange])
    }

    private func lanBases24() -> [String] {
        var bases: [String] = []
        var seen = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        if getifaddrs(&ifaddr) == 0 {
            var pointer = ifaddr
            while pointer != nil {
                let interface = pointer!.pointee
                guard let address = interface.ifa_addr else {
                    pointer = interface.ifa_next
                    continue
                }

                if address.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" || name.hasPrefix("pdp_ip") {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(
                            address,
                            socklen_t(address.pointee.sa_len),
                            &host,
                            socklen_t(host.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        )
                        let ip = String(cString: host)
                        if let base = base24(ip), !seen.contains(base) {
                            seen.insert(base)
                            bases.append(base)
                        }
                    }
                }
                pointer = interface.ifa_next
            }
            freeifaddrs(ifaddr)
        }

        return bases
    }

    private func base24(_ ip: String) -> String? {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        guard parts[0] > 0, parts[0] < 224, parts[0] != 127, parts[3] > 0, parts[3] < 255 else {
            return nil
        }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    private func isIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts.allSatisfy { $0 >= 0 && $0 <= 255 }
    }
}
