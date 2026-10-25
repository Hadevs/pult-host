import CoreGraphics
import Foundation

/// The Pult wire protocol: constants, message types and payloads, shared by
/// the host and its clients. PROTOCOL.md specifies the byte layout.
enum Pult {
    /// Bumped only for incompatible changes; the host refuses other versions.
    static let version: UInt8 = 1
    /// Plain TCP, accepted only from the host's own networks (LAN, Tailscale).
    static let port: UInt16 = 7777
    /// TLS 1.2 with a pre-shared key: the only port meant to face the internet.
    static let securePort: UInt16 = 7778
    static let bonjourType = "_pult._tcp"
    /// Video frames the host sends ahead of the client's acks before it starts
    /// skipping captures, which keeps latency bounded on a slow link.
    static let maxFramesInFlight = 4
    /// Largest message either side accepts; anything bigger is a protocol error.
    static let maxMessageSize = 32 << 20
}

/// The byte after the length prefix. Messages of an unknown type are
/// skipped, so a newer peer can add messages without breaking an older one.
enum MsgType: UInt8 {
    // Client → host
    case hello = 0x01               // u8 version, str pairing code
    case mouseMove = 0x40           // f32 x, f32 y: absolute, in display points
    case mouseButton = 0x41         // u8 MouseButton, u8 down, u8 click count
    case scroll = 0x42              // f32 dx, f32 dy: pixels
    case key = 0x43                 // u16 Mac key code, u8 down, u32 Modifiers
    case text = 0x44                // UTF-8 text to type
    case requestKeyframe = 0x45
    case ping = 0x46                // u64 client clock, echoed in pong
    case frameAck = 0x47            // u32 id of the newest video frame shown
    case dictation = 0x48           // UTF-8 text to paste into the focused field
    case unlock = 0x49              // UTF-8 login password; encrypted port only
    case image = 0x4A               // JPEG or PNG bytes to paste
    case mouseMoveRelative = 0x4B   // f32 dx, f32 dy: relative motion for game cameras

    // Host → client
    case helloOK = 0x81             // ScreenInfo
    case helloDenied = 0x82         // UTF-8 reason; the host closes the connection
    case video = 0x90               // VideoFrame
    case cursorImage = 0xA0         // CursorImage
    case cursorPos = 0xA1           // f32 x, f32 y: display points
    case screenInfo = 0xA2          // ScreenInfo, after the display changed
    case dictationResult = 0xA3     // u8 1 = a text field had focus
    case pairInfo = 0xA4            // PairInfo
    case unlockResult = 0xA5        // u8 UnlockResult
    case lockState = 0xA6           // u8 1 = screen locked
    case imageResult = 0xA7         // u8 1 = pasted, 0 = only copied
    case pong = 0xB0                // u64 the client clock from ping
}

enum MouseButton: UInt8 {
    case left = 0, right = 1, middle = 2
}

/// Modifier keys as sent with key events.
struct Modifiers: OptionSet {
    let rawValue: UInt32
    static let shift = Modifiers(rawValue: 1)
    static let control = Modifiers(rawValue: 2)
    static let option = Modifiers(rawValue: 4)
    static let command = Modifiers(rawValue: 8)
}

/// The streamed display: its size in points (the coordinate space of every
/// pointer message) and the size of the video.
struct ScreenInfo: Equatable {
    var width: Float
    var height: Float
    var videoWidth: UInt16
    var videoHeight: UInt16
    var name: String

    init(width: Float, height: Float, videoWidth: UInt16, videoHeight: UInt16, name: String) {
        self.width = width
        self.height = height
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.name = name
    }

    init(_ r: inout ByteReader) throws {
        width = try r.f32()
        height = try r.f32()
        videoWidth = try r.u16()
        videoHeight = try r.u16()
        name = try r.string()
    }

    func encode(_ w: inout ByteWriter) {
        w.f32(width)
        w.f32(height)
        w.u16(videoWidth)
        w.u16(videoHeight)
        w.string(name)
    }
}

/// One H.264 access unit in AVCC form (4-byte big-endian NAL lengths).
/// Keyframes also carry the SPS and PPS needed to start decoding.
struct VideoFrame: Equatable {
    var id: UInt32
    var isKey: Bool
    var ptsMicros: UInt64
    var sps: Data
    var pps: Data
    var avcc: Data

    init(id: UInt32, isKey: Bool, ptsMicros: UInt64, sps: Data, pps: Data, avcc: Data) {
        self.id = id
        self.isKey = isKey
        self.ptsMicros = ptsMicros
        self.sps = sps
        self.pps = pps
        self.avcc = avcc
    }

    init(_ r: inout ByteReader) throws {
        id = try r.u32()
        isKey = try r.u8() == 1
        ptsMicros = try r.u64()
        if isKey {
            sps = try r.blob16()
            pps = try r.blob16()
        } else {
            sps = Data()
            pps = Data()
        }
        avcc = r.rest()
    }

    func encode(_ w: inout ByteWriter) {
        w.u32(id)
        w.u8(isKey ? 1 : 0)
        w.u64(ptsMicros)
        if isKey {
            w.blob16(sps)
            w.blob16(pps)
        }
        w.raw(avcc)
    }
}

/// The current pointer shape, so the client can draw the cursor itself
/// with no network delay. Sizes are in points.
struct CursorImage: Equatable {
    var hotSpot: CGPoint
    var size: CGSize
    var png: Data

    init(hotSpot: CGPoint, size: CGSize, png: Data) {
        self.hotSpot = hotSpot
        self.size = size
        self.png = png
    }

    init(_ r: inout ByteReader) throws {
        hotSpot = CGPoint(x: CGFloat(try r.f32()), y: CGFloat(try r.f32()))
        size = CGSize(width: CGFloat(try r.f32()), height: CGFloat(try r.f32()))
        png = r.rest()
    }

    func encode(_ w: inout ByteWriter) {
        w.f32(Float(hotSpot.x))
        w.f32(Float(hotSpot.y))
        w.f32(Float(size.width))
        w.f32(Float(size.height))
        w.raw(png)
    }
}

/// Everything a client needs to reach this host later from anywhere: the
/// remote-access key and the addresses to try. Sent after every hello.
struct PairInfo: Equatable {
    var hostId: String
    var name: String
    var psk: Data
    /// Private and Tailscale IPv4 addresses.
    var lan: [String]
    var publicV4: [String]
    var v6: [String]

    init(hostId: String, name: String, psk: Data, lan: [String], publicV4: [String], v6: [String]) {
        self.hostId = hostId
        self.name = name
        self.psk = psk
        self.lan = lan
        self.publicV4 = publicV4
        self.v6 = v6
    }

    init(_ r: inout ByteReader) throws {
        hostId = try r.string()
        name = try r.string()
        psk = try r.blob16()
        func list() throws -> [String] { try (0..<Int(try r.u8())).map { _ in try r.string() } }
        lan = try list()
        publicV4 = try list()
        v6 = try list()
    }

    func encode(_ w: inout ByteWriter) {
        w.string(hostId)
        w.string(name)
        w.blob16(psk)
        for list in [lan, publicV4, v6] {
            let capped = list.prefix(Int(UInt8.max))
            w.u8(UInt8(capped.count))
            capped.forEach { w.string($0) }
        }
    }
}

enum UnlockResult: UInt8 {
    case unlocked = 0
    case notLocked = 1
    /// Wrong password, or macOS ignored typing on the lock screen.
    case stillLocked = 2
    /// The password came over the plain port; it is only accepted encrypted.
    case needsEncryption = 3
}
