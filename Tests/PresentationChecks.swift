import Foundation
let sample = "› Hello\n\n• Hi there!\n\n ⠈ · \n› Ask Codex to do anything ⠁\n ⠈ \n gpt-6-astra low · ~"
assert(TerminalPresentation.conversation(sample, kind: "codex") == "› Hello\n\n• Hi there!")
let messages = TerminalPresentation.messages(sample, kind: "codex")
assert(messages.count == 2 && messages[0].fromUser && !messages[1].fromUser)
assert(messages[0].text == "Hello" && messages[1].text == "• Hi there!")
let output = "A result without a prompt"
assert(TerminalPresentation.messages(output, kind: "codex").first?.text == output)
assert(TerminalPresentation.conversation(sample, kind: "claude") == sample)
print("Presentation checks passed")
let multiline = "Previous assistant output\n\n› First paragraph\n\nSecond paragraph\n\n• Answer\n```\n› literal code\n```"
let grouped = TerminalPresentation.messages(multiline, kind: "codex")
assert(grouped.count == 3)
assert(grouped[0].text.contains("Previous assistant output"))
assert(grouped[1].text.contains("Second paragraph") && grouped[1].fromUser)
assert(grouped[2].text.contains("› literal code") && !grouped[2].fromUser)
let repeated = TerminalPresentation.messages("› hello\n• one\n› hello\n• two", kind: "codex")
assert(Set(repeated.map(\.id)).count == repeated.count)
assert(TerminalPresentation.mergeHistory("a\nb\nc\nd", live: "c\nd\ne") == "a\nb\nc\nd\ne")
assert(TerminalPresentation.mergeHistory("a\nb\nc\npar", live: "a\nb\nc\npartial response") == "a\nb\nc\npartial response")
assert(TerminalPresentation.mergeHistory("older", live: "unrelated").contains("— Live terminal view —"))
print("Leading output, multiline prompts, code fences, stable unique IDs and conservative history merging passed")
// A saved footer can sit inside accumulated history. It must never hide later turns.
let savedFooter = "› earlier\n• earlier reply\n› Ask Codex to do anything ⠁\n  gpt-6-astra low · ~"
let laterTurns = "\n\n— Live terminal view —\n\n› new message\n⚠ Falling back from WebSockets to HTTPS transport. request timed out\n• new reply"
let recovered = TerminalPresentation.messages(savedFooter + laterTurns, kind: "codex")
assert(recovered.contains { $0.text.contains("new message") })
assert(recovered.contains { $0.text.contains("new reply") }, "Interior cached footers must not truncate newer replies")
let completed = savedFooter + laterTurns + "\n›⠁Ask Codex to do anything ⠂\n  ⠈\n  gpt-6-astra low · ~"
let cleanedCompleted = TerminalPresentation.conversation(completed, kind: "codex")
assert(cleanedCompleted.contains("new reply"))
assert(!cleanedCompleted.hasSuffix("gpt-6-astra low · ~"))
assert(TerminalPresentation.activityNotice(completed, status: "working")?.contains("network") == true)
assert(TerminalPresentation.activityNotice(completed, status: "done") == nil)
assert(TerminalPresentation.activityNotice("Messages to be submitted after next tool call", status: "working")?.contains("queued") == true)
print("Interior footer regression, latest reply preservation, decorated footer and delivery-delay feedback passed")
let styled = TerminalPresentation.parts("• Received!\n\n  done 2:20 PM\n\nAnother reply\n  Worked for 1m 47s · done 2:07 PM", fromUser: false)
assert(styled.filter(\.status).map(\.text) == ["done 2:20 PM", "Worked for 1m 47s · done 2:07 PM"])
assert(!TerminalPresentation.parts("done 2:20 PM", fromUser: true)[0].status)
assert(!TerminalPresentation.parts("```\ndone 2:20 PM\n```", fromUser: false).contains(where: \.status))
let files = TerminalPresentation.artifacts("Saved to:\nfile:///Users/example/.codex/generated_images/id/\nexec-image.png\n[Report](</Users/example/My Report.pdf>)\n[Notes](notes.md)\n[Website](https://example.com/index.html)")
assert(files.map(\.path).contains("/Users/example/.codex/generated_images/id/exec-image.png"))
assert(files.map(\.path).contains("/Users/example/My Report.pdf"))
assert(files.map(\.path).contains("notes.md"))
assert(!files.contains { $0.path.contains("https:") })
assert(TerminalPresentation.artifacts("file:///tmp/a.png\n`/tmp/a.png`").count == 1)
assert(TerminalPresentation.messages("› Look at /tmp/a.png\n• Here is file:///tmp/b.png", kind: "codex")[0].artifacts.isEmpty)
print("Muted status classification, code/user preservation and artifact path/link/wrapping detection passed")
let wrappedRelative = """
• Here’s the image we created: The Starkeeper’s Observatory (.codex/
  generated_images/01a0c03b-e6a5-7273-9032-471792099402/
  exec-17bef5f5-6032-4907-8d81-
  a17f5948f7b4.png).
"""
let relativeImage = TerminalPresentation.artifacts(wrappedRelative)
assert(relativeImage.count == 1, "Wrapped paths must produce exactly one complete artifact")
assert(relativeImage[0].path == ".codex/generated_images/01a0c03b-e6a5-7273-9032-471792099402/exec-17bef5f5-6032-4907-8d81-a17f5948f7b4.png")
assert(relativeImage[0].isImage)
assert(TerminalPresentation.artifacts("Here is the image (images/result.png).").first?.path == "images/result.png")
assert(TerminalPresentation.artifacts("Here is (./images/result.png).").first?.path == "./images/result.png")
assert(TerminalPresentation.artifacts("https://example.com/images/result.png").isEmpty)
assert(TerminalPresentation.artifacts("An unfinished path (.codex/\n  this is unrelated prose).\nAnother paragraph").isEmpty)
print("Wrapped parenthesized relative image paths, punctuation, deduplication and URL rejection passed")
let startup = """
user@Mac Project % codex
╭──────────────────╮
│ >_ OpenAI Codex (v0.155.1) │
│ model: gpt-6-astra low │
│ directory: ~/Project │
╰──────────────────╯

Tip: Try the Desktop app. Run 'codex app' or visit
https://chatgpt.com/codex?app-landing-page=true

› Hello
• **Hello!**
"""
let startupCleaned = TerminalPresentation.messages(startup, kind: "codex")
assert(startupCleaned.count == 2 && startupCleaned[0].text == "Hello")
assert(!startupCleaned.contains { $0.text.contains("OpenAI Codex") })
let quotedStartup = "› Explain this\n• Here is the output:\n```\n" + startup + "\n```"
assert(TerminalPresentation.conversation(quotedStartup, kind: "codex").contains("OpenAI Codex"))
let blocks = ConversationBlock.parse("## Summary\n\n- **First**\n2. Second\n```swift\nlet value = 1\n```\nFinal paragraph")
assert(blocks.contains { $0.kind == .heading && $0.text == "Summary" })
assert(blocks.contains { $0.kind == .item("•") && $0.text == "**First**" })
assert(blocks.contains { $0.kind == .item("2.") })
assert(blocks.contains { $0.kind == .code && $0.text == "let value = 1" })
assert(ConversationBlock.parse("```\npartial").last == ConversationBlock(kind: .code, text: "partial"))
print("Startup banner cleanup, quoted-output preservation, Markdown lists/headings/code and streaming fences passed")

// The terminal transcript in the conversation-mode report: commands and temporary
// downloads should collapse, while the actual answer and its links stay readable.
let noisyTurn = """
› Check my website.
• I’ll check the page and its title.
✔ You approved codex to run curl -fsS https://example.com/ this time
• Running curl -fsS https://example.com/ -o /tmp/site-check.html
  │ && rg -o '<title>[^<]+' /tmp/site-check.html
• Ran curl -fsS https://example.com/ -o /tmp/site-check.html
  └ <title>My website
• The website is available at [example.com](https://example.com).

Keep your Mac awake while the server is running.
Worked for 13m 35s · done 8:29 PM
"""
let noisyMessages = TerminalPresentation.messages(noisyTurn, kind: "codex")
let quiet = TerminalPresentation.response(noisyMessages[1], kind: "codex", working: false)
assert(quiet.answer == "The website is available at [example.com](https://example.com).\n\nKeep your Mac awake while the server is running.")
assert(quiet.duration == "Worked for 13m 35s")
assert(quiet.activity.contains("You approved") && quiet.activity.contains("Ran curl") && quiet.activity.contains("I’ll check"))
assert(quiet.artifacts.isEmpty, "Temporary files mentioned in tool output must not become answer cards")
let inProgress = TerminalPresentation.messages("› Check the site.\n• I’ll check its title.\n• Running curl https://example.com", kind: "codex")
let thinking = TerminalPresentation.response(inProgress[1], kind: "codex", working: true)
assert(thinking.answer.isEmpty && thinking.activity.contains("Running curl"))
assert(inProgress[1].text.contains("• I’ll check"), "Collapsing must not mutate the searchable source")
let finished = TerminalPresentation.messages("› Check\n• Explored\n  └ Read README.md\n─ Worked for 2m 10s ─────\n• Done. See [notes](/tmp/release-notes.md).", kind: "codex")
let finalDuringStatusLag = TerminalPresentation.response(finished[1], kind: "codex", working: true)
assert(finalDuringStatusLag.answer == "Done. See [notes](/tmp/release-notes.md).")
assert(finalDuringStatusLag.duration == "Worked for 2m 10s")
assert(finalDuringStatusLag.artifacts.map(\.path) == ["/tmp/release-notes.md"])
let literal = SessionMessage(id: "literal", fromUser: false, text: "• Example:\n```\n• Ran curl\nWorked for 10s\n```\n- Keep this list\n\nAnother paragraph.")
let literalResponse = TerminalPresentation.response(literal, kind: "codex", working: false)
assert(literalResponse.answer.contains("• Ran curl") && literalResponse.answer.contains("Worked for 10s"))
assert(literalResponse.answer.contains("- Keep this list") && literalResponse.activity.isEmpty)
let noTools = SessionMessage(id: "prose", fromUser: false, text: "• Let me think.\n─ Worked for 5s ───\n• Here is the answer.")
assert(TerminalPresentation.response(noTools, kind: "codex", working: false).activity == "Let me think.")
assert(TerminalPresentation.response(noTools, kind: "codex", working: false).answer == "Here is the answer.")
assert(TerminalPresentation.response(noisyMessages[0], kind: "codex", working: true).answer == "Check my website.")
assert(TerminalPresentation.response(literal, kind: "claude", working: false).answer == literal.text)
let partial = SessionMessage(id: "partial", fromUser: false, text: "A partial viewport with no recognizable cells.")
assert(TerminalPresentation.response(partial, kind: "codex", working: false).answer == partial.text)
print("Collapsed activity: commands, approvals, progress, streaming, completion boundaries, final artifacts, quoted code, user text and fallback preservation passed")
let approvalFirst = TerminalPresentation.messages("› Do it.\n✔ You approved codex to run swift test this time\n• Ran swift test\n  └ Passed\n• Done.", kind: "codex")
assert(approvalFirst[0].text == "Do it." && approvalFirst.count == 2)
assert(TerminalPresentation.response(approvalFirst[1], kind: "codex", working: false).answer == "Done.")
print("Approval-first responses stay out of user messages")

let screenshotHistory = """
› Merge latest dev.
• Running yarn install
  └ Linking dependencies
› Ask Codex to do anything
GPT-6-Astra low fast · ~/Documents/PROJECTS/AP-NEW · Check dev against origin    ⚠ 1 warning · f2 to view

— Live terminal view —

core/supabase/migrations/example.sql:111: new blank line at EOF.
  +6 lines (ctrl+t to view transcript)
Working (2m 28s • esc to interrupt)
─ Worked for 2m 32s ───
• Merged latest origin/dev and pushed.

Resolved four conflicts. All checks pass.
› Ask Codex to do anything
GPT-6-Astra low fast · ~/Documents/PROJECTS/AP-NEW · Check dev against origin    ⚠ 1 warning · f2 to view
"""
let screenshotMessages = TerminalPresentation.messages(screenshotHistory, kind: "codex")
assert(screenshotMessages.filter(\.fromUser).map(\.text) == ["Merge latest dev."])
assert(!screenshotMessages.contains { $0.text.contains("GPT-6-Astra") || $0.text.contains("Ask Codex") })
let screenshotResponses = screenshotMessages.filter { !$0.fromUser }.map { TerminalPresentation.response($0, kind: "codex", working: false) }
assert(screenshotResponses.last?.answer == "Merged latest origin/dev and pushed.\n\nResolved four conflicts. All checks pass.")
assert(screenshotResponses.last?.activity.contains("new blank line at EOF") == true)
assert(!screenshotResponses.contains { $0.answer.contains("ctrl+t") || $0.answer.contains("esc to interrupt") || $0.answer.contains("Live terminal view") })
let quotedChrome = "› Explain this\n• Example:\n```\n› Ask Codex to do anything\nGPT-6-Astra low fast · ~/Project\n— Live terminal view —\n```"
assert(TerminalPresentation.messages(quotedChrome, kind: "codex").last?.text.contains("GPT-6-Astra") == true)
print("Screenshot regression: cached composers, model footers, terminal fragments and transient status stay out of chat; fenced examples survive")

let settingsCard = """
/status
╭──────────────────────────────────────────╮
│ >_ OpenAI Codex (v0.155.1)                │
│ Model: gpt-6-astra (reasoning low)        │
│ Permissions: Full Access                 │
│ Account: example                        │
╰──────────────────────────────────────────╯
"""
let settingsHistory = "› Hello\n• A clear reply.\n\n" + settingsCard + "\n› Ask Codex to do anything\n  GPT-6-Astra low fast · ~/project"
let withoutSettings = TerminalPresentation.messages(settingsHistory, kind: "codex")
assert(withoutSettings.map(\.text) == ["Hello", "• A clear reply."])
let quotedSettings = TerminalPresentation.messages("› Explain this\n• Example:\n```\n" + settingsCard + "\n```", kind: "codex")
assert(quotedSettings.last?.text.contains("Permissions: Full Access") == true)
assert(TerminalPresentation.conversation(settingsCard, kind: "claude") == settingsCard)
print("Codex settings reports stay out of conversation; quoted and non-Codex output remains intact")
