import Foundation

/// Fictional fixtures only. Demo mode never discovers profiles or starts a subprocess.
actor DemoConnection: HerdrConnection {
    let machine: Machine
    private var output = "› Help me prepare this project for release.\n\n• The release checklist is ready.\n\n## Ready to share\n\n- Installation instructions\n- Connection recovery\n- Private local settings\n\nYou can switch between machines without losing your draft.\n\n```swift\nlet nextStep = \"Ship something useful\"\n```"
    init(_ machine: Machine) { self.machine = machine }
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        switch method {
        case "session.snapshot":
            return ["_herdrorb_version": "0.9.1", "snapshot": ["protocol": 22,
                "panes": [["pane_id": "demo-pane", "terminal_id": "demo-terminal", "tab_id": "demo-tab", "workspace_id": "demo-workspace"]],
                "agents": [["pane_id": "demo-pane", "agent": machine.id == "local" ? "codex" : "claude", "agent_status": "idle"]],
                "tabs": [["tab_id": "demo-tab", "label": machine.id == "local" ? "Release checklist" : "Documentation"]],
                "workspaces": [["workspace_id": "demo-workspace", "label": "Sample project"]]]]
        case "pane.read": return ["read": ["text": output]]
        case "agent.prompt":
            output += "\n\n› \(params["text"] as? String ?? "Demo message")\n\n• This is a local demo response. No message was sent to an agent."
            return ["sent": true]
        default: throw RPCError(code: "demo", message: "This action is unavailable in demo mode.")
        }
    }
    func events() async throws -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
    func shutdown() async { }
}

@MainActor enum AppModel {
    static func make() -> BubbleModel {
        if AppPreferences.isDemo || AppPreferences.isSetupPreview {
            let preferences = AppPreferences.current
            preferences.set(false, forKey: "saveConversations")
            let cache = ConversationCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("herdrorb-preview-" + UUID().uuidString))
            if AppPreferences.isSetupPreview {
                return BubbleModel(cache: cache, preferences: preferences, discover: {
                    throw RPCError(code: "missing", message: "Herdr was not found. Install Herdr and start it, then check again.")
                }, makeTransport: { DemoConnection($0) })
            }
            let machines = [Machine.local, Machine(id: "demo-studio", label: "Studio Mac")]
            return BubbleModel(cache: cache, preferences: preferences, isDemo: true,
                               probeAgents: { _ in AgentAvailability(codex: true, claude: true) },
                               discover: { machines }, makeTransport: { DemoConnection($0) })
        }
        return BubbleModel()
    }
}
