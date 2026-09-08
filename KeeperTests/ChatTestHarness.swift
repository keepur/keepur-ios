import XCTest
import SwiftData
import Combine
@testable import Keepur

@MainActor
final class WeakReference {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}

@MainActor
func reflectedObject(_ root: Any, _ name: String) throws -> AnyObject {
    let field = try XCTUnwrap(
        Mirror(reflecting: root).children.first { $0.label == name }?.value
    )
    let mirror = Mirror(reflecting: field)
    let value: Any = mirror.displayStyle == .optional
        ? try XCTUnwrap(mirror.children.first?.value) : field
    XCTAssertEqual(Mirror(reflecting: value).displayStyle, .class)
    return value as AnyObject
}

@MainActor
struct ConciergeFlowProbe {
    let task: Task<Void, Never>
    let run: WeakReference
    let latch: WeakReference
    let subscription: WeakReference

    init(_ coordinator: ConciergeViewModel) throws {
        let field = try XCTUnwrap(
            Mirror(reflecting: coordinator).children.first { $0.label == "flowTask" }?.value
        )
        let stored = try XCTUnwrap(field as? Optional<Task<Void, Never>>)
        task = try XCTUnwrap(stored)
        let run = try reflectedObject(coordinator, "activeRun")
        let latch = try reflectedObject(run, "replyLatch")
        let subscription = try reflectedObject(latch, "subscription")
        self.run = WeakReference(run)
        self.latch = WeakReference(latch)
        self.subscription = WeakReference(subscription)
    }
}

@MainActor
func eventually(_ label: String, timeout: Duration = .seconds(1),
                file: StaticString = #filePath, line: UInt = #line,
                _ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(try condition()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out: \(label)", file: file, line: line)
            throw NSError(domain: "ChatTestHarness.Timeout", code: 1)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
final class ChatTestHarness {
    let credentials: FakeCredentialStore
    let factory: FakeWebSocketTaskFactory
    let container: ModelContainer
    let context: ModelContext
    let socket: BeekeeperSocket
    let vm: ChatViewModel
    let suiteName: String
    let defaults: UserDefaults
    let store: ConciergeSessionStore
    var task: FakeWebSocketTask { factory.latest! }
    private(set) var received = 0
    private var observer: AnyCancellable?

    init(watchdog: Duration = .seconds(90), configure: Bool = true,
         speech: SpeechManager? = nil) throws {
        let credentials = FakeCredentialStore(), factory = FakeWebSocketTaskFactory()
        let suiteName = "ChatTestHarness.\(UUID().uuidString)"
        let container = try ModelContainer(for: Session.self, Message.self, Workspace.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let socket = BeekeeperSocket(credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) })
        let vm = ChatViewModel(socket: socket, credentials: credentials,
                              speech: speech, staleBusyTimeout: watchdog)
        self.credentials = credentials
        self.factory = factory
        self.suiteName = suiteName
        self.container = container
        self.context = context
        self.defaults = defaults
        self.store = ConciergeSessionStore(defaults: defaults)
        self.socket = socket
        self.vm = vm
        observer = vm.incoming.sink { [weak self] _ in self?.received += 1 }
        if configure { vm.configure(context: context) }
    }
    func close() {
        taskIfPresent?.onSend = nil
        vm.unpair()
        observer?.cancel()
        defaults.removePersistentDomain(forName: suiteName)
    }
    private var taskIfPresent: FakeWebSocketTask? { factory.latest }
    func connect() async throws {
        if factory.latest == nil { vm.configure(context: context) }
        try await eventually("handshake requested") { self.task.handshakeRequested }
        task.completeHandshake()
        try await eventually("connected and receive armed") {
            self.vm.connectionState == .connected && self.task.receiveRequested
        }
    }
    func receive(_ object: [String: Any]) async throws {
        try await eventually("receive callback armed") { self.task.receiveRequested }
        let before = received
        let data = try JSONSerialization.data(withJSONObject: object)
        task.deliver(String(decoding: data, as: UTF8.self))
        try await eventually("decoded frame delivered") { self.received == before + 1 }
    }
    func status(_ state: String, id: String = "a", tool: String? = nil) async throws {
        var frame: [String: Any] = ["type": "status", "state": state, "sessionId": id]
        if let tool { frame["toolName"] = tool }
        try await receive(frame)
    }
    func list(_ rows: [(String, String, String)]) async throws {
        try await receive(["type": "session_list", "sessions": rows.map {
            ["sessionId": $0.0, "path": "/\($0.0)", "state": $0.1, "mode": $0.2]
        }])
    }
    func chunk(_ text: String, id: String = "a", final: Bool = false) async throws {
        try await receive(["type": "message", "text": text, "sessionId": id, "final": final])
    }
    func approval(_ use: String, id: String? = "a") async throws {
        var frame: [String: Any] = ["type": "tool_approval", "toolUseId": use,
                                    "tool": "shell", "input": "{}"]
        if let id { frame["sessionId"] = id }
        try await receive(frame)
    }
    func messages(_ id: String? = nil, role: String? = nil) throws -> [Message] {
        try context.fetch(FetchDescriptor<Message>()).filter {
            (id == nil || $0.sessionId == id) && (role == nil || $0.role == role)
        }
    }
    func sessions() throws -> [Session] { try context.fetch(FetchDescriptor<Session>()) }
    func workspaces() throws -> [Workspace] { try context.fetch(FetchDescriptor<Workspace>()) }
    func frames(_ type: String? = nil) throws -> [[String: Any]] {
        try task.sentTexts.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter { type == nil || $0["type"] as? String == type }
    }
    @discardableResult
    func send(_ text: String, id: String = "a", attachment: AttachmentData? = nil) throws -> String {
        let old = Set(try messages().map(\.id))
        vm.currentSessionId = id
        vm.messageText = text
        vm.pendingAttachment = attachment
        vm.sendText()
        return try XCTUnwrap(messages().first { !old.contains($0.id) }?.id)
    }
}
