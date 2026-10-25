import Foundation

enum OutputTarget: String, CaseIterable {
    case main
    case hp

    var treeName: String {
        switch self {
        case .main: "hwout0"
        case .hp: "hwout1"
        }
    }

    var label: String {
        switch self {
        case .main: "Main Out"
        case .hp: L("Headphones", "Kulaklık")
        }
    }

    var other: OutputTarget { self == .main ? .hp : .main }
}

struct OutputState: Equatable {
    var gain: Double
    var muted: Bool
    var dimmed: Bool
}

struct DuetState: Equatable {
    var uid: String
    var name: String
    var outputs: [OutputTarget: OutputState]
}

enum StateChangeSource {
    case resync // fresh tree from ApogeeGlue
    case local // this process
    case external // knob, Apogee Control 2, ...
}

/// Talks to ApogeeGlue directly, the same way Apogee Control 2 does. All public
/// API and callbacks run on the main thread.
final class GlueClient: @unchecked Sendable {
    static let gainRange = -64.0...0.0

    private(set) var state: DuetState?
    private(set) var isConnected = false
    var onChange: ((DuetState?, StateChangeSource) -> Void)?

    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var generation = 0
    private var keyMap: [UInt32: (OutputTarget, String)] = [:]
    private var lastTreeLoad = Date.distantPast

    func start() {
        connect()
    }

    // MARK: Commands

    func setGain(_ target: OutputTarget, dB: Double) {
        guard var output = state?.outputs[target] else { return }
        let value = (dB.clamped(to: Self.gainRange) * 2).rounded() / 2
        output.gain = value
        update(target, output)
        send(path: path(target, "gain"), value: .double(value))
    }

    func setMuted(_ target: OutputTarget, _ muted: Bool) {
        guard var output = state?.outputs[target] else { return }
        output.muted = muted
        update(target, output)
        send(path: path(target, "mute"), value: .int(muted ? 1 : 0))
    }

    func setDimmed(_ target: OutputTarget, _ dimmed: Bool) {
        guard var output = state?.outputs[target] else { return }
        output.dimmed = dimmed
        update(target, output)
        send(path: path(target, "dim"), value: .int(dimmed ? 1 : 0))
    }

    private func update(_ target: OutputTarget, _ output: OutputState) {
        state?.outputs[target] = output
        onChange?(state, .local)
    }

    private func path(_ target: OutputTarget, _ property: String) -> String {
        "/dev/\(state?.uid ?? "")/hwout/\(target.treeName)/\(property)"
    }

    private func send(path: String, value: GlueValue) {
        write(GlueProtocol.setProperty(path: path, value: value))
    }

    // MARK: Connection

    private func connect() {
        generation += 1
        let myGeneration = generation
        Thread.detachNewThread { [weak self] in
            self?.run(generation: myGeneration)
        }
    }

    private func run(generation myGeneration: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return scheduleReconnect(myGeneration) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = GlueProtocol.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return scheduleReconnect(myGeneration)
        }

        lock.withLock { socketFD = fd }
        write(GlueProtocol.frame(type: .hello, body: []))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { break }
            buffer.append(chunk, count: count)
            let messages = GlueProtocol.takeMessages(from: &buffer)
                .filter { $0.type != GlueMessageType.meters.rawValue }
            if !messages.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == myGeneration else { return }
                    messages.forEach { self.handle(type: $0.type, body: $0.body) }
                }
            }
        }

        lock.withLock {
            if socketFD == fd { socketFD = -1 }
        }
        close(fd)
        debugLog("glue connection closed")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == myGeneration else { return }
            self.isConnected = false
            self.state = nil
            self.onChange?(nil, .resync)
        }
        scheduleReconnect(myGeneration)
    }

    private func scheduleReconnect(_ myGeneration: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == myGeneration else { return }
            self.connect()
        }
    }

    /// Drops the connection; the read loop then reconnects and re-reads the tree.
    private func resync() {
        lock.withLock {
            if socketFD >= 0 { shutdown(socketFD, SHUT_RDWR) }
        }
    }

    private func write(_ data: Data) {
        lock.withLock {
            guard socketFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let sent = Darwin.send(socketFD, raw.baseAddress! + offset, raw.count - offset, 0)
                    if sent <= 0 { break }
                    offset += sent
                }
            }
        }
    }

    // MARK: Incoming

    private func handle(type: UInt8, body: Data) {
        switch GlueMessageType(rawValue: type) {
        case .entireTree:
            guard let inflated = GlueProtocol.inflate(body), let root = GlueTree.parse(inflated) else {
                debugLog("could not decode glue tree")
                return
            }
            isConnected = true
            lastTreeLoad = Date()
            loadDevice(from: root)
        case .setProperty:
            guard let (key, value) = GlueValue.decodeSetProperty(body),
                  let (target, property) = keyMap[key],
                  var output = state?.outputs[target] else { return }
            switch property {
            case "gain": output.gain = value.doubleValue ?? output.gain
            case "mute": output.muted = value.boolValue ?? output.muted
            case "dim": output.dimmed = value.boolValue ?? output.dimmed
            default: return
            }
            guard output != state?.outputs[target] else { return }
            state?.outputs[target] = output
            onChange?(state, .external)
        case .setSubtree, .addTree:
            // A device was plugged in or re-enumerated; the simplest correct
            // response is to fetch the whole tree again.
            let path = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            if path.hasPrefix("/dev"), Date().timeIntervalSince(lastTreeLoad) > 2 {
                debugLog("glue tree changed at \(path); resyncing")
                resync()
            }
        default:
            break
        }
    }

    private func loadDevice(from root: GlueTree) {
        guard let device = root.child("dev")?.children.first(where: { $0.name.hasPrefix("DuetII") })
            ?? root.child("dev")?.children.first,
            let hwout = device.child("hwout") else {
            state = nil
            keyMap = [:]
            onChange?(nil, .resync)
            return
        }

        var outputs: [OutputTarget: OutputState] = [:]
        var keys: [UInt32: (OutputTarget, String)] = [:]
        for target in OutputTarget.allCases {
            guard let node = hwout.child(target.treeName) else { continue }
            outputs[target] = OutputState(
                gain: node.properties["gain"]?.doubleValue ?? 0,
                muted: node.properties["mute"]?.boolValue ?? false,
                dimmed: node.properties["dim"]?.boolValue ?? false
            )
            for property in ["gain", "mute", "dim"] {
                keys[GlueProtocol.key("/dev/\(device.name)/hwout/\(target.treeName)/\(property)")] = (target, property)
            }
        }

        keyMap = keys
        state = DuetState(
            uid: device.name,
            name: { if case .string(let name) = device.properties["name"] { return name }; return "Duet" }(),
            outputs: outputs
        )
        debugLog("glue state loaded for \(device.name)")
        onChange?(state, .resync)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
