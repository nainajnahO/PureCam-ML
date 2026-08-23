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
import AVFoundation
import CoreLocation
import Observation
import Photos
import OSLog
import ImageIO

@Observable
class CameraService: NSObject {
    var session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.purelenz.sessionQueue")
    private let output = AVCapturePhotoOutput()

    // Tracks the device's physical orientation relative to gravity and supplies
    // the rotation angle to apply at capture time. This is Apple's replacement
    // (iOS 17+) for hand-mapping UIDeviceOrientation to angles, and it stays
    // correct regardless of the portrait-locked UI or the Control Center
    // rotation lock. Must be retained for the lifetime of the session.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    // Observes the coordinator's capture angle to keep `deviceOrientation` live.
    // Invalidated on deinit (also auto-invalidates when this token deallocates).
    private var rotationObservation: NSKeyValueObservation?

    // Watches for the ISP reporting that the scene changed meaningfully, so a
    // tapped focus can hand back to continuous AF. Registered once for the
    // session's lifetime (see `configureSession`), not per tap.
    private var subjectAreaObserver: NSObjectProtocol?

    // The session's own lifecycle notifications: interruption begin/end and
    // runtime errors. Registered once in `configureSession` for the session's
    // lifetime; without them a session that was interrupted at launch (another
    // process still holding the camera), by a phone call, or by a media-server
    // reset stays dead until the next background/foreground round trip.
    private var sessionObservers: [NSObjectProtocol] = []

    /// Callers waiting for the current focus scan to settle. Only ever touched on
    /// `sessionQueue`, which is what guarantees each continuation resumes exactly
    /// once whether the lens or the timeout gets there first.
    private var pendingFocusSettles: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    // The in-flight one-shot metering pass started by `holdCurrentExposure()`.
    // Both are torn down the instant the app adopts the metered value, so
    // nothing here outlives the seed — see that method's doc comment for why
    // this is not the "follow the camera forever" observation the design
    // deliberately avoids. All three are touched only on `sessionQueue`.
    private var exposureSeedObservation: NSKeyValueObservation?
    private var exposureSeedTimeout: DispatchWorkItem?
    private var isSeedingExposure = false

    // Reported on the main queue with the exposure a seed settled on, so the UI
    // can move the rings to where the camera actually is. Cleared as it fires;
    // a seed superseded by a newer one never reports.
    private var exposureSeedCompletion: ((Float, Double) -> Void)?

    // When the current metering pass started, for the settle time in the log.
    private var exposureSeedStart: ContinuousClock.Instant?

    // Video output for live frame capture (for ML feature extraction)
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "com.purelenz.videoOutputQueue")

    /// A live preview frame plus the exposure it was captured with. The exposure
    /// lets ML normalize the frame's brightness into an absolute scene light level
    /// (the same image can come from a sunny scene at ISO 32 or a dim one at ISO 1600).
    struct CapturedFrame {
        let image: CIImage
        let iso: Float
        let shutterSeconds: Double

        /// The tapped focus point in effect when the frame was delivered, or nil
        /// while the lens is in continuous AF. Spot metering rides on focus: the
        /// model meters `SceneFeatures.spotLuminance` here.
        ///
        /// In `focusPointOfInterest`'s normalized device coordinates — (0,0)
        /// top-left, (1,1) bottom-right of the native sensor frame — which is
        /// also how `image` arrives: the video output has no rotation applied, so
        /// its buffer is that same native frame and the point indexes it directly.
        let meteringPoint: CGPoint?
    }

    // On-demand frame delivery: the video output does no per-frame work until
    // something asks for a frame. Pending requests are fulfilled by the next
    // delivered sample buffer. All access is serialized on `videoOutputQueue`.
    private var pendingFrameRequests: [(id: UUID, continuation: CheckedContinuation<CapturedFrame?, Never>)] = []

    // Callback for preview captures — delivers the decoded UIImage, or nil
    // when the capture fails, so the caller can release its in-flight state.
    var onPreviewCaptured: ((UIImage?) -> Void)?
    
    enum Status {
        case unconfigured
        case configured
        case unauthorized
        case failed
    }
    
    /// Published to the main queue, for the UI. Not the gate for starting the
    /// session — see `isSessionConfigured`.
    var status: Status = .unconfigured

    /// Set on `sessionQueue` the moment `configureSession` succeeds, and the
    /// only thing `startSession` checks. `status` would not do: it is
    /// published through `DispatchQueue.main.async`, so right after
    /// configuration it still reads `.unconfigured` on the session queue —
    /// and the scene going active can read it that way on the main queue too,
    /// if configuration is still running. A start gated on `status` lost
    /// that race on a cold launch and left the viewfinder black (#47).
    private var isSessionConfigured = false

    /// Aspect ratio (long / short) of the saved RAW frame — the full sensor
    /// readout. Defaults to 4:3 (every iPhone rear sensor) and is set from the
    /// active format at configuration, so it stays correct on any device/format.
    private(set) var photoAspectRatio: CGFloat = 4.0 / 3.0

    /// Physical device orientation — the single source of truth for rotating UI
    /// overlays (buttons, exposure text, framing indicator). Derived from the
    /// same `RotationCoordinator` that orients the saved photo, so the UI can
    /// never disagree with the capture. Being gravity-based, it stays correct
    /// under Control Center rotation lock — the reason `UIDevice` orientation
    /// notifications (which the lock suppresses) are not used.
    private(set) var deviceOrientation: UIDeviceOrientation = .portrait

    enum CaptureMode {
        case save       // Normal capture - saves to library
        case preview    // Preview capture - temporary, no save
    }

    private var currentCaptureMode: CaptureMode = .save

    // Warm location fix for geotagging. Created here so the when-in-use prompt
    // and GPS warm-up happen when the camera opens, not at first capture.
    private let locationService = LocationService()

    /// The fix snapshotted at shutter time for the capture in flight, so the
    /// Photos save (which runs later) tags where the shot was taken, not where
    /// the device is by save time. Same in-flight pattern as currentCaptureMode.
    private var inFlightCaptureLocation: CLLocation?

    // Exposure State
    var currentISO: Float = 0
    var currentShutterSpeed: Double = 0 // in seconds
    var minISO: Float = 0
    var maxISO: Float = 0
    var minShutterSpeed: Double = 0
    var maxShutterSpeed: Double = 0

    // Discrete ISO values in 1/3 stop increments; filtered to the active
    // format's reported range at configuration time (see `isoDetents`).
    private static let supportedISOValues: [Float] = [
        32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
        1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400
    ]

    /// The discrete ISO detents the manual control offers — the standard table
    /// limited to what the active format actually supports, so the knob can
    /// never land on a value `setCustomExposure` would have to clamp away.
    private(set) var isoDetents: [Float] = CameraService.supportedISOValues

    /// Rounds an arbitrary ISO value to the nearest supported detent
    func roundToNearestISO(_ value: Float) -> Float {
        isoDetents.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
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
    
    /// How long to wait for a one-shot metering pass before adopting whatever
    /// the device has reached. A large change of scene between launches takes
    /// appreciably longer to converge than a re-meter in steady light, so this
    /// is sized for the former — the case the seed exists to handle.
    private static let exposureSeedTimeoutSeconds = 3.0

    /// Meter the scene once, then take that exposure over and hold it.
    ///
    /// This is the app's starting exposure, and it replaces the old
    /// `resetAutoExposure()`. `.autoExpose` is AVFoundation's one-shot: the
    /// device meters the scene a single time and moves itself to `.locked`. We
    /// wait for that, read what it chose, and immediately re-apply it through
    /// `setCustomExposure`. iOS auto-exposure is a *seed*, never a resting
    /// state — every exposure the camera holds is then one this app set, so
    /// `currentISO` / `currentShutterSpeed` are correct by construction and
    /// cannot drift behind the app's back.
    ///
    /// **Why a fresh `.autoExpose` rather than just reading the device.**
    /// Once this has run, the device sits in `.custom` and is not metering
    /// anything. Reading `device.iso` on a later launch would hand back the
    /// value *we* set last time, which is "restore the last exposure" — good
    /// in the same room, useless after the user has walked outside. Only a new
    /// metering pass reflects the scene actually in front of the camera.
    ///
    /// **Why the observation below is not the one this design avoids.** The
    /// hazard is *permanently* trailing a value that drifts, because then the
    /// app can never be sure its copy is current. This observation ends the
    /// moment the app takes the value over, after which nothing drifts —
    /// there is exactly one writer.
    ///
    /// ISO is snapped to the nearest detent because the manual knob only offers
    /// detents — holding an off-table value would leave the knob unable to find
    /// its own position. The resulting shift is at most 1/6 stop.
    ///
    /// - Parameter onApplied: Called on the main queue with the exposure that
    ///   was adopted. The rings do not track the camera on their own, so
    ///   without this they would sit at their default while the camera holds
    ///   something else — and the first nudge would jump to that default.
    func holdCurrentExposure(then onApplied: ((Float, Double) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let input = self.session.inputs.first as? AVCaptureDeviceInput else { return }
            let device = input.device

            // A fast background/foreground cycle can land here twice; the
            // newer pass replaces the older one.
            self.endExposureSeed()
            self.exposureSeedCompletion = onApplied

            guard device.isExposureModeSupported(.autoExpose) else {
                self.adoptMeteredExposure(from: device)
                return
            }

            do {
                try device.lockForConfiguration()
                device.exposureMode = .autoExpose
                device.unlockForConfiguration()
            } catch {
                Logger.camera.error("Failed to start one-shot metering: \(error.localizedDescription)")
                self.adoptMeteredExposure(from: device)
                return
            }

            self.isSeedingExposure = true
            self.exposureSeedStart = .now

            // Wait on `exposureMode` reaching `.locked` rather than on
            // `isAdjustingExposure`: the mode is a one-way transition, so there
            // is no ordering race, whereas the flag flicks true-then-false and
            // may not have gone true yet at the moment we start observing.
            self.exposureSeedObservation = device.observe(\.exposureMode, options: [.new]) { [weak self] device, _ in
                guard let self else { return }
                self.sessionQueue.async { self.finishExposureSeed(device: device) }
            }

            // If metering never reports finishing, adopt whatever the device
            // has rather than leaving the app sitting in auto indefinitely.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.isSeedingExposure else { return }
                // Notice, not debug: this is the fallback path silently taking
                // over for the observation, which is worth seeing in field logs.
                Logger.camera.notice("One-shot metering did not settle in time - adopting current exposure")
                self.endExposureSeed()
                self.adoptMeteredExposure(from: device)
            }
            self.exposureSeedTimeout = timeout
            self.sessionQueue.asyncAfter(deadline: .now() + Self.exposureSeedTimeoutSeconds, execute: timeout)

            // It may already have settled in the gap before the observation
            // was installed.
            self.finishExposureSeed(device: device)
        }
    }

    /// Complete a one-shot metering pass, if one is still in flight and the
    /// device has finished. Idempotent — the observation, the timeout and the
    /// post-install check all funnel through here.
    private func finishExposureSeed(device: AVCaptureDevice) {
        guard isSeedingExposure, device.exposureMode == .locked else { return }
        endExposureSeed()
        adoptMeteredExposure(from: device)
    }

    /// Mark that no metering pass is in flight and tear down what backed it.
    private func endExposureSeed() {
        isSeedingExposure = false
        exposureSeedObservation?.invalidate()
        exposureSeedObservation = nil
        exposureSeedTimeout?.cancel()
        exposureSeedTimeout = nil
    }

    /// Re-apply what the device metered as a custom exposure, so the value the
    /// camera holds is one this app set.
    private func adoptMeteredExposure(from device: AVCaptureDevice) {
        let meteredISO = device.iso
        let meteredShutter = device.exposureDuration.seconds
        let onApplied = exposureSeedCompletion
        exposureSeedCompletion = nil
        let settle = exposureSeedStart?.duration(to: .now)
        exposureSeedStart = nil

        // Hop to main to round: `isoDetents` is written on the main thread
        // (see configureSession) and must not be read from this queue.
        // `setCustomExposure` dispatches back to sessionQueue itself.
        DispatchQueue.main.async {
            let adoptedISO = self.roundToNearestISO(meteredISO)
            self.setCustomExposure(iso: adoptedISO, shutterSeconds: meteredShutter)
            let settled = settle?.formatted(
                .units(allowed: [.milliseconds], width: .abbreviated, fractionalPart: .show(length: 1))
            ) ?? "n/a"
            Logger.camera.info(
                "Seeded exposure: ISO \(Int(adoptedISO)), shutter 1/\(Int(1 / meteredShutter)) (metered in \(settled))"
            )

            // Report the values directly rather than letting the caller read
            // `currentISO`: `setCustomExposure` has not written them back yet.
            onApplied?(adoptedISO, meteredShutter)
        }
    }


    // MARK: - Focus

    /// Focus once on a normalized sensor point.
    ///
    /// The point must already be in sensor coordinates — `CameraPreview` converts
    /// the tap through `captureDevicePointConverted(fromLayerPoint:)`, which is the
    /// only thing that knows about the preview's aspect-fill crop and fixed 90°
    /// rotation. Passing a raw screen fraction here would focus the wrong place.
    ///
    /// **Focus only.** Apple's tap-to-focus also sets `exposurePointOfInterest` and
    /// flips to `.continuousAutoExposure`. This deliberately does not: exposure is
    /// owned by the app (`AutoExposureCoordinator` and the manual knob) via
    /// `setExposureModeCustom`, so handing metering back to the ISP here would throw
    /// away the model's decision on every tap. The model meters at the tapped
    /// point instead — every `CapturedFrame` delivered while this focus is in
    /// effect carries it as `meteringPoint`, until `releaseFocus()` lets go.
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let input = self.session.inputs.first as? AVCaptureDeviceInput else { return }
            let device = input.device

            guard device.isFocusPointOfInterestSupported,
                  device.isFocusModeSupported(.autoFocus) else { return }

            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus

                // Ask the ISP to report when the scene changes meaningfully — a
                // coarse "something is different now" signal, not object
                // recognition, and the same mechanism the stock Camera app uses
                // to release a tapped focus. This flag is the only switch that
                // matters: nothing is posted while it is off, and the listener
                // itself already stands for the whole session (`configureSession`).
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {
                Logger.camera.error("Failed to lock configuration for focus: \(error.localizedDescription)")
            }
        }
    }

    /// How long a shutter press waits for a tapped focus scan before firing
    /// anyway. Sized from the log on an iPhone Air: scans land in two clusters,
    /// ~200 ms and ~480 ms (longest seen 595 ms), so 300 ms cut off half of
    /// them. 600 ms clears both; a press with the lens already settled — the
    /// common case — never waits at all.
    static let shutterFocusSettleTimeoutSeconds: TimeInterval = 0.6

    /// Resolves when the scan started by `focus(at:)` has settled.
    ///
    /// AVFoundation has no completion callback for autofocus. The one handler it
    /// offers, `setFocusModeLockedWithLensPosition(_:completionHandler:)`, is for
    /// driving the lens to an explicit position, not for a scan. What the device
    /// does publish is state: `.autoFocus` means "scan once, then set `focusMode`
    /// to `.locked` yourself", and that transition is KVO-observable. So the mode
    /// *leaving* `.autoFocus` is the completion signal for the request this app
    /// makes — more precise than `isAdjustingFocus`, which is a general "is the
    /// lens moving" flag and may never turn on at all when the lens is already
    /// where it needs to be.
    ///
    /// A single-shot scan always ends, at a pace only the camera knows, so by
    /// default there is no timeout: the ripple that waits on this wants the real
    /// answer however long it takes. The one way a scan could fail to end is by
    /// never starting — a device that would not take the mode — and that case
    /// resolves at once, because the mode is then still whatever it was before.
    ///
    /// The shutter is the caller that cannot wait indefinitely: a photo that is
    /// a fraction late still exists, one that never fires does not. It passes a
    /// `timeout`, after which this resolves regardless of the lens.
    ///
    /// With no tapped scan in flight — continuous AF, or a tap that already
    /// settled — this resolves immediately, so it costs the common case nothing.
    ///
    /// - Parameter timeout: Seconds to wait before resolving anyway. `nil` waits
    ///   for the scan, however long it takes.
    func awaitFocusSettled(timeout: TimeInterval? = nil) async {
        // Ordered behind the `focus(at:)` this is waiting on. `sessionQueue` is
        // serial, so by the time this lands the new scan has been requested and
        // `focusMode` is no longer whatever the *previous* tap left locked.
        await withCheckedContinuation { continuation in
            sessionQueue.async { continuation.resume() }
        }

        guard let input = session.inputs.first as? AVCaptureDeviceInput else { return }
        let device = input.device
        let id = UUID()
        var observation: NSKeyValueObservation?
        let start = ContinuousClock.now

        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                self?.pendingFocusSettles.append((id, continuation))
            }

            observation = device.observe(\.focusMode, options: [.initial, .new]) { [weak self] device, _ in
                guard device.focusMode != .autoFocus else { return }
                self?.resolveFocusSettle(id)
            }

            // Timeout fallback, on the same serial queue as the observation's
            // resolve, so the continuation is resumed exactly once.
            if let timeout {
                sessionQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self,
                          let index = self.pendingFocusSettles.firstIndex(where: { $0.id == id }) else { return }
                    // Notice, not debug: the lens was still racking when the
                    // caller stopped waiting, which is worth seeing in field logs.
                    Logger.camera.notice("Focus did not settle within \(timeout, format: .fixed(precision: 2))s - continuing anyway")
                    self.pendingFocusSettles.remove(at: index).continuation.resume()
                }
            }
        }

        observation?.invalidate()

        // The ripple's waiter (no timeout) sees the scan through, so its time
        // is the real scan length — the number the shutter's cap is sized
        // against. The shutter's own time shows what a press actually paid.
        let elapsed = start.duration(to: .now).formatted(
            .units(allowed: [.milliseconds], width: .abbreviated, fractionalPart: .show(length: 1))
        )
        if timeout == nil {
            Logger.camera.info("Focus settled in \(elapsed)")
        } else {
            Logger.camera.info("Shutter waited \(elapsed) for focus")
        }
    }

    /// Resume one waiter, if it is still waiting. Hops to `sessionQueue` so the
    /// removal and the resume are atomic with respect to every other caller.
    private func resolveFocusSettle(_ id: UUID) {
        sessionQueue.async { [weak self] in
            guard let self,
                  let index = self.pendingFocusSettles.firstIndex(where: { $0.id == id }) else { return }
            self.pendingFocusSettles.remove(at: index).continuation.resume()
        }
    }

    private func removeSubjectAreaObserver() {
        guard let observer = subjectAreaObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        subjectAreaObserver = nil
    }

    /// Hand focus back to the device: continuous AF, point recentred, monitoring off.
    ///
    /// Idempotent, and safe to call when no tapped focus is in effect — which is
    /// what lets both callers share it: the subject-area observer, and the app
    /// leaving the foreground.
    ///
    /// **Why leaving the foreground releases focus.** A tapped focus is transient
    /// state, exactly like the reticle that marks it. Surviving a glance at
    /// Control Center would leave the lens locked at a distance the user can no
    /// longer see marked — and `AutoExposureCoordinator` re-establishes exposure
    /// on every return to active, so focus outliving the trip would make it the
    /// one piece of camera state that silently persists.
    ///
    /// Nothing here tears the observer down. Leaving it standing is what makes
    /// the two failure paths below retry-able: if this call cannot reconfigure
    /// the device, monitoring stays on and the next notification tries again,
    /// rather than stranding the lens with nobody listening.
    func releaseFocus() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let input = self.session.inputs.first as? AVCaptureDeviceInput else { return }
            let device = input.device

            guard device.isFocusModeSupported(.continuousAutoFocus) else { return }

            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                device.focusMode = .continuousAutoFocus
                device.isSubjectAreaChangeMonitoringEnabled = false
                device.unlockForConfiguration()
            } catch {
                Logger.camera.error(
                    "Failed to lock configuration to resume continuous focus: \(error.localizedDescription)"
                )
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
            
            // Capture the exposure limits: the device-reported range clamped to
            // the app's manual-control policy caps (CameraConstants). This is
            // the single home of the usable range — the knob mapping, the AI
            // ramp, and setCustomExposure all read these same values, so the
            // knob position and the applied exposure can never disagree.
            let activeFormat = camera.activeFormat
            self.minISO = activeFormat.minISO
            self.maxISO = activeFormat.maxISO
            self.minShutterSpeed = max(
                activeFormat.minExposureDuration.seconds, CameraConstants.fastestManualShutter
            )
            self.maxShutterSpeed = min(
                activeFormat.maxExposureDuration.seconds, CameraConstants.slowestManualShutter
            )
            let detents = Self.supportedISOValues.filter {
                $0 >= activeFormat.minISO && $0 <= activeFormat.maxISO
            }
            if !detents.isEmpty {
                // Published on main like `status` below: this runs on
                // sessionQueue, and the drag gesture reads `isoDetents` on the
                // main thread. Swapping an array out from under a concurrent
                // read is a use-after-free, not just a stale value.
                DispatchQueue.main.async { self.isoDetents = detents }
            }
            
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
            let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
            rotationCoordinator = coordinator

            // Mirror the capture angle into `deviceOrientation` so the UI rotates
            // from the same gravity-based source that orients the saved photo.
            // `.initial` seeds the current orientation (correct even when the app
            // launches in landscape); `.new` then tracks each physical turn.
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                DispatchQueue.main.async { self?.setDeviceOrientation(forCaptureAngle: angle) }
            }

            // Listen for subject-area changes for the whole session rather than
            // arming a fresh observer per tap.
            //
            // `isSubjectAreaChangeMonitoringEnabled` is the real on/off switch —
            // nothing is posted while it is false — so a per-tap registration
            // would receive no fewer notifications, and would open a window
            // between enabling monitoring and starting to listen. That window is
            // not theoretical: the focus scan a tap kicks off is itself a large
            // change to the image, so the notification tends to arrive right
            // then, and a missed one leaves the lens locked until the next tap.
            subjectAreaObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                object: camera,
                queue: .main
            ) { [weak self] _ in
                self?.releaseFocus()
            }

            // `startSession` deliberately refuses to start an interrupted session,
            // which is correct for the moment it runs — so something has to start
            // it once the interruption lifts. Relaunching a dev build over a
            // running instance is the common case: the new process configures
            // its session while the old one still owns the camera. `startSession`
            // is idempotent, so if the session resumed on its own this is a no-op.
            sessionObservers = [
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.wasInterruptedNotification,
                    object: session,
                    queue: .main
                ) { notification in
                    let rawReason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                    let reason = rawReason.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                    let description = reason.map { String(describing: $0) } ?? "unknown reason \(rawReason ?? -1)"
                    // `.public` so the reason survives into a collected field log
                    // instead of being redacted to `<private>`.
                    Logger.camera.notice("Session interrupted: \(description, privacy: .public)")
                },
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.interruptionEndedNotification,
                    object: session,
                    queue: .main
                ) { [weak self] _ in
                    Logger.camera.notice("Session interruption ended - restarting")
                    self?.startSession()
                },
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification,
                    object: session,
                    queue: .main
                ) { [weak self] notification in
                    guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
                    // The media server restarting underneath a running app is the
                    // other classic way to end up with a dead session; anything
                    // else is logged and left alone.
                    if error.code == .mediaServicesWereReset {
                        Logger.camera.notice("Media services were reset - restarting session")
                        self?.startSession()
                    } else {
                        Logger.camera.error("Session runtime error: \(error.localizedDescription, privacy: .public)")
                    }
                },
            ]

            if session.canAddOutput(output) {
                session.addOutput(output)

                // Configure for high quality capture
                if let maxDimensions = camera.activeFormat.supportedMaxPhotoDimensions.last {
                    output.maxPhotoDimensions = maxDimensions

                    // The saved RAW shares these dimensions' aspect ratio (RAW is
                    // the full sensor). Orientation is handled in the view, so just
                    // expose the orientation-agnostic long/short ratio.
                    let long = CGFloat(max(maxDimensions.width, maxDimensions.height))
                    let short = CGFloat(min(maxDimensions.width, maxDimensions.height))
                    if short > 0 {
                        let ratio = long / short
                        DispatchQueue.main.async { self.photoAspectRatio = ratio }
                    }
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
            isSessionConfigured = true

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

    /// Maps the rear-camera horizon-level capture angle (0/90/180/270°) to a
    /// device orientation for rotating UI overlays. Portrait (90°) and upside-
    /// down (270°) are gravity-unambiguous; the landscape pair (0° → left,
    /// 180° → right) is the on-device-confirmed assignment — the capture angle
    /// and UIDeviceOrientation's left/right naming run opposite ways.
    /// Call on the main thread — it publishes to `@Observable` UI.
    private func setDeviceOrientation(forCaptureAngle angle: CGFloat) {
        let orientation: UIDeviceOrientation
        switch Int(angle.rounded()) {
        case 90:  orientation = .portrait
        case 270: orientation = .portraitUpsideDown
        case 0:   orientation = .landscapeLeft
        case 180: orientation = .landscapeRight
        default:  return
        }
        if orientation != deviceOrientation {
            deviceOrientation = orientation
        }
    }

    /// Start the session if it is configured and not already running.
    ///
    /// Idempotent, and safe to call early: `init` calls it on `sessionQueue`
    /// right behind `configureSession`, where the serial queue guarantees the
    /// configuration is done, and the scene going active calls it again from
    /// the main queue whenever that happens to land. Whichever arrives first
    /// after configuration starts the session; the other is a no-op.
    func startSession() {
        sessionQueue.async {
            guard self.isSessionConfigured else { return }
            if !self.session.isRunning && !self.session.isInterrupted {
                self.session.startRunning()
                // Info, not debug, so a field log can show the start — or its
                // absence, which is what a black viewfinder looks like.
                Logger.camera.info("Session started")
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func capturePhoto(mode: CaptureMode = .save) {
        guard session.isRunning else {
            reportPreviewFailure(mode: mode)
            return
        }
        currentCaptureMode = mode
        inFlightCaptureLocation = locationService.latestLocation

        // Capture RAW only
        guard let rawFormat = output.availableRawPhotoPixelFormatTypes.first else {
            Logger.camera.error("RAW format not available")
            reportPreviewFailure(mode: mode)
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

        // Embed GPS EXIF in the DNG itself. No fix (permission denied, or none
        // yet) simply means no GPS tags — the photo saves normally.
        if let location = inFlightCaptureLocation {
            settings.metadata[kCGImagePropertyGPSDictionary as String] = location.exifGPSDictionary
        }

        output.capturePhoto(with: settings, delegate: self)
    }

    /// Report a failed preview capture through `onPreviewCaptured` (nil image)
    /// so the caller's in-flight state is always released. No-op for saves.
    private func reportPreviewFailure(mode: CaptureMode) {
        guard mode == .preview else { return }
        DispatchQueue.main.async { self.onPreviewCaptured?(nil) }
    }

    /// Request the next camera frame for ML feature extraction, along with the
    /// exposure it was captured with.
    ///
    /// The video data output stays attached but does no per-frame work until a
    /// request is pending, at which point the next delivered sample buffer
    /// fulfills it. Returns nil if no frame arrives within `timeout` seconds
    /// (e.g. the session is not running).
    func captureNextFrame(timeout: TimeInterval = 1.0) async -> CapturedFrame? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            videoOutputQueue.async { [weak self] in
                self?.pendingFrameRequests.append((id, continuation))
            }
            // Timeout fallback so a request can never hang forever. Runs on the
            // same serial queue as the delegate, so the continuation is resumed
            // exactly once.
            videoOutputQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self,
                      let index = self.pendingFrameRequests.firstIndex(where: { $0.id == id }) else { return }
                let request = self.pendingFrameRequests.remove(at: index)
                request.continuation.resume(returning: nil)
            }
        }
    }
    
    /// Pull the next full-sensor video frame and render it as an upright,
    /// downscaled UIImage for the framing-indicator preview. Reuses the same
    /// on-demand frame source as ML (`captureNextFrame`) — there is no second
    /// preview layer — so it can never disturb the main viewfinder's connection.
    /// Returns nil if no frame arrives (e.g. the session is not running).
    func nextFramingPreviewImage(maxDimension: CGFloat) async -> UIImage? {
        guard let ciImage = await captureNextFrame()?.image else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Upright in the portrait reference (videoRotationAngle 90° == .right),
                // exactly like the main preview and RAW snapshot. The framing indicator
                // is fixed to the portrait-locked screen (not counter-rotated like the
                // exposure text), so the frame uses this same fixed orientation as the
                // main viewfinder rather than being pre-rotated per device orientation.
                let oriented = ciImage.oriented(.right)

                // Downscale toward the on-screen size before rasterizing so we
                // never render a full-res buffer ~15×/second.
                let extent = oriented.extent
                guard extent.width > 0, extent.height > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let scale = min(1, maxDimension / max(extent.width, extent.height))
                let target = scale < 1
                    ? oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    : oriented

                guard let cgImage = CIContext.shared.createCGImage(target, from: target.extent) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: cgImage, scale: 1, orientation: .up))
            }
        }
    }

    private func savePhotoAsRAW(rawData: Data, location: CLLocation?) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }

        // Write RAW data to temporary file
        let tempRAWURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dng")

        do {
            try rawData.write(to: tempRAWURL)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: tempRAWURL)
                // Cheap guarantee the library asset is geotagged even if a
                // reader ignores the DNG's embedded GPS tags.
                request?.location = location
            }
            try? FileManager.default.removeItem(at: tempRAWURL)
            Logger.camera.debug("Saved pure RAW (DNG)")
        } catch {
            Logger.camera.error("Failed to save RAW: \(error.localizedDescription)")
        }
    }

    deinit {
        rotationObservation?.invalidate()
        exposureSeedObservation?.invalidate()
        exposureSeedTimeout?.cancel()
        removeSubjectAreaObserver()
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        // Reset to save mode for next capture
        let mode = currentCaptureMode
        currentCaptureMode = .save
        let location = inFlightCaptureLocation
        inFlightCaptureLocation = nil

        if let error {
            Logger.camera.error("Capture failed: \(error.localizedDescription)")
            reportPreviewFailure(mode: mode)
            return
        }

        switch mode {
        case .save:
            // Save pure RAW
            Logger.camera.debug("Saving pure RAW")
            guard let rawData = photo.fileDataRepresentation() else { return }
            Task { await savePhotoAsRAW(rawData: rawData, location: location) }

        case .preview:
            // Preview RAW (no save)
            guard let data = photo.fileDataRepresentation() else {
                reportPreviewFailure(mode: mode)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                // Apply the SAME fixed orientation the live preview layer uses
                // (videoRotationAngle = 90°, i.e. .right / EXIF orientation 6). A
                // fixed transform shows upright in every device orientation — the
                // device tilt and the portrait-locked screen cancel out — so it
                // needs no UIDevice orientation and keeps working with rotation
                // lock on, exactly like the live preview. The snapshot then matches
                // the preview by construction.
                var uiImage: UIImage?
                if let ciImage = CIImage(data: data) {
                    let orientedImage = ciImage.oriented(.right)
                    if let cgImage = CIContext.shared.createCGImage(orientedImage, from: orientedImage.extent) {
                        uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
                    }
                }

                // Deliver to main thread; nil reports a decode failure so the
                // caller can release its in-flight state.
                DispatchQueue.main.async {
                    self.onPreviewCaptured?(uiImage)
                }
            }
        }
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

        // The exposure this exact frame was captured with, from the ISP's EXIF
        // attachment. The cached currentISO/currentShutterSpeed can't be used
        // here: they go stale whenever the device is in continuous auto-exposure.
        // NSDictionary keeps the CFDictionary toll-free bridged — casting to
        // [String: Any] would eagerly bridge every EXIF key just to read two.
        var frameISO: Float = 0
        var frameShutter: Double = 0
        if let exif = CMGetAttachment(sampleBuffer,
                                      key: kCGImagePropertyExifDictionary,
                                      attachmentModeOut: nil) as? NSDictionary {
            frameISO = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?
                .first?.floatValue ?? 0
            frameShutter = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?
                .doubleValue ?? 0
        }
        let device = (session.inputs.first as? AVCaptureDeviceInput)?.device
        if frameISO <= 0 || frameShutter <= 0, let device {
            frameISO = device.iso
            frameShutter = device.exposureDuration.seconds
        }

        // A tapped focus is in effect exactly while subject-area monitoring is
        // on: `focus(at:)` is the only thing that switches it on and
        // `releaseFocus()` the only thing that switches it off, so the flag is
        // app-owned truth. `focusMode` would not do — a device whose resting
        // mode is not continuous would read as permanently tapped at the centre.
        // Read here, on the frame's own queue, so the point travels with the
        // frame it applies to rather than whatever is true when ML gets to it.
        let meteringPoint = device.flatMap { device in
            device.isSubjectAreaChangeMonitoringEnabled ? device.focusPointOfInterest : nil
        }

        let frame = CapturedFrame(
            image: ciImage, iso: frameISO, shutterSeconds: frameShutter, meteringPoint: meteringPoint
        )

        let requests = pendingFrameRequests
        pendingFrameRequests.removeAll()
        for request in requests {
            request.continuation.resume(returning: frame)
        }
    }
}

enum CameraError: Error {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
}
