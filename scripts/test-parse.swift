// Runnable check for Monitor.parse — compile with the real source, no framework:
//   swiftc App/Monitor.swift scripts/test-parse.swift -o /tmp/ptest && /tmp/ptest
// Verifies the two-block cumulative→delta→Mbps math and multi-word process names.
import Foundation

let fixture = """
time                                   bytes_in       bytes_out
11:12:28.9 procA.100                     1000000               0
11:12:28.9 Google Chrome H.200           5000000          500000
11:12:28.9 2.1.203.49417                  999999          999999
time                                   bytes_in       bytes_out
11:12:29.9 procA.100                     2250000               0
11:12:29.9 Google Chrome H.200           5000000         1000000
11:12:29.9 2.1.203.49417                 9999999         9999999
"""

@main enum ParseCheck {
    static func main() {
        let rates = Monitor.parse(fixture, seconds: 1)
        func rate(_ n: String) -> Monitor.Rate? { rates.first { $0.name == n } }

        // procA: 1,250,000 bytes/s * 8 / 1e6 = 10 Mbps down, 0 up
        assert(abs(rate("procA")!.mbpsDown - 10.0) < 0.001, "procA down \(rate("procA")!.mbpsDown)")
        assert(rate("procA")!.mbpsUp == 0, "procA up")
        // Multi-word name parsed; 500,000 bytes/s up = 4 Mbps, 0 down
        assert(rate("Google Chrome H")!.mbpsUp == 4.0, "chrome up \(rate("Google Chrome H")!.mbpsUp)")
        assert(rate("Google Chrome H")!.mbpsDown == 0, "chrome down")
        // IP-only row filtered out
        assert(rate("2.1.203") == nil, "ip row should be filtered")
        // busiest first
        assert(rates.first?.name == "procA", "sort order")

        print("OK — \(rates.count) rows: " + rates.map { String(format: "%@ ↓%.1f ↑%.1f", $0.name, $0.mbpsDown, $0.mbpsUp) }.joined(separator: ", "))
    }
}
