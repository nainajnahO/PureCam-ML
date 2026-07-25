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

        // angleFromISO maps progress 0...1 to 0°...360°.
        let expectedDegrees = originalProgress * 360.0
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

    @Test("angleFromShutter clamps to 0...360 for out-of-range shutter values")
    func angleFromShutterClampsToValidRange() {
        let min = CameraConstants.fastestManualShutter
        let max = CameraConstants.slowestManualShutter

        // Faster than the minimum → clamp to 0°
        let tooFast = ExposureCalculator.angleFromShutter(1.0 / 8000.0, min: min, max: max)
        #expect(tooFast.degrees == 0)

        // Slower than the maximum → clamp to 360°
        let tooSlow = ExposureCalculator.angleFromShutter(2.0, min: min, max: max)
        #expect(tooSlow.degrees == 360)
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
