// AirPods case lid as a game controller.
//
//   ./ble-apple-scan                     print Apple adverts as hex, highlight changed bytes
//   ./ble-apple-scan --serve 8787 --open serve the game and stream lid events over WebSocket
//   add --lan to let phones on the same Wi-Fi open it (prints a link with a per-run key)
//
// Byte layout of the Apple proximity-pairing advert (continuity type 0x07), as
// confirmed against 195 captured packets from an AirPods 0x3020:
//
//   [5]      status; alternates 0x15/0x75 as the two pods take turns advertising
//   [6]      pods battery nibbles (0xF = unavailable)
//   [7]      case battery in the high nibble (0xF = unavailable)
//   [8]      LID BYTE: low 3 bits = open counter (mod 8), bit 0x08 = lid closed
//   [12][13] per-pod, swap with the advertising pod
//   [23..26] change on every packet (encrypted/auth tail)
//
// Closing the lid raises bit 0x08 and leaves the counter alone; opening it clears
// the bit and bumps the counter. So any change to byte 8 is a lid action.

import Foundation
import CoreBluetooth
import Network
import CryptoKit

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: see adverts the moment they arrive

// MARK: - options

let args = ProcessInfo.processInfo.arguments
func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let servePort = flagValue("--serve").flatMap { UInt16($0) }
let openBrowser = args.contains("--open")
let showFull = args.contains("--full")
let showRaw = args.contains("--raw")
let showAll = args.contains("--all")
let rssiFloor = flagValue("--rssi").flatMap { Int($0) } ?? -70
let debugCounts = args.contains("--debug")
let traceAdverts = args.contains("--trace")
let quiet = servePort != nil && !args.contains("--verbose")
let lanMode = args.contains("--lan")   // let phones on the same Wi-Fi in, with a per-run key

let appleCompanyID: UInt16 = 0x004C
let encryptedFrom = 11

let models: [UInt16: String] = [
    0x0220: "AirPods 1", 0x0F20: "AirPods 2", 0x1320: "AirPods 3", 0x1920: "AirPods 4",
    0x1B20: "AirPods 4 ANC", 0x0E20: "AirPods Pro", 0x1420: "AirPods Pro 2",
    0x2420: "AirPods Pro 2 USB-C", 0x2920: "AirPods Pro 3",
    0x0A20: "AirPods Max", 0x1F20: "AirPods Max USB-C", 0x0B20: "Powerbeats Pro",
    0x1120: "Beats Studio Buds", 0x1220: "Beats Fit Pro", 0x1720: "Beats Studio Pro",
]

let clock: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
}()

func hex(_ d: ArraySlice<UInt8>) -> String {
    d.map { String(format: "%02X", $0) }.joined(separator: " ")
}

// MARK: - lid state

struct LidState: Equatable {
    var closed: Bool
    var count: Int

    init(_ byte8: UInt8) {
        closed = byte8 & 0x08 != 0
        count = Int(byte8 & 0x07)
    }

    /// Rebuild the byte this state came from, for logging.
    static func byte(_ s: LidState) -> UInt8 {
        UInt8((s.closed ? 0x08 : 0) | s.count)
    }

    /// Which way the lid moved, given what it was before.
    func action(from old: LidState) -> String {
        if old.closed != closed { return closed ? "closed" : "opened" }
        // Same flag, new counter: a whole open-shut slipped past unseen, so the
        // last thing that happened is whatever the flag now says.
        return count != old.count ? (closed ? "closed" : "opened") : "unknown"
    }
}

// MARK: - websocket framing and access rules

/// The server's rules, kept free of Network.framework so
/// tests/run-security-test.sh can compile and drive them directly.
enum Wire {
    /// Largest frame the page could ever send (it only sends close and pong
    /// frames). Anything bigger is refused instead of buffered.
    static let maxFrame = 64 * 1024
    /// Most bytes held for one connection while a frame is incomplete.
    static let maxBuffered = maxFrame + 14
    /// Most bytes of request headers held before the request is refused.
    static let maxRequestHead = 16 * 1024

    enum Parsed: Equatable {
        case frame(opcode: UInt8, payload: Data, consumed: Int)
        case incomplete
        case invalid(String)
    }

    /// One client-to-server WebSocket frame. The length is checked before any
    /// arithmetic, so a forged 64-bit length can neither wrap negative nor
    /// overflow (it used to crash the scanner with a single packet).
    static func parseFrame(_ d: Data) -> Parsed {
        let b = [UInt8](d)
        guard b.count >= 2 else { return .incomplete }
        let opcode = b[0] & 0x0F
        // Browsers always mask what they send; an unmasked frame is not a browser.
        guard b[1] & 0x80 != 0 else { return .invalid("unmasked frame") }
        var len = Int(b[1] & 0x7F)
        var i = 2
        if len == 126 {
            guard b.count >= 4 else { return .incomplete }
            len = Int(b[2]) << 8 | Int(b[3]); i = 4
        } else if len == 127 {
            guard b.count >= 10 else { return .incomplete }
            // A length needing more than 32 bits is far past maxFrame: refuse it
            // before shifting, so the value can never wrap.
            guard b[2...5].allSatisfy({ $0 == 0 }) else { return .invalid("frame too large") }
            len = 0
            for k in 6..<10 { len = len << 8 | Int(b[k]) }
            i = 10
        }
        guard len <= maxFrame else { return .invalid("frame too large") }
        guard b.count >= i + 4 else { return .incomplete }
        let mask = Array(b[i..<(i + 4)]); i += 4
        guard b.count >= i + len else { return .incomplete }
        var payload = Array(b[i..<(i + len)])
        for k in 0..<payload.count { payload[k] ^= mask[k % 4] }
        return .frame(opcode: opcode, payload: Data(payload), consumed: i + len)
    }

    static func frame(opcode: UInt8, payload: Data) -> Data {
        var f: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            f.append(UInt8(n))
        } else if n <= 0xFFFF {
            f += [126, UInt8(n >> 8), UInt8(n & 0xFF)]
        } else {
            f.append(127)
            for s in stride(from: 56, through: 0, by: -8) { f.append(UInt8((n >> s) & 0xFF)) }
        }
        return Data(f) + payload
    }

    /// "/ws?k=abc" -> ("/ws", ["k": "abc"])
    static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? "/"
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { query[String(kv[0])] = String(kv[1]) }
            }
        }
        return (path.isEmpty ? "/" : path, query)
    }

    /// Who may load the page and the live feed:
    ///  - this Mac (loopback) always may;
    ///  - another device only when the server runs with --lan, and only with
    ///    this run's key in the URL (?k=...);
    ///  - a WebSocket opened by a browser must come from the page itself: its
    ///    Origin has to match the Host it connected to, so another website open
    ///    on this Mac cannot read the feed.
    static func allowed(loopback: Bool, lan: Bool, key: String, query: [String: String],
                        websocket: Bool, origin: String?, host: String?) -> Bool {
        if !loopback {
            guard lan, let k = query["k"], sameSecret(k, key) else { return false }
        }
        if websocket, let origin {
            guard let host, origin.lowercased() == "http://\(host.lowercased())" else { return false }
        }
        return true
    }

    /// Compares every byte whatever the first mismatch, so timing does not
    /// reveal how much of a guessed key was right.
    static func sameSecret(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for k in 0..<x.count { diff |= x[k] ^ y[k] }
        return diff == 0
    }

    static func newKey() -> String {
        // SystemRandomNumberGenerator is the system's cryptographic generator.
        (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

// MARK: - websocket + http server

final class GameServer {
    private let port: UInt16
    private let lan: Bool
    private let key = Wire.newKey()
    private var listener: NWListener?
    private var sockets: [NWConnection] = []
    private var pending: Set<ObjectIdentifier> = []
    private var lastSnapshot = #"{"type":"hello","seen":false}"#
    private static let maxClients = 16
    private static let requestTimeout: TimeInterval = 10

    init(port: UInt16, lan: Bool) { self.port = port; self.lan = lan }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Without --lan nothing outside this Mac can even connect.
        if !lan { params.requiredInterfaceType = .loopback }
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            print("game server on http://localhost:\(self.port)")
            if self.lan {
                for ip in Self.lanAddresses() {
                    print("phone on the same Wi-Fi: http://\(ip):\(self.port)/?k=\(self.key)")
                }
                print("(the link changes every time the scanner starts)")
            }
            if openBrowser {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["http://localhost:\(self.port)"]
                try? p.run()
            }
        }
        l.start(queue: .main)
        listener = l
    }

    func snapshot(_ json: String) { lastSnapshot = json }

    func broadcast(_ json: String) {
        let data = Wire.frame(opcode: 0x1, payload: Data(json.utf8))
        for s in sockets { s.send(content: data, completion: .contentProcessed { _ in }) }
    }

    // MARK: connection handling

    private func accept(_ conn: NWConnection) {
        let loopback = Self.isLoopback(conn.endpoint)
        if !lan && !loopback {                    // belt and braces behind the listener
            refuse(nil, conn, "not this Mac"); conn.cancel(); return
        }
        conn.start(queue: .main)
        // A client that never finishes its request is dropped, so idle
        // connections cannot pile up.
        let id = ObjectIdentifier(conn)
        pending.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            if self?.pending.remove(id) != nil { conn.cancel() }
        }
        readRequest(conn, buffer: Data(), loopback: loopback)
    }

    private func readRequest(_ conn: NWConnection, buffer: Data, loopback: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if err != nil || (done && buf.isEmpty) { self.pending.remove(ObjectIdentifier(conn)); conn.cancel(); return }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if buf.count > Wire.maxRequestHead {
                    self.pending.remove(ObjectIdentifier(conn)); conn.cancel(); return
                }
                self.readRequest(conn, buffer: buf, loopback: loopback)
                return
            }
            self.pending.remove(ObjectIdentifier(conn))
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            self.route(conn, head: head, rest: Data(buf[end.upperBound...]), loopback: loopback)
        }
    }

    private func route(_ conn: NWConnection, head: String, rest: Data, loopback: Bool) {
        var headers: [String: String] = [:]
        let lines = head.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            headers[line[..<c].lowercased()] = line[line.index(after: c)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let target = lines.first?.components(separatedBy: " ").dropFirst().first ?? "/"
        let (path, query) = Wire.splitTarget(target)
        let wsKey = path == "/ws" ? headers["sec-websocket-key"] : nil

        guard Wire.allowed(loopback: loopback, lan: lan, key: key, query: query,
                           websocket: wsKey != nil, origin: headers["origin"], host: headers["host"]) else {
            let keyOK = loopback || (lan && Wire.sameSecret(query["k"] ?? "", key))
            refuse(conn, conn, keyOK ? "page from another website" : "missing or wrong key")
            return
        }

        if let wsKey {
            guard sockets.count < Self.maxClients else {
                refuse(conn, conn, "too many open pages"); return
            }
            let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            let accept = Data(Insecure.SHA1.hash(data: Data((wsKey + magic).utf8))).base64EncodedString()
            let resp = """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: \(accept)\r
            \r

            """
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            sockets.append(conn)
            conn.send(content: Wire.frame(opcode: 0x1, payload: Data(lastSnapshot.utf8)),
                      completion: .contentProcessed { _ in })
            readFrames(conn, buffer: rest)
            return
        }

        if path == "/" || path == "/index.html" {
            if let html = try? Data(contentsOf: URL(fileURLWithPath: Self.htmlPath())) {
                respond(conn, status: "200 OK", type: "text/html; charset=utf-8", body: html)
            } else {
                respond(conn, status: "500 Internal Server Error", type: "text/plain; charset=utf-8",
                        body: Data("game.html not found next to the binary\n".utf8))
            }
        } else {
            respond(conn, status: "404 Not Found", type: "text/plain; charset=utf-8", body: Data("no\n".utf8))
        }
    }

    private func refuse(_ reply: NWConnection?, _ conn: NWConnection, _ why: String) {
        print("refused  \(clock.string(from: Date()))  \(Self.describe(conn.endpoint))  (\(why))")
        if let reply {
            respond(reply, status: "403 Forbidden", type: "text/plain; charset=utf-8", body: Data("forbidden\n".utf8))
        }
    }

    private static func htmlPath() -> String {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let beside = exeDir.appendingPathComponent("game.html").path
        if FileManager.default.fileExists(atPath: beside) { return beside }
        return FileManager.default.currentDirectoryPath + "/game.html"
    }

    private func respond(_ conn: NWConnection, status: String, type: String, body: Data) {
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: \(type)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        X-Content-Type-Options: nosniff\r
        Connection: close\r
        \r

        """
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: framing

    private func drop(_ conn: NWConnection) {
        sockets.removeAll { $0 === conn }
    }

    private func readFrames(_ conn: NWConnection, buffer: Data) {
        var buf = buffer
        parsing: while true {
            switch Wire.parseFrame(buf) {
            case let .frame(opcode, payload, consumed):
                buf.removeFirst(consumed)
                switch opcode {
                case 0x8:
                    drop(conn); conn.cancel(); return
                case 0x9:
                    conn.send(content: Wire.frame(opcode: 0xA, payload: payload),
                              completion: .contentProcessed { _ in })
                default:
                    break   // the page only listens; nothing to act on
                }
            case .incomplete:
                break parsing
            case let .invalid(why):
                print("closed   \(clock.string(from: Date()))  \(Self.describe(conn.endpoint))  (\(why))")
                drop(conn); conn.cancel(); return
            }
        }
        guard buf.count <= Wire.maxBuffered else {
            print("closed   \(clock.string(from: Date()))  \(Self.describe(conn.endpoint))  (too much data)")
            drop(conn); conn.cancel(); return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
            guard let self else { return }
            if err != nil || done {
                self.drop(conn); conn.cancel(); return
            }
            var next = buf
            if let data { next.append(data) }
            self.readFrames(conn, buffer: next)
        }
    }

    // MARK: addresses

    private static func isLoopback(_ e: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || (a.asIPv4?.isLoopback ?? false)
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    private static func describe(_ e: NWEndpoint) -> String {
        if case let .hostPort(host, _) = e { return "\(host)" }
        return "\(e)"
    }

    /// This Mac's IPv4 addresses on its networks, for the phone link.
    private static func lanAddresses() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let f = p.pointee
            guard let sa = f.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  f.ifa_flags & UInt32(IFF_UP) != 0, f.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}

// MARK: - which case the page follows

/// With two cases in range the page used to take events from both and show
/// a mix. It now follows one case at a time:
///   - a lid movement claims the page, unless another case holds it with its
///     lid open and is still being heard;
///   - adverts from any other case are ignored;
///   - a case that goes quiet while open (carried off, or its Bluetooth address
///     rotated, which makes it look like a new case) hands over to whichever
///     case is heard next. A quiet case that is closed keeps the page, so a
///     stranger's open case nearby cannot take it without moving its lid.
/// Kept free of CoreBluetooth so follow-test.swift can drive it directly.
struct Follower {
    var staleAfter: TimeInterval = 8
    private(set) var active: String?
    private var firm = false                  // claimed by a lid movement, not just heard
    private var heard: [String: Date] = [:]
    private var closed: [String: Bool] = [:]

    /// Call once per advert. `closed` is the lid state the page would be shown
    /// for this case; `lidEvent` is true when this advert is a new lid movement.
    /// Returns whether to pass the advert on, and a note when the page switches.
    mutating func hear(_ key: String, closed isClosed: Bool, lidEvent: Bool,
                       at now: Date = Date()) -> (follow: Bool, note: String?) {
        defer { heard[key] = now; closed[key] = isClosed }
        guard let current = active else {
            active = key; firm = lidEvent
            return (true, "first case heard")
        }
        if current == key {
            if lidEvent { firm = true }
            return (true, nil)
        }
        let quiet = now.timeIntervalSince(heard[current] ?? .distantPast) > staleAfter
        let currentOpen = closed[current] == false
        if lidEvent && (!firm || !currentOpen || quiet) {
            active = key; firm = true
            return (true, "its lid moved")
        }
        if !lidEvent && quiet && (!firm || currentOpen) {
            active = key; firm = false
            return (true, "the previous case went quiet")
        }
        return (false, nil)
    }
}

// MARK: - scanner

final class Scanner: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private var previous: [String: [UInt8]] = [:]
    // Keyed per pod, because the two pods of one case report byte 8 a beat apart
    // and briefly disagree — sharing a slot made them flip it back and forth.
    private var lid: [String: LidState] = [:]
    // Per device: the lid state the game was last told, the one before it, and
    // when. Together they tell the second pod echoing a movement apart from a
    // genuine quick open-shut, which a plain cooldown could not.
    private var told: [String: LidState] = [:]
    private var toldBefore: [String: LidState] = [:]
    private var toldAt: [String: Date] = [:]
    private var follower = Follower()
    private var events = 0
    private var lastSeenPush = Date.distantPast

    // Counted before any filtering, so a silent run can be told apart from a
    // filtered-out one.
    private var nTotal = 0, nMfg = 0, nApple = 0, nType07 = 0, nBelowFloor = 0
    private var bestRSSI = -200, bestAppleRSSI = -200
    private var typeCounts: [UInt8: Int] = [:]
    private var typeSample: [UInt8: String] = [:]

    var server: GameServer?

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            print("scanning Apple 0x004C adverts, rssi >= \(rssiFloor) dBm")
            if servePort == nil { print("open and close the case lid. ctrl-c to stop.\n") }
            c.scanForPeripherals(withServices: nil,
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            if debugCounts {
                Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    self?.report()
                }
            }
        case .poweredOff:   print("bluetooth is off — turn it on")
        case .unauthorized: print("bluetooth permission denied — System Settings > Privacy & Security > Bluetooth")
        case .unsupported:  print("bluetooth LE not supported here")
        case .resetting:    print("state: resetting")
        case .unknown:      print("state: unknown (waiting for CoreBluetooth)")
        @unknown default:   print("state: unhandled (\(c.state.rawValue))")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        guard RSSI.intValue != 127 else { return }   // CoreBluetooth's "unknown"
        nTotal += 1
        bestRSSI = max(bestRSSI, RSSI.intValue)

        guard let md = ad[CBAdvertisementDataManufacturerDataKey] as? Data, md.count >= 3 else { return }
        nMfg += 1
        let bytes = [UInt8](md)
        guard UInt16(bytes[0]) | UInt16(bytes[1]) << 8 == appleCompanyID else { return }
        nApple += 1
        bestAppleRSSI = max(bestAppleRSSI, RSSI.intValue)

        let payload = Array(bytes.dropFirst(2))
        typeCounts[payload[0], default: 0] += 1
        if typeSample[payload[0]] == nil {
            typeSample[payload[0]] = "rssi \(RSSI.intValue)  \(hex(payload[0...]))"
        }
        guard payload[0] == 0x07, payload.count >= 11 else {
            if showAll && !quiet { printOther(payload, p, RSSI) }
            return
        }
        nType07 += 1
        guard RSSI.intValue >= rssiFloor else { nBelowFloor += 1; return }

        let model = UInt16(payload[3]) << 8 | UInt16(payload[4])
        let productID = UInt16(payload[4]) << 8 | UInt16(payload[3])
        let name = models[model] ?? "Apple audio \(String(format: "0x%04X", productID))"

        // The two pods alternate adverts, so diff each against itself — otherwise
        // every packet looks like a change. Status bits 0x60 tell them apart.
        let pod = payload[5] & 0x60
        let key = "\(model)-\(pod)"
        let old = previous[key]
        previous[key] = payload

        // A rotating address makes a new key, which only costs one missed event;
        // sharing a key between two cases cost 205 false ones.
        let deviceKey = p.identifier.uuidString
        let podKey = "\(deviceKey)-\(pod)"
        let now = LidState(payload[8])
        if traceAdverts {
            print("adv   \(clock.string(from: Date()))  [8]=\(String(format: "%02X", payload[8]))"
                  + "  pod \(String(format: "%02X", pod))  rssi \(RSSI.intValue)")
        }
        let before = lid[podKey]
        lid[podKey] = now

        // One lid movement reaches us twice, once per pod, usually 6-30 ms apart
        // but up to ~370 ms. Timing alone cannot tell that echo from a genuine
        // quick open-shut (a 0.4 s cooldown swallowed real closes 300 ms after an
        // open), so judge by state: an echo lands on the open/closed flag the game
        // already knows; a real movement flips it. The flag, not the whole byte,
        // because the two pods' counters drift apart by one for minutes at a time.
        // The counter only breaks the tie for a pod so late that the lid has
        // already moved again: its report matches the state before the last one.
        let moved = before != nil && before! != now
        var dropped: String? = nil
        if moved {
            if let known = told[deviceKey], known.closed == now.closed {
                dropped = "echo"
            } else if toldBefore[deviceKey] == now,
                      Date().timeIntervalSince(toldAt[deviceKey] ?? .distantPast) < 0.4 {
                dropped = "late echo"
            }
        }
        if moved, let dropped, let before {
            print("drop  \(clock.string(from: Date()))  [8] "
                  + String(format: "%02X->%02X", LidState.byte(before), payload[8])
                  + "  pod \(String(format: "%02X", pod))  (\(dropped))")
        }
        // Dedup state is kept for every case, followed or not, so a case that
        // later takes the page starts from the right lid state.
        let isEvent = moved && dropped == nil
        var action = "unknown"
        if isEvent, let before {
            // Name the action against what the game was last told, so a pod that
            // slept through a close still gets the following open right.
            let reference = told[deviceKey] ?? before
            toldBefore[deviceKey] = reference
            told[deviceKey] = now
            toldAt[deviceKey] = Date()
            action = now.action(from: reference)
        }
        let shown = told[deviceKey] ?? now
        let (follow, note) = follower.hear(deviceKey, closed: shown.closed, lidEvent: isEvent)
        if let note {
            print("follow \(clock.string(from: Date()))  case \(deviceKey.prefix(8))  (\(note))"
                  + "  rssi \(RSSI.intValue)")
        }

        if isEvent && !follow {
            print("skip  \(clock.string(from: Date()))  lid \(action) on case \(deviceKey.prefix(8))"
                  + "  (page is following case \(follower.active?.prefix(8) ?? "-"))")
        } else if isEvent {
            events += 1
            if debugCounts {
                print("   (device \(deviceKey.prefix(8)) pod \(String(format: "%02X", pod)), rssi \(RSSI.intValue))")
            }
            if !quiet {
                print(">>> \(clock.string(from: Date()))  LID \(action.uppercased())   "
                      + "[8]=0x\(String(format: "%02X", payload[8])) count=\(now.count) "
                      + "closed=\(now.closed)  (\(name), event #\(events))")
            } else {
                print("lid \(action)  \(clock.string(from: Date()))  count=\(now.count) "
                      + "closed=\(now.closed)  pod \(String(format: "%02X", pod))  rssi \(RSSI.intValue)")
            }
            server?.broadcast(json(type: "lid", name: name, productID: productID, lid: now,
                                   rssi: RSSI.intValue, action: action, payload: payload))
        } else if follow, server != nil, note != nil || Date().timeIntervalSince(lastSeenPush) > 1 {
            // A switch is pushed at once so the page redraws for the new case.
            lastSeenPush = Date()
            server?.broadcast(json(type: "seen", name: name, productID: productID, lid: shown,
                                   rssi: RSSI.intValue, action: nil, payload: payload))
        }

        // Snapshots and "seen" carry the state the game was told, not this pod's:
        // a pod lagging behind the other would otherwise undo the last event.
        if follow {
            server?.snapshot(json(type: "hello", name: name, productID: productID, lid: shown,
                                  rssi: RSSI.intValue, action: nil, payload: payload))
        }

        guard !quiet else { return }

        let compared = showFull ? payload.count : min(encryptedFrom, payload.count)
        let changed: [Int] = {
            guard let old, old.count == payload.count else { return [] }
            return (0..<compared).filter { old[$0] != payload[$0] }
        }()
        if !showRaw && old != nil && changed.isEmpty { return }

        print("[\(clock.string(from: Date()))] \(name)  rssi \(RSSI.intValue)  pod \(String(format: "0x%02X", pod))")
        print("  \(hex(payload[0..<compared]))" + (showFull ? "" : "  | +\(payload.count - compared) encrypted"))
        if old == nil {
            print("  (first sighting of this pod)")
        } else if !changed.isEmpty {
            print("  CHANGED: " + changed.map {
                String(format: "[%d] %02X->%02X", $0, old![$0], payload[$0])
            }.joined(separator: "  "))
        }
        func pct(_ n: UInt8) -> String { n == 0x0F ? "n/a" : "\(Int(n) * 10)%" }
        print("  lid: \(now.closed ? "CLOSED" : "OPEN")  count=\(now.count)"
              + "   pods=\(pct(payload[6] >> 4))/\(pct(payload[6] & 0x0F))  case=\(pct(payload[7] >> 4))")
        print("  status=0b\(String(payload[5], radix: 2).leftPad(8))\n")
    }

    private func report() {
        print("debug  adverts=\(nTotal) withMfgData=\(nMfg) apple=\(nApple) "
              + "type07=\(nType07) droppedByRssiFloor=\(nBelowFloor)  "
              + "bestRssi=\(bestRSSI == -200 ? 0 : bestRSSI) "
              + "bestAppleRssi=\(bestAppleRSSI == -200 ? 0 : bestAppleRSSI)")
        let hist = typeCounts.sorted { $0.value > $1.value }
            .map { "0x\(String(format: "%02X", $0.key))=\($0.value)" }
            .joined(separator: " ")
        print("       apple continuity types: \(hist.isEmpty ? "none" : hist)")
        for (t, sample) in typeSample.sorted(by: { $0.key < $1.key }) {
            print("         0x\(String(format: "%02X", t)): \(sample)")
        }
    }

    /// Battery nibbles run 0...10 for 0-100%%, and 15 means "not reported".
    /// Verified for the pods against macOS's own "Battery L .. R .." reading;
    /// the case nibble is sent raw as well because it has produced impossible
    /// values before and is not trusted yet.
    private func batteryPercent(_ nibble: UInt8) -> String {
        nibble <= 10 ? String(Int(nibble) * 10) : "null"
    }

    private func json(type: String, name: String, productID: UInt16, lid: LidState,
                      rssi: Int, action: String?, payload: [UInt8]? = nil) -> String {
        var parts = [
            #""type":"\#(type)""#,
            #""device":"\#(name)""#,
            #""model":"0x\#(String(format: "%04X", productID))""#,
            #""closed":\#(lid.closed)"#,
            #""count":\#(lid.count)"#,
            #""rssi":\#(rssi)"#,
            #""seen":true"#,
            #""t":\#(Int(Date().timeIntervalSince1970 * 1000))"#,
        ]
        if let action { parts.append(#""action":"\#(action)""#) }
        if let p = payload, p.count > 7 {
            parts.append(#""left":\#(batteryPercent(p[6] >> 4))"#)
            parts.append(#""right":\#(batteryPercent(p[6] & 0x0F))"#)
            parts.append(#""case":\#(batteryPercent(p[7] & 0x0F))"#)
            parts.append(#""caseHighNibble":\#(batteryPercent(p[7] >> 4))"#)
            parts.append(#""b6":"0x\#(String(format: "%02X", p[6]))""#)
            parts.append(#""b7":"0x\#(String(format: "%02X", p[7]))""#)
            parts.append(#""b8":"0x\#(String(format: "%02X", p[8]))""#)
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func printOther(_ p: [UInt8], _ periph: CBPeripheral, _ rssi: NSNumber) {
        let key = "\(periph.identifier.uuidString)-\(p[0])"
        if !showRaw, previous[key] == p { return }
        previous[key] = p
        print("[\(clock.string(from: Date()))] type 0x\(String(format: "%02X", p[0]))"
              + "  rssi \(rssi.intValue)  \(hex(p[0...]))\n")
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

// MARK: - main

let scanner = Scanner()
if let port = servePort {
    let server = GameServer(port: port, lan: lanMode)
    do {
        try server.start()
    } catch {
        print("could not listen on port \(port): \(error)")
        exit(1)
    }
    scanner.server = server
}
scanner.start()
signal(SIGINT) { _ in print("\nstopped"); exit(0) }
RunLoop.main.run()
