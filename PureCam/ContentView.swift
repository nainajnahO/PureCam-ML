import SwiftUI

enum ExposureControl {
    case iso      // Inner dot
    case shutter  // Outer dot
}

struct ContentView: View {
    @State private var cameraService = CameraService()
    @Environment(\.scenePhase) var scenePhase

    // Rotation gesture state for dual control
    @State private var isoRotationAngle: Angle = .zero
    @State private var shutterRotationAngle: Angle = .zero
    @State private var isoDetent: Int = 0
    @State private var shutterDetent: Int = 0
    @State private var activeControl: ExposureControl? = nil
    @State private var lastHapticTime: Date = .distantPast

    // RAW preview state
    @State private var showRAWPreview = false
    @State private var rawPreviewImage: UIImage?
    @State private var isCapturingPreview = false

    // Capture flash effect
    @State private var showCaptureFlash = false

    var body: some View {
        ZStack {
            // Camera Feed
            if cameraService.status == .configured {
                GeometryReader { geometry in
                    ZStack {
                        CameraPreview(session: cameraService.session)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .opacity(showRAWPreview ? 0 : 1)

                        if showRAWPreview, let previewImage = rawPreviewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .transition(.opacity)
                        }
                    }
                }
                .ignoresSafeArea()
            } else if cameraService.status == .unauthorized {
                ContentUnavailableView(
                    "Camera Access Denied",
                    systemImage: "video.slash.fill",
                    description: Text("Please enable camera access in Settings.")
                )
            } else if cameraService.status == .failed {
                ContentUnavailableView(
                    "Camera Failed",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text("The camera could not be started.")
                )
            }

            // Button UI Layer
            GeometryReader { geometry in
                // MARK: - Responsive Design Constants
                // All UI dimensions are relative to screen size following Apple's HIG
                // Reference: https://developer.apple.com/design/human-interface-guidelines/layout

                // Global UI scale factor - adjust this single value to resize entire interface
                let globalScale: CGFloat = 1.5  // 1.0 = baseline, >1.0 = larger, <1.0 = smaller

                // Button sizing (uses harmonic mean of width and height)
                let screenDimension = (2 * geometry.size.width * geometry.size.height) / (geometry.size.width + geometry.size.height)
                let captureButtonSize: CGFloat = screenDimension * 0.15 * globalScale
                let captureButtonVisualSize = captureButtonSize * 0.75
                let previewButtonSize: CGFloat = captureButtonSize * 0.2

                // Control dot sizing (relative to button size)
                let dotSize: CGFloat = captureButtonSize * 0.067  // ~8pt on standard iPhone
                let isoRingRadius = captureButtonSize * 0.3       // Inner ring
                let shutterRingRadius = captureButtonSize * 0.433 // Outer ring

                // Button positions
                let captureX = geometry.size.width * 1 / 2
                let buttonSpacing = geometry.size.width * 0.19
                let previewX = captureX + buttonSpacing
                let bottomMargin = geometry.size.height * 0.12
                let buttonY = geometry.size.height - bottomMargin

                // Gesture zones (relative to button size)
                let buttonCenter = captureButtonSize / 2
                let isoZoneRadius = captureButtonSize * 0.35  // Threshold between ISO and shutter zones

                // Visual Layer
                GlassEffectContainer(spacing: 0) {
                    ZStack {
                        // Capture Button - Visual Layer Only
                        Circle()
                            .fill(.clear)
                            .frame(width: captureButtonVisualSize, height: captureButtonVisualSize)
                            .glassEffect(.clear)
                            .frame(width: captureButtonSize, height: captureButtonSize)
                            .position(x: captureX, y: buttonY)

                        // RAW Preview Button
                        Button(action: {
                            guard !isCapturingPreview else { return }

                            isCapturingPreview = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            cameraService.capturePhoto(mode: .preview)
                        }) {
                            Color.clear
                                .frame(width: previewButtonSize, height: previewButtonSize)
                        }
                        .glassEffect(.clear)
                        .disabled(isCapturingPreview || showRAWPreview)
                        .opacity(isCapturingPreview || showRAWPreview ? 0.5 : 1.0)
                        .position(x: previewX, y: buttonY)
                        .accessibilityLabel("Preview RAW Image")
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .overlay(alignment: .center) {
                    // Interaction Layer - Renders ON TOP of glass effect
                    ZStack {
                        // Capture Button - Controls Only
                        ZStack {
                            // Outer dot (shutter control)
                            Circle()
                                .fill(.yellow.opacity(0.8))
                                .frame(width: dotSize, height: dotSize)
                                .offset(y: -shutterRingRadius)
                                .rotationEffect(shutterRotationAngle)
                                .allowsHitTesting(false)

                            // Inner dot (ISO control)
                            Circle()
                                .fill(.white.opacity(0.8))
                                .frame(width: dotSize, height: dotSize)
                                .offset(y: -isoRingRadius)
                                .rotationEffect(isoRotationAngle)
                                .allowsHitTesting(false)
                        }
                        .frame(width: captureButtonSize, height: captureButtonSize)
                        .contentShape(Circle())
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            showCaptureFlash = true
                            withAnimation(.easeOut(duration: 0.15)) {
                                showCaptureFlash = false
                            }
                            cameraService.capturePhoto()
                        }
                        .sensoryFeedback(.selection, trigger: isoDetent) { oldValue, newValue in
                            guard activeControl == .iso else { return false }
                            let now = Date()
                            let timeSinceLastHaptic = now.timeIntervalSince(lastHapticTime)
                            if oldValue != newValue && timeSinceLastHaptic >= 0.15 {
                                lastHapticTime = now
                                return true
                            }
                            return false
                        }
                        .sensoryFeedback(.selection, trigger: shutterDetent) { oldValue, newValue in
                            guard activeControl == .shutter else { return false }
                            let now = Date()
                            let timeSinceLastHaptic = now.timeIntervalSince(lastHapticTime)
                            if oldValue != newValue && timeSinceLastHaptic >= 0.15 {
                                lastHapticTime = now
                                return true
                            }
                            return false
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    // Calculate distance from center (dynamic based on button size)
                                    let center = CGPoint(x: buttonCenter, y: buttonCenter)
                                    let dx = value.location.x - center.x
                                    let dy = value.location.y - center.y
                                    let distance = sqrt(dx * dx + dy * dy)

                                    // Detect zone (threshold relative to button size)
                                    let control: ExposureControl = distance < isoZoneRadius ? .iso : .shutter

                                    if activeControl == nil {
                                        activeControl = control
                                    }

                                    // Calculate rotation angle
                                    let angleRadians = atan2(dy, dx)
                                    let angleDegrees = angleRadians * 180 / .pi
                                    let rotationAngle = Angle.degrees(angleDegrees + 90)
                                    let normalizedAngle = (angleDegrees + 90 + 360)
                                        .truncatingRemainder(dividingBy: 360)
                                    let progress = normalizedAngle / 360.0

                                    switch activeControl {
                                    case .iso:
                                        isoRotationAngle = rotationAngle

                                        // Map to ISO logarithmically
                                        let logMin = log(cameraService.minISO)
                                        let logMax = log(cameraService.maxISO)
                                        let logISO = logMin + Float(progress) * (logMax - logMin)
                                        let newISO = exp(logISO)

                                        // Apply new ISO (shutter stays fixed)
                                        cameraService.setCustomExposure(
                                            iso: newISO,
                                            shutterSeconds: cameraService.currentShutterSpeed
                                        )

                                        // Update detent
                                        let newDetent = Int(normalizedAngle / 15)
                                        if newDetent != isoDetent {
                                            isoDetent = newDetent
                                        }

                                    case .shutter:
                                        shutterRotationAngle = rotationAngle

                                        // Map to shutter speed logarithmically
                                        let minShutter = max(cameraService.minShutterSpeed, 1.0 / 4000.0)
                                        let maxShutter = min(cameraService.maxShutterSpeed, 1.0 / 2.0)
                                        let logMin = log(minShutter)
                                        let logMax = log(maxShutter)
                                        let logShutter = logMin + Double(progress) * (logMax - logMin)
                                        let newShutter = exp(logShutter)

                                        // Apply new shutter (ISO stays fixed)
                                        cameraService.setCustomExposure(
                                            iso: cameraService.currentISO,
                                            shutterSeconds: newShutter
                                        )

                                        // Update detent
                                        let newDetent = Int(normalizedAngle / 15)
                                        if newDetent != shutterDetent {
                                            shutterDetent = newDetent
                                        }

                                    case .none:
                                        break
                                    }
                                }
                                .onEnded { _ in
                                    activeControl = nil
                                }
                        )
                        .accessibilityLabel("Capture Photo - Drag inner dot to adjust ISO, outer dot to adjust shutter speed")
                        .position(x: captureX, y: buttonY)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .overlay {
            // Capture flash effect
            if showCaptureFlash {
                Color.black
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                cameraService.startSession()
            } else if newPhase == .background || newPhase == .inactive {
                cameraService.stopSession()
                showRAWPreview = false
                rawPreviewImage = nil
                isCapturingPreview = false
            }
        }
        .onAppear {
            cameraService.onPreviewCaptured = { image in
                rawPreviewImage = image
                withAnimation(.easeInOut(duration: 0.2)) {
                    showRAWPreview = true
                }

                // Auto-dismiss after 1 second
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showRAWPreview = false
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        rawPreviewImage = nil
                        isCapturingPreview = false
                    }
                }
            }
        }
    }
}
