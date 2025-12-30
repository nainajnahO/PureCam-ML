// PureCam - An iOS camera app with AI-powered exposure control
// Copyright (C) 2025 nainajnahO
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import CoreImage
import CoreVideo
import Accelerate
import UIKit

/// Extracts scene features from camera preview for ML inference
/// Optimized for performance on modern devices
class SceneFeatureExtractor {
    // MARK: - Properties

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    // Optimization: Downsample to 256x256 for analysis (reduces 12MP to 65K pixels)
    private let targetSize = CGSize(width: 256, height: 256)

    // MARK: - Public Methods

    /// Extract scene features from CIImage
    /// - Parameter ciImage: Live camera preview or captured image
    /// - Returns: SceneFeatures if successful, nil otherwise
    func extract(from ciImage: CIImage) -> SceneFeatures? {
        let startTime = Date()

        // 1. Downsample image
        let downsampled = downsample(ciImage)

        // 2. Convert to luminance buffer
        guard let luminanceBuffer = extractLuminance(from: downsampled) else {
            print("Failed to extract luminance")
            return nil
        }

        // 3. Compute statistics using Accelerate
        let stats = computeStatistics(luminanceBuffer: luminanceBuffer)

        // 4. Compute histogram
        let histogram = computeHistogram(luminanceBuffer: luminanceBuffer)

        // 5. Extract color info
        let colorInfo = extractColorInfo(from: downsampled)

        // 6. Compute center-weighted luminance
        let centerWeighted = computeCenterWeightedLuminance(luminanceBuffer: luminanceBuffer)

        let features = SceneFeatures(
            meanLuminance: stats.mean,
            medianLuminance: stats.median,
            minLuminance: stats.min,
            maxLuminance: stats.max,
            stdDevLuminance: stats.stdDev,
            shadowsPercent: histogram.shadows,
            midtonesPercent: histogram.midtones,
            highlightsPercent: histogram.highlights,
            clippedHighlightsPercent: histogram.clippedHighlights,
            clippedShadowsPercent: histogram.clippedShadows,
            colorTemperature: colorInfo.temperature,
            saturation: colorInfo.saturation,
            centerWeightedLuminance: centerWeighted,
            timestamp: Date()
        )

        let elapsed = Date().timeIntervalSince(startTime) * 1000
        print("Feature extraction: \(String(format: "%.1f", elapsed))ms")

        return features
    }

    // MARK: - Private Helpers

    /// Downsample image to target size for efficient processing
    private func downsample(_ image: CIImage) -> CIImage {
        let scaleX = targetSize.width / image.extent.width
        let scaleY = targetSize.height / image.extent.height
        let scale = min(scaleX, scaleY)

        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Extract luminance values as Float array using Rec. 709 coefficients
    private func extractLuminance(from image: CIImage) -> [Float]? {
        // Convert to grayscale using Rec. 709: Y = 0.2126R + 0.7152G + 0.0722B
        let grayscaleFilter = CIFilter(name: "CIColorMatrix")!
        grayscaleFilter.setValue(image, forKey: kCIInputImageKey)
        grayscaleFilter.setValue(CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), forKey: "inputRVector")
        grayscaleFilter.setValue(CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), forKey: "inputGVector")
        grayscaleFilter.setValue(CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), forKey: "inputBVector")
        grayscaleFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")

        guard let outputImage = grayscaleFilter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        // Extract pixel data
        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8

        var floatPixels = [Float]()
        floatPixels.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let pixel = bytes[offset]
                floatPixels.append(Float(pixel) / 255.0)
            }
        }

        return floatPixels
    }

    /// Compute luminance statistics using Accelerate framework
    private func computeStatistics(luminanceBuffer: [Float]) -> (mean: Float, median: Float, min: Float, max: Float, stdDev: Float) {
        var mean: Float = 0
        var min: Float = 1
        var max: Float = 0

        // Use Accelerate for vectorized operations
        vDSP_meanv(luminanceBuffer, 1, &mean, vDSP_Length(luminanceBuffer.count))
        vDSP_minv(luminanceBuffer, 1, &min, vDSP_Length(luminanceBuffer.count))
        vDSP_maxv(luminanceBuffer, 1, &max, vDSP_Length(luminanceBuffer.count))

        // Compute standard deviation
        var variance: Float = 0
        var meanSubtracted = [Float](repeating: 0, count: luminanceBuffer.count)
        var negMean = -mean
        vDSP_vsadd(luminanceBuffer, 1, &negMean, &meanSubtracted, 1, vDSP_Length(luminanceBuffer.count))
        vDSP_measqv(meanSubtracted, 1, &variance, vDSP_Length(luminanceBuffer.count))
        let stdDev = sqrt(variance)

        // Median (requires sort)
        let sorted = luminanceBuffer.sorted()
        let median = sorted[sorted.count / 2]

        return (mean, median, min, max, stdDev)
    }

    /// Compute histogram distribution
    private func computeHistogram(luminanceBuffer: [Float]) -> (
        shadows: Float,
        midtones: Float,
        highlights: Float,
        clippedShadows: Float,
        clippedHighlights: Float
    ) {
        let total = Float(luminanceBuffer.count)

        var shadows = 0
        var midtones = 0
        var highlights = 0
        var clippedShadows = 0
        var clippedHighlights = 0

        for pixel in luminanceBuffer {
            // Clipping detection
            if pixel < 0.02 { clippedShadows += 1 }
            if pixel > 0.98 { clippedHighlights += 1 }

            // Histogram bins
            if pixel < 0.25 {
                shadows += 1
            } else if pixel < 0.75 {
                midtones += 1
            } else {
                highlights += 1
            }
        }

        return (
            Float(shadows) / total,
            Float(midtones) / total,
            Float(highlights) / total,
            Float(clippedShadows) / total,
            Float(clippedHighlights) / total
        )
    }

    /// Extract color information using RGB analysis
    private func extractColorInfo(from image: CIImage) -> (temperature: Float, saturation: Float) {
        // Downsample to 32x32 for fast color analysis (1024 pixels)
        let smallImage = downsampleForColorAnalysis(image, targetSize: 32)

        guard let pixelData = extractRGBPixels(from: smallImage) else {
            return (5500, 0.5) // Fallback to neutral values
        }

        // Calculate average RGB values
        var totalR: Float = 0
        var totalG: Float = 0
        var totalB: Float = 0

        for pixel in pixelData {
            totalR += pixel.r
            totalG += pixel.g
            totalB += pixel.b
        }

        let avgR = totalR / Float(pixelData.count)
        let avgG = totalG / Float(pixelData.count)
        let avgB = totalB / Float(pixelData.count)

        // Estimate color temperature from RGB ratios
        let temperature = estimateColorTemperature(r: avgR, g: avgG, b: avgB)

        // Calculate average saturation via HSV conversion
        var totalSaturation: Float = 0
        for pixel in pixelData {
            let hsv = rgbToHSV(pixel)
            totalSaturation += hsv.s
        }
        let avgSaturation = totalSaturation / Float(pixelData.count)

        return (temperature, avgSaturation)
    }

    /// Downsample image for fast color analysis
    private func downsampleForColorAnalysis(_ image: CIImage, targetSize: Int) -> CIImage {
        let size = CGFloat(targetSize)
        let scaleX = size / image.extent.width
        let scaleY = size / image.extent.height
        let scale = min(scaleX, scaleY)
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Extract RGB pixel data from image
    private func extractRGBPixels(from image: CIImage) -> [(r: Float, g: Float, b: Float)]? {
        // Render to bitmap
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8

        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert to Float tuples
        var result = [(r: Float, g: Float, b: Float)]()
        result.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * bytesPerPixel
                let r = Float(pixelData[offset]) / 255.0
                let g = Float(pixelData[offset + 1]) / 255.0
                let b = Float(pixelData[offset + 2]) / 255.0
                result.append((r, g, b))
            }
        }

        return result
    }

    /// Estimate color temperature from RGB ratios
    /// Uses simplified McCamy's approximation
    private func estimateColorTemperature(r: Float, g: Float, b: Float) -> Float {
        // Blue/Red ratio approach
        let ratio = b / max(r, 0.001)

        // Map ratio to temperature (empirical calibration)
        // ratio > 1.0 → cool (blue-ish) → high Kelvin (6500-10000)
        // ratio < 1.0 → warm (orange-ish) → low Kelvin (2500-5500)

        if ratio > 1.0 {
            // Cool light: Linear map from 5500 to 10000
            return 5500 + min((ratio - 1.0) * 4500, 4500)
        } else {
            // Warm light: Linear map from 2500 to 5500
            return 2500 + (ratio * 3000)
        }
    }

    /// Convert RGB to HSV for saturation extraction
    private func rgbToHSV(_ pixel: (r: Float, g: Float, b: Float)) -> (h: Float, s: Float, v: Float) {
        let maxComponent = max(pixel.r, pixel.g, pixel.b)
        let minComponent = min(pixel.r, pixel.g, pixel.b)
        let delta = maxComponent - minComponent

        let v = maxComponent
        let s = maxComponent == 0 ? 0 : delta / maxComponent

        // Hue not needed for saturation extraction
        let h: Float = 0

        return (h, s, v)
    }

    /// Compute center-weighted luminance using Gaussian weighting
    /// Mimics traditional center-weighted metering in photography
    private func computeCenterWeightedLuminance(luminanceBuffer: [Float]) -> Float {
        // Calculate actual dimensions from buffer size (assumes square image)
        let totalPixels = luminanceBuffer.count
        let dimension = Int(sqrt(Double(totalPixels)))

        // Safety check: ensure buffer is valid
        guard dimension * dimension == totalPixels else {
            // Fallback to simple mean if buffer size doesn't match expected dimensions
            var mean: Float = 0
            vDSP_meanv(luminanceBuffer, 1, &mean, vDSP_Length(luminanceBuffer.count))
            return mean
        }

        let width = dimension
        let height = dimension

        // Gaussian weighting parameters
        let centerX = Float(width) / 2.0
        let centerY = Float(height) / 2.0
        let sigma = Float(width) / 4.0  // Standard deviation (covers ~95% at edges)

        var weightedSum: Float = 0
        var totalWeight: Float = 0

        for y in 0..<height {
            for x in 0..<width {
                let dx = Float(x) - centerX
                let dy = Float(y) - centerY
                let distanceSquared = dx * dx + dy * dy

                // Gaussian weight: exp(-distance²/(2σ²))
                let weight = exp(-distanceSquared / (2 * sigma * sigma))

                let pixel = luminanceBuffer[y * width + x]
                weightedSum += pixel * weight
                totalWeight += weight
            }
        }

        return weightedSum / totalWeight
    }
}
