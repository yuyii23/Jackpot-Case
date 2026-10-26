// Checks for the server rules in ble-apple-scan.swift (enum Wire): malformed
// WebSocket frames that used to crash the scanner, size limits, and who may
// load the page or the live feed.
// Run with:  zsh tests/run-security-test.sh
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(label)")
}
func masked(_ payload: [UInt8], opcode: UInt8 = 0x1) -> [UInt8] {
    let mask: [UInt8] = [9, 8, 7, 6]
    var head: [UInt8] = [0x80 | opcode]
    let n = payload.count
    if n < 126 { head.append(0x80 | UInt8(n)) }
    else { head += [0x80 | 126, UInt8(n >> 8), UInt8(n & 0xFF)] }
    return head + mask + payload.enumerated().map { $0.1 ^ mask[$0.0 % 4] }
}
func parse(_ b: [UInt8]) -> Wire.Parsed { Wire.parseFrame(Data(b)) }

print("-- frames")
let hello = Array("hello".utf8)
check("valid masked frame decodes", parse(masked(hello)) == .frame(opcode: 1, payload: Data(hello), consumed: 11))
check("16-bit length frame decodes", {
    if case let .frame(_, p, used) = parse(masked([UInt8](repeating: 65, count: 300))) { return p.count == 300 && used == 308 }
    return false }())
check("half a frame waits for more", parse(Array(masked(hello).prefix(7))) == .incomplete)
check("unmasked frame is refused", parse([0x81, 0x05] + hello) == .invalid("unmasked frame"))
check("64-bit length with top bit set (used to crash) is refused",
      parse([0x81, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 5, 1, 2, 3, 4]) == .invalid("frame too large"))
check("64-bit length near Int.max (used to crash) is refused",
      parse([0x81, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == .invalid("frame too large"))
check("length just over the limit is refused",
      parse([0x81, 0xFF, 0, 0, 0, 0, 0, 1, 0, 1]) == .invalid("frame too large"))
check("length at the limit waits for its data",
      parse([0x81, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0, 1, 2, 3, 4]) == .incomplete)
var fuzzCrashFree = true
for seed in 0..<20000 {                       // random headers must never trap
    var g = SystemRandomNumberGenerator()
    let n = Int.random(in: 0...24, using: &g)
    _ = parse((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    if seed < 0 { fuzzCrashFree = false }
}
check("20,000 random byte strings parse without crashing", fuzzCrashFree)

print("-- who may connect")
let key = Wire.newKey()
check("key is 24 hex characters", key.count == 24 && key.allSatisfy { $0.isHexDigit })
check("two runs get different keys", Wire.newKey() != Wire.newKey())
func ok(loopback: Bool, lan: Bool, query: [String: String] = [:], ws: Bool = false,
        origin: String? = nil, host: String? = "localhost:8787") -> Bool {
    Wire.allowed(loopback: loopback, lan: lan, key: key, query: query, websocket: ws, origin: origin, host: host)
}
check("this Mac loads the page", ok(loopback: true, lan: false))
check("this Mac's page opens the live feed",
      ok(loopback: true, lan: false, ws: true, origin: "http://localhost:8787"))
check("another website on this Mac cannot open the live feed",
      !ok(loopback: true, lan: false, ws: true, origin: "https://evil.example"))
check("look-alike origin is refused",
      !ok(loopback: true, lan: false, ws: true, origin: "http://localhost:8787.evil.example"))
check("another device is refused without --lan", !ok(loopback: false, lan: false, query: ["k": key]))
check("another device is refused with --lan but no key", !ok(loopback: false, lan: true))
check("another device is refused with a wrong key",
      !ok(loopback: false, lan: true, query: ["k": String(key.reversed())]))
check("phone with the key loads the page",
      ok(loopback: false, lan: true, query: ["k": key], host: "192.168.1.20:8787"))
check("phone's page with the key opens the live feed",
      ok(loopback: false, lan: true, query: ["k": key], ws: true,
         origin: "http://192.168.1.20:8787", host: "192.168.1.20:8787"))
check("query parsing", { let r = Wire.splitTarget("/ws?k=abc&x=1"); return r.path == "/ws" && r.query == ["k": "abc", "x": "1"] }())
check("bare path parsing", { let r = Wire.splitTarget("/"); return r.path == "/" && r.query.isEmpty }())

print(failures == 0 ? "\nall checks pass" : "\n\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
