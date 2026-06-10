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

struct ButtonUILayer: View {
    // `@Observable` references — SwiftUI tracks the properties we read, so no
    // manual Bindings are needed. We only call methods and read state here.
    let cameraService: CameraService
    let cameraVM: CameraViewModel
    let exposureVM: ExposureControlViewModel
    let autoExposure: AutoExposureCoordinator

    let sizes: ButtonSizes
    let positions: ButtonPositions
    let textPosition: CGPoint
    let deviceOrientation: UIDeviceOrientation

    var body: some View {
        // Liquid Glass surfaces live in their own container (so they share a
        // single backdrop sample), with the interactive controls layered on top
        // via `.overlay`. The glass is `.interactive()` so the material reacts
        // to touch, and shaped as a circle to match the round controls.
        GlassEffectContainer(spacing: 0) {
            ZStack {
                // Capture button glass surface.
                Circle()
                    .fill(.clear)
                    .frame(width: sizes.captureButtonVisualSize, height: sizes.captureButtonVisualSize)
                    .glassEffect(.clear.interactive(), in: .circle)
                    .position(x: positions.captureX, y: positions.buttonY)

                // Preview / AI button (its glass and gesture are the same view).
                previewButton
                    .position(x: positions.previewX, y: positions.buttonY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            // Interactive controls render ON TOP of the glass.
            ZStack {
                CaptureButton(
                    exposureVM: exposureVM,
                    cameraService: cameraService,
                    autoExposure: autoExposure,
                    buttonSize: sizes.captureButtonSize,
                    dotSize: sizes.dotSize,
                    isoRingRadius: sizes.isoRingRadius,
                    shutterRingRadius: sizes.shutterRingRadius,
                    isoZoneRadius: sizes.isoZoneRadius,
                    onCapture: {
                        cameraVM.triggerCaptureFlash()
                        autoExposure.recordTrainingSampleIfNeeded()
                        cameraService.capturePhoto()
                    }
                )
                .position(x: positions.captureX, y: positions.buttonY)

                ExposureOverlay(
                    activeControl: exposureVM.activeControl,
                    currentISO: cameraService.currentISO,
                    currentShutterSpeed: cameraService.currentShutterSpeed,
                    deviceOrientation: deviceOrientation
                )
                .position(x: textPosition.x, y: textPosition.y)
            }
        }
    }

    /// RAW preview button: tap captures a one-shot preview, long press triggers
    /// a manual AI inference. Disabled while a preview is in flight.
    private var previewButton: some View {
        let isBusy = cameraVM.isCapturingPreview || cameraVM.showRAWPreview

        return Color.clear
            .frame(width: sizes.previewButtonSize, height: sizes.previewButtonSize)
            .glassEffect(.clear.interactive(), in: .circle)
            .contentShape(Circle())
            .disabled(isBusy)
            .opacity(isBusy ? 0.5 : 1.0)
            .onLongPressGesture(minimumDuration: 0.5, pressing: { isPressing in
                if isPressing {
                    // Press started — immediate feedback.
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else {
                    // Released before the long-press threshold — treat as a tap.
                    guard !isBusy else { return }
                    if cameraVM.startPreviewCapture() {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        cameraService.capturePhoto(mode: .preview)
                    }
                }
            }) {
                // Long-press threshold reached — run manual AI inference.
                guard !isBusy else { return }
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                autoExposure.triggerManualInference()
            }
            .accessibilityLabel("Preview RAW Image - Long press to trigger AI exposure")
    }
}
