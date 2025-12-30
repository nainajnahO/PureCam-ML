import SwiftUI

enum ExposureControl {
    case iso      // Inner dot
    case shutter  // Outer dot
}

struct ContentView: View {
    @State private var cameraService = CameraService()
    @State private var hapticManager = HapticManager()
    @Environment(\.scenePhase) var scenePhase

    // ML Auto-Exposure
    @State private var autoExposureManager: AutoExposureManager? = nil
    @State private var trainingDataManager = TrainingDataManager()
    @State private var hasTriggeredStartupInference = false

    // Rotation gesture state for dual control
    @State private var isoRotationAngle: Angle = .zero
    @State private var shutterRotationAngle: Angle = .zero
    @State private var lastDiscreteISO: Float = 0
    @State private var activeControl: ExposureControl? = nil
    @State private var showExposureOverlay = false
    @State private var overlayFadeTask: Task<Void, Never>?

    // Velocity tracking for shutter rumble intensity
    @State private var lastDragTime: Date = .distantPast
    @State private var lastDragAngle: Double = 0.0

    // Device orientation tracking
    @State private var deviceOrientation: UIDeviceOrientation = .portrait

    // RAW preview state
    @State private var showRAWPreview = false
    @State private var rawPreviewImage: UIImage?
    @State private var isCapturingPreview = false

    // Capture flash effect
    @State private var showCaptureFlash = false

    var body: some View {
        ZStack {
            // Camera Feed
            CameraFeedView(
                cameraService: cameraService,
                showRAWPreview: showRAWPreview,
                rawPreviewImage: rawPreviewImage
            )

            // Button UI Layer
            GeometryReader { geometry in
                let sizes = UIConstants.buttonSizes(for: geometry)
                let positions = UIConstants.buttonPositions(for: geometry)
                let textPos = UIConstants.textPosition(
                    captureX: positions.captureX,
                    buttonY: positions.buttonY,
                    captureButtonSize: sizes.captureButtonSize,
                    deviceOrientation: deviceOrientation
                )

                ButtonUILayer(
                    cameraService: $cameraService,
                    hapticManager: $hapticManager,
                    autoExposureManager: $autoExposureManager,
                    isoRotationAngle: $isoRotationAngle,
                    shutterRotationAngle: $shutterRotationAngle,
                    lastDiscreteISO: $lastDiscreteISO,
                    activeControl: $activeControl,
                    lastDragTime: $lastDragTime,
                    lastDragAngle: $lastDragAngle,
                    isCapturingPreview: $isCapturingPreview,
                    showRAWPreview: $showRAWPreview,
                    showCaptureFlash: $showCaptureFlash,
                    sizes: sizes,
                    positions: positions,
                    textPosition: textPos,
                    deviceOrientation: deviceOrientation,
                    onCaptureWithManualSettings: recordTrainingSampleIfNeeded
                )
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .overlay {
            if showCaptureFlash {
                Color.black
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onAppear {
            setupCamera()
            setupOrientationTracking()
            setupAutoExposure()
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase == .active {
            cameraService.startSession()
            hapticManager.start()
            autoExposureManager?.resetForNewSession()

            // Trigger inference after short delay for camera warmup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                triggerStartupInferenceIfReady()
            }
        } else if newPhase == .background || newPhase == .inactive {
            cameraService.stopSession()
            hapticManager.stop()
            showRAWPreview = false
            rawPreviewImage = nil
            isCapturingPreview = false
            overlayFadeTask?.cancel()
            showExposureOverlay = false
        }
    }

    private func setupCamera() {
        cameraService.onPreviewCaptured = { image in
            rawPreviewImage = image
            withAnimation(.easeInOut(duration: 0.2)) {
                showRAWPreview = true
            }

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

    private func setupOrientationTracking() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            let orientation = UIDevice.current.orientation
            if orientation.isPortrait || orientation.isLandscape {
                deviceOrientation = orientation
            }
        }

        let initialOrientation = UIDevice.current.orientation
        if initialOrientation.isPortrait || initialOrientation.isLandscape {
            deviceOrientation = initialOrientation
        }
    }

    // MARK: - ML Auto-Exposure

    private func setupAutoExposure() {
        autoExposureManager = AutoExposureManager(dataManager: trainingDataManager)
    }

    private func triggerStartupInferenceIfReady() {
        guard let manager = autoExposureManager,
              !hasTriggeredStartupInference,
              cameraService.status == .configured else {
            return
        }

        guard let previewFrame = cameraService.getCurrentPreviewFrame() else {
            print("No preview frame available - staying in iOS auto mode")
            return
        }

        hasTriggeredStartupInference = true

        DispatchQueue.global(qos: .userInitiated).async {
            if let prediction = manager.runStartupInference(from: previewFrame) {
                DispatchQueue.main.async { [self] in
                    self.applyAIPrediction(iso: prediction.iso, shutter: prediction.shutterSeconds)
                }
            } else {
                DispatchQueue.main.async { [self] in
                    self.cameraService.resetAutoExposure()
                    print("Using iOS auto-exposure (ML not available)")
                }
            }
        }
    }

    private func applyAIPrediction(iso: Float, shutter: Double) {
        // 1. Round ISO to discrete value
        let roundedISO = CameraService.roundToNearestISO(iso)

        // 2. Calculate rotation angles (inverse mapping)
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

        // 3. Animate knobs to position
        withAnimation(.spring(duration: 0.8, bounce: 0.2)) {
            isoRotationAngle = isoAngle
            shutterRotationAngle = shutterAngle
        }

        // 4. Apply exposure settings
        cameraService.setCustomExposure(iso: roundedISO, shutterSeconds: shutter)

        print("AI applied: ISO \(roundedISO), Shutter 1/\(Int(1/shutter))")
    }

    private func recordTrainingSampleIfNeeded() {
        // Record training sample if:
        // 1. No model exists yet (.disabled) - collecting initial training data
        // 2. User manually overrode AI prediction (.manualOverride)
        // 3. Model load failed (.error) - need to retrain
        guard let manager = autoExposureManager,
              let previewFrame = cameraService.getCurrentPreviewFrame() else {
            return
        }

        // Only record in states where we need training data
        switch manager.state {
        case .disabled, .manualOverride, .error:
            // Continue to record training sample
            break
        default:
            // Skip recording in other states (.ready, .inferring, .applied)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let extractor = SceneFeatureExtractor()
            if let features = extractor.extract(from: previewFrame) {
                manager.recordTrainingSample(
                    features: features,
                    iso: cameraService.currentISO,
                    shutterSeconds: cameraService.currentShutterSpeed
                )
            }
        }
    }
}