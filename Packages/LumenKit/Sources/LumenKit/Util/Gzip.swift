import Foundation
#if canImport(Compression)
import Compression
#endif

public enum GzipError: Error, Equatable, Sendable {
    case invalidHeader
    case corruptData
    case unsupportedPlatform
}

/// Minimal gzip (RFC 1952) decoding on top of Apple's Compression framework, used for
/// `.xml.gz` EPG files. Supports streaming file-to-file decoding so large EPGs never need to
/// be held in memory in either form.
public enum Gzip {
    public static func isGzipped(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    public static func isGzipped(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2)) ?? Data()
        return isGzipped(head)
    }

    public static func decompress(_ data: Data) throws -> Data {
        #if canImport(Compression)
        let decoder = try GzipStreamDecoder()
        var output = Data()
        _ = try decoder.feed(data, isFinal: true) { output.append($0) }
        return output
        #else
        throw GzipError.unsupportedPlatform
        #endif
    }

    public static func decompress(fileAt source: URL, to destination: URL, chunkSize: Int = 256 * 1024) throws {
        #if canImport(Compression)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let decoder = try GzipStreamDecoder()
        while true {
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            let isFinal = chunk.count < chunkSize
            let finished = try decoder.feed(chunk, isFinal: isFinal) { try output.write(contentsOf: $0) }
            if finished || isFinal { break }
        }
        #else
        throw GzipError.unsupportedPlatform
        #endif
    }

    /// Length of the gzip member header at the start of `data`.
    static func headerLength(_ data: Data) throws -> Int {
        let bytes = [UInt8](data.prefix(min(data.count, 64 * 1024)))
        guard bytes.count >= 10, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw GzipError.invalidHeader
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard bytes.count >= index + 2 else { throw GzipError.invalidHeader }
            let length = Int(bytes[index]) | Int(bytes[index + 1]) << 8
            index += 2 + length
        }
        if flags & 0x08 != 0 { // FNAME
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 } // FHCRC
        guard index <= bytes.count else { throw GzipError.invalidHeader }
        return index
    }
}

#if canImport(Compression)
/// Incremental raw-deflate decoder that strips the gzip header from the first chunk.
public final class GzipStreamDecoder {
    private let stream: UnsafeMutablePointer<compression_stream>
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 64 * 1024
    private var headerParsed = false
    private var streamInitialized = false
    private var finished = false

    public init() throws {
        stream = .allocate(capacity: 1)
        buffer = .allocate(capacity: bufferSize)
        // deinit frees the allocations, including when this initializer throws.
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GzipError.unsupportedPlatform
        }
        streamInitialized = true
    }

    deinit {
        if streamInitialized { compression_stream_destroy(stream) }
        stream.deallocate()
        buffer.deallocate()
    }

    /// Feeds compressed bytes; `output` receives decompressed chunks.
    /// Returns true once the end of the deflate stream was reached.
    @discardableResult
    public func feed(_ chunk: Data, isFinal: Bool, output: (Data) throws -> Void) throws -> Bool {
        guard !finished else { return true }
        var payload = chunk
        if !headerParsed {
            let offset = try Gzip.headerLength(chunk)
            payload = chunk.subdata(in: (chunk.startIndex + offset)..<chunk.endIndex)
            headerParsed = true
        }
        if payload.isEmpty && !isFinal { return false }

        let flags = isFinal ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let source = raw.bindMemory(to: UInt8.self)
            stream.pointee.src_ptr = source.baseAddress ?? UnsafePointer(buffer)
            stream.pointee.src_size = source.count

            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, flags)
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 {
                    try output(Data(bytes: buffer, count: produced))
                }
                if status == COMPRESSION_STATUS_END {
                    finished = true
                    return
                }
                guard status == COMPRESSION_STATUS_OK else { throw GzipError.corruptData }
                // Need more input: everything consumed and the output buffer wasn't filled.
                if stream.pointee.src_size == 0 && produced < bufferSize { return }
            }
        }
        if isFinal && !finished { throw GzipError.corruptData }
        return finished
    }
}
#endif
