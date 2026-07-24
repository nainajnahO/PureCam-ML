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

import CoreHaptics
import UIKit
import OSLog

/// Single home for haptic feedback: prepared UIKit impact generators for
/// one-shot taps, plus Core Haptics for the exposure controls — discrete ISO
/// clicks and velocity-modulated shutter rumble, which are beyond what
/// UIFeedbackGenerator offers.
final class HapticManager {
    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?

    /// Cached player for the ISO detent click. The pattern never changes and
    /// clicks can fire ~10-20×/s during a fast drag, so it is built once (and
    /// rebuilt on engine reset) instead of per click.
    private var isoClickPlayer: CHHapticPatternPlayer?

    private var isRumbling = false

    /// Prepared one-shot impact generators shared by every view. A generator
    /// created fresh at tap time has documented first-fire latency; these stay
    /// alive and ready.
    private let impactGenerators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [
        .light: UIImpactFeedbackGenerator(style: .light),
        .medium: UIImpactFeedbackGenerator(style: .medium),
        .heavy: UIImpactFeedbackGenerator(style: .heavy)
    ]

    init() {
        prepareHaptics()
    }

    // MARK: - One-Shot Impacts

    /// Play a one-shot impact (button taps, gesture feedback).
    /// Supported styles: `.light`, `.medium`, `.heavy`.
    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        impactGenerators[style]?.impactOccurred()
    }

    // MARK: - Setup

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            Logger.haptics.info("Device doesn't support haptics")
            return
        }

        do {
            engine = try CHHapticEngine()
            try engine?.start()

            // Handle engine stopped
            engine?.stoppedHandler = { [weak self] reason in
                Logger.haptics.debug("Haptic engine stopped: \(reason.rawValue)")
                self?.isRumbling = false
            }

            // Handle engine reset — a reset invalidates existing players, so
            // the cached click player is rebuilt along with the restart.
            engine?.resetHandler = { [weak self] in
                Logger.haptics.debug("Haptic engine reset")
                do {
                    try self?.engine?.start()
                    self?.makeISOClickPlayer()
                } catch {
                    Logger.haptics.error("Failed to restart haptic engine: \(error.localizedDescription)")
                }
            }

            makeISOClickPlayer()
        } catch {
            Logger.haptics.error("Failed to create haptic engine: \(error.localizedDescription)")
        }
    }

    /// Build the cached ISO click player: a sharp, brief transient that feels
    /// like a mechanical detent.
    private func makeISOClickPlayer() {
        guard let engine else { return }

        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [intensity, sharpness],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            isoClickPlayer = try engine.makePlayer(with: pattern)
        } catch {
            Logger.haptics.error("Failed to create ISO click player: \(error.localizedDescription)")
        }
    }

    // MARK: - ISO Haptics (Discrete Clicks)

    /// Play a discrete click haptic for ISO value changes
    func playISOClick() {
        do {
            try isoClickPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            Logger.haptics.error("Failed to play ISO click: \(error.localizedDescription)")
        }
    }

    // MARK: - Shutter Haptics (Velocity-Based Rumble)

    /// Start continuous rumble for shutter speed adjustment
    /// Intensity increases with drag velocity
    func startShutterRumble() {
        guard let engine = engine else { return }
        guard !isRumbling else { return }

        do {
            // Create a continuous haptic event (sustained rumble)
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)

            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [intensity, sharpness],
                relativeTime: 0,
                duration: 30.0 // Long duration, we'll stop it manually
            )

            let pattern = try CHHapticPattern(events: [event], parameters: [])
            continuousPlayer = try engine.makeAdvancedPlayer(with: pattern)

            try continuousPlayer?.start(atTime: CHHapticTimeImmediate)
            isRumbling = true

        } catch {
            Logger.haptics.error("Failed to start shutter rumble: \(error.localizedDescription)")
        }
    }

    /// Update rumble intensity based on drag velocity
    /// - Parameter velocity: Normalized velocity (0.0 - 1.0)
    func updateShutterRumble(velocity: Double) {
        guard isRumbling, let player = continuousPlayer else { return }

        // Map velocity to intensity (0.2 - 1.0 range for noticeable effect)
        let intensity = Float(0.2 + velocity * 0.8)

        // Map velocity to sharpness (0.2 - 0.8 for smooth to crisp feel)
        let sharpness = Float(0.2 + velocity * 0.6)

        let intensityParam = CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl,
            value: intensity,
            relativeTime: 0
        )

        let sharpnessParam = CHHapticDynamicParameter(
            parameterID: .hapticSharpnessControl,
            value: sharpness,
            relativeTime: 0
        )

        do {
            try player.sendParameters([intensityParam, sharpnessParam], atTime: CHHapticTimeImmediate)
        } catch {
            Logger.haptics.error("Failed to update rumble intensity: \(error.localizedDescription)")
        }
    }

    /// Stop continuous rumble for shutter speed
    func stopShutterRumble() {
        guard isRumbling else { return }

        do {
            try continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
            isRumbling = false
            continuousPlayer = nil
        } catch {
            Logger.haptics.error("Failed to stop shutter rumble: \(error.localizedDescription)")
        }
    }

    // MARK: - Lifecycle

    /// Stop engine when app backgrounds
    func stop() {
        stopShutterRumble()
        engine?.stop()
    }

    /// Restart engine when app becomes active
    func start() {
        guard let engine = engine else {
            prepareHaptics()
            return
        }

        do {
            try engine.start()
        } catch {
            Logger.haptics.error("Failed to start haptic engine: \(error.localizedDescription)")
        }
    }
}
