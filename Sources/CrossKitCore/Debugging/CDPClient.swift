import Foundation

/// Chrome DevTools Protocol client over a WebSocket: the protocol of the Node.js inspector
/// (`node --inspect-brk`). Requests are `{id, method, params}`; events are `{method, params}`.
public final class CDPClient: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    public typealias EventHandler = @Sendable (_ method: String, _ params: JSONValue) -> Void

    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventHandler: EventHandler?
    private var closed = false
    private var opened = false

    public init(url: URL) {
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
        receiveNext()
    }

    public func onEvent(_ handler: @escaping EventHandler) {
        lock.withLock { eventHandler = handler }
    }

    /// Waits until the WebSocket handshake finished (or fails after `timeout`).
    public func waitUntilOpen(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !lock.withLock({ opened }) {
            if lock.withLock({ closed }) { throw DebugError.launchFailed("the Node.js inspector closed the connection.") }
            if Date() > deadline { throw DebugError.launchFailed("could not connect to the Node.js inspector.") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.withLock { opened = true }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        fail("the Node.js inspector closed the connection.")
    }

    @discardableResult
    public func request(_ method: String, _ params: JSONValue = [:], timeout: TimeInterval = 15) async throws -> JSONValue {
        let id: Int = lock.withLock { defer { nextID += 1 }; return nextID }
        let message: JSONValue = ["id": .int(id), "method": .string(method), "params": params]
        let text = String(decoding: try message.encoded(), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            let isClosed: Bool = lock.withLock {
                if closed { return true }
                pending[id] = continuation
                return false
            }
            if isClosed {
                continuation.resume(throwing: DebugError.launchFailed("the Node.js inspector is not connected."))
                return
            }
            task.send(.string(text)) { [weak self] error in
                guard let error, let self, let c = self.lock.withLock({ self.pending.removeValue(forKey: id) }) else { return }
                c.resume(throwing: DebugError.launchFailed("\(method): \(error.localizedDescription)"))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let c = self.lock.withLock({ self.pending.removeValue(forKey: id) }) else { return }
                c.resume(throwing: DebugError.launchFailed("\(method) timed out after \(Int(timeout))s"))
            }
        }
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail("the Node.js inspector connection ended (\(error.localizedDescription)).")
            case .success(let message):
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: data = Data()
                }
                if let value = try? JSONDecoder().decode(JSONValue.self, from: data) { self.dispatch(value) }
                self.receiveNext()
            }
        }
    }

    private func dispatch(_ message: JSONValue) {
        if let id = message["id"]?.intValue {
            guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: DebugError.launchFailed(error["message"]?.stringValue ?? "inspector request failed"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        } else if let method = message["method"]?.stringValue {
            let handler = lock.withLock { eventHandler }
            handler?(method, message["params"] ?? .null)
        }
    }

    private func fail(_ reason: String) {
        let (waiting, wasClosed): ([CheckedContinuation<JSONValue, Error>], Bool) = lock.withLock {
            let was = closed
            closed = true
            defer { pending.removeAll() }
            return (Array(pending.values), was)
        }
        for continuation in waiting { continuation.resume(throwing: DebugError.launchFailed(reason)) }
        if !wasClosed {
            let handler = lock.withLock { eventHandler }
            handler?("CrossKit.disconnected", .null)
        }
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        fail("closed")
    }

    /// `ws://…` URL from the inspector banner (`Debugger listening on ws://127.0.0.1:9229/<uuid>`).
    public static func webSocketURL(inBanner text: String) -> URL? {
        guard let range = text.range(of: #"ws://[^\s]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    /// JavaScript regex source matching a file's URL (`file:///private/tmp/x.ts` and `/tmp/x.ts` alike).
    public static func urlRegex(forFile path: String) -> String {
        var tail = LaunchPlanner.canonicalPath(path)
        if tail.hasPrefix("/private/") { tail = String(tail.dropFirst("/private".count)) }
        let escaped = tail.map { ch -> String in "\\^$.*+?()[]{}|/".contains(ch) ? "\\" + String(ch) : String(ch) }.joined()
        return "^file://(?:/private)?" + escaped + "$"
    }

    /// Path from a `file://` script URL.
    public static func path(fromURL url: String) -> String? {
        guard url.hasPrefix("file://"), let parsed = URL(string: url) else { return nil }
        return parsed.path
    }
}
