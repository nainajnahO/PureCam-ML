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

struct CaptureButton: View {
    // `@Observable` references — read directly, no Bindings required.
    let exposureVM: ExposureControlViewModel
    let autoExposure: AutoExposureCoordinator
    let haptics: HapticManager

    let buttonSize: CGFloat
    let dotSize: CGFloat
    let isoRingRadius: CGFloat
    let shutterRingRadius: CGFloat
    let isoZoneRadius: CGFloat

    var onCapture: () -> Void

    /// Spoken ISO. Plain number rather than the HUD's monospaced readout —
    /// VoiceOver reads it aloud, so formatting for column alignment is noise.
    private var isoValueText: String {
        "\(Int(exposureVM.currentISO))"
    }

    /// Spoken shutter speed, as the fraction photographers actually say.
    private var shutterValueText: String {
        "1 over \(Int((1.0 / exposureVM.currentShutterSeconds).rounded())) second"
    }

    var body: some View {
        let isAIAnimating = autoExposure.isAIAnimating

        // Control dots only. The Liquid Glass surface is a separate layer below
        // (see ButtonUILayer) so these dots render on top of the glass — the
        // orbiting dots sit at a larger radius than the glass disc, so they
        // can't be glass "content" and must be their own overlay layer.
        ZStack {
            // Shutter release, as its own element. VoiceOver exposes one value
            // per element, so the two exposure controls below cannot share an
            // element with each other or with this — hence three, not one.
            Color.clear
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Capture photo")
                .accessibilityAction {
                    haptics.impact(.medium)
                    onCapture()
                }

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
                .accessibilityElement()
                .accessibilityLabel("Shutter speed")
                .accessibilityValue(shutterValueText)
                .accessibilityAdjustableAction { direction in
                    // Slower shutter is the brighter end, and matches the
                    // clockwise direction of the drag, so increment slows.
                    switch direction {
                    case .increment: exposureVM.stepShutter(by: 1)
                    case .decrement: exposureVM.stepShutter(by: -1)
                    @unknown default: break
                    }
                }

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
                .accessibilityElement()
                .accessibilityLabel("ISO")
                .accessibilityValue(isoValueText)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: exposureVM.stepISO(by: 1)
                    case .decrement: exposureVM.stepISO(by: -1)
                    @unknown default: break
                    }
                }
        }
        .frame(width: buttonSize, height: buttonSize)
        .contentShape(Circle())
        .onTapGesture {
            haptics.impact(.medium)
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
        // A container, not an element: the shutter release and the two exposure
        // controls inside each need their own focus and their own value.
        .accessibilityElement(children: .contain)
    }

    private func handleDragChange(_ value: DragGesture.Value) {
        let buttonCenter = buttonSize / 2

        // Calculate distance from center
        let center = CGPoint(x: buttonCenter, y: buttonCenter)
        let dx = value.location.x - center.x
        let dy = value.location.y - center.y
        let distance = hypot(dx, dy)

        // Detect zone
        let control: ExposureControl = distance < isoZoneRadius ? .iso : .shutter

        // Thumb bearing: 0° = 12 o'clock, increasing clockwise. Only its change
        // between frames matters now — the knob turns by how far the thumb
        // travels, so where it first landed carries no meaning.
        let angleDegrees = atan2(dy, dx) * 180 / .pi
        let bearing = (angleDegrees + 90 + 360).truncatingRemainder(dividingBy: 360)

        guard exposureVM.activeControl != nil else {
            // First frame: latch the ring under the thumb and take a reference
            // bearing, without moving anything.
            exposureVM.beginDrag(control: control, bearing: bearing)
            return
        }

        switch exposureVM.activeControl {
        case .iso:
            exposureVM.updateISO(bearing: bearing)

        case .shutter:
            exposureVM.updateShutter(bearing: bearing)

        case .none:
            break
        }
    }

    private func handleDragEnd() {
        // Delegate to ViewModel
        exposureVM.resetActiveControl()
    }
}
