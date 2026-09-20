import Foundation

/// Read-only live transport verification. Never submits input or creates a terminal.
@main struct LiveConnectionChecks {
    static func main() async throws {
        let machines = try await HerdrClient.machines()
        for machine in machines {
            let transport = MachineTransport(machine)
            let cold = Date()
            let result = try await transport.call("session.snapshot")
            let agents = try HerdrClient.inventory(result, machine: machine)
            print("\(machine.label): cold \(Int(Date().timeIntervalSince(cold)*1000)) ms, \(agents.count) terminals")
            var times: [Int] = []
            for _ in 0..<5 {
                let start = Date(); _ = try await transport.call("session.snapshot")
                times.append(Int(Date().timeIntervalSince(start)*1000))
            }
            print("  warm snapshot ms: \(times)")
            if let agent = agents.first {
                let start = Date()
                let result = try await transport.call("pane.read", ["pane_id": agent.pane_id, "source": "visible", "format": "text"])
                assert(result["read"] != nil)
                print("  visible read: \(Int(Date().timeIntervalSince(start)*1000)) ms")
            }
            let stream = try await transport.events()
            let task = Task {
                for try await data in stream {
                    let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    assert(value["error"] == nil, "Subscription must be accepted")
                    print("  event stream acknowledged")
                    break
                }
            }
            try await task.value
            await transport.shutdown()
        }
    }
}
