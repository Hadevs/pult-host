import AppKit
import Network
import Observation

/// Accepts one client at a time, streams the screen to it, and applies its
/// input. Two listeners: the plain port (home network only, and where a new
/// client is handed the remote key), and the TLS port that may face the
/// internet. A new client replaces the current one.
@Observable
final class HostServer {
    enum Status: Equatable {
        case starting
        case listening
        case connected(peer: String)
        case failed(String)
    }

    var status: Status = .starting
    /// Off by default: on the home network, anyone who can reach the port may
    /// connect. The internet-facing port always requires the key regardless.
    var requireCode = UserDefaults.standard.bool(forKey: "requireCode") {
        didSet { UserDefaults.standard.set(requireCode, forKey: "requireCode") }
    }
    let pairingCode: String
    @ObservationIgnored let access = RemoteAccess()

    @ObservationIgnored private let queue = DispatchQueue(label: "com.hadevs.pult.host.net", qos: .userInteractive)
    @ObservationIgnored private let streamer = ScreenStreamer()
    @ObservationIgnored private let input = InputInjector()
    @ObservationIgnored private let cursor = CursorTracker()
    @ObservationIgnored private let lockMonitor = LockScreen.Monitor()

    @ObservationIgnored private var plainListener: NWListener?
    @ObservationIgnored private var secureListener: NWListener?
    @ObservationIgnored private var client: NWConnection?
    @ObservationIgnored private var clientIsSecure = false
    @ObservationIgnored private var parser = MessageParser()
    @ObservationIgnored private var sentFrameId: UInt32 = 0
    @ObservationIgnored private var ackedFrameId: UInt32 = 0
    @ObservationIgnored private var failedAttempts = 0
    @ObservationIgnored private var displayAssertion: PowerAssertion?

    init() {
        pairingCode = Self.loadOrMakePairingCode()
        streamer.canSend = { [weak self] in
            guard let self else { return false }
            return self.queue.sync { self.sentFrameId &- self.ackedFrameId < UInt32(Pult.maxFramesInFlight) }
        }
        streamer.onFrame = { [weak self] in self?.sendFrame($0) }
        streamer.onStopped = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.restartCaptureIfConnected() }
        }
        cursor.onMove = { [weak self] p in self?.send(.cursorPos) { $0.f32(Float(p.x)); $0.f32(Float(p.y)) } }
        cursor.onImage = { [weak self] image in self?.send(.cursorImage) { image.encode(&$0) } }
        lockMonitor.onChange = { [weak self] locked in self?.send(.lockState) { $0.u8(locked ? 1 : 0) } }
    }

    // MARK: Lifecycle

    func start() {
        access.startRefreshing()
        let name = Host.current().localizedName ?? "Mac"
        do {
            secureListener = try makeListener(port: Pult.securePort, psk: access.psk, bonjourName: nil, secure: true)
            plainListener = try makeListener(port: Pult.port, psk: nil, bonjourName: name, secure: false)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func makeListener(port: UInt16, psk: Data?, bonjourName: String?, secure: Bool) throws -> NWListener {
        let params = Pult.parameters(psk: psk)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        if let bonjourName {
            // Bonjour only on the plain port; a failed registration must not
            // take down the internet-facing listener.
            listener.service = NWListener.Service(name: bonjourName, type: Pult.bonjourType)
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c, secure: secure) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready where !secure:
                    if case .connected = self.status {} else { self.status = .listening }
                case .failed(let e):
                    if secure { Log.server.error("secure listener failed: \(e.localizedDescription, privacy: .public)") }
                    else { self.status = .failed(e.localizedDescription) }
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
        return listener
    }

    // MARK: Accepting a client

    private func accept(_ c: NWConnection, secure: Bool) {
        // The plain port is home-only, even if a router forwards it by mistake.
        guard secure || NetworkAddresses.isLocal(c.endpoint) else {
            Log.server.notice("refused plain connection from \(String(describing: c.endpoint), privacy: .public)")
            c.cancel()
            return
        }
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            if case .failed = state { self.queue.async { self.dropped(c) } }
            if case .cancelled = state { self.queue.async { self.dropped(c) } }
        }
        c.start(queue: queue)
        awaitHello(c, secure: secure)
        // Drop a connection that never says hello.
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.client !== c, c.state != .cancelled { c.cancel() }
        }
    }

    private func awaitHello(_ c: NWConnection, secure: Bool) {
        var handshakeParser = MessageParser()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data, let messages = try? handshakeParser.feed(data), let (type, body) = messages.first {
                    self.handshake(c, secure: secure, type: type, body: body)
                } else if done || error != nil {
                    c.cancel()
                } else {
                    read()
                }
            }
        }
        read()
    }

    private func handshake(_ c: NWConnection, secure: Bool, type: MsgType, body: Data) {
        var r = ByteReader(body)
        guard type == .hello, let version = try? r.u8(), let code = try? r.string() else { c.cancel(); return }
        guard failedAttempts < 20 else { return deny(c, "Too many attempts — restart Pult on the Mac") }
        guard version == Pult.version else { return deny(c, "Version mismatch — update the app") }
        // On the TLS port the pre-shared key already proved the client's identity.
        if !secure, requireCode, !constantTimeEqual(code.uppercased(), pairingCode) {
            failedAttempts += 1
            return deny(c, "Wrong pairing code")
        }
        failedAttempts = 0

        client.map { replace in
            replace.stateUpdateHandler = nil
            replace.cancel()
            DispatchQueue.main.async { self.input.releaseAll() }
        }
        client = c
        clientIsSecure = secure
        parser = MessageParser()
        sentFrameId = 0
        ackedFrameId = 0
        let peer = String(describing: c.endpoint)
        DispatchQueue.main.async { self.beginSession(peer: peer) }
        receiveLoop(c)
    }

    private func deny(_ c: NWConnection, _ reason: String) {
        c.send(content: Message.make(.helloDenied) { $0.string(reason) },
               completion: .contentProcessed { _ in c.cancel() })
    }

    private func receiveLoop(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, self.client === c else { return }
            if let data {
                do {
                    for (type, body) in try self.parser.feed(data) { self.handle(type, body) }
                } catch {
                    Log.server.error("protocol error, dropping client: \(error.localizedDescription, privacy: .public)")
                    return self.dropped(c)
                }
            }
            if done || error != nil { self.dropped(c) } else { self.receiveLoop(c) }
        }
    }

    private func dropped(_ c: NWConnection) {
        guard client === c else { return }
        client = nil
        c.cancel()
        DispatchQueue.main.async {
            self.input.releaseAll()
            self.endSession()
        }
    }

    // MARK: Session (main thread)

    @MainActor private func beginSession(peer: String) {
        status = .connected(peer: peer)
        PowerAssertion.wakeDisplay(reason: "Pult client connected")
        displayAssertion = PowerAssertion.keepDisplayOn(reason: "Pult streaming")
        Task {
            await restartCapture(initial: true)
            lockMonitor.start()
        }
    }

    @MainActor private func endSession() {
        status = .listening
        streamer.stop()
        cursor.stop()
        lockMonitor.stop()
        displayAssertion = nil
    }

    private func restartCaptureIfConnected() {
        guard case .connected = status else { return }
        Task { await restartCapture(initial: false) }
    }

    @MainActor private func restartCapture(initial: Bool) async {
        streamer.stop()
        do {
            try await streamer.start()
            guard let info = streamer.info else { return }
            input.displayBounds = streamer.displayBounds
            cursor.start(displayBounds: streamer.displayBounds)
            if initial {
                let pair = access.pairInfo(name: info.name)
                send(.helloOK) { info.encode(&$0) }
                send(.pairInfo) { pair.encode(&$0) }
            } else {
                send(.screenInfo) { info.encode(&$0) }
            }
            streamer.requestKeyframe()
        } catch {
            Log.capture.error("capture start failed: \(error.localizedDescription, privacy: .public)")
            if initial {
                queue.async { self.client.map { self.deny($0, "Screen capture failed — grant Screen Recording to Pult on the Mac") } }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.restartCaptureIfConnected() }
            }
        }
    }

    // MARK: Messages from the client (net queue)

    private func handle(_ type: MsgType, _ body: Data) {
        var r = ByteReader(body)
        do {
            switch type {
            case .mouseMove:
                let x = try r.f32(), y = try r.f32()
                DispatchQueue.main.async { self.input.moveMouse(x: x, y: y); self.cursor.noteInjected(self.input.lastInjected) }
            case .mouseButton:
                let button = try r.u8(), down = try r.u8() == 1, clicks = try r.u8()
                DispatchQueue.main.async { self.input.mouseButton(button, down: down, clickCount: clicks) }
            case .mouseMoveRelative:
                let dx = try r.f32(), dy = try r.f32()
                DispatchQueue.main.async { self.input.moveMouseRelative(dx: dx, dy: dy) }
            case .scroll:
                let dx = try r.f32(), dy = try r.f32()
                DispatchQueue.main.async { self.input.scroll(dx: dx, dy: dy) }
            case .key:
                let code = try r.u16(), down = try r.u8() == 1, mods = Modifiers(rawValue: try r.u32())
                DispatchQueue.main.async { self.input.key(code: code, down: down, modifiers: mods) }
            case .text:
                let text = String(decoding: r.rest(), as: UTF8.self)
                DispatchQueue.main.async { self.input.type(text) }
            case .dictation:
                let text = String(decoding: r.rest(), as: UTF8.self)
                DispatchQueue.main.async {
                    let inserted = self.input.insertOrCopy(text)
                    self.send(.dictationResult) { $0.u8(inserted ? 1 : 0) }
                }
            case .image:
                let data = r.rest()
                DispatchQueue.main.async {
                    let pasted = self.input.insertImage(data)
                    self.send(.imageResult) { $0.u8(pasted ? 1 : 0) }
                }
            case .unlock:
                let password = String(decoding: r.rest(), as: UTF8.self)
                let secure = clientIsSecure
                DispatchQueue.main.async { self.unlock(password, secure: secure) }
            case .requestKeyframe:
                streamer.requestKeyframe()
            case .ping:
                let clock = try r.u64()
                send(.pong) { $0.u64(clock) }
            case .frameAck:
                let id = try r.u32()
                let wasFull = sentFrameId &- ackedFrameId >= UInt32(Pult.maxFramesInFlight)
                if Int32(bitPattern: id &- ackedFrameId) > 0 { ackedFrameId = id }
                if wasFull { streamer.pipeDrained() }
            default:
                break
            }
        } catch {
            Log.server.error("bad \(String(describing: type), privacy: .public) message")
        }
    }

    @MainActor private func unlock(_ password: String, secure: Bool) {
        guard secure else { return send(.unlockResult) { $0.u8(UnlockResult.needsEncryption.rawValue) } }
        LockScreen.unlock(password: password, input: input) { [weak self] result in
            self?.send(.unlockResult) { $0.u8(result.rawValue) }
        }
    }

    // MARK: Sending

    private func send(_ type: MsgType, _ body: @escaping (inout ByteWriter) -> Void = { _ in }) {
        let data = Message.make(type, body)
        queue.async { self.client?.send(content: data, completion: .idempotent) }
    }

    private func sendFrame(_ frame: VideoFrame) {
        let data = Message.make(.video) { frame.encode(&$0) }
        queue.async {
            guard self.client != nil else { return }
            self.sentFrameId = frame.id
            self.client?.send(content: data, completion: .idempotent)
        }
    }

    // MARK: Pairing code

    private static func loadOrMakePairingCode() -> String {
        let key = "pairingCode"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")   // no look-alikes
        let code = String((0..<10).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(code, forKey: key)
        return code
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
