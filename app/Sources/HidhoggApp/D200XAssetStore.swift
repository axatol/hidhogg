import CryptoKit
import CoreGraphics
import Foundation
import HidhoggDomain
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct D200XAssetStore {
    enum Failure: LocalizedError {
        case invalidReference
        case unsupportedFormat
        case oversizedInput
        case invalidImage
        case unsafePath
        case missingAsset
        case assetIntegrity
        case fileAccess

        var errorDescription: String? {
            switch self {
            case .invalidReference: "The image reference is invalid."
            case .unsupportedFormat: "Choose a PNG or JPEG image."
            case .oversizedInput: "Images must be no larger than 16 MiB or 16 million pixels."
            case .invalidImage: "The selected file is not a valid PNG or JPEG image."
            case .unsafePath: "The image path is not safe to access."
            case .missingAsset: "The saved tile image is missing."
            case .assetIntegrity: "The saved tile image failed its integrity check."
            case .fileAccess: "The image could not be read or saved."
            }
        }
    }

    static let maximumInputBytes = 16 * 1024 * 1024
    static let maximumPixels: UInt64 = 16_000_000
    static let maximumDimension = 1024

    let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    func importImage(from sourceURL: URL) throws -> String {
        let input = try readInput(from: sourceURL)
        let normalized = try normalizePNG(input)
        return try persist(normalized)
    }

    func restoreImage(_ data: Data, reference: String) throws {
        try validateAsset(data, reference: reference)
        _ = try persist(data)
    }

    func validateAsset(_ data: Data, reference: String) throws {
        guard data.count <= Self.maximumInputBytes,
              D200XTileAppearance.isValidAssetReference(reference),
              Self.reference(for: data) == reference else { throw Failure.assetIntegrity }
        try validateNormalizedPNG(data)
    }

    private func persist(_ normalized: Data) throws -> String {
        let reference = Self.reference(for: normalized)
        let directoryPath = try validatedDirectoryPath(createMissing: true)

        let destinationPath = Self.appending(reference, to: directoryPath)
        var existing = stat()
        if lstat(destinationPath, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }
            let current = try readFile(atPath: destinationPath, maximumBytes: Self.maximumInputBytes)
            guard current == normalized else { throw Failure.assetIntegrity }
            return reference
        }
        guard errno == ENOENT else { throw Failure.fileAccess }

        do {
            try normalized.write(to: URL(fileURLWithPath: destinationPath), options: .atomic)
        } catch {
            throw Failure.fileAccess
        }
        return reference
    }

    func imageData(for reference: String) throws -> Data {
        guard D200XTileAppearance.isValidAssetReference(reference) else { throw Failure.invalidReference }
        let directoryPath = try validatedDirectoryPath(createMissing: false)
        let assetPath = Self.appending(reference, to: directoryPath)
        var assetInfo = stat()
        guard lstat(assetPath, &assetInfo) == 0 else {
            if errno == ENOENT { throw Failure.missingAsset }
            throw Failure.fileAccess
        }
        guard (assetInfo.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }

        let data = try readFile(atPath: assetPath, maximumBytes: Self.maximumInputBytes)
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              Self.reference(for: data) == reference else {
            throw Failure.assetIntegrity
        }
        try validateNormalizedPNG(data)
        return data
    }

    private func readInput(from url: URL) throws -> Data {
        var sourceInfo = stat()
        guard lstat(url.standardizedFileURL.path, &sourceInfo) == 0 else { throw Failure.fileAccess }
        guard (sourceInfo.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }
        guard sourceInfo.st_size >= 0, sourceInfo.st_size <= off_t(Self.maximumInputBytes) else {
            throw Failure.oversizedInput
        }
        return try readFile(atPath: url.standardizedFileURL.path, maximumBytes: Self.maximumInputBytes)
    }

    private func readFile(atPath path: String, maximumBytes: Int) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw Failure.unsafePath }
            throw Failure.fileAccess
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0 else { throw Failure.fileAccess }
        guard (openedInfo.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }
        guard openedInfo.st_size >= 0, openedInfo.st_size <= off_t(maximumBytes) else {
            throw Failure.oversizedInput
        }

        var data = Data()
        while data.count <= maximumBytes {
            let count = min(64 * 1024, maximumBytes + 1 - data.count)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: count) ?? Data()
            } catch {
                throw Failure.fileAccess
            }
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw Failure.oversizedInput }
        return data
    }

    private func normalizePNG(_ input: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(input as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.invalidImage
        }
        guard CGImageSourceGetCount(source) == 1 else { throw Failure.invalidImage }
        guard let sourceType = CGImageSourceGetType(source) else { throw Failure.unsupportedFormat }
        let sourceTypeIdentifier = sourceType as String
        guard sourceTypeIdentifier == UTType.png.identifier || sourceTypeIdentifier == UTType.jpeg.identifier else {
            throw Failure.unsupportedFormat
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthValue = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightValue = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw Failure.invalidImage
        }
        let width = widthValue.uint64Value
        let height = heightValue.uint64Value
        guard width > 0, height > 0 else { throw Failure.invalidImage }
        guard width <= Self.maximumPixels, height <= Self.maximumPixels,
              width <= Self.maximumPixels / height else {
            throw Failure.oversizedInput
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width <= Self.maximumDimension, image.height <= Self.maximumDimension else {
            throw Failure.invalidImage
        }

        let thumbnailWidth = image.width
        let thumbnailHeight = image.height
        guard let bitmap = CGContext(
            data: nil,
            width: thumbnailWidth,
            height: thumbnailHeight,
            bitsPerComponent: 8,
            bytesPerRow: thumbnailWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw Failure.invalidImage
        }
        bitmap.interpolationQuality = .high
        bitmap.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(thumbnailWidth), height: CGFloat(thumbnailHeight))
        )
        guard let metadataFreeImage = bitmap.makeImage() else { throw Failure.invalidImage }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.invalidImage
        }
        CGImageDestinationAddImage(destination, metadataFreeImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        return output as Data
    }

    private func validateNormalizedPNG(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source),
              sourceType as String == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthValue = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightValue = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw Failure.assetIntegrity
        }

        let width = widthValue.uint64Value
        let height = heightValue.uint64Value
        let maximumDimension = UInt64(Self.maximumDimension)
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0,
              width <= maximumDimension, height <= maximumDimension,
              !overflow, pixelCount <= maximumDimension * maximumDimension else {
            throw Failure.assetIntegrity
        }
    }

    private func validatedDirectoryPath(createMissing: Bool) throws -> String {
        let requestedPath = directory.standardizedFileURL.path
        let requested = requestedPath as NSString
        let leaf = requested.lastPathComponent
        guard !leaf.isEmpty, leaf != "/", leaf != ".", leaf != ".." else { throw Failure.unsafePath }

        var candidate = requested.deletingLastPathComponent
        var missingComponents = [String]()
        var canonicalParent: String?
        while canonicalParent == nil {
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
            if realpath(candidate, &resolved) != nil {
                canonicalParent = String(cString: resolved)
                continue
            }
            guard errno == ENOENT else { throw Failure.fileAccess }

            let missing = (candidate as NSString).lastPathComponent
            let parent = (candidate as NSString).deletingLastPathComponent
            guard !missing.isEmpty, parent != candidate else { throw Failure.fileAccess }
            missingComponents.insert(missing, at: 0)
            candidate = parent
        }

        guard var currentPath = canonicalParent else { throw Failure.fileAccess }
        for component in missingComponents + [leaf] {
            currentPath = Self.appending(component, to: currentPath)
            var info = stat()
            if lstat(currentPath, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafePath }
                continue
            }
            guard errno == ENOENT else { throw Failure.fileAccess }
            guard createMissing else { throw Failure.missingAsset }
            guard mkdir(currentPath, 0o700) == 0 || errno == EEXIST else { throw Failure.fileAccess }
            guard lstat(currentPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw Failure.unsafePath
            }
        }
        return currentPath
    }

    private static func reference(for data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(digest).png"
    }

    private static func appending(_ component: String, to path: String) -> String {
        path == "/" ? "/\(component)" : "\(path)/\(component)"
    }
}
