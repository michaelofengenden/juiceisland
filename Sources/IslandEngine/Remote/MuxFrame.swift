import Foundation

/// One frame of an SSH tunnel's stdio (P740): the remote helper's `serve` carries each hook connection on the remote
/// over ssh's stdin and stdout, so the tunnel needs no port or socket forwarding at all. A frame is a kind byte, a
/// channel (one hook connection) and a body, the two numbers big-endian.
public struct MuxFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// Remote to Mac, channel 0, once: `{"v":<helper version>}`. The tunnel is up.
        case hello = 0x48
        /// Remote to Mac: a hook connected.
        case open = 0x4F
        /// Either way: bytes of one connection.
        case data = 0x44
        /// Either way: the connection ended.
        case close = 0x43
        /// Mac to remote, channel 0: select a tmux pane, `{"socket":…,"pane":"%3"}` (a jump, best effort).
        case tmux = 0x54
    }

    public var kind: Kind
    public var channel: UInt32
    public var body: Data

    public init(_ kind: Kind, _ channel: UInt32, _ body: Data = Data()) {
        self.kind = kind
        self.channel = channel
        self.body = body
    }

    public static let headerSize = 9

    public func encoded() -> Data {
        var data = Data([kind.rawValue])
        withUnsafeBytes(of: channel.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { data.append(contentsOf: $0) }
        return data + body
    }
}

/// Reads frames from the tunnel's stdout. The remote login shell may print before `serve` starts (a banner, an rc
/// file's echo), so everything before the preamble is skipped, up to `noiseLimit` bytes.
public struct MuxDecoder: Sendable {
    public static let preamble = Data([0x00]) + Data("JRMUX1\n".utf8)
    public static let bodyLimit = 2 << 20
    public static let noiseLimit = 64 * 1_024

    public enum Failure: Error, Equatable {
        /// No preamble within `noiseLimit` bytes: not our helper on the other end.
        case noPreamble
        case tooLarge
        case unknownKind(UInt8)
    }

    private var synced = false
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ data: Data) throws -> [MuxFrame] {
        buffer.append(data)
        if !synced {
            guard let range = buffer.range(of: Self.preamble) else {
                if buffer.count > Self.noiseLimit { throw Failure.noPreamble }
                return []
            }
            buffer = Data(buffer[range.upperBound...])
            synced = true
        }
        var frames: [MuxFrame] = []
        while buffer.count >= MuxFrame.headerSize {
            let bytes = [UInt8](buffer.prefix(MuxFrame.headerSize))
            guard let kind = MuxFrame.Kind(rawValue: bytes[0]) else { throw Failure.unknownKind(bytes[0]) }
            let channel = bytes[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let length = Int(bytes[5..<9].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length <= Self.bodyLimit else { throw Failure.tooLarge }
            guard buffer.count >= MuxFrame.headerSize + length else { break }
            let start = buffer.startIndex + MuxFrame.headerSize
            frames.append(MuxFrame(kind, channel, Data(buffer[start..<(start + length)])))
            buffer = Data(buffer[(start + length)...])
        }
        return frames
    }
}
