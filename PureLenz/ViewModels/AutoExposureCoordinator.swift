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
/// Manages auto-exposure manager, training data collection, and AI animation
///
/// Inherits from NSObject so the exposure-ramp display link can target an
/// `@objc` selector (same pattern as CameraService).
@Observable
class AutoExposureCoordinator: NSObject {
    // MARK: - Dependencies

    private let cameraService: CameraService
    private let exposureControlVM: ExposureControlViewModel

    // MARK: - State

    /// Auto-exposure manager for ML inference
    private(set) var autoExposureManager: AutoExposureManager?

    /// Training data manager for ML model training
    private let trainingDataManager: TrainingDataManager

    /// Flag to ensure startup inference runs only once per session
    private var hasTriggeredStartupInference = false

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

    // MARK: - Initialization

    init(cameraService: CameraService, exposureControlVM: ExposureControlViewModel) {
        let dataManager = TrainingDataManager()
        self.cameraService = cameraService
        self.exposureControlVM = exposureControlVM
        self.trainingDataManager = dataManager
        self.autoExposureManager = AutoExposureManager(dataManager: dataManager)
        super.init()

        Logger.ml.debug("AutoExposureCoordinator initialized")
    }

    deinit {
        exposureRampLink?.invalidate()
    }

    // MARK: - Public Methods

    /// Handle scene phase changes (active, background, inactive)
    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase == .active {
            // Trigger inference after short delay for camera warmup
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.triggerStartupInferenceIfReady()
            }
        } else if newPhase == .background || newPhase == .inactive {
            // Reset for next session
            hasTriggeredStartupInference = false
        }
    }

    /// Reset for new camera session
    func resetForNewSession() {
        autoExposureManager?.resetForNewSession()
        hasTriggeredStartupInference = false
    }

    /// Record training sample if needed (called on manual photo capture)
    func recordTrainingSampleIfNeeded() {
        // Record training sample if:
        // 1. No model exists yet (.disabled) - collecting initial training data
        // 2. User manually overrode AI prediction (.manualOverride)
        // 3. Model load failed (.error) - need to retrain
        guard let manager = autoExposureManager else { return }

        // Only record in states where we need training data
        switch manager.state {
        case .disabled, .manualOverride, .error:
            // Continue to record training sample
            break
        default:
            // Skip recording in other states (.ready, .inferring, .applied)
            return
        }

        Task { [weak self] in
            guard let self,
                  let frame = await self.cameraService.captureNextFrame() else { return }
            let extractor = SceneFeatureExtractor()
            if let features = extractor.extract(
                from: frame.image,
                frameISO: frame.iso,
                frameShutterSeconds: frame.shutterSeconds
            ) {
                // Label with the exposure the frame was actually captured at, not
                // the cached currentISO/currentShutterSpeed: in continuous auto-
                // exposure (.disabled/.error before any knob touch) the cache is
                // a stale launch-time snapshot, which would pair a correct
                // sceneLightLevel with a wrong target. The frame's own exposure
                // keeps feature and label consistent by construction — in custom
                // mode it equals the dialed-in settings, and in auto mode it is
                // the AE choice the user accepted by taking the shot.
                manager.recordTrainingSample(
                    features: features,
                    iso: frame.iso,
                    shutterSeconds: frame.shutterSeconds
                )
            }
        }
    }

    /// Manually trigger AI inference (called by long press on preview button)
    /// Can be called multiple times, unlike startup inference
    func triggerManualInference() {
        guard let manager = autoExposureManager else {
            Logger.ml.error("AutoExposureManager not available")
            return
        }

        Logger.ml.debug("Manual inference triggered by user")

        Task { [weak self] in
            guard let self else { return }
            guard let frame = await self.cameraService.captureNextFrame() else {
                Logger.ml.debug("No preview frame available for inference")
                return
            }

            if let prediction = manager.runManualInference(from: frame) {
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

    /// Trigger startup inference if ready
    private func triggerStartupInferenceIfReady() {
        guard let manager = autoExposureManager,
              !hasTriggeredStartupInference,
              cameraService.status == .configured else {
            return
        }

        hasTriggeredStartupInference = true

        Task { [weak self] in
            guard let self else { return }
            guard let frame = await self.cameraService.captureNextFrame() else {
                Logger.ml.debug("No preview frame available - staying in iOS auto mode")
                return
            }
            if let prediction = manager.runStartupInference(from: frame) {
                await MainActor.run {
                    self.applyAIPrediction(iso: prediction.iso, shutter: prediction.shutterSeconds)
                }
            } else {
                await MainActor.run {
                    self.cameraService.resetAutoExposure()
                    Logger.ml.debug("Using iOS auto-exposure (ML not available)")
                }
            }
        }
    }

    /// Apply AI prediction with smooth animation
    private func applyAIPrediction(iso: Float, shutter: Double) {
        let roundedISO = CameraService.roundToNearestISO(iso)

        // 1. Move the knobs to their predicted positions with a spring.
        let isoAngle = AutoExposureManager.rotationAngleForISO(
            roundedISO,
            min: cameraService.minISO,
            max: cameraService.maxISO
        )
        let shutterAngle = AutoExposureManager.rotationAngleForShutter(
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
        link.add(to: .main, forMode: .common)
        exposureRampLink = link
    }

    /// One tick of the exposure ramp, called once per display refresh.
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
            iso: CameraService.roundToNearestISO(interpolatedISO),
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
