//
//  CreateIpaOperation.swift
//  SideStore
//
//  Created by Magesh K on 9/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

final class CreateIpaOperation: BasePipelineOperation<InstallAppOperationContext, URL?>, @unchecked Sendable {

    override func execute(parentProgress: Progress?) async throws -> URL? {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[CreateIpaOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[CreateIpaOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)

        guard UserDefaults.standard.preferResignedIPA || UserDefaults.standard.isExportResignedAppEnabled else {
            debugLog("[CreateIpaOperation] Skipping: preferResignedIPA and isExportResignedAppEnabled are disabled")
            self.setProgress(100)
            return nil
        }

        guard let resignedAppBundle = self.context.resignedAppBundle else {
            throw OperationError.invalidParameters("CreateIpaOperation: context.resignedAppBundle is nil")
        }

        let appURL = resignedAppBundle.fileURL
        debugLog("[CreateIpaOperation] Packaging app bundle at \(appURL.path)...")
        self.setProgress(30)

        do {
            let ipaURL = try FastIpaPackager.package(appURL: appURL)
            self.context.ipaURL = ipaURL
            self.setProgress(100)
            debugLog("[CreateIpaOperation] Packaged IPA created at \(ipaURL.path)")
            return ipaURL
        } catch {
            debugLog("[CreateIpaOperation] Packaging IPA failed with error: \(error). Falling back to direct app bundle transfer.")
            self.context.ipaURL = nil
            self.setProgress(100)
            return nil
        }
    }
}

// MARK: - Fast & Robust IPA Packager

private enum FastIpaPackager {

    private struct CentralDirectoryRecord {
        let filename: String
        let modTime: UInt16
        let modDate: UInt16
        let crc32: UInt32
        let uncompressedSize: UInt32
        let compressedSize: UInt32
        let externalAttributes: UInt32
        let localHeaderOffset: UInt64
    }

    private struct CRC32 {
        private static let table: [UInt32] = {
            (0...255).map { i -> UInt32 in
                var c = UInt32(i)
                for _ in 0..<8 {
                    c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
                }
                return c
            }
        }()

        static func calculate(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFFFFFF
            data.withUnsafeBytes { rawBuffer in
                for byte in rawBuffer {
                    let index = Int((crc ^ UInt32(byte)) & 0xFF)
                    crc = table[index] ^ (crc >> 8)
                }
            }
            return crc ^ 0xFFFFFFFF
        }
    }

    private static func dosDateTime(from date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, comps.year ?? 1980) - 1980
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0

        let dosDate = UInt16(((year & 0x7F) << 9) | ((month & 0x0F) << 5) | (day & 0x1F))
        let dosTime = UInt16(((hour & 0x1F) << 11) | ((minute & 0x3F) << 5) | ((second / 2) & 0x1F))
        return (dosDate, dosTime)
    }

    static func package(appURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let name = appURL.deletingPathExtension().lastPathComponent
        let ipaURL = appURL.deletingLastPathComponent().appendingPathComponent("\(name).ipa")

        if fileManager.fileExists(atPath: ipaURL.path) {
            try? fileManager.removeItem(at: ipaURL)
        }

        guard fileManager.createFile(atPath: ipaURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: ipaURL)
        defer {
            try? handle.close()
        }

        var currentOffset: UInt64 = 0
        var cdRecords: [CentralDirectoryRecord] = []
        var seenPaths = Set<String>()

        func writeZipEntry(
            path: String,
            data: Data,
            date: Date,
            externalAttributes: UInt32
        ) throws {
            guard !seenPaths.contains(path) else { return }
            seenPaths.insert(path)

            let nameData = Data(path.utf8)
            let (dosDate, dosTime) = dosDateTime(from: date)
            let size = UInt32(data.count)
            let crc = data.isEmpty ? 0 : CRC32.calculate(data)
            let localHeaderOffset = currentOffset

            var localHeader = Data(count: 30)
            localHeader.writeUInt32LE(0x04034b50, at: 0) // Local header signature
            localHeader.writeUInt16LE(20, at: 4)         // Version needed: 2.0
            localHeader.writeUInt16LE(0x0800, at: 6)     // Flags: UTF-8
            localHeader.writeUInt16LE(0, at: 8)          // Compression: Store (0)
            localHeader.writeUInt16LE(dosTime, at: 10)
            localHeader.writeUInt16LE(dosDate, at: 12)
            localHeader.writeUInt32LE(crc, at: 14)
            localHeader.writeUInt32LE(size, at: 18)
            localHeader.writeUInt32LE(size, at: 22)
            localHeader.writeUInt16LE(UInt16(nameData.count), at: 26)
            localHeader.writeUInt16LE(0, at: 28)

            try handle.write(contentsOf: localHeader)
            try handle.write(contentsOf: nameData)
            if !data.isEmpty {
                try handle.write(contentsOf: data)
            }

            currentOffset += UInt64(30 + nameData.count + data.count)

            cdRecords.append(CentralDirectoryRecord(
                filename: path,
                modTime: dosTime,
                modDate: dosDate,
                crc32: crc,
                uncompressedSize: size,
                compressedSize: size,
                externalAttributes: externalAttributes,
                localHeaderOffset: localHeaderOffset
            ))
        }

        let appDirName = appURL.lastPathComponent

        // 1. Root directory entries
        let rootDate = Date()
        try writeZipEntry(
            path: "Payload/",
            data: Data(),
            date: rootDate,
            externalAttributes: UInt32(0o040755) << 16
        )
        try writeZipEntry(
            path: "Payload/\(appDirName)/",
            data: Data(),
            date: rootDate,
            externalAttributes: UInt32(0o040755) << 16
        )

        // 2. Enumerate bundle contents
        let searchPath = fileManager.fileExists(atPath: appURL.path) ? appURL.path : appURL.resolvingSymlinksInPath().path
        guard let enumerator = fileManager.enumerator(atPath: searchPath) else {
            throw CocoaError(.fileReadUnknown)
        }

        var fileCount = 0
        for case let relativePath as String in enumerator {
            guard !relativePath.isEmpty else { continue }
            let itemPath = (searchPath as NSString).appendingPathComponent(relativePath)
            let itemURL = URL(fileURLWithPath: itemPath)

            guard let attrs = try? fileManager.attributesOfItem(atPath: itemPath) else {
                continue
            }
            let fileType = attrs[.type] as? FileAttributeType
            let posixPerms = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
            let modDate = (attrs[.modificationDate] as? Date) ?? rootDate

            fileCount += 1

            if fileType == .typeSymbolicLink {
                // Symlink: read destination target, store with S_IFLNK (0o120777)
                guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: itemPath) else {
                    continue
                }
                let zipPath = "Payload/\(appDirName)/\(relativePath)"
                let linkData = Data(destination.utf8)
                let extAttr = UInt32(0o120777) << 16
                try writeZipEntry(path: zipPath, data: linkData, date: modDate, externalAttributes: extAttr)
            } else if fileType == .typeDirectory {
                // Directory: store with S_IFDIR and trailing slash
                let zipPath = "Payload/\(appDirName)/\(relativePath)/"
                let extAttr = UInt32(0o040000 | (posixPerms & 0o777)) << 16
                try writeZipEntry(path: zipPath, data: Data(), date: modDate, externalAttributes: extAttr)
            } else {
                // Regular file: memory map to prevent OOM on large files like OpenJDK modules
                let zipPath = "Payload/\(appDirName)/\(relativePath)"
                let fileData: Data
                do {
                    fileData = try Data(contentsOf: itemURL, options: .mappedIfSafe)
                } catch {
                    debugLog("[CreateIpaOperation] Warning: failed to read file at \(itemPath): \(error)")
                    continue
                }
                let extAttr = UInt32(0o100000 | (posixPerms & 0o777)) << 16
                try writeZipEntry(path: zipPath, data: fileData, date: modDate, externalAttributes: extAttr)
            }
        }

        guard fileCount > 0 else {
            debugLog("[CreateIpaOperation] ERROR: Enumeration returned 0 items from \(searchPath)!")
            throw CocoaError(.fileReadUnknown)
        }

        // 3. Central Directory & End of Central Directory (EOCD)
        let cdStartOffset = currentOffset
        for record in cdRecords {
            let nameData = Data(record.filename.utf8)

            var cdHeader = Data(count: 46)
            cdHeader.writeUInt32LE(0x02014b50, at: 0) // Central directory signature
            cdHeader.writeUInt16LE(0x031e, at: 4)     // UNIX 3.0
            cdHeader.writeUInt16LE(20, at: 6)         // Version needed: 2.0
            cdHeader.writeUInt16LE(0x0800, at: 8)     // Flags: UTF-8
            cdHeader.writeUInt16LE(0, at: 10)         // Compression: Store (0)
            cdHeader.writeUInt16LE(record.modTime, at: 12)
            cdHeader.writeUInt16LE(record.modDate, at: 14)
            cdHeader.writeUInt32LE(record.crc32, at: 16)
            cdHeader.writeUInt32LE(record.compressedSize, at: 20)
            cdHeader.writeUInt32LE(record.uncompressedSize, at: 24)
            cdHeader.writeUInt16LE(UInt16(nameData.count), at: 28)
            cdHeader.writeUInt16LE(0, at: 30)         // Extra field length
            cdHeader.writeUInt16LE(0, at: 32)         // File comment length
            cdHeader.writeUInt16LE(0, at: 34)         // Disk number start
            cdHeader.writeUInt16LE(0, at: 36)         // Internal attributes
            cdHeader.writeUInt32LE(record.externalAttributes, at: 38)
            cdHeader.writeUInt32LE(UInt32(record.localHeaderOffset), at: 42)

            try handle.write(contentsOf: cdHeader)
            try handle.write(contentsOf: nameData)
            currentOffset += UInt64(46 + nameData.count)
        }

        let cdSize = UInt32(currentOffset - cdStartOffset)
        let totalRecords = UInt16(min(cdRecords.count, 65535))

        var eocd = Data(count: 22)
        eocd.writeUInt32LE(0x06054b50, at: 0) // EOCD signature
        eocd.writeUInt16LE(0, at: 4)          // Disk number
        eocd.writeUInt16LE(0, at: 6)          // Disk with CD
        eocd.writeUInt16LE(totalRecords, at: 8)
        eocd.writeUInt16LE(totalRecords, at: 10)
        eocd.writeUInt32LE(cdSize, at: 12)
        eocd.writeUInt32LE(UInt32(cdStartOffset), at: 16)
        eocd.writeUInt16LE(0, at: 20)         // Comment length

        try handle.write(contentsOf: eocd)
        try handle.synchronize()
        try handle.close()

        let ipaAttributes = (try? fileManager.attributesOfItem(atPath: ipaURL.path)) ?? [:]
        let ipaSize = (ipaAttributes[.size] as? NSNumber)?.int64Value ?? 0
        debugLog("[CreateIpaOperation] FastIpaPackager finished: \(ipaURL.path) (\(ipaSize) bytes, \(cdRecords.count) entries, \(fileCount) items)")

        guard ipaSize > 1024 else {
            debugLog("[CreateIpaOperation] ERROR: Packaged IPA is unreasonably small (\(ipaSize) bytes). Aborting packaging.")
            throw CocoaError(.fileWriteUnknown)
        }

        return ipaURL
    }
}

private extension Data {
    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset]     = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset]     = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
