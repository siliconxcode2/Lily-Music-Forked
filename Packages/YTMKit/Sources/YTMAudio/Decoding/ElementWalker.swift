/// Walks EBML elements or MP4 boxes as the bytes arrive in pieces of any size. Only the element being read,
/// which is always small, is ever copied, and only when it is split across two pieces.
struct ElementWalker {
    struct Header {
        var id: UInt32
        /// Bytes of the header itself.
        var length: Int
        /// Bytes of the body, or nil when unknown or running to the file's end.
        var size: Int64?
    }

    enum Action {
        /// Its children follow as elements of their own.
        case enter
        case read
        case skip
    }

    /// Reads a header from the front of `bytes`, or returns nil when more
    /// bytes are needed. With `maxHeaderLength` bytes it never returns nil.
    typealias HeaderReader = (UnsafeRawBufferPointer) throws -> Header?

    /// Larger reads than this are a broken file rather than a header.
    static let maxReadLength: Int64 = 16 << 20

    private let maxHeaderLength: Int
    private let readHeader: HeaderReader
    /// A header, or the body being read, split across two pieces.
    private var carry: [UInt8] = []
    private var reading: (header: Header, size: Int, offset: Int64)?
    private var skipping: Int64 = 0
    /// The file offset of the next byte to arrive.
    private var position: Int64 = 0

    /// `position` is where the first byte walked lies in the file, at an element's start.
    init(maxHeaderLength: Int, startingAt position: Int64 = 0, header: @escaping HeaderReader) {
        self.maxHeaderLength = maxHeaderLength
        self.position = position
        readHeader = header
    }

    /// `action` gets each element's header and its body's offset in the file; `element` gets each element
    /// read whole, with its body and the body's offset.
    mutating func walk(
        _ bytes: UnsafeRawBufferPointer,
        action: (Header, Int64) -> Action,
        element: (Header, UnsafeRawBufferPointer, Int64) throws -> Void
    ) throws {
        var index = 0
        defer { position += Int64(bytes.count) }
        while index < bytes.count {
            let rest = bytes.count - index
            if skipping > 0 {
                let count = Int(min(skipping, Int64(rest)))
                index += count
                skipping -= Int64(count)
            } else if let (header, size, offset) = reading {
                if carry.isEmpty, rest >= size {
                    try element(header, UnsafeRawBufferPointer(rebasing: bytes[index..<index + size]), offset)
                    index += size
                    reading = nil
                    continue
                }
                let count = min(size - carry.count, rest)
                carry.append(contentsOf: bytes[index..<index + count])
                index += count
                if carry.count == size {
                    try carry.withUnsafeBytes { try element(header, $0, offset) }
                    carry.removeAll(keepingCapacity: true)
                    reading = nil
                }
            } else if carry.isEmpty {
                guard let header = try readHeader(UnsafeRawBufferPointer(rebasing: bytes[index...])) else {
                    carry.append(contentsOf: bytes[index...])
                    return
                }
                index += header.length
                try begin(header, at: position + Int64(index), action: action, element: element)
            } else {
                let before = carry.count
                let count = min(maxHeaderLength - before, rest)
                carry.append(contentsOf: bytes[index..<index + count])
                guard let header = try carry.withUnsafeBytes(readHeader) else {
                    index += count
                    continue
                }
                carry.removeAll(keepingCapacity: true)
                index += header.length - before
                try begin(header, at: position + Int64(index), action: action, element: element)
            }
        }
    }

    private mutating func begin(
        _ header: Header,
        at offset: Int64,
        action: (Header, Int64) -> Action,
        element: (Header, UnsafeRawBufferPointer, Int64) throws -> Void
    ) throws {
        switch action(header, offset) {
        case .enter:
            break
        case .skip:
            skipping = header.size ?? .max
        case .read:
            guard let size = header.size, size <= Self.maxReadLength else { throw AudioFailure.damaged }
            if size == 0 {
                try element(header, UnsafeRawBufferPointer(start: nil, count: 0), offset)
            } else {
                reading = (header, Int(size), offset)
            }
        }
    }

    /// `bytes` must hold whole elements; offsets are within `bytes`. One of unknown size runs to the end.
    static func forEach(
        in bytes: UnsafeRawBufferPointer,
        header readHeader: HeaderReader,
        _ body: (Header, UnsafeRawBufferPointer, Int) throws -> Void
    ) throws {
        var index = 0
        while index < bytes.count {
            guard let header = try readHeader(UnsafeRawBufferPointer(rebasing: bytes[index...])) else {
                throw AudioFailure.damaged
            }
            let start = index + header.length
            let length = header.size.map { Int(clamping: $0) } ?? bytes.count - start
            // Compared with what is left rather than added, as a damaged size could overflow.
            guard length <= bytes.count - start else { throw AudioFailure.damaged }
            try body(header, UnsafeRawBufferPointer(rebasing: bytes[start..<start + length]), start)
            index = start + length
        }
    }
}

/// Big-endian; throws rather than reading past the end.
struct ByteReader {
    private let bytes: UnsafeRawBufferPointer
    private(set) var offset = 0

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw AudioFailure.damaged }
        offset += count
    }

    mutating func uint(_ count: Int) throws -> UInt64 {
        guard count <= 8, count <= remaining else { throw AudioFailure.damaged }
        defer { offset += count }
        return (offset..<offset + count).reduce(0) { $0 << 8 | UInt64(bytes[$1]) }
    }

    mutating func take(_ count: Int) throws -> UnsafeRawBufferPointer {
        guard count >= 0, count <= remaining else { throw AudioFailure.damaged }
        defer { offset += count }
        return UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + count])
    }
}
