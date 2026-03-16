import Foundation
import zlib

struct ExtractedGCode: Sendable, Hashable {
    let path: String
    let content: String
}

enum ThreeMFReaderError: Error, LocalizedError {
    case unreadableArchive
    case invalidArchive
    case noGCodeFound
    case unsupportedCompression(UInt16)
    case decompressionFailed
    case invalidTextEncoding

    var errorDescription: String? {
        switch self {
        case .unreadableArchive:
            return "Could not read the .3mf file."
        case .invalidArchive:
            return "The .3mf archive appears to be invalid."
        case .noGCodeFound:
            return "No embedded G-code file was found inside this .3mf archive."
        case .unsupportedCompression(let method):
            return "Unsupported compression method in ZIP entry: \(method)."
        case .decompressionFailed:
            return "Could not decompress a ZIP entry from the .3mf archive."
        case .invalidTextEncoding:
            return "The extracted G-code could not be decoded as text."
        }
    }
}

struct ThreeMFReader {
    func extractGCode(from fileURL: URL, preferredPlateId: Int? = nil) throws -> ExtractedGCode {
        guard let archiveData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            throw ThreeMFReaderError.unreadableArchive
        }
        return try extractGCode(from: archiveData, preferredPlateId: preferredPlateId)
    }

    func extractGCode(from archiveData: Data, preferredPlateId: Int? = nil) throws -> ExtractedGCode {
        let archive = ZIPArchive(data: archiveData)
        let entries = try archive.centralDirectoryEntries()

        let gcodeEntries = entries.filter { entry in
            let lower = entry.fileName.lowercased()
            return lower.hasSuffix(".gcode") || lower.hasSuffix(".gco") || lower.hasSuffix(".gc") || lower.hasSuffix(".g")
        }

        guard !gcodeEntries.isEmpty else {
            throw ThreeMFReaderError.noGCodeFound
        }

        let preferred = gcodeEntries.sorted { lhs, rhs in
            score(path: lhs.fileName, preferredPlateId: preferredPlateId) >
                score(path: rhs.fileName, preferredPlateId: preferredPlateId)
        }.first!

        let payload = try archive.extractData(for: preferred)
        guard let text = String(data: payload, encoding: .utf8)
            ?? String(data: payload, encoding: .ascii)
            ?? String(data: payload, encoding: .isoLatin1) else {
            throw ThreeMFReaderError.invalidTextEncoding
        }

        return ExtractedGCode(path: preferred.fileName, content: text)
    }

    private func score(path: String, preferredPlateId: Int?) -> Int {
        let lower = path.lowercased()
        var total = 0

        if let preferredPlateId {
            let pathPlateId = plateId(in: lower)
            if pathPlateId == preferredPlateId {
                total += 1_000
            } else if preferredPlateId == 0 && pathPlateId == 1 {
                // Some files encode the first plate as "plate_1" while metadata starts at 0.
                total += 900
            } else if pathPlateId != nil {
                total -= 100
            }
        }

        if lower.contains("metadata/") { total += 20 }
        if lower.contains("plate") { total += 10 }
        if lower.contains("gcode/") { total += 6 }
        if lower.contains("toolpath") { total += 4 }
        if lower.hasSuffix(".gcode") { total += 3 }

        return total
    }

    private func plateId(in lowercasedPath: String) -> Int? {
        let pattern = #"plate[_-]?(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(lowercasedPath.startIndex..<lowercasedPath.endIndex, in: lowercasedPath)
        guard let match = regex.firstMatch(in: lowercasedPath, range: nsRange),
              let idRange = Range(match.range(at: 1), in: lowercasedPath) else {
            return nil
        }
        return Int(lowercasedPath[idRange])
    }
}

private struct ZIPCentralDirectoryEntry {
    let fileName: String
    let compressionMethod: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

private struct ZIPArchive {
    let data: Data

    func centralDirectoryEntries() throws -> [ZIPCentralDirectoryEntry] {
        let eocdOffset = try endOfCentralDirectoryOffset()
        let totalEntries = Int(try data.readUInt16LE(at: eocdOffset + 10))
        let directoryOffset = Int(try data.readUInt32LE(at: eocdOffset + 16))

        var entries: [ZIPCentralDirectoryEntry] = []
        var cursor = directoryOffset

        for _ in 0..<totalEntries {
            let signature = try data.readUInt32LE(at: cursor)
            guard signature == 0x0201_4B50 else {
                throw ThreeMFReaderError.invalidArchive
            }

            let compressionMethod = try data.readUInt16LE(at: cursor + 10)
            let compressedSize = Int(try data.readUInt32LE(at: cursor + 20))
            let uncompressedSize = Int(try data.readUInt32LE(at: cursor + 24))
            let nameLength = Int(try data.readUInt16LE(at: cursor + 28))
            let extraLength = Int(try data.readUInt16LE(at: cursor + 30))
            let commentLength = Int(try data.readUInt16LE(at: cursor + 32))
            let localHeaderOffset = Int(try data.readUInt32LE(at: cursor + 42))

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard data.indices.contains(nameStart), nameEnd <= data.count else {
                throw ThreeMFReaderError.invalidArchive
            }

            let nameData = data.subdata(in: nameStart..<nameEnd)
            let fileName = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? "entry_\(entries.count)"

            entries.append(
                ZIPCentralDirectoryEntry(
                    fileName: fileName,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )

            cursor = nameEnd + extraLength + commentLength
        }

        return entries
    }

    func extractData(for entry: ZIPCentralDirectoryEntry) throws -> Data {
        let localOffset = entry.localHeaderOffset
        let localSignature = try data.readUInt32LE(at: localOffset)
        guard localSignature == 0x0403_4B50 else {
            throw ThreeMFReaderError.invalidArchive
        }

        let localNameLength = Int(try data.readUInt16LE(at: localOffset + 26))
        let localExtraLength = Int(try data.readUInt16LE(at: localOffset + 28))
        let payloadStart = localOffset + 30 + localNameLength + localExtraLength
        let payloadEnd = payloadStart + entry.compressedSize

        guard data.indices.contains(payloadStart), payloadEnd <= data.count else {
            throw ThreeMFReaderError.invalidArchive
        }

        let compressed = data.subdata(in: payloadStart..<payloadEnd)

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try inflateRawDeflate(compressedData: compressed, expectedSize: entry.uncompressedSize)
        default:
            throw ThreeMFReaderError.unsupportedCompression(entry.compressionMethod)
        }
    }

    private func endOfCentralDirectoryOffset() throws -> Int {
        let signature: UInt32 = 0x0605_4B50
        let minLength = 22

        guard data.count >= minLength else {
            throw ThreeMFReaderError.invalidArchive
        }

        let maxWindow = min(data.count, 65_557)
        let lowerBound = data.count - maxWindow
        var cursor = data.count - minLength

        while cursor >= lowerBound {
            let candidate = try data.readUInt32LE(at: cursor)
            if candidate == signature {
                return cursor
            }
            cursor -= 1
        }

        throw ThreeMFReaderError.invalidArchive
    }

    private func inflateRawDeflate(compressedData: Data, expectedSize: Int) throws -> Data {
        if compressedData.isEmpty {
            return Data()
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ThreeMFReaderError.decompressionFailed
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data()
        output.reserveCapacity(max(expectedSize, compressedData.count * 2))
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        let status: Int32 = compressedData.withUnsafeBytes { rawInput in
            guard let baseAddress = rawInput.bindMemory(to: Bytef.self).baseAddress else {
                return Z_DATA_ERROR
            }

            stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
            stream.avail_in = uInt(compressedData.count)

            while true {
                let inflateStatus: Int32 = buffer.withUnsafeMutableBytes { rawOutput in
                    stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: buffer[0..<produced])
                }

                if inflateStatus == Z_STREAM_END {
                    return Z_OK
                }

                if inflateStatus != Z_OK {
                    return inflateStatus
                }

                if produced == 0 && stream.avail_in == 0 {
                    return Z_BUF_ERROR
                }
            }
        }

        guard status == Z_OK else {
            throw ThreeMFReaderError.decompressionFailed
        }

        return output
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw ThreeMFReaderError.invalidArchive
        }
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1]) << 8
        return b0 | b1
    }

    func readUInt32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw ThreeMFReaderError.invalidArchive
        }
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1]) << 8
        let b2 = UInt32(self[offset + 2]) << 16
        let b3 = UInt32(self[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
