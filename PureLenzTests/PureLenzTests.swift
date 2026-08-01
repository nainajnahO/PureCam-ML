// PureLenz - An iOS camera app with AI-powered exposure control
// Copyright (C) 2025 nainajnahO
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Testing
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import TabularData
@testable import PureLenz

@Suite("ExposureCalculator")
struct ExposureCalculatorTests {
    // Typical iPhone ISO range used across these tests.
    private let minISO: Float = 32
    private let maxISO: Float = 3200

    @Test("isoFromProgress returns the minimum at progress 0")
    func isoAtZeroProgressReturnsMin() {
        let iso = ExposureCalculator.isoFromProgress(0, min: minISO, max: maxISO)
        #expect(abs(iso - minISO) < 0.01)
    }

    @Test("isoFromProgress returns the maximum at progress 1")
    func isoAtOneProgressReturnsMax() {
        let iso = ExposureCalculator.isoFromProgress(1, min: minISO, max: maxISO)
        #expect(abs(iso - maxISO) < 1.0)
    }

    @Test("isoFromProgress is logarithmic: midpoint equals the geometric mean")
    func isoAtMidpointIsGeometricMean() {
        // A logarithmic mapping puts the geometric mean (not the arithmetic mean)
        // at progress=0.5. For min=32, max=3200, geometric mean is sqrt(32 * 3200) = 320.
        let iso = ExposureCalculator.isoFromProgress(0.5, min: minISO, max: maxISO)
        let geometricMean = sqrt(minISO * maxISO)
        #expect(abs(iso - geometricMean) < 1.0)
    }

    @Test("angleFromISO is the inverse of isoFromProgress (round trip)")
    func angleAndProgressRoundTrip() {
        let originalProgress = 0.42
        let iso = ExposureCalculator.isoFromProgress(originalProgress, min: minISO, max: maxISO)
        let angle = ExposureCalculator.angleFromISO(iso, min: minISO, max: maxISO)

        // angleFromISO maps progress 0...1 across the knob's arc, which is
        // deliberately less than a full turn — see sweepDegrees.
        let expectedDegrees = originalProgress * ExposureControlConstants.sweepDegrees
        #expect(abs(angle.degrees - expectedDegrees) < 0.1)
    }

    @Test("shutterFromProgress maps the endpoints to the supplied range")
    func shutterMapsEndpointsToRange() {
        // The calculator is pure math over the range it is handed — the manual
        // policy caps are applied upstream, in CameraService's configuration.
        let min = CameraConstants.fastestManualShutter
        let max = CameraConstants.slowestManualShutter

        let fastest = ExposureCalculator.shutterFromProgress(0, min: min, max: max)
        let slowest = ExposureCalculator.shutterFromProgress(1, min: min, max: max)

        #expect(abs(fastest - min) < 1e-9)
        #expect(abs(slowest - max) < 1e-9)
    }

    @Test("angleFromShutter clamps to the knob's arc for out-of-range shutter values")
    func angleFromShutterClampsToValidRange() {
        let min = CameraConstants.fastestManualShutter
        let max = CameraConstants.slowestManualShutter

        // Faster than the minimum → clamp to 0°
        let tooFast = ExposureCalculator.angleFromShutter(1.0 / 8000.0, min: min, max: max)
        #expect(tooFast.degrees == 0)

        // Slower than the maximum → clamp to the far end of the arc
        let tooSlow = ExposureCalculator.angleFromShutter(2.0, min: min, max: max)
        #expect(tooSlow.degrees == ExposureControlConstants.sweepDegrees)
    }

    /// The whole point of the wall: the two ends must not be the same bearing.
    /// If the sweep ever went back to a full turn, minimum and maximum would
    /// coincide at 12 o'clock again and a nudge past one would land on the other.
    @Test("the arc stops short of a full turn, so the ends are different places")
    func sweepLeavesAGap() {
        #expect(ExposureControlConstants.sweepDegrees < 360)
        #expect(ExposureControlConstants.sweepDegrees > 180)

        let start = ExposureCalculator.angle(forProgress: 0).degrees
        let end = ExposureCalculator.angle(forProgress: 1).degrees
        #expect(360 - (end - start) >= 30)
    }
}

@Suite("Knob accumulation")
struct KnobAccumulationTests {
    /// Turning the knob past an end must hold there. Before accumulation, the
    /// value came straight from the thumb's bearing, so crossing 12 o'clock
    /// flipped ISO from its maximum to its minimum in a single frame.
    @Test("pushing past the top holds at the maximum instead of wrapping")
    func pushingPastTopHolds() {
        let nearTop = ExposureCalculator.accumulate(progress: 0.95, bearingDelta: 60)
        #expect(nearTop.progress == 1.0)
        #expect(nearTop.hitWall)

        // Keep pushing: still pinned, and no second bump.
        let pushOn = ExposureCalculator.accumulate(progress: 1.0, bearingDelta: 60)
        #expect(pushOn.progress == 1.0)
        #expect(!pushOn.hitWall)
    }

    @Test("pushing past the bottom holds at the minimum instead of wrapping")
    func pushingPastBottomHolds() {
        let nearBottom = ExposureCalculator.accumulate(progress: 0.05, bearingDelta: -60)
        #expect(nearBottom.progress == 0.0)
        #expect(nearBottom.hitWall)

        let pushOn = ExposureCalculator.accumulate(progress: 0.0, bearingDelta: -60)
        #expect(pushOn.progress == 0.0)
        #expect(!pushOn.hitWall)
    }

    /// Reversing has to release immediately. If arriving at the wall stored any
    /// overshoot, the user would have to wind that back before the value moved,
    /// which reads as the knob being stuck.
    @Test("reversing off the wall moves on the very next frame")
    func reversingLeavesTheWallAtOnce() {
        let pinned = ExposureCalculator.accumulate(progress: 1.0, bearingDelta: 60).progress
        #expect(pinned == 1.0)

        let backOff = ExposureCalculator.accumulate(progress: pinned, bearingDelta: -30)
        #expect(backOff.progress < 1.0)
        #expect(!backOff.hitWall)
    }

    /// A continuous sweep all the way round must not cycle. This is the exact
    /// gesture that used to flip the extremes.
    @Test("a full turn cannot carry the value past an end and back round")
    func fullTurnCannotWrap() {
        var progress = 0.5
        // 24 frames of +30° is 720° — two full turns in one drag.
        for _ in 0..<24 {
            progress = ExposureCalculator.accumulate(progress: progress, bearingDelta: 30).progress
        }
        #expect(progress == 1.0)
    }

    /// Bearings are compass readings, so a thumb crossing 12 o'clock reports
    /// 359° → 1°. Read naively that is a 358° leap backwards, which would slam
    /// the knob to the opposite end.
    @Test("crossing twelve o'clock reads as a small step, not a leap backwards")
    func shortestArcHandlesTheSeam() {
        #expect(ExposureCalculator.shortestArcDelta(from: 359, to: 1) == 2)
        #expect(ExposureCalculator.shortestArcDelta(from: 1, to: 359) == -2)
        #expect(ExposureCalculator.shortestArcDelta(from: 10, to: 40) == 30)
        #expect(abs(ExposureCalculator.shortestArcDelta(from: 40, to: 10)) == 30)
    }

    /// The sweep is what converts thumb travel into value, so a turn equal to
    /// the whole arc must cover exactly the whole range — no more, no less.
    @Test("turning through the full arc covers exactly the whole range")
    func fullArcCoversFullRange() {
        let full = ExposureCalculator.accumulate(
            progress: 0, bearingDelta: ExposureControlConstants.sweepDegrees
        )
        #expect(abs(full.progress - 1.0) < 1e-12)

        let half = ExposureCalculator.accumulate(
            progress: 0, bearingDelta: ExposureControlConstants.sweepDegrees / 2
        )
        #expect(abs(half.progress - 0.5) < 1e-12)
    }

    /// Progress is the source of truth for the value too, so the forward mapping
    /// must refuse to extrapolate past the ends even if handed an out-of-range
    /// progress — otherwise a wall in the gesture could still be walked around.
    @Test("the value mapping clamps rather than extrapolating past the ends")
    func valueMappingClamps() {
        let beyondMax = ExposureCalculator.isoFromProgress(1.5, min: 32, max: 3200)
        let atMax = ExposureCalculator.isoFromProgress(1.0, min: 32, max: 3200)
        #expect(abs(beyondMax - atMax) < 0.01)

        let belowMin = ExposureCalculator.shutterFromProgress(
            -0.5, min: CameraConstants.fastestManualShutter,
            max: CameraConstants.slowestManualShutter
        )
        #expect(abs(belowMin - CameraConstants.fastestManualShutter) < 1e-9)
    }
}

@Suite("SceneLightLevel")
struct SceneLightLevelTests {
    @Test("computeSceneLightLevel matches the formula for known inputs")
    func knownValue() {
        // log2(0.5) - log2(50 * 1/1000) = -1 - log2(0.05) ≈ 3.3219
        let value = SceneFeatures.computeSceneLightLevel(
            meanLuminance: 0.5, iso: 50, shutterSeconds: 1.0 / 1000.0
        )
        #expect(abs(value - 3.3219) < 0.001)
    }

    @Test("separates a sunny scene from a dim scene even when previews look alike")
    func separatesSunnyFromDim() {
        // Both frames are well exposed (similar meanLuminance) — the situation
        // where the other 13 features are blind. The exposure normalization
        // must still tell them apart by many stops.
        let sunny = SceneFeatures.computeSceneLightLevel(
            meanLuminance: 0.48, iso: 50, shutterSeconds: 1.0 / 1250.0
        )
        let dim = SceneFeatures.computeSceneLightLevel(
            meanLuminance: 0.44, iso: 640, shutterSeconds: 1.0 / 30.0
        )
        #expect(sunny - dim > 5)
    }

    @Test("equal previews at different exposures yield different scene light")
    func normalizesByExposure() {
        // Same preview brightness, 4x the exposure → exactly 2 stops less scene light.
        let a = SceneFeatures.computeSceneLightLevel(
            meanLuminance: 0.5, iso: 100, shutterSeconds: 1.0 / 100.0
        )
        let b = SceneFeatures.computeSceneLightLevel(
            meanLuminance: 0.5, iso: 400, shutterSeconds: 1.0 / 100.0
        )
        #expect(abs((a - b) - 2) < 0.001)
    }

    @Test("stays finite for an all-black frame")
    func blackFrameIsFinite() {
        let value = SceneFeatures.computeSceneLightLevel(
            meanLuminance: 0, iso: 6400, shutterSeconds: 0.5
        )
        #expect(value.isFinite)
    }
}

@Suite("DataFrameBuilder log-space targets")
struct DataFrameBuilderTests {
    private let samples = [
        TrainingSample(
            features: SceneFeatures(
                meanLuminance: 0.5,
                medianLuminance: 0.5,
                minLuminance: 0.0,
                maxLuminance: 1.0,
                stdDevLuminance: 0.2,
                shadowsPercent: 0.2,
                midtonesPercent: 0.6,
                highlightsPercent: 0.2,
                clippedHighlightsPercent: 0.01,
                clippedShadowsPercent: 0.01,
                colorTemperature: 5500,
                saturation: 0.3,
                centerWeightedLuminance: 0.5,
                sceneLightLevel: 3.3,
                timestamp: Date()
            ),
            iso: 64,
            shutterSeconds: 1.0 / 256.0
        )
    ]

    @Test("ISO DataFrame stores targets as log2 and includes sceneLightLevel")
    func isoDataFrameUsesLogTargets() {
        let df = DataFrameBuilder.createISODataFrame(samples: samples)
        #expect(df.columns.map(\.name).contains("sceneLightLevel"))
        #expect(df["targetLogISO", Double.self][0] == 6.0)  // log2(64)
    }

    @Test("shutter DataFrame stores chosen ISO and target as log2")
    func shutterDataFrameUsesLogTargets() {
        let df = DataFrameBuilder.createShutterDataFrame(samples: samples)
        #expect(df["chosenLogISO", Double.self][0] == 6.0)    // log2(64)
        #expect(df["targetLogShutter", Double.self][0] == -8.0)  // log2(1/256)
    }

    /// Both the training columns and the inference keys are generated from
    /// `SceneFeatures.mlFeatures`, so comparing them to each other can only
    /// ever pass. What this *does* pin is that every entry survives the trip
    /// through `MLDictionaryFeatureProvider` — a value it refused to box would
    /// go missing here.
    @Test("every schema column survives conversion to an ML feature provider")
    func everyColumnSurvivesProviderConversion() throws {
        let df = DataFrameBuilder.createISODataFrame(samples: samples)
        let provider = try samples[0].features.toMLFeatureProvider()
        let featureColumns = Set(df.columns.map(\.name)).subtracting(["targetLogISO"])
        #expect(featureColumns == Set(provider.featureNames))
    }

    /// The drift the shared table cannot prevent: adding a `Float` to
    /// `SceneFeatures` and forgetting its row. The feature would then be
    /// silently absent from both training and inference — no crash, no error,
    /// it simply never reaches the model. Reflection catches it because it sees
    /// the struct's real stored properties rather than the table's view of them.
    @Test("every Float feature on SceneFeatures has a row in the ML schema table")
    func schemaTableCoversEveryFloatProperty() {
        let declaredFloats = Mirror(reflecting: samples[0].features).children
            .compactMap { $0.value is Float ? $0.label : nil }

        #expect(Set(declaredFloats) == Set(SceneFeatures.mlFeatures.map(\.name)))
    }

    /// Column names are part of the on-disk contract with an already-trained
    /// model: renaming one without bumping the `MLFiles` suffix would leave a
    /// model being fed a column it never saw during training. Spelling the
    /// expected schema out here makes that rename fail a test rather than
    /// surface as a prediction error after the next training run.
    @Test("the ML schema is exactly the fourteen expected columns, in order")
    func schemaTableMatchesExpectedNames() {
        #expect(SceneFeatures.mlFeatures.map(\.name) == [
            "meanLuminance",
            "medianLuminance",
            "minLuminance",
            "maxLuminance",
            "stdDevLuminance",
            "shadowsPercent",
            "midtonesPercent",
            "highlightsPercent",
            "clippedHighlightsPercent",
            "clippedShadowsPercent",
            "colorTemperature",
            "saturation",
            "centerWeightedLuminance",
            "sceneLightLevel"
        ])
    }
}

@Suite("SceneFeatureExtractor exposure guard")
struct SceneFeatureExtractorGuardTests {
    @Test("rejects frames with unknown exposure instead of fabricating scene light")
    func rejectsNonPositiveExposure() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let extractor = SceneFeatureExtractor()
        #expect(extractor.extract(from: image, frameISO: 0, frameShutterSeconds: 1.0 / 60.0) == nil)
        #expect(extractor.extract(from: image, frameISO: 100, frameShutterSeconds: 0) == nil)
    }
}

@Suite("Center-weighted metering")
struct CenterWeightedMeteringTests {
    /// Build a dark frame with a bright square at its centre.
    /// 4:3 is what the sensor delivers, and it is exactly the shape that used
    /// to fail the square-buffer guard and silently fall back to a plain mean.
    private func centreBrightFrame() -> CIImage {
        let frame = CGRect(x: 0, y: 0, width: 256, height: 192)
        let background = CIImage(color: CIColor.black).cropped(to: frame)
        let centrePatch = CIImage(color: CIColor.white)
            .cropped(to: CGRect(x: 96, y: 64, width: 64, height: 64))
        return centrePatch.composited(over: background)
    }

    @Test("centre weighting runs on non-square frames instead of falling back to the mean")
    func weightsCentreOnNonSquareFrame() throws {
        let features = try #require(
            SceneFeatureExtractor().extract(
                from: centreBrightFrame(), frameISO: 100, frameShutterSeconds: 1.0 / 60.0
            )
        )

        // A bright centre on a dark surround must read brighter under centre
        // weighting than under a flat average. Equality is the exact signature
        // of the old bug: the fallback returned the plain mean.
        #expect(features.centerWeightedLuminance > features.meanLuminance)
    }

    @Test("a uniform frame meters to its own luminance whatever the weighting")
    func uniformFrameMatchesMean() throws {
        // With no spatial variation the weighted mean must equal the plain
        // mean — this pins the weight normalisation (sum of weights) as
        // correct, which a lopsided weight table would break.
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 192))
        let features = try #require(
            SceneFeatureExtractor().extract(
                from: flat, frameISO: 100, frameShutterSeconds: 1.0 / 60.0
            )
        )

        #expect(abs(features.centerWeightedLuminance - features.meanLuminance) < 0.001)
    }
}

@Suite("Sample thumbnails")
struct SampleThumbnailTests {
    /// A deliberately JPEG-hostile frame.
    ///
    /// A smooth gradient is the friendliest input an encoder can get, and it
    /// exercises exactly the averaged features that survive compression anyway.
    /// This adds what actually stresses the remaining columns: pure black and
    /// pure white patches (so the clipping counts have something to count and
    /// the extrema sit at the limits), hard high-contrast edges (ringing, which
    /// is what pushes pixels across the 0.02 / 0.98 thresholds), and saturated
    /// primaries (chroma subsampling, which is what moves colour temperature).
    private func texturedFrame() -> CIImage {
        let frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.color0 = CIColor(red: 0.15, green: 0.2, blue: 0.35)
        gradient.point1 = CGPoint(x: 1024, y: 768)
        gradient.color1 = CIColor(red: 0.85, green: 0.75, blue: 0.5)
        var image = (gradient.outputImage ?? CIImage(color: .gray)).cropped(to: frame)

        // Hard-edged patches, including both clipping extremes.
        let patches: [(CIColor, CGRect)] = [
            (CIColor.black, CGRect(x: 40, y: 40, width: 180, height: 140)),
            (CIColor.white, CGRect(x: 260, y: 40, width: 180, height: 140)),
            (CIColor(red: 0.95, green: 0.1, blue: 0.1), CGRect(x: 480, y: 40, width: 180, height: 140)),
            (CIColor(red: 0.1, green: 0.15, blue: 0.95), CGRect(x: 700, y: 40, width: 180, height: 140)),
            (CIColor(red: 0.05, green: 0.9, blue: 0.2), CGRect(x: 380, y: 420, width: 220, height: 200))
        ]
        for (colour, rect) in patches {
            image = CIImage(color: colour).cropped(to: rect).composited(over: image)
        }

        // Fine alternating bars — high-frequency detail is where JPEG's DCT
        // quantization does the most damage.
        for i in stride(from: 0, to: 24, by: 2) {
            image = CIImage(color: i % 4 == 0 ? .white : .black)
                .cropped(to: CGRect(x: 60 + i * 24, y: 600, width: 12, height: 120))
                .composited(over: image)
        }
        return image
    }

    /// The point of storing thumbnails: a sample recorded today must still be
    /// usable when a feature is added tomorrow. That only holds if features
    /// recomputed from the stored JPEG match those taken from the live frame.
    @Test("features recomputed from a stored thumbnail match the originals")
    func thumbnailRoundTripPreservesFeatures() throws {
        let extractor = SceneFeatureExtractor()
        let frame = texturedFrame()
        let iso: Float = 200
        let shutter = 1.0 / 120.0

        // One call, exactly as the recording path uses it: the features and the
        // stored JPEG come from the same downsampled buffer.
        let captured = try #require(
            extractor.extractWithThumbnail(from: frame, frameISO: iso, frameShutterSeconds: shutter)
        )
        let original = captured.features

        let thumbnail = try #require(captured.thumbnail)
        let decoded = try #require(CIImage(data: thumbnail))
        let restored = try #require(
            extractor.extract(from: decoded, frameISO: iso, frameShutterSeconds: shutter)
        )

        // Only JPEG quantization separates the two: the buffer is encoded at
        // `analysisSize`, so re-extraction finds scale 1.0 and does not
        // downsample a second time.
        #expect(abs(restored.meanLuminance - original.meanLuminance) < 0.02)
        #expect(abs(restored.medianLuminance - original.medianLuminance) < 0.02)
        #expect(abs(restored.centerWeightedLuminance - original.centerWeightedLuminance) < 0.02)
        #expect(abs(restored.stdDevLuminance - original.stdDevLuminance) < 0.02)
        #expect(abs(restored.saturation - original.saturation) < 0.05)
        #expect(abs(restored.sceneLightLevel - original.sceneLightLevel) < 0.1)
    }

    /// The stored JPEG for a frame, as the recording path produces it.
    private func thumbnailData(for image: CIImage) throws -> Data {
        let captured = try #require(
            SceneFeatureExtractor().extractWithThumbnail(
                from: image, frameISO: 200, frameShutterSeconds: 1.0 / 120.0
            )
        )
        return try #require(captured.thumbnail)
    }

    /// Pins the property the round-trip depends on. If the stored image were
    /// larger or smaller than `analysisSize`, re-extraction would downsample
    /// again and the recomputed features would drift from the originals.
    @Test("a thumbnail is stored at exactly the analysis size")
    func thumbnailIsStoredAtAnalysisSize() throws {
        let data = try thumbnailData(for: texturedFrame())
        let decoded = try #require(CIImage(data: data))

        #expect(max(decoded.extent.width, decoded.extent.height) == 256)
        // Aspect ratio preserved: 1024x768 is 4:3, so the short edge is 192.
        #expect(min(decoded.extent.width, decoded.extent.height) == 192)
    }

    /// A thumbnail per sample is only affordable if each stays small — 500 of
    /// these live in the app's Documents directory.
    @Test("a thumbnail is small enough to keep one per sample")
    func thumbnailStaysSmall() throws {
        let data = try thumbnailData(for: texturedFrame())
        #expect(data.count < 32_768)
    }

    /// `includeThumbnail: false` is what `extract` relies on to stay allocation-free
    /// for the inference path, which runs per frame and never stores anything.
    @Test("features can be extracted without paying for a thumbnail")
    func thumbnailIsOptional() throws {
        let captured = try #require(
            SceneFeatureExtractor().extractWithThumbnail(
                from: texturedFrame(), frameISO: 200, frameShutterSeconds: 1.0 / 120.0,
                includeThumbnail: false
            )
        )
        #expect(captured.thumbnail == nil)
    }
}

@Suite("Training dataset eviction")
struct TrainingDatasetEvictionTests {
    private func sample() -> TrainingSample {
        TrainingSample(
            features: SceneFeatures(
                meanLuminance: 0.5, medianLuminance: 0.5, minLuminance: 0, maxLuminance: 1,
                stdDevLuminance: 0.2, shadowsPercent: 0.2, midtonesPercent: 0.6,
                highlightsPercent: 0.2, clippedHighlightsPercent: 0.01,
                clippedShadowsPercent: 0.01, colorTemperature: 5500, saturation: 0.3,
                centerWeightedLuminance: 0.5, sceneLightLevel: 3.3, timestamp: Date()
            ),
            iso: 64,
            shutterSeconds: 1.0 / 256.0
        )
    }

    @Test("adding below the cap evicts nothing")
    func noEvictionBelowCap() {
        var dataset = TrainingDataset()
        for _ in 0..<TrainingDataset.defaultMaxSamples {
            #expect(dataset.addSample(sample()).isEmpty)
        }
        #expect(dataset.samples.count == TrainingDataset.defaultMaxSamples)
    }

    /// The evicted samples are the only signal the manager has for deleting
    /// their thumbnails. If this returned nothing, the thumbnail directory would
    /// grow without bound while the dataset stayed capped.
    @Test("passing the cap returns the dropped sample so its thumbnail can be released")
    func evictionReportsDroppedSample() {
        var dataset = TrainingDataset()
        for _ in 0..<TrainingDataset.defaultMaxSamples { dataset.addSample(sample()) }

        let oldest = dataset.samples[0].id
        let evicted = dataset.addSample(sample())

        #expect(evicted.map(\.id) == [oldest])
        #expect(dataset.samples.count == TrainingDataset.defaultMaxSamples)
        #expect(!dataset.samples.contains { $0.id == oldest })
    }

    /// Lowering "Max training samples" in Settings drops the whole backlog on
    /// the next capture, not one sample. Every dropped sample must come back so
    /// its thumbnail is released — returning only the head would strand the rest
    /// on disk with no sample left to match them to.
    @Test("lowering the cap returns the entire backlog it drops")
    func loweringCapReturnsWholeBacklog() {
        var dataset = TrainingDataset()
        for _ in 0..<20 { dataset.addSample(sample(), maxSamples: 100) }

        let survivors = dataset.samples.suffix(4).map(\.id)
        let evicted = dataset.addSample(sample(), maxSamples: 5)

        // 21 samples against a cap of 5: 16 go, the last 4 plus the new one stay.
        #expect(evicted.count == 16)
        #expect(dataset.samples.count == 5)
        #expect(Set(evicted.map(\.id)).isDisjoint(with: Set(survivors)))
    }

    /// The cap is read per call rather than captured at init, so raising it in
    /// Settings has to take effect without restarting the app.
    @Test("raising the cap stops evicting immediately")
    func raisingCapStopsEviction() {
        var dataset = TrainingDataset()
        for _ in 0..<10 { dataset.addSample(sample(), maxSamples: 10) }

        #expect(dataset.addSample(sample(), maxSamples: 10).count == 1)
        #expect(dataset.addSample(sample(), maxSamples: 50).isEmpty)
        #expect(dataset.samples.count == 11)
    }
}

@Suite("Rec. 709 luminance weighting")
struct LuminanceWeightingTests {
    private func meanLuminance(ofSolid colour: CIColor) throws -> Float {
        let frame = CIImage(color: colour)
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 192))
        let features = try #require(
            SceneFeatureExtractor().extract(
                from: frame, frameISO: 100, frameShutterSeconds: 1.0 / 60.0
            )
        )
        return features.meanLuminance
    }

    /// Pins the Rec. 709 coefficients in `lumaVector`, and that they reach the
    /// output channel the extractor actually reads. Getting either wrong skews
    /// every luminance statistic feeding the ML models, silently.
    ///
    /// No other test can catch it. The rest of the extractor suite meters grey
    /// frames, and grey is invariant to how the R/G/B weights are distributed —
    /// permute the coefficients and a grey frame reports exactly the same
    /// value. Verified: with `lumaVector` deliberately permuted, all 18 other
    /// tests still pass and only this one fails.
    ///
    /// Rec. 709 weights green (0.7152) well above red (0.2126) and red above
    /// blue (0.0722). Comparing the primaries pins that ordering without
    /// depending on the exact values colour management happens to produce.
    @Test("green reads brighter than red, and red brighter than blue")
    func primariesFollowRec709Ordering() throws {
        let red = try meanLuminance(ofSolid: CIColor(red: 1, green: 0, blue: 0))
        let green = try meanLuminance(ofSolid: CIColor(red: 0, green: 1, blue: 0))
        let blue = try meanLuminance(ofSolid: CIColor(red: 0, green: 0, blue: 1))

        #expect(green > red)
        #expect(red > blue)
    }
}
