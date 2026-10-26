// Scenarios for the Follower in ble-apple-scan.swift: two (or more) cases in
// range, and which one the page should be following after each advert.
// Run with:  zsh tests/run-follow-test.sh
import Foundation

var f = Follower()
var failures = 0
let t0 = Date(timeIntervalSince1970: 1_000_000)

func step(_ label: String, _ key: String, closed: Bool, event: Bool = false, at t: Double,
          expectFollow: Bool, expectActive: String) {
    let (follow, note) = f.hear(key, closed: closed, lidEvent: event, at: t0.addingTimeInterval(t))
    let ok = follow == expectFollow && f.active == expectActive
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  t=\(String(format: "%5.1f", t))  \(label)"
          + "  -> follow=\(follow) active=\(f.active ?? "-")" + (note.map { "  [\($0)]" } ?? ""))
}

print("-- my case A, a stranger's case B nearby")
step("A heard, closed",                    "A", closed: true,  at: 0,    expectFollow: true,  expectActive: "A")
step("B heard, open (stranger)",           "B", closed: false, at: 0.5,  expectFollow: false, expectActive: "A")
step("A opens",                            "A", closed: false, event: true, at: 1, expectFollow: true, expectActive: "A")
step("B closes while A is open",           "B", closed: true,  event: true, at: 2, expectFollow: false, expectActive: "A")
step("B opens again while A is open",      "B", closed: false, event: true, at: 3, expectFollow: false, expectActive: "A")
step("A advert",                           "A", closed: false, at: 4,    expectFollow: true,  expectActive: "A")
step("B advert",                           "B", closed: false, at: 4.5,  expectFollow: false, expectActive: "A")
step("A closes",                           "A", closed: true,  event: true, at: 5, expectFollow: true, expectActive: "A")
step("B advert while A is closed",         "B", closed: false, at: 5.5,  expectFollow: false, expectActive: "A")

print("-- the other case is opened after mine is shut")
step("B closes",                           "B", closed: true,  event: true, at: 6, expectFollow: true, expectActive: "B")
step("B opens",                            "B", closed: false, event: true, at: 7, expectFollow: true, expectActive: "B")
step("A advert while B is open",           "A", closed: true,  at: 7.5,  expectFollow: false, expectActive: "B")
step("A opens while B is open and heard",  "A", closed: false, event: true, at: 8, expectFollow: false, expectActive: "B")

print("-- B is carried off with its lid open")
step("A advert, B silent 1 s",             "A", closed: false, at: 9,    expectFollow: false, expectActive: "B")
step("A advert, B silent 9 s",             "A", closed: false, at: 16,   expectFollow: true,  expectActive: "A")
step("A closes",                           "A", closed: true,  event: true, at: 17, expectFollow: true, expectActive: "A")

print("-- my closed case goes quiet; a stranger's open case must not take over")
step("B advert, A silent 23 s",            "B", closed: false, at: 40,   expectFollow: false, expectActive: "A")
step("B advert again",                     "B", closed: false, at: 41,   expectFollow: false, expectActive: "A")

print("-- my open case rotates its Bluetooth address (A becomes A2)")
step("A opens",                            "A", closed: false, event: true, at: 50, expectFollow: true, expectActive: "A")
step("A advert",                           "A", closed: false, at: 51,   expectFollow: true,  expectActive: "A")
step("A2 advert, A silent 2 s",            "A2", closed: false, at: 53,  expectFollow: false, expectActive: "A")
step("A2 advert, A silent 9 s",            "A2", closed: false, at: 60,  expectFollow: true,  expectActive: "A2")
step("A2 closes",                          "A2", closed: true, event: true, at: 61, expectFollow: true, expectActive: "A2")

print("-- at start-up the first case heard is only provisional")
f = Follower()
step("C heard first, open (stranger)",     "C", closed: false, at: 100,  expectFollow: true,  expectActive: "C")
step("D opens",                            "D", closed: false, event: true, at: 101, expectFollow: true, expectActive: "D")
step("C advert",                           "C", closed: false, at: 101.5, expectFollow: false, expectActive: "D")

print(failures == 0 ? "\nall scenarios pass" : "\n\(failures) scenario(s) FAILED")
exit(failures == 0 ? 0 : 1)
