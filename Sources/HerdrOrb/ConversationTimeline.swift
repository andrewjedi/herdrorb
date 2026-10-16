import Foundation

struct ConversationTimelineItem: Equatable, Identifiable {
    enum Kind { case message, work }
    var id: String
    var kind: Kind
    var messages: [SessionMessage]
    var duration: String? = nil
}

/// A pure display projection. Source messages remain intact in the searchable archive.
enum ConversationTimeline {
    static func items(_ messages: [SessionMessage], provider: String?, working: Bool) -> [ConversationTimelineItem] {
        var normalized: [SessionMessage] = []
        var durations: [String: String] = [:]
        for message in messages {
            if !message.fromUser && message.source == nil && provider == "codex" && message.text.count <= LongMessagePresentation.limit {
                let response = TerminalPresentation.response(message, kind: provider, working: working && message.id == messages.last?.id)
                if !response.activity.isEmpty {
                    var activity = message
                    activity.id += ":work"; activity.text = response.activity; activity.phase = "commentary"
                    activity.source = "terminal-presentation"; activity.artifacts = []; activity.parts = []
                    normalized.append(activity)
                    durations[activity.id] = response.duration
                }
                if !response.answer.isEmpty {
                    var answer = message
                    answer.text = response.answer; answer.source = "terminal-presentation"
                    answer.parts = [.init(text: response.answer, status: false)]; answer.artifacts = response.artifacts
                    normalized.append(answer)
                }
            } else { normalized.append(message) }
        }
        var result: [ConversationTimelineItem] = [], turn: [SessionMessage] = []
        func flushTurn() {
            guard !turn.isEmpty else { return }
            let lastTool = turn.lastIndex(where: { $0.activity != nil })
            var work: [SessionMessage] = []
            func flushWork() {
                guard let first = work.first else { return }
                result.append(.init(id: "work:" + first.id, kind: .work, messages: work,
                                    duration: work.compactMap { durations[$0.id] }.last))
                work = []
            }
            for (index, message) in turn.enumerated() {
                let commentary = message.phase == "commentary" || (!message.parts.isEmpty && message.parts.allSatisfy(\.status))
                // Claude prose preceding a tool is narration. Prose after the last
                // tool remains the answer; explicit Codex final answers always stay visible.
                let beforeTool = message.source == "claude" && lastTool.map { index < $0 } == true
                if message.activity != nil || (message.phase != "final_answer" && (commentary || beforeTool)) { work.append(message) }
                else { flushWork(); result.append(.init(id: "message:" + message.id, kind: .message, messages: [message])) }
            }
            flushWork(); turn = []
        }
        for message in normalized {
            if message.fromUser {
                flushTurn()
                result.append(.init(id: "message:" + message.id, kind: .message, messages: [message]))
            } else { turn.append(message) }
        }
        flushTurn()
        return result
    }
}
