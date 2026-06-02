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
import AVFoundation
import Observation
import Photos
import OSLog

@Observable
class CameraService: NSObject {
    var session = AVCaptureSession()
    var isSessionRunning = false

    private let sessionQueue = DispatchQueue(label: "com.purecam.sessionQueue")
    private let output = AVCapturePhotoOutput()

    // Tracks the device's physical orientation relative to gravity and supplies
    // the rotation angle to apply at capture time. This is Apple's replacement
    // (iOS 17+) for hand-mapping UIDeviceOrientation to angles, and it stays
    // correct regardless of the portrait-locked UI or the Control Center
    // rotation lock. Must be retained for the lifetime of the session.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    // Video output for live frame capture (for ML feature extraction)
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "com.purecam.videoOutputQueue")

    // On-demand frame delivery: the video output does no per-frame work until
    // something asks for a frame. Pending requests are fulfilled by the next
    // delivered sample buffer. All access is serialized on `videoOutputQueue`.
    private var pendingFrameRequests: [(id: UUID, continuation: CheckedContinuation<CIImage?, Never>)] = []

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

    // Discrete ISO values supported by iPhone cameras (1/3 stop increments)
    static let supportedISOValues: [Float] = [
        32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
        1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400
    ]

    /// Rounds an arbitrary ISO value to the nearest supported discrete value
    static func roundToNearestISO(_ value: Float) -> Float {
        // Find the closest supported ISO value
        guard let nearest = supportedISOValues.min(by: { abs($0 - value) < abs($1 - value) }) else {
            return value
        }
        return nearest
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
                Logger.camera.error("Failed to lock configuration for exposure: \(error.localizedDescription)")
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
                Logger.camera.error("Failed to reset auto exposure: \(error.localizedDescription)")
            }
        }
    }


    override init() {
        super.init()
        checkPermissions()

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.configureSession()
            self.startSession()
        }
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

            // Start tracking physical orientation for this device. previewLayer is
            // nil because the preview stays portrait (the app is portrait-locked);
            // we only need the capture angle.
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
            
            if session.canAddOutput(output) {
                session.addOutput(output)

                // Configure for high quality capture
                if let maxDimensions = camera.activeFormat.supportedMaxPhotoDimensions.last {
                    output.maxPhotoDimensions = maxDimensions
                }
            } else {
                throw CameraError.cannotAddOutput
            }

            // Add video data output for live frame capture (ML feature extraction)
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
                videoDataOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)

                // Drop late frames rather than stalling the capture pipeline.
                videoDataOutput.alwaysDiscardsLateVideoFrames = true

                // Configure for efficient preview extraction
                videoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ]
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
            Logger.camera.error("RAW format not available")
            return
        }

        // Orient the capture to gravity at the instant of capture. Reading the
        // angle here (rather than on a rotation notification) avoids stale or
        // missing orientation values. For RAW this is recorded in the DNG
        // orientation tag — the pixels themselves are never rotated.
        if let connection = output.connection(with: .video),
           let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }

        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        output.capturePhoto(with: settings, delegate: self)
    }

    /// Request the next camera frame for ML feature extraction.
    ///
    /// The video data output stays attached but does no per-frame work until a
    /// request is pending, at which point the next delivered sample buffer
    /// fulfills it. Returns nil if no frame arrives within `timeout` seconds
    /// (e.g. the session is not running).
    func captureNextFrame(timeout: TimeInterval = 1.0) async -> CIImage? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            videoOutputQueue.async { [weak self] in
                self?.pendingFrameRequests.append((id, continuation))
            }
            // Timeout fallback so a request can never hang forever. Runs on the
            // same serial queue as the delegate, so the continuation is resumed
            // exactly once.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.videoOutputQueue.async {
                    guard let self,
                          let index = self.pendingFrameRequests.firstIndex(where: { $0.id == id }) else { return }
                    let request = self.pendingFrameRequests.remove(at: index)
                    request.continuation.resume(returning: nil)
                }
            }
        }
    }
    
    private func savePhotoAsRAW(rawData: Data) async {
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
            Logger.camera.debug("Saved pure RAW (DNG)")
        } catch {
            Logger.camera.error("Failed to save RAW: \(error.localizedDescription)")
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
            Logger.camera.debug("Saving pure RAW")
            guard let rawData = photo.fileDataRepresentation() else { return }
            Task { await savePhotoAsRAW(rawData: rawData) }

        case .preview:
            // Preview RAW (no save)
            guard let data = photo.fileDataRepresentation() else { return }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self,
                      let ciImage = CIImage(data: data) else { return }

                // Apply the SAME fixed orientation the live preview layer uses
                // (videoRotationAngle = 90°, i.e. .right / EXIF orientation 6). A
                // fixed transform shows upright in every device orientation — the
                // device tilt and the portrait-locked screen cancel out — so it
                // needs no UIDevice orientation and keeps working with rotation
                // lock on, exactly like the live preview. The snapshot then matches
                // the preview by construction.
                let orientedImage = ciImage.oriented(.right)

                guard let cgImage = CIContext.shared.createCGImage(orientedImage, from: orientedImage.extent) else { return }

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

// MARK: - Video Data Output Delegate (for live frame capture)
extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                      didOutput sampleBuffer: CMSampleBuffer,
                      from connection: AVCaptureConnection) {
        // No work unless something is waiting for a frame. This keeps the ML
        // pipeline idle (no per-frame CIImage allocation) until inference or
        // training actually needs the current scene.
        guard !pendingFrameRequests.isEmpty else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // CIImage retains the pixel buffer, so it stays valid for the awaiting
        // caller to render even after this callback returns.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let requests = pendingFrameRequests
        pendingFrameRequests.removeAll()
        for request in requests {
            request.continuation.resume(returning: ciImage)
        }
    }
}

enum CameraError: Error {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
}
