// PureLenz - An iOS camera app with AI-powered exposure control
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
import OSLog

/// Extracts scene features from camera preview for ML inference
/// Optimized for performance on modern devices
class SceneFeatureExtractor {
    // MARK: - Properties

    /// Shared, GPU-backed context (creating a CIContext per extractor is costly).
    private let context = CIContext.shared

    /// Long edge of the luminance analysis buffer (reduces 12MP to ~50K pixels).
    private let analysisSize: CGFloat = 256

    /// Rec. 709 luma coefficients for the grayscale conversion.
    private let lumaVector = CIVector(
        x: CGFloat(LuminanceConstants.rec709Red),
        y: CGFloat(LuminanceConstants.rec709Green),
        z: CGFloat(LuminanceConstants.rec709Blue),
        w: 0
    )

    // MARK: - Public Methods

    /// Extract scene features from CIImage
    /// - Parameters:
    ///   - ciImage: Live camera preview or captured image
    ///   - frameISO: ISO the frame was captured with (for scene-light normalization)
    ///   - frameShutterSeconds: Exposure duration the frame was captured with
    /// - Returns: SceneFeatures if successful, nil otherwise
    func extract(from ciImage: CIImage, frameISO: Float, frameShutterSeconds: Double) -> SceneFeatures? {
        // A frame with unknown exposure can't be normalized into an absolute
        // scene light level — better no features than a wildly wrong value.
        guard frameISO > 0, frameShutterSeconds > 0 else {
            Logger.ml.error("Rejecting frame with non-positive exposure (ISO \(frameISO), shutter \(frameShutterSeconds)s)")
            return nil
        }

        let startTime = Date()

        // 1. Downsample image
        let downsampled = downsample(ciImage, toFit: analysisSize)

        // 2. Convert to luminance buffer (dimensions carried alongside — the
        //    center-weighted metering needs the real shape, not a guess).
        guard let luminance = extractLuminance(from: downsampled) else {
            Logger.ml.error("Failed to extract luminance")
            return nil
        }

        // 3. One byte-quantized histogram feeds both the median and the tonal
        //    bins; vDSP covers the rest of the statistics.
        let bins = quantizedHistogram(luminance.values)
        let stats = computeStatistics(luminanceBuffer: luminance.values, histogram: bins)
        let histogram = computeHistogram(histogram: bins, totalPixels: luminance.values.count)

        // 4. Extract color info
        let colorInfo = extractColorInfo(from: downsampled)

        // 5. Compute center-weighted luminance
        let centerWeighted = computeCenterWeightedLuminance(
            luminanceBuffer: luminance.values,
            width: luminance.width,
            height: luminance.height
        )

        // 6. Normalize brightness by the frame's exposure to get absolute scene light
        let sceneLight = SceneFeatures.computeSceneLightLevel(
            meanLuminance: stats.mean,
            iso: frameISO,
            shutterSeconds: frameShutterSeconds
        )

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
            sceneLightLevel: sceneLight,
            timestamp: Date()
        )

        let elapsed = Date().timeIntervalSince(startTime) * 1000
        Logger.ml.debug("Feature extraction: \(String(format: "%.1f", elapsed))ms")

        return features
    }

    // MARK: - Private Helpers

    /// Downsample image so its long edge fits `target`, preserving aspect ratio.
    private func downsample(_ image: CIImage, toFit target: CGFloat) -> CIImage {
        let scale = min(target / image.extent.width, target / image.extent.height)
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Extract luminance values as a Float array using Rec. 709 coefficients,
    /// with the buffer's real dimensions. The shape is returned rather than
    /// inferred later: `downsample` preserves aspect ratio, so the buffer is
    /// generally not square and cannot be reconstructed from its count.
    private func extractLuminance(from image: CIImage) -> (values: [Float], width: Int, height: Int)? {
        // Convert to grayscale using Rec. 709: Y = 0.2126R + 0.7152G + 0.0722B
        let grayscale = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": lumaVector,
            "inputGVector": lumaVector,
            "inputBVector": lumaVector,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        guard let cgImage = context.createCGImage(grayscale, from: grayscale.extent),
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8

        // vDSP bulk-converts each row's first-channel bytes (the stride skips
        // any other channels); one final divide normalizes to 0-1.
        var floatPixels = [Float](repeating: 0, count: width * height)
        floatPixels.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<height {
                vDSP_vfltu8(
                    bytes + y * bytesPerRow, vDSP_Stride(bytesPerPixel),
                    buffer.baseAddress! + y * width, 1,
                    vDSP_Length(width)
                )
            }
        }
        var divisor: Float = 255
        vDSP_vsdiv(floatPixels, 1, &divisor, &floatPixels, 1, vDSP_Length(floatPixels.count))

        return (floatPixels, width, height)
    }

    /// 256-bin counting histogram of the luminance values. The buffer came from
    /// 8-bit pixels (each value is exactly k/255), so binning by round(v·255)
    /// is exact — it feeds both the median and the tonal-range fractions.
    private func quantizedHistogram(_ luminanceBuffer: [Float]) -> [Int] {
        var bins = [Int](repeating: 0, count: 256)
        for value in luminanceBuffer {
            bins[Int(value * 255 + 0.5)] += 1
        }
        return bins
    }

    /// Compute luminance statistics using Accelerate framework
    private func computeStatistics(
        luminanceBuffer: [Float],
        histogram: [Int]
    ) -> (mean: Float, median: Float, min: Float, max: Float, stdDev: Float) {
        let count = vDSP_Length(luminanceBuffer.count)
        var mean: Float = 0
        var stdDev: Float = 0
        var min: Float = 1
        var max: Float = 0

        vDSP_minv(luminanceBuffer, 1, &min, count)
        vDSP_maxv(luminanceBuffer, 1, &max, count)
        // Mean and standard deviation in a single pass (a nil output vector
        // means "statistics only, don't normalize").
        vDSP_normalize(luminanceBuffer, 1, nil, 1, &mean, &stdDev, count)

        // Median: the (n/2 + 1)-th smallest value read from the cumulative
        // histogram — exact for these quantized values, no O(n log n) sort.
        var median: Float = 0
        var cumulative = 0
        for (bin, binCount) in histogram.enumerated() {
            cumulative += binCount
            if cumulative > luminanceBuffer.count / 2 {
                median = Float(bin) / 255
                break
            }
        }

        return (mean, median, min, max, stdDev)
    }

    /// Compute the tonal distribution from the quantized histogram — same
    /// thresholds as a per-pixel pass, applied per bin instead of per pixel.
    private func computeHistogram(histogram: [Int], totalPixels: Int) -> (
        shadows: Float,
        midtones: Float,
        highlights: Float,
        clippedShadows: Float,
        clippedHighlights: Float
    ) {
        var shadows = 0
        var midtones = 0
        var highlights = 0
        var clippedShadows = 0
        var clippedHighlights = 0

        for (bin, count) in histogram.enumerated() {
            let value = Float(bin) / 255

            // Clipping detection
            if value < LuminanceConstants.clippedShadowsThreshold { clippedShadows += count }
            if value > LuminanceConstants.clippedHighlightsThreshold { clippedHighlights += count }

            // Histogram bins
            if value < LuminanceConstants.shadowsUpperBound {
                shadows += count
            } else if value < LuminanceConstants.midtonesUpperBound {
                midtones += count
            } else {
                highlights += count
            }
        }

        let total = Float(totalPixels)
        return (
            Float(shadows) / total,
            Float(midtones) / total,
            Float(highlights) / total,
            Float(clippedShadows) / total,
            Float(clippedHighlights) / total
        )
    }

    /// Extract color information (temperature and saturation) from a 32×32
    /// downsample, rendered once and accumulated in a single pass.
    private func extractColorInfo(from image: CIImage) -> (temperature: Float, saturation: Float) {
        let smallImage = downsample(image, toFit: 32)
        let width = Int(smallImage.extent.width.rounded())
        let height = Int(smallImage.extent.height.rounded())

        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return (5500, 0.5) // Fallback to neutral values
        }

        // Render RGBA bytes straight into the buffer — no intermediate CGImage
        // or second CGContext draw.
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            smallImage,
            toBitmap: &pixelData,
            rowBytes: width * 4,
            bounds: smallImage.extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )

        // One pass accumulates the channel averages and the mean saturation.
        // Saturation must be per pixel — the saturation of the average color is
        // not the average saturation.
        var totalR: Float = 0
        var totalG: Float = 0
        var totalB: Float = 0
        var totalSaturation: Float = 0

        for offset in stride(from: 0, to: pixelData.count, by: 4) {
            let r = Float(pixelData[offset]) / 255.0
            let g = Float(pixelData[offset + 1]) / 255.0
            let b = Float(pixelData[offset + 2]) / 255.0
            totalR += r
            totalG += g
            totalB += b

            let maxComponent = max(r, g, b)
            let minComponent = min(r, g, b)
            totalSaturation += maxComponent == 0 ? 0 : (maxComponent - minComponent) / maxComponent
        }

        let pixelCount = Float(width * height)
        let temperature = estimateColorTemperature(
            r: totalR / pixelCount,
            g: totalG / pixelCount,
            b: totalB / pixelCount
        )

        return (temperature, totalSaturation / pixelCount)
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

    /// Compute center-weighted luminance using Gaussian weighting.
    /// Mimics traditional center-weighted metering in photography: the middle
    /// of the frame counts for more than the edges.
    ///
    /// Sigma is a quarter of *each* axis, so the frame edge sits at 2σ (~13.5%
    /// weight) on both axes whatever the aspect ratio. That is the same
    /// relationship the original square-only code had, generalized per axis
    /// rather than replaced — a square buffer produces identical weights.
    ///
    /// The 2D Gaussian is separable — exp(-(dx²/2σx² + dy²/2σy²)) factors into
    /// exp(-dx²/2σx²)·exp(-dy²/2σy²) — so the two 1D profiles cost width+height
    /// `exp` calls instead of width×height (≈450 instead of ≈49,000), and the
    /// weighted sum becomes one vDSP dot product per row. No cached state, so
    /// the extractor stays free of shared mutable data.
    private func computeCenterWeightedLuminance(
        luminanceBuffer: [Float],
        width: Int,
        height: Int
    ) -> Float {
        guard width > 0, height > 0, luminanceBuffer.count == width * height else { return 0 }

        let sigmaX = Float(width) / 4.0
        let sigmaY = Float(height) / 4.0
        let weightsX = (0..<width).map { x -> Float in
            let dx = Float(x) - Float(width) / 2.0
            return exp(-(dx * dx) / (2 * sigmaX * sigmaX))
        }
        let weightsY = (0..<height).map { y -> Float in
            let dy = Float(y) - Float(height) / 2.0
            return exp(-(dy * dy) / (2 * sigmaY * sigmaY))
        }

        var weightedSum: Float = 0
        luminanceBuffer.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for y in 0..<height {
                var rowSum: Float = 0
                vDSP_dotpr(base + y * width, 1, weightsX, 1, &rowSum, vDSP_Length(width))
                weightedSum += rowSum * weightsY[y]
            }
        }

        // The full weight matrix sums to the product of the two profile sums.
        let totalWeight = weightsX.reduce(0, +) * weightsY.reduce(0, +)
        return weightedSum / totalWeight
    }
}
