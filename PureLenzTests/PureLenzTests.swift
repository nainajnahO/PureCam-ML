// PureLenz - An iOS camera app with AI-powered exposure control
// Copyright (C) 2025 nainajnahO
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Testing
import SwiftUI
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

    @Test("shutterFromProgress clamps to camera hardware limits")
    func shutterRespectsHardwareLimits() {
        // Caller-supplied range is wider than hardware allows; output must stay within
        // CameraConstants.hardwareMinShutter ... hardwareMaxShutter.
        let aggressiveMin = 1.0 / 10_000.0  // faster than 1/4000
        let aggressiveMax = 1.0              // slower than 1/2

        let fastest = ExposureCalculator.shutterFromProgress(0, min: aggressiveMin, max: aggressiveMax)
        let slowest = ExposureCalculator.shutterFromProgress(1, min: aggressiveMin, max: aggressiveMax)

        #expect(abs(fastest - CameraConstants.hardwareMinShutter) < 1e-6)
        #expect(abs(slowest - CameraConstants.hardwareMaxShutter) < 1e-6)
    }

    @Test("angleFromShutter clamps to 0...360 for out-of-range shutter values")
    func angleFromShutterClampsToValidRange() {
        let min = CameraConstants.hardwareMinShutter
        let max = CameraConstants.hardwareMaxShutter

        // Faster than the minimum → clamp to 0°
        let tooFast = ExposureCalculator.angleFromShutter(1.0 / 8000.0, min: min, max: max)
        #expect(tooFast.degrees == 0)

        // Slower than the maximum → clamp to 360°
        let tooSlow = ExposureCalculator.angleFromShutter(2.0, min: min, max: max)
        #expect(tooSlow.degrees == 360)
    }
}
