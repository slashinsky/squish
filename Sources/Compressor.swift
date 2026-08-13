import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Compression core
//
// Picks the highest JPEG quality on a fixed ladder that fits under a size cap —
// the same ladder and the same answer as compress-images.py (quality 95 stepping
// down by 5, floor 15), but reached by binary search rather than by encoding
// every rung. JPEG size rises monotonically with quality, so the rungs that fit
// form a suffix of the ladder and the first fitting rung is findable in ~5
// encodes instead of ~17.
//
// Deliberate differences from the script:
//  1. Attempts are encoded in memory; only the winner is written to disk.
//  2. If the full-resolution ladder bottoms out and the file is STILL over the
//     cap, dimensions are reduced and the ladder retried. Without this, ~50 MP
//     photos cannot reach 2 MB at any JPEG quality — the script produced ruined
//     images that were over the cap anyway.

enum Compressor {
    /// Full-resolution pass — identical rungs to the Python script's ladder.
    static let qualities: [Int] = Array(stride(from: 95, through: 15, by: -5))
    /// Reduced-resolution passes stay in a range that still looks acceptable;
    /// pixels come down instead of quality collapsing.
    static let resizeQualities: [Int] = Array(stride(from: 85, through: 40, by: -5))

    static let maxResizeAttempts = 5
    static let minimumWidth = 640

    struct FileResult {
        let name: String
        let outputBytes: Int
        let quality: Int
        let width: Int
        let height: Int
        let wasResized: Bool
        let overCap: Bool
        let error: String?
    }

    private static func encode(
        _ image: CGImage, quality: Int, orientation: CGImagePropertyOrientation?
    ) -> Data? {
        let buffer = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                buffer, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }

        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0
        ]
        // The Python version dropped EXIF entirely, which loses the orientation
        // tag and can leave photos rotated. Carry it through instead.
        if let orientation {
            props[kCGImagePropertyOrientation] = orientation.rawValue
        }

        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }

    /// Highest-quality rung that fits under `maxBytes`, or the lowest rung if
    /// none do. `ladder` must run from highest quality to lowest.
    ///
    /// Equivalent to scanning the ladder top-down and taking the first fit, but
    /// costs O(log n) encodes instead of O(n).
    private static func search(
        _ image: CGImage, ladder: [Int], maxBytes: Int,
        orientation: CGImagePropertyOrientation?
    ) -> (data: Data, quality: Int)? {
        var low = 0
        var high = ladder.count - 1
        var fit: (data: Data, quality: Int)?

        while low <= high {
            let mid = (low + high) / 2
            guard let data = encode(image, quality: ladder[mid], orientation: orientation) else {
                return fit
            }
            if data.count <= maxBytes {
                fit = (data, ladder[mid])
                high = mid - 1  // fits — reach for better quality
            } else {
                low = mid + 1
            }
        }

        if let fit { return fit }
        // Nothing fit. The caller needs the smallest we can manage, which is the
        // bottom rung — the search may not have landed on it.
        guard let last = ladder.last, let data = encode(image, quality: last, orientation: orientation)
        else { return nil }
        return (data, last)
    }

    /// Decodes at (or just above) a target size. ImageIO scales during decode,
    /// which is far cheaper than decoding full-size and resampling afterwards.
    private static func decode(
        _ source: CGImageSource, maxPixelSize: Int?
    ) -> CGImage? {
        var options: [CFString: Any] = [
            // Decode once, up front, and hold the pixels. Without this the
            // bitmap can be re-decoded behind every single encode.
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
            // Orientation is written into the output separately; don't bake it in.
            options[kCGImageSourceCreateThumbnailWithTransform] = false
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    static func compress(
        source: URL, destination: URL, maxBytes: Int, allowResize: Bool = true
    ) -> FileResult {
        let name = source.lastPathComponent

        func failure(_ message: String) -> FileResult {
            FileResult(
                name: name, outputBytes: 0, quality: 0, width: 0, height: 0,
                wasResized: false, overCap: false, error: message)
        }

        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            return failure("could not be read")
        }
        guard let original = decode(imageSource, maxPixelSize: nil) else {
            return failure("could not be decoded")
        }

        let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:))

        // Pass 1: full resolution, same rungs as the script.
        guard
            var best = search(
                original, ladder: qualities, maxBytes: maxBytes, orientation: orientation)
        else {
            return failure("could not be encoded")
        }
        var width = original.width
        var height = original.height
        var resizedAtAll = false

        // Pass 2+: only reached when full resolution can't fit.
        if best.data.count > maxBytes && allowResize {
            var maxDimension = max(original.width, original.height)
            for _ in 0..<maxResizeAttempts {
                // JPEG size tracks pixel count, so the square root of the
                // overshoot is a good step; clamp so we neither crawl nor
                // overshoot into mush.
                let ratio = Double(maxBytes) / Double(best.data.count)
                let factor = min(0.85, max(0.45, (ratio * 0.9).squareRoot()))
                maxDimension = Int(Double(maxDimension) * factor)

                guard maxDimension >= minimumWidth,
                    let smaller = decode(imageSource, maxPixelSize: maxDimension),
                    let candidate = search(
                        smaller, ladder: resizeQualities, maxBytes: maxBytes,
                        orientation: orientation)
                else { break }

                best = candidate
                width = smaller.width
                height = smaller.height
                resizedAtAll = true
                if candidate.data.count <= maxBytes { break }
            }
        }

        do {
            try best.data.write(to: destination, options: .atomic)
        } catch {
            return failure(error.localizedDescription)
        }

        return FileResult(
            name: name, outputBytes: best.data.count, quality: best.quality,
            width: width, height: height, wasResized: resizedAtAll,
            overCap: best.data.count > maxBytes, error: nil)
    }
}

// MARK: - Folder scanning

enum FolderScanner {
    static let extensions: Set<String> = ["jpg", "jpeg"]

    static func images(in folder: URL) -> [URL] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return contents
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Sibling of the input folder, in the same parent: "Photos" -> "Photos_Compressed".
    /// Adds a numeric suffix rather than overwriting an existing folder.
    static func outputFolder(for input: URL) -> URL {
        let parent = input.deletingLastPathComponent()
        let base = input.lastPathComponent + "_Compressed"
        var candidate = parent.appendingPathComponent(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(counter)")
            counter += 1
        }
        return candidate
    }
}
