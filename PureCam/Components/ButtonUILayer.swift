import SwiftUI

struct ButtonUILayer: View {
    @Binding var cameraService: CameraService
    @Binding var hapticManager: HapticManager
    @Binding var autoExposureManager: AutoExposureManager?
    @Binding var isoRotationAngle: Angle
    @Binding var shutterRotationAngle: Angle
    @Binding var lastDiscreteISO: Float
    @Binding var activeControl: ExposureControl?
    @Binding var lastDragTime: Date
    @Binding var lastDragAngle: Double
    @Binding var isCapturingPreview: Bool
    @Binding var showRAWPreview: Bool
    @Binding var showCaptureFlash: Bool

    let sizes: ButtonSizes
    let positions: ButtonPositions
    let textPosition: CGPoint
    let deviceOrientation: UIDeviceOrientation
    let onCaptureWithManualSettings: () -> Void

    var body: some View {
        // Visual Layer
        GlassEffectContainer(spacing: 0) {
            ZStack {
                // Capture Button - Visual Layer Only
                Circle()
                    .fill(.clear)
                    .frame(width: sizes.captureButtonVisualSize, height: sizes.captureButtonVisualSize)
                    .glassEffect(.clear)
                    .frame(width: sizes.captureButtonSize, height: sizes.captureButtonSize)
                    .position(x: positions.captureX, y: positions.buttonY)

                // RAW Preview Button
                Button(action: {
                    guard !isCapturingPreview else { return }
                    isCapturingPreview = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    cameraService.capturePhoto(mode: .preview)
                }) {
                    Color.clear
                        .frame(width: sizes.previewButtonSize, height: sizes.previewButtonSize)
                }
                .glassEffect(.clear)
                .disabled(isCapturingPreview || showRAWPreview)
                .opacity(isCapturingPreview || showRAWPreview ? 0.5 : 1.0)
                .position(x: positions.previewX, y: positions.buttonY)
                .accessibilityLabel("Preview RAW Image")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .center) {
            // Interaction Layer - Renders ON TOP of glass effect
            ZStack {
                // Capture Button - Controls Only
                CaptureButton(
                    cameraService: $cameraService,
                    hapticManager: $hapticManager,
                    autoExposureManager: $autoExposureManager,
                    isoRotationAngle: $isoRotationAngle,
                    shutterRotationAngle: $shutterRotationAngle,
                    lastDiscreteISO: $lastDiscreteISO,
                    activeControl: $activeControl,
                    lastDragTime: $lastDragTime,
                    lastDragAngle: $lastDragAngle,
                    buttonSize: sizes.captureButtonSize,
                    dotSize: sizes.dotSize,
                    isoRingRadius: sizes.isoRingRadius,
                    shutterRingRadius: sizes.shutterRingRadius,
                    isoZoneRadius: sizes.isoZoneRadius,
                    onCapture: {
                        showCaptureFlash = true
                        withAnimation(.easeOut(duration: 0.15)) {
                            showCaptureFlash = false
                        }

                        // Record training sample if in manual override mode
                        onCaptureWithManualSettings()

                        cameraService.capturePhoto()
                    }
                )
                .position(x: positions.captureX, y: positions.buttonY)

                // Exposure value overlay
                ExposureOverlay(
                    activeControl: activeControl,
                    currentISO: cameraService.currentISO,
                    currentShutterSpeed: cameraService.currentShutterSpeed,
                    deviceOrientation: deviceOrientation
                )
                .position(x: textPosition.x, y: textPosition.y)
            }
        }
    }
}