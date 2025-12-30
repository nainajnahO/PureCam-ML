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

import SwiftUI

struct CaptureButton: View {
    @Binding var cameraService: CameraService
    @Binding var hapticManager: HapticManager
    @Binding var autoExposureManager: AutoExposureManager?
    @Binding var isoRotationAngle: Angle
    @Binding var shutterRotationAngle: Angle
    @Binding var lastDiscreteISO: Float
    @Binding var activeControl: ExposureControl?
    @Binding var lastDragTime: Date
    @Binding var lastDragAngle: Double
    @Binding var isAIAnimating: Bool

    let buttonSize: CGFloat
    let dotSize: CGFloat
    let isoRingRadius: CGFloat
    let shutterRingRadius: CGFloat
    let isoZoneRadius: CGFloat

    var onCapture: () -> Void

    var body: some View {
        ZStack {
            // Outer dot (shutter control) with HDR glow
            Circle()
                .fill(.yellow)
                .frame(width: dotSize, height: dotSize)
                .shadow(color: .yellow.opacity(isAIAnimating ? 0.9 : 0), radius: isAIAnimating ? 15 : 0)
                .shadow(color: .yellow.opacity(isAIAnimating ? 0.7 : 0), radius: isAIAnimating ? 30 : 0)
                .offset(y: -shutterRingRadius)
                .rotationEffect(shutterRotationAngle)
                .opacity(isAIAnimating ? 1.0 : 0.8)
                .brightness(isAIAnimating ? 0.4 : 0)
                .allowsHitTesting(false)

            // Inner dot (ISO control) with HDR glow
            Circle()
                .fill(.white)
                .frame(width: dotSize, height: dotSize)
                .shadow(color: .white.opacity(isAIAnimating ? 0.9 : 0), radius: isAIAnimating ? 15 : 0)
                .shadow(color: .white.opacity(isAIAnimating ? 0.7 : 0), radius: isAIAnimating ? 30 : 0)
                .offset(y: -isoRingRadius)
                .rotationEffect(isoRotationAngle)
                .opacity(isAIAnimating ? 1.0 : 0.8)
                .brightness(isAIAnimating ? 0.4 : 0)
                .allowsHitTesting(false)
        }
        .frame(width: buttonSize, height: buttonSize)
        .contentShape(Circle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onCapture()
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    handleDragChange(value)
                }
                .onEnded { _ in
                    handleDragEnd()
                }
        )
        .accessibilityLabel("Capture Photo - Drag inner dot to adjust ISO, outer dot to adjust shutter speed")
    }

    private func handleDragChange(_ value: DragGesture.Value) {
        // Notify AI manager of manual override (disables AI for session)
        autoExposureManager?.notifyManualOverride()

        let buttonCenter = buttonSize / 2

        // Calculate distance from center
        let center = CGPoint(x: buttonCenter, y: buttonCenter)
        let dx = value.location.x - center.x
        let dy = value.location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)

        // Detect zone
        let control: ExposureControl = distance < isoZoneRadius ? .iso : .shutter

        if activeControl == nil {
            activeControl = control
        }

        // Calculate rotation angle
        let angleRadians = atan2(dy, dx)
        let angleDegrees = angleRadians * 180 / .pi
        let rotationAngle = Angle.degrees(angleDegrees + 90)
        let normalizedAngle = (angleDegrees + 90 + 360).truncatingRemainder(dividingBy: 360)
        let progress = normalizedAngle / 360.0

        switch activeControl {
        case .iso:
            updateISO(rotationAngle: rotationAngle, progress: progress)

        case .shutter:
            updateShutter(rotationAngle: rotationAngle, normalizedAngle: normalizedAngle, progress: progress)

        case .none:
            break
        }
    }

    private func updateISO(rotationAngle: Angle, progress: Double) {
        isoRotationAngle = rotationAngle

        // Map to ISO logarithmically using ExposureCalculator
        let continuousISO = ExposureCalculator.isoFromProgress(
            progress,
            min: cameraService.minISO,
            max: cameraService.maxISO
        )

        // Round to nearest discrete ISO value
        let newISO = CameraService.roundToNearestISO(continuousISO)

        // Trigger haptic when discrete ISO value changes
        if newISO != lastDiscreteISO {
            lastDiscreteISO = newISO
            hapticManager.playISOClick()
        }

        // Apply new ISO (shutter stays fixed)
        cameraService.setCustomExposure(
            iso: newISO,
            shutterSeconds: cameraService.currentShutterSpeed
        )
    }

    private func updateShutter(rotationAngle: Angle, normalizedAngle: Double, progress: Double) {
        shutterRotationAngle = rotationAngle

        // Start rumble on first drag
        if lastDragTime == .distantPast {
            hapticManager.startShutterRumble()
            lastDragTime = Date()
            lastDragAngle = normalizedAngle
        } else {
            // Calculate velocity
            let now = Date()
            let timeDelta = now.timeIntervalSince(lastDragTime)

            // Handle angle wraparound
            var angleDelta = normalizedAngle - lastDragAngle
            if angleDelta > 180 {
                angleDelta -= 360
            } else if angleDelta < -180 {
                angleDelta += 360
            }

            // Calculate velocity and normalize to 0-1 range
            let velocity = timeDelta > 0 ? abs(angleDelta / timeDelta) : 0
            let normalizedVelocity = min(velocity / 500.0, 1.0)

            // Update rumble intensity
            hapticManager.updateShutterRumble(velocity: normalizedVelocity)

            // Update tracking variables
            lastDragTime = now
            lastDragAngle = normalizedAngle
        }

        // Map to shutter speed logarithmically using ExposureCalculator
        let newShutter = ExposureCalculator.shutterFromProgress(
            progress,
            min: cameraService.minShutterSpeed,
            max: cameraService.maxShutterSpeed
        )

        // Apply new shutter (ISO stays fixed)
        cameraService.setCustomExposure(
            iso: cameraService.currentISO,
            shutterSeconds: newShutter
        )
    }

    private func handleDragEnd() {
        // Stop rumble if we were adjusting shutter
        if activeControl == .shutter {
            hapticManager.stopShutterRumble()
            lastDragTime = .distantPast
            lastDragAngle = 0.0
        }

        activeControl = nil
    }
}
