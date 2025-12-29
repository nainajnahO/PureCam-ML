import SwiftUI
import AVFoundation
import Observation
import Photos
import UniformTypeIdentifiers

@Observable
class CameraService: NSObject {
    var session = AVCaptureSession()
    var isSessionRunning = false

    private let sessionQueue = DispatchQueue(label: "com.purecam.sessionQueue")
    private let output = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    // Callback for preview captures - delivers decoded UIImage
    var onPreviewCaptured: ((UIImage) -> Void)?
    
    enum Status {
        case unconfigured
        case configured
        case unauthorized
        case failed
    }
    
    var status: Status = .unconfigured

    enum CaptureMode {
        case save       // Normal capture - saves to library
        case preview    // Preview capture - temporary, no save
    }

    private var currentCaptureMode: CaptureMode = .save

    // Exposure State
    var currentISO: Float = 0
    var currentShutterSpeed: Double = 0 // in seconds
    var minISO: Float = 0
    var maxISO: Float = 0
    var minShutterSpeed: Double = 0
    var maxShutterSpeed: Double = 0
    
    private func setupObservers() {
        // Observe device rotation to update capture orientation
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
    }
    
    @objc func orientationChanged() {
        guard let connection = output.connection(with: .video) else { return }
        
        let deviceOrientation = UIDevice.current.orientation
        let angle: CGFloat
        
        switch deviceOrientation {
        case .portrait: angle = 90
        case .portraitUpsideDown: angle = 270
        case .landscapeLeft: angle = 0      // Home button right
        case .landscapeRight: angle = 180   // Home button left
        default: return // Keep existing rotation
        }
        
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
    
    // Manual Exposure Controls
    func setCustomExposure(iso: Float, shutterSeconds: Double) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Find the active video device input
            guard let input = self.session.inputs.first as? AVCaptureDeviceInput else { return }
            let device = input.device
            
            do {
                try device.lockForConfiguration()
                
                // Clamp values
                let newISO = min(max(iso, self.minISO), self.maxISO)
                let newShutter = min(max(shutterSeconds, self.minShutterSpeed), self.maxShutterSpeed)
                let duration = CMTime(seconds: newShutter, preferredTimescale: 1000000)

                device.setExposureModeCustom(duration: duration, iso: newISO, completionHandler: nil)
                
                device.unlockForConfiguration()
                
                // Update local state on main thread
                DispatchQueue.main.async {
                    self.currentISO = newISO
                    self.currentShutterSpeed = newShutter
                }
            } catch {
                print("Failed to lock configuration for exposure: \(error)")
            }
        }
    }
    
    func resetAutoExposure() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let input = self.session.inputs.first as? AVCaptureDeviceInput else { return }
            let device = input.device
            
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                print("Failed to reset auto exposure: \(error)")
            }
        }
    }
    
    override init() {
        super.init()
        checkPermissions()
        setupObservers()
        
        // Enable device orientation notifications
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.configureSession()
            self.startSession()
        }
    }
    
    deinit {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    
    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera.
            break
        case .notDetermined:
            // The user has not yet been presented with the option to grant video access.
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video) { [weak self] authorized in
                guard let self = self else { return }
                if !authorized {
                    DispatchQueue.main.async {
                        self.status = .unauthorized
                    }
                }
                self.sessionQueue.resume()
            }
        default:
            // The user has previously denied access.
            DispatchQueue.main.async {
                self.status = .unauthorized
            }
        }
    }
    
    private func configureSession() {
        guard status == .unconfigured else { return }
        
        session.beginConfiguration()
        session.sessionPreset = .photo
        
        // Add video input
        do {
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                throw CameraError.cameraUnavailable
            }
            
            // Attempt to disable ISP processing for a "Pure" preview
            try? camera.lockForConfiguration()
            
            // 1. Disable Video HDR (Multi-exposure blending)
            if camera.automaticallyAdjustsVideoHDREnabled {
                camera.automaticallyAdjustsVideoHDREnabled = false
            }
            if camera.isVideoHDREnabled {
                camera.isVideoHDREnabled = false
            }
            
            // 2. Disable Low Light Boost (Artificial gain/denoising)
            if camera.automaticallyEnablesLowLightBoostWhenAvailable {
                camera.automaticallyEnablesLowLightBoostWhenAvailable = false
            }
            
            // 3. Disable Lens Correction (Digital straightening)
            // RAW data is optically distorted; the preview should match.
            if camera.isGeometricDistortionCorrectionSupported {
                camera.isGeometricDistortionCorrectionEnabled = false
            }
            
            camera.unlockForConfiguration()
            
            // Capture initial exposure limits
            let activeFormat = camera.activeFormat
            self.minISO = activeFormat.minISO
            self.maxISO = activeFormat.maxISO
            self.minShutterSpeed = activeFormat.minExposureDuration.seconds
            self.maxShutterSpeed = activeFormat.maxExposureDuration.seconds
            
            // Initialize current values
            self.currentISO = camera.iso
            self.currentShutterSpeed = camera.exposureDuration.seconds
            
            let input = try AVCaptureDeviceInput(device: camera)
            
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                throw CameraError.cannotAddInput
            }
            
            if session.canAddOutput(output) {
                session.addOutput(output)
                
                // Configure for high quality capture
                if let maxDimensions = camera.activeFormat.supportedMaxPhotoDimensions.last {
                    output.maxPhotoDimensions = maxDimensions
                }
            } else {
                throw CameraError.cannotAddOutput
            }
            
            session.commitConfiguration()
            
            DispatchQueue.main.async {
                self.status = .configured
            }
            
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.status = .failed
            }
        }
    }
    
    func startSession() {
        guard status == .configured else { return }
        // Start the session on the background thread
        sessionQueue.async {
            if !self.session.isRunning && !self.session.isInterrupted {
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = true
                }
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = false
                }
            }
        }
    }
    
    func capturePhoto(mode: CaptureMode = .save) {
        guard session.isRunning else { return }
        currentCaptureMode = mode

        // Capture RAW only
        guard let rawFormat = output.availableRawPhotoPixelFormatTypes.first else {
            print("⚠️ RAW format not available")
            return
        }

        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        output.capturePhoto(with: settings, delegate: self)
    }
    
    private func savePhotoAsRAW(rawData: Data, photo: AVCapturePhoto) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }

        // Write RAW data to temporary file
        let tempRAWURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dng")

        do {
            try rawData.write(to: tempRAWURL)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: tempRAWURL)
            }
            try? FileManager.default.removeItem(at: tempRAWURL)
            print("✅ Saved pure RAW (DNG)")
        } catch {
            print("❌ Failed to save RAW: \(error)")
        }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil else { return }

        switch currentCaptureMode {
        case .save:
            // Save pure RAW
            print("📸 Saving pure RAW")
            guard let rawData = photo.fileDataRepresentation() else { return }
            Task { await savePhotoAsRAW(rawData: rawData, photo: photo) }

        case .preview:
            // Preview RAW (no save)
            guard let data = photo.fileDataRepresentation() else { return }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self,
                      let ciImage = CIImage(data: data) else { return }

                // Apply orientation transform
                let orientedImage = ciImage.oriented(forExifOrientation: Int32(photo.metadata[kCGImagePropertyOrientation as String] as? UInt32 ?? 6))

                let context = CIContext(options: [.useSoftwareRenderer: false])
                guard let cgImage = context.createCGImage(orientedImage, from: orientedImage.extent) else { return }

                let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)

                // Deliver to main thread
                DispatchQueue.main.async {
                    self.onPreviewCaptured?(uiImage)
                }
            }
        }

        // Reset to save mode for next capture
        currentCaptureMode = .save
    }
}

enum CameraError: Error {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
}
