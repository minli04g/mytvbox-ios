import Foundation
import Capacitor
import Network

// DLNA / UPnP AVTransport casting, driven from the phone (cross-LAN use: the
// phone is on the TV's LAN, the mytvbox server may be remote). This is a faithful
// Swift port of the proven gui/dlna.js: discover MediaRenderers, then SetAVTransportURI
// + Play over SOAP.
//
// Discovery is by PORT SCAN of the phone's /24 (TCP connect to the usual UPnP
// description ports, then fetch the description and pull the AVTransport controlURL).
// We deliberately do NOT use SSDP here: SSDP needs UDP multicast, which iOS 14+
// gates behind the com.apple.developer.networking.multicast entitlement (pending
// Apple approval). Port scan needs only the Local Network permission
// (NSLocalNetworkUsageDescription) and works today. When the multicast entitlement
// lands, SSDP can be added as the fast path with this as the fallback.
//
// The cast URL handed to the TV is a DIRECT CDN URL (resolved server-side); the TV
// pulls the stream itself, so the mytvbox server is never in the data path.
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

    // Mirror gui/dlna.js. 49152 first — that's where Xiaomi/HyperOS renderers sit,
    // so the prioritized scan finds them within the first sweep.
    private let UPNP_PORTS: [UInt16] = [49152, 49153, 49154, 8200, 7676, 9197, 2869, 1400, 5000, 8060, 1901]
    private let DESC_PATHS = [
        "/description.xml", "/dmr.xml", "/MediaRenderer/desc.xml", "/xml/device.xml",
        "/dlna/desc.xml", "/device.xml", "/upnp/dev/description.xml", "/rootDesc.xml",
        "/DeviceDescription.xml", "/ssdp/device-desc.xml", "/",
    ]

    private let workQueue = DispatchQueue(label: "dlna.work", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "dlna.scan", qos: .userInitiated, attributes: .concurrent)

    // MARK: - Discovery

    @objc func discover(_ call: CAPPluginCall) {
        let timeoutMs = call.getInt("timeoutMs") ?? 12000
        workQueue.async {
            guard let base = self.lanBase24() else { call.resolve(["devices": []]); return }
            // (ip,port) tasks, port-priority order (all hosts on 49152 first, etc.)
            var tasks: [(String, UInt16)] = []
            for port in self.UPNP_PORTS {
                for host in 1...254 { tasks.append(("\(base).\(host)", port)) }
            }
            let open = self.scanOpen(tasks, deadlineMs: timeoutMs)
            var seen = Set<String>()
            var devices: [[String: String]] = []
            for (ip, port) in open {
                for path in self.DESC_PATHS {
                    if let dev = self.describe("http://\(ip):\(port)\(path)") {
                        let udn = dev["udn"] ?? dev["controlURL"] ?? "\(ip):\(port)"
                        if !seen.contains(udn) { seen.insert(udn); devices.append(dev) }
                        break
                    }
                }
            }
            call.resolve(["devices": devices])
        }
    }

    // Probe (ip,port) pairs for an open TCP port, bounded concurrency + overall deadline.
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
                if ok { lock.lock(); open.append((host, port)); lock.unlock() }
                sem.signal(); group.leave()
            }
        }
        _ = group.wait(timeout: .now() + Double(deadlineMs) / 1000.0 + 2)
        return open
    }

    private func probeOpen(_ host: String, _ port: UInt16, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { completion(false); return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        var done = false
        let finish: (Bool) -> Void = { ok in
            if done { return }; done = true
            conn.cancel()
            completion(ok)
        }
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        conn.start(queue: scanQueue)
        scanQueue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    // Fetch + parse a device description; return a device dict if it has AVTransport.
    private func describe(_ loc: String) -> [String: String]? {
        guard let (status, body) = httpGet(loc), status == 200, !body.isEmpty else { return nil }
        guard let re = try? NSRegularExpression(pattern: "<service>(.*?)</service>",
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let full = NSRange(body.startIndex..., in: body)
        var ctrl: String? = nil
        for m in re.matches(in: body, range: full) {
            guard let gr = Range(m.range(at: 1), in: body) else { continue }
            let svc = String(body[gr])
            if svc.range(of: "AVTransport", options: .caseInsensitive) != nil {
                ctrl = rx("<controlURL>([^<]*)</controlURL>", svc)
                break
            }
        }
        guard var control = ctrl?.trimmingCharacters(in: .whitespacesAndNewlines), !control.isEmpty else { return nil }
        let urlBase = rx("<URLBase>([^<]*)</URLBase>", body)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseStr = (urlBase?.isEmpty == false) ? urlBase! : loc
        if let abs = URL(string: control, relativeTo: URL(string: baseStr))?.absoluteString { control = abs }
        let name = rx("<friendlyName>([^<]*)</friendlyName>", body)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "DLNA 设备"
        let udn = rx("<UDN>([^<]*)</UDN>", body)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? loc
        return ["name": name, "controlURL": control, "udn": udn, "location": loc]
    }

    // MARK: - Control

    @objc func cast(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL"), let mediaUrl = call.getString("url") else {
            call.reject("controlURL and url required"); return
        }
        let title = call.getString("title") ?? ""
        let isM3u8 = call.getBool("isM3u8") ?? mediaUrl.contains(".m3u8")
        let mime = isM3u8 ? "application/vnd.apple.mpegurl" : (mediaUrl.contains(".mp4") ? "video/mp4" : "video/*")
        workQueue.async {
            let meta = self.didl(mediaUrl, title, mime)
            let body1 = "<InstanceID>0</InstanceID><CurrentURI>\(self.esc(mediaUrl))</CurrentURI>"
                + "<CurrentURIMetaData>\(meta)</CurrentURIMetaData>"
            _ = self.soap(controlURL, "SetAVTransportURI", body1)
            // Some renderers (Xiaomi) are briefly TRANSITIONING and drop an immediate Play.
            Thread.sleep(forTimeInterval: 0.7)
            var r = self.soap(controlURL, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
            if r == nil {
                Thread.sleep(forTimeInterval: 0.5)
                r = self.soap(controlURL, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
            }
            call.resolve(["ok": true])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL") else { call.reject("controlURL required"); return }
        workQueue.async {
            _ = self.soap(controlURL, "Stop", "<InstanceID>0</InstanceID>")
            call.resolve(["ok": true])
        }
    }

    // Transport state + current/total position — lets the UI act as a remote:
    // confirm the TV started, drive the progress bar, and seek.
    @objc func state(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL") else { call.reject("controlURL required"); return }
        workQueue.async {
            let ti = self.soap(controlURL, "GetTransportInfo", "<InstanceID>0</InstanceID>") ?? ""
            let pi = self.soap(controlURL, "GetPositionInfo", "<InstanceID>0</InstanceID>") ?? ""
            call.resolve([
                "transportState": self.rx("<CurrentTransportState>([^<]*)</CurrentTransportState>", ti) ?? "",
                "transportStatus": self.rx("<CurrentTransportStatus>([^<]*)</CurrentTransportStatus>", ti) ?? "",
                "relSeconds": self.secs(self.rx("<RelTime>([^<]*)</RelTime>", pi) ?? ""),
                "durSeconds": self.secs(self.rx("<TrackDuration>([^<]*)</TrackDuration>", pi) ?? ""),
            ])
        }
    }

    @objc func seek(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL") else { call.reject("controlURL required"); return }
        let target = hms(call.getDouble("seconds") ?? 0)
        workQueue.async {
            _ = self.soap(controlURL, "Seek", "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(target)</Target>")
            call.resolve(["ok": true])
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL") else { call.reject("controlURL required"); return }
        workQueue.async { _ = self.soap(controlURL, "Pause", "<InstanceID>0</InstanceID>"); call.resolve(["ok": true]) }
    }

    @objc func resume(_ call: CAPPluginCall) {
        guard let controlURL = call.getString("controlURL") else { call.reject("controlURL required"); return }
        workQueue.async { _ = self.soap(controlURL, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>"); call.resolve(["ok": true]) }
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
        var out: String? = nil
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data { out = String(data: d, encoding: .utf8) ?? "" }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 7)
        return out
    }

    private func httpGet(_ urlStr: String, timeout: TimeInterval = 4) -> (Int, String)? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, String)? = nil
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse {
                result = (http.statusCode, String(data: data ?? Data(), encoding: .utf8) ?? "")
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return result
    }

    // DIDL-Lite metadata, XML-escaped so it can sit inside the SOAP text value
    // (matches gui/dlna.js exactly).
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

    // seconds -> "H:MM:SS" (UPnP REL_TIME), and "H:MM:SS" -> seconds.
    private func hms(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
    private func secs(_ t: String) -> Int {
        let p = t.split(separator: ":").compactMap { Int($0) }
        if p.count == 3 { return p[0] * 3600 + p[1] * 60 + p[2] }
        if p.count == 2 { return p[0] * 60 + p[1] }
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
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let r = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: r), m.numberOfRanges > group,
              let gr = Range(m.range(at: group), in: s) else { return nil }
        return String(s[gr])
    }

    // The phone's Wi-Fi /24 base (e.g. "192.168.123"), used to enumerate scan targets.
    private func lanBase24() -> String? {
        var ip: String? = nil
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var p = ifaddr
            while p != nil {
                let ifa = p!.pointee
                if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ifa.ifa_name)
                    if name == "en0" {  // Wi-Fi
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                        ip = String(cString: host)
                    }
                }
                p = ifa.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        guard let addr = ip else { return nil }
        let parts = addr.split(separator: ".")
        return parts.count == 4 ? "\(parts[0]).\(parts[1]).\(parts[2])" : nil
    }
}
