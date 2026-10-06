import BitFoundation
import Foundation
import AVFoundation

enum ChatMediaPreparationError: Error, Equatable {
    case encodingFailed
    case voiceNoteTooLarge(bytes: Int)
    case imageTooLarge(bytes: Int)
    case videoTooLarge(bytes: Int)
    case videoExportFailed
}

struct ChatPreparedImage {
    let outputURL: URL
    let packet: BitchatFilePacket
}

enum ChatMediaPreparation {
    static func prepareVoiceNotePacket(at url: URL) throws -> BitchatFilePacket {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int else {
            throw ChatMediaPreparationError.voiceNoteTooLarge(bytes: 0)
        }
        guard fileSize <= FileTransferLimits.maxVoiceNoteBytes else {
            throw ChatMediaPreparationError.voiceNoteTooLarge(bytes: fileSize)
        }

        let data = try Data(contentsOf: url)
        let packet = BitchatFilePacket(
            fileName: url.lastPathComponent,
            fileSize: UInt64(data.count),
            mimeType: "audio/mp4",
            content: data
        )
        guard packet.encode() != nil else { throw ChatMediaPreparationError.encodingFailed }
        return packet
    }

    static func prepareVideoPacket(from sourceURL: URL) throws -> BitchatFilePacket {
        let asset = AVURLAsset(url: sourceURL)
        guard asset.isReadable else {
            throw ChatMediaPreparationError.videoExportFailed
        }

        let maxBytes = FileTransferLimits.maxVideoBytes
        let presets = [
            AVAssetExportPresetMediumQuality,
            AVAssetExportPreset640x480,
            AVAssetExportPresetLowQuality
        ].filter { AVAssetExportSession.exportPresets(compatibleWith: asset).contains($0) }

        guard !presets.isEmpty else {
            throw ChatMediaPreparationError.videoExportFailed
        }

        var lastSize = 0
        for (index, preset) in presets.enumerated() {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("bitchat-video-\(UUID().uuidString).mp4")
            try? FileManager.default.removeItem(at: outputURL)

            do {
                try exportVideo(asset: asset, preset: preset, to: outputURL)
                let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
                lastSize = fileSize
                guard fileSize > 0 else {
                    try? FileManager.default.removeItem(at: outputURL)
                    continue
                }

                if fileSize <= maxBytes {
                    let data = try Data(contentsOf: outputURL)
                    let fileName = sourceURL.deletingPathExtension().lastPathComponent + ".mp4"
                    let packet = BitchatFilePacket(
                        fileName: fileName,
                        fileSize: UInt64(data.count),
                        mimeType: "video/mp4",
                        content: data
                    )
                    try? FileManager.default.removeItem(at: outputURL)
                    guard packet.encode() != nil else {
                        throw ChatMediaPreparationError.encodingFailed
                    }
                    return packet
                }
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                if index == presets.count - 1 {
                    if lastSize > maxBytes {
                        throw ChatMediaPreparationError.videoTooLarge(bytes: lastSize)
                    }
                    throw ChatMediaPreparationError.videoExportFailed
                }
            }

            try? FileManager.default.removeItem(at: outputURL)
        }

        if lastSize > maxBytes {
            throw ChatMediaPreparationError.videoTooLarge(bytes: lastSize)
        }
        throw ChatMediaPreparationError.videoExportFailed
    }

    private static func exportVideo(asset: AVAsset, preset: String, to outputURL: URL) throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ChatMediaPreparationError.videoExportFailed
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        let result: Result<Void, Error> = awaitExport(exporter)
        try result.get()
    }

    private static func awaitExport(_ exporter: AVAssetExportSession) -> Result<Void, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .failure(ChatMediaPreparationError.videoExportFailed)
        exporter.exportAsynchronously {
            switch exporter.status {
            case .completed:
                result = .success(())
            case .failed:
                result = .failure(exporter.error ?? ChatMediaPreparationError.videoExportFailed)
            case .cancelled:
                result = .failure(CancellationError())
            default:
                result = .failure(exporter.error ?? ChatMediaPreparationError.videoExportFailed)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    static func prepareImagePacket(from sourceURL: URL) throws -> ChatPreparedImage {
        let outputURL = try ImageUtils.processImage(at: sourceURL)
        do {
            let data = try Data(contentsOf: outputURL)
            guard data.count <= FileTransferLimits.maxImageBytes else {
                throw ChatMediaPreparationError.imageTooLarge(bytes: data.count)
            }

            let packet = BitchatFilePacket(
                fileName: outputURL.lastPathComponent,
                fileSize: UInt64(data.count),
                mimeType: "image/jpeg",
                content: data
            )
            guard packet.encode() != nil else { throw ChatMediaPreparationError.encodingFailed }
            return ChatPreparedImage(outputURL: outputURL, packet: packet)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}
