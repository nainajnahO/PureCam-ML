import CoreHaptics
import Foundation

/// Manages advanced haptic feedback using Core Haptics framework
/// Provides discrete clicks for ISO and velocity-based rumble for shutter speed
@Observable
class HapticManager {
    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var isRumbling = false

    init() {
        prepareHaptics()
    }

    // MARK: - Setup

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            print("⚠️ Device doesn't support haptics")
            return
        }

        do {
            engine = try CHHapticEngine()
            try engine?.start()

            // Handle engine stopped
            engine?.stoppedHandler = { [weak self] reason in
                print("⚠️ Haptic engine stopped: \(reason.rawValue)")
                self?.isRumbling = false
            }

            // Handle engine reset
            engine?.resetHandler = { [weak self] in
                print("🔄 Haptic engine reset")
                do {
                    try self?.engine?.start()
                } catch {
                    print("❌ Failed to restart haptic engine: \(error)")
                }
            }

        } catch {
            print("❌ Failed to create haptic engine: \(error)")
        }
    }

    // MARK: - ISO Haptics (Discrete Clicks)

    /// Play a discrete click haptic for ISO value changes
    /// Sharp, brief feedback that feels like a mechanical detent
    func playISOClick() {
        guard let engine = engine else { return }

        // Create a sharp, brief click
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)

        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [intensity, sharpness],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("❌ Failed to play ISO click: \(error)")
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
            print("❌ Failed to start shutter rumble: \(error)")
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
            print("Failed to update rumble intensity: \(error)")
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
            print("Failed to stop shutter rumble: \(error)")
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
            print("Failed to start haptic engine: \(error)")
        }
    }
}
