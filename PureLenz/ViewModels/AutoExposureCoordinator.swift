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

import SwiftUI
import Observation
import QuartzCore
import OSLog

/// Coordinator responsible for ML inference orchestration and AI prediction application
/// Owns the ML session lifecycle (per-session reset + one-shot startup inference)
/// and the AI animation.
///
/// Inherits from NSObject so the exposure-ramp display link can target an
/// `@objc` selector (same pattern as CameraService).
@Observable
class AutoExposureCoordinator: NSObject {
    // MARK: - Dependencies

    private let cameraService: CameraService
    private let exposureControlVM: ExposureControlViewModel

    /// Auto-exposure manager for ML inference (owned by CameraScene).
    private let autoExposureManager: AutoExposureManager

    // MARK: - State

    /// AI animation state (HDR glow effect)
    private(set) var isAIAnimating = false

    // MARK: - Exposure Ramp Animation State

    /// Single display-link that smoothly ramps the camera exposure to the
    /// AI-predicted values (replaces dozens of dispatched timer closures).
    private var exposureRampLink: CADisplayLink?
    private var rampStartTime: CFTimeInterval = 0
    private let rampDuration: CFTimeInterval = 1.0
    private var rampStartISO: Float = 0
    private var rampTargetISO: Float = 0
    private var rampStartShutter: Double = 0
    private var rampTargetShutter: Double = 0

    /// The pending camera-warmup delay before startup inference; stored so a
    /// second `.active` (a Control Center swipe, a notification banner) cancels
    /// the previous one instead of queueing a redundant frame capture.
    private var startupInferenceTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        cameraService: CameraService,
        exposureControlVM: ExposureControlViewModel,
        autoExposureManager: AutoExposureManager
    ) {
        self.cameraService = cameraService
        self.exposureControlVM = exposureControlVM
        self.autoExposureManager = autoExposureManager
        super.init()
    }

    deinit {
        exposureRampLink?.invalidate()
        startupInferenceTask?.cancel()
    }

    // MARK: - Public Methods

    /// Handle scene phase changes. The ML session lifecycle is owned here:
    /// becoming active resets the per-session inference state and schedules the
    /// one-shot startup inference after a short camera warmup.
    ///
    /// Inference runs at most once per active session: this type is main-actor
    /// isolated (the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor`), so `runStartupInference`'s check of `hasRunStartupInference`
    /// and its later set of it cannot interleave with another call. Cancelling
    /// the pending delay below is therefore about not doing redundant work —
    /// each stale task would still wake up and capture a frame before
    /// discovering it had nothing to do.
    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        startupInferenceTask?.cancel()
        guard newPhase == .active else { return }
        autoExposureManager.resetForNewSession()

        startupInferenceTask = Task { [weak self] in
            // Short delay for camera warmup before the startup inference.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.triggerStartupInferenceIfReady()
        }
    }

    /// Record a training sample from the next camera frame if the ML layer
    /// wants one (called on manual photo capture). The recording policy and
    /// the feature extraction both live in `AutoExposureManager`; this method
    /// only supplies the frame.
    func recordTrainingSampleIfNeeded() {
        // Respect the user's "Contribute to on-device AI training" setting (Settings app).
        guard UserDefaults.standard.bool(forKey: "contributeTrainingData") else { return }

        guard autoExposureManager.wantsTrainingSample else { return }

        Task { [weak self] in
            guard let self,
                  let frame = await self.cameraService.captureNextFrame() else { return }
            self.autoExposureManager.recordTrainingSampleIfNeeded(from: frame)
        }
    }

    /// Manually trigger AI inference (called by long press on preview button)
    /// Can be called multiple times, unlike startup inference
    func triggerManualInference() {
        Logger.ml.debug("Manual inference triggered by user")

        Task { [weak self] in
            guard let self else { return }
            guard let frame = await self.cameraService.captureNextFrame() else {
                Logger.ml.debug("No preview frame available for inference")
                return
            }

            if let prediction = self.autoExposureManager.runManualInference(from: frame) {
                await MainActor.run {
                    // Reuse existing animation logic
                    self.applyAIPrediction(iso: prediction.iso, shutter: prediction.shutterSeconds)
                }
            } else {
                Logger.ml.debug("Manual inference failed - models not ready")
            }
        }
    }

    // MARK: - Private Methods

    /// Trigger startup inference if ready.
    ///
    /// Every path out of this method leaves the camera holding an exposure the
    /// app set — from the model when there is one, from the scene reading iOS
    /// metered during the warmup delay above when there is not. The app never
    /// rests in `continuousAutoExposure`, so `CameraService.currentISO` /
    /// `currentShutterSpeed` always describe the exposure actually in force.
    private func triggerStartupInferenceIfReady() {
        guard cameraService.status == .configured else { return }

        // Respect the user's "Auto-adjust exposure on launch" setting (Settings app).
        // When off, the app skips inference but still takes over the metered
        // exposure; manual long-press inference (triggerManualInference) is unaffected.
        guard UserDefaults.standard.bool(forKey: "autoExposureOnLaunch") else {
            holdMeteredExposure()
            Logger.ml.info("Startup inference disabled - holding the metered exposure")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            guard let frame = await self.cameraService.captureNextFrame() else {
                await MainActor.run {
                    self.holdMeteredExposure()
                    Logger.ml.info("No preview frame available - holding the metered exposure")
                }
                return
            }
            if let prediction = self.autoExposureManager.runStartupInference(from: frame) {
                await MainActor.run {
                    self.applyAIPrediction(iso: prediction.iso, shutter: prediction.shutterSeconds)
                }
            } else {
                await MainActor.run {
                    self.holdMeteredExposure()
                    Logger.ml.info("No trained model yet - holding the metered exposure")
                }
            }
        }
    }

    /// Seed the starting exposure and move the rings to match it.
    ///
    /// The rings do not track the camera on their own — `applyAIPrediction` is
    /// the only other thing that positions them. Without this the camera would
    /// hold the metered exposure while the rings sat at their default, and the
    /// first nudge would snap the exposure down to that default.
    ///
    /// Deliberately unlike `applyAIPrediction`: no exposure ramp, because the
    /// value is already applied, and no `isAIAnimating` glow, because a metered
    /// starting exposure is not a prediction and should not claim to be one.
    private func holdMeteredExposure() {
        cameraService.holdCurrentExposure { [weak self] iso, shutter in
            guard let self else { return }
            let isoAngle = ExposureCalculator.angleFromISO(
                iso,
                min: self.cameraService.minISO,
                max: self.cameraService.maxISO
            )
            let shutterAngle = ExposureCalculator.angleFromShutter(
                shutter,
                min: self.cameraService.minShutterSpeed,
                max: self.cameraService.maxShutterSpeed
            )
            withAnimation(.spring(duration: 0.4)) {
                self.exposureControlVM.updateRotationAngle(control: .iso, angle: isoAngle)
                self.exposureControlVM.updateRotationAngle(control: .shutter, angle: shutterAngle)
            }
        }
    }

    /// Apply AI prediction with smooth animation
    private func applyAIPrediction(iso: Float, shutter: Double) {
        let roundedISO = cameraService.roundToNearestISO(iso)

        // 1. Move the knobs to their predicted positions with a spring.
        let isoAngle = ExposureCalculator.angleFromISO(
            roundedISO,
            min: cameraService.minISO,
            max: cameraService.maxISO
        )
        let shutterAngle = ExposureCalculator.angleFromShutter(
            shutter,
            min: cameraService.minShutterSpeed,
            max: cameraService.maxShutterSpeed
        )

        // 2. Enable the HDR glow instantly.
        isAIAnimating = true

        // 3. Animate the knobs to position.
        withAnimation(.spring(duration: 1.0, bounce: 0.3)) {
            exposureControlVM.updateRotationAngle(control: .iso, angle: isoAngle)
            exposureControlVM.updateRotationAngle(control: .shutter, angle: shutterAngle)
        }

        // 4. Ramp the actual camera exposure to the predicted values, driven by
        //    a single CADisplayLink (see stepExposureRamp).
        rampStartISO = cameraService.currentISO
        rampTargetISO = roundedISO
        rampStartShutter = cameraService.currentShutterSpeed
        rampTargetShutter = shutter
        startExposureRamp()

        Logger.ml.debug("AI applied: ISO \(Int(roundedISO)), Shutter 1/\(Int(1 / shutter))")
    }

    /// Begin (or restart) the display-link-driven exposure ramp.
    private func startExposureRamp() {
        exposureRampLink?.invalidate()
        rampStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepExposureRamp(_:)))
        // The sensor can't settle exposure at display rate, and every tick costs
        // a lockForConfiguration round-trip on the session queue — ~15Hz is
        // plenty for a smooth 1-second ramp.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
        link.add(to: .main, forMode: .common)
        exposureRampLink = link
    }

    /// One tick of the exposure ramp, called once per display-link fire.
    ///
    /// AVFoundation has no native ramp for custom ISO/shutter (unlike video
    /// zoom), so we interpolate ourselves — but with one display-synced timer
    /// instead of flooding the main queue with dozens of dispatched closures.
    @objc private func stepExposureRamp(_ link: CADisplayLink) {
        let progress = min((link.timestamp - rampStartTime) / rampDuration, 1.0)
        let eased = 1 - pow(1 - progress, 3) // ease-out cubic

        let interpolatedISO = rampStartISO + Float(eased) * (rampTargetISO - rampStartISO)
        let interpolatedShutter = rampStartShutter + eased * (rampTargetShutter - rampStartShutter)
        cameraService.setCustomExposure(
            iso: cameraService.roundToNearestISO(interpolatedISO),
            shutterSeconds: interpolatedShutter
        )

        if progress >= 1.0 {
            link.invalidate()
            exposureRampLink = nil

            // Fade out the HDR glow once the ramp completes.
            withAnimation(.easeOut(duration: 0.5)) {
                isAIAnimating = false
            }
        }
    }
}
