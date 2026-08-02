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

    /// Cached player for the shutter rumble. Cached for the same reason as the
    /// click below, but the trigger is different: pinning the knob against an
    /// end stops the rumble and easing off restarts it, so a thumb held at the
    /// wall crosses that boundary repeatedly. Building the pattern and player
    /// per start meant one allocation per crossing.
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?

    /// Cached player for the detent click. The pattern never changes and
    /// clicks can fire ~10-20×/s during a fast drag, so it is built once (and
    /// rebuilt on engine reset) instead of per click.
    private var detentClickPlayer: CHHapticPatternPlayer?

    private var isRumbling = false

    /// The one-shot impact strengths this app uses. A dedicated enum rather
    /// than `UIImpactFeedbackGenerator.FeedbackStyle`, so a call site can only
    /// name a strength that is actually wired up — the wider UIKit type has
    /// styles (`.soft`, `.rigid`) that would otherwise be accepted and then
    /// silently do nothing.
    enum Impact {
        case light, medium, heavy
    }

    // Long-lived generators, shared by every view: creating one at tap time
    // both allocates and starts cold. Keeping them alive covers the allocation;
    // `prepare()` (see `prepare(_:)` and `impact(_:)`) covers the cold start.
    private let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)

    private func generator(for impact: Impact) -> UIImpactFeedbackGenerator {
        switch impact {
        case .light: lightGenerator
        case .medium: mediumGenerator
        case .heavy: heavyGenerator
        }
    }

    init() {
        prepareHaptics()
    }

    // MARK: - One-Shot Impacts

    /// Warm the Taptic Engine for an impact that is about to happen.
    ///
    /// Worth calling when a gesture *begins* and the feedback comes later — a
    /// long press, say, whose `.heavy` fires half a second after touch-down.
    /// The readiness this buys expires after a short idle, which is why it is
    /// renewed per gesture rather than once at init.
    func prepare(_ impact: Impact) {
        generator(for: impact).prepare()
    }

    /// Play a one-shot impact (button taps, gesture feedback).
    func impact(_ impact: Impact) {
        let generator = generator(for: impact)
        generator.impactOccurred()
        // Leave the engine warm: these fire in sequences (tap, then another
        // tap; press, then release), and re-preparing here keeps the follow-up
        // from paying the cold-start latency again.
        generator.prepare()
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
            // both cached players are rebuilt along with the restart. A reset
            // also leaves nothing playing, so the rumble flag has to drop or
            // `startShutterRumble` would refuse to start the rebuilt player.
            engine?.resetHandler = { [weak self] in
                Logger.haptics.debug("Haptic engine reset")
                do {
                    try self?.engine?.start()
                    self?.isRumbling = false
                    self?.makeDetentClickPlayer()
                    self?.makeShutterRumblePlayer()
                } catch {
                    Logger.haptics.error("Failed to restart haptic engine: \(error.localizedDescription)")
                }
            }

            makeDetentClickPlayer()
            makeShutterRumblePlayer()
        } catch {
            Logger.haptics.error("Failed to create haptic engine: \(error.localizedDescription)")
        }
    }

    /// Build the cached detent click player: a sharp, brief transient that feels
    /// like a mechanical detent.
    private func makeDetentClickPlayer() {
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
            detentClickPlayer = try engine.makePlayer(with: pattern)
        } catch {
            Logger.haptics.error("Failed to create detent click player: \(error.localizedDescription)")
        }
    }

    /// Build the cached shutter rumble player: one sustained event whose
    /// intensity and sharpness are driven live by `updateShutterRumble`.
    private func makeShutterRumblePlayer() {
        guard let engine else { return }

        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)

        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [intensity, sharpness],
            relativeTime: 0,
            duration: 30.0 // Long duration, we'll stop it manually
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            continuousPlayer = try engine.makeAdvancedPlayer(with: pattern)
        } catch {
            Logger.haptics.error("Failed to create shutter rumble player: \(error.localizedDescription)")
        }
    }

    // MARK: - Detent Haptics (Discrete Clicks)

    /// Play a discrete click haptic for a detent change — ISO on the drag path,
    /// and either control when VoiceOver steps it.
    func playDetentClick() {
        do {
            try detentClickPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            Logger.haptics.error("Failed to play detent click: \(error.localizedDescription)")
        }
    }

    // MARK: - Shutter Haptics (Velocity-Based Rumble)

    /// Start continuous rumble for shutter speed adjustment
    /// Intensity increases with drag velocity
    func startShutterRumble() {
        guard !isRumbling, let continuousPlayer else { return }

        do {
            try continuousPlayer.start(atTime: CHHapticTimeImmediate)
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
    /// The player is kept, not discarded: it is restarted every time the knob
    /// eases off an end, and rebuilding it there was the churn this avoids.
    func stopShutterRumble() {
        guard isRumbling, let continuousPlayer else { return }

        do {
            try continuousPlayer.stop(atTime: CHHapticTimeImmediate)
            isRumbling = false
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
