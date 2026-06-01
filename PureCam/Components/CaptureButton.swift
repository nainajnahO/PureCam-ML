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
    // `@Observable` references — read directly, no Bindings required.
    let exposureVM: ExposureControlViewModel
    let cameraService: CameraService
    let autoExposure: AutoExposureCoordinator

    let buttonSize: CGFloat
    let dotSize: CGFloat
    let isoRingRadius: CGFloat
    let shutterRingRadius: CGFloat
    let isoZoneRadius: CGFloat

    var onCapture: () -> Void

    var body: some View {
        let isAIAnimating = autoExposure.isAIAnimating

        // Control dots only. The Liquid Glass surface is a separate layer below
        // (see ButtonUILayer) so these dots render on top of the glass — the
        // orbiting dots sit at a larger radius than the glass disc, so they
        // can't be glass "content" and must be their own overlay layer.
        ZStack {
            // Outer dot (shutter control) with HDR glow
            Circle()
                .fill(.yellow)
                .frame(width: dotSize, height: dotSize)
                .shadow(color: .yellow.opacity(isAIAnimating ? 0.9 : 0), radius: isAIAnimating ? 15 : 0)
                .shadow(color: .yellow.opacity(isAIAnimating ? 0.7 : 0), radius: isAIAnimating ? 30 : 0)
                .offset(y: -shutterRingRadius)
                .rotationEffect(exposureVM.shutterRotationAngle)
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
                .rotationEffect(exposureVM.isoRotationAngle)
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
        exposureVM.notifyAutoExposureManager(autoExposure.autoExposureManager)

        let buttonCenter = buttonSize / 2

        // Calculate distance from center
        let center = CGPoint(x: buttonCenter, y: buttonCenter)
        let dx = value.location.x - center.x
        let dy = value.location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)

        // Detect zone
        let control: ExposureControl = distance < isoZoneRadius ? .iso : .shutter

        if exposureVM.activeControl == nil {
            exposureVM.setActiveControl(control)
        }

        // Calculate rotation angle
        let angleRadians = atan2(dy, dx)
        let angleDegrees = angleRadians * 180 / .pi
        let rotationAngle = Angle.degrees(angleDegrees + 90)
        let normalizedAngle = (angleDegrees + 90 + 360).truncatingRemainder(dividingBy: 360)
        let progress = normalizedAngle / 360.0

        // Update rotation angle in ViewModel
        if let activeControl = exposureVM.activeControl {
            exposureVM.updateRotationAngle(control: activeControl, angle: rotationAngle)
        }

        switch exposureVM.activeControl {
        case .iso:
            exposureVM.updateISO(progress: progress)

        case .shutter:
            exposureVM.updateShutter(progress: progress, normalizedAngle: normalizedAngle)

        case .none:
            break
        }
    }

    private func handleDragEnd() {
        // Delegate to ViewModel
        exposureVM.resetActiveControl()
    }
}
