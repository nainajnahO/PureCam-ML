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

/// One finger's progress across the viewfinder, from touch-down to lift.
enum FocusTouchPhase {
    case began, moved, ended
    /// The system took the touch (an incoming call, the app going inactive).
    /// Nothing was chosen, so nothing should be focused.
    case cancelled
}

struct CameraPreview: UIViewRepresentable {
    class VideoPreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }

        /// Reports the fraction of the source frame's short axis the preview
        /// currently shows (aspect-fill crops the rest). Read directly from the
        /// layer, so it stays correct on any screen size / safe-area layout
        /// without the app ever measuring the screen itself.
        var onCropFraction: ((CGFloat) -> Void)?
        private var reportedCropFraction: CGFloat?

        /// Reports each phase of a finger on the viewfinder as both the point
        /// in this view's own coordinates (where the water is pressed) and the
        /// normalized sensor point it maps to (what focus needs).
        ///
        /// The conversion has to happen here, because only the layer knows the
        /// two things that make a screen fraction *not* a sensor fraction:
        /// `.resizeAspectFill` crops the short axis, and the connection is
        /// rotated a fixed 90°, which swaps the axes. `captureDevicePointConverted`
        /// accounts for both — dividing by the view's width and height does not.
        var onFocusTouch: ((FocusTouchPhase, _ viewPoint: CGPoint, _ devicePoint: CGPoint) -> Void)?

        // Raw touch events rather than a gesture recognizer: the water needs
        // touch-down, not touch-up, and these four map one-to-one onto the
        // phases with nothing to configure. A touch only arrives here at all
        // if it hit-tested to this view, so the controls layered above the
        // viewfinder (capture button, preview button, framing indicator) are
        // excluded by construction.
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            report(.began, touches)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            report(.moved, touches)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            report(.ended, touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            report(.cancelled, touches)
        }

        private func report(_ phase: FocusTouchPhase, _ touches: Set<UITouch>) {
            guard let touch = touches.first else { return }
            var viewPoint = touch.location(in: self)
            // A drag keeps reporting after the finger leaves the view, and a
            // lift out there would hand focus a sensor point outside 0…1.
            viewPoint.x = min(max(viewPoint.x, 0), bounds.width)
            viewPoint.y = min(max(viewPoint.y, 0), bounds.height)
            let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
            onFocusTouch?(phase, viewPoint, devicePoint)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportCropFractionIfNeeded()
        }

        private func reportCropFractionIfNeeded() {
            let layer = videoPreviewLayer
            guard layer.bounds.width > 0, layer.bounds.height > 0,
                  layer.connection != nil else { return }

            // The normalized region of the source frame the layer actually
            // displays. The cropped (sub-1.0) dimension is the short-axis
            // fraction the framing indicator needs.
            let shown = layer.metadataOutputRectConverted(fromLayerRect: layer.bounds)
            let fraction = min(shown.width, shown.height)
            guard fraction > 0, fraction <= 1, reportedCropFraction != fraction else { return }

            reportedCropFraction = fraction
            // Defer past the current layout pass so we never mutate observable
            // view-model state mid-update.
            DispatchQueue.main.async { [weak self] in
                self?.onCropFraction?(fraction)
            }
        }
    }

    let session: AVCaptureSession
    /// Surfaces the preview's true short-axis crop fraction (see `VideoPreviewView`).
    var onCropFraction: ((CGFloat) -> Void)?
    /// Surfaces a finger on the viewfinder, already converted to a sensor point (see `VideoPreviewView`).
    var onFocusTouch: ((FocusTouchPhase, _ viewPoint: CGPoint, _ devicePoint: CGPoint) -> Void)?
    /// Hands the preview layer itself to whoever needs to map sensor-space
    /// rects onto the screen — the tracking marker, which follows a subject
    /// the camera reports in sensor coordinates. Only the layer knows the
    /// aspect-fill crop and rotation that conversion depends on. Called once,
    /// when the view is made.
    var onPreviewLayer: ((AVCaptureVideoPreviewLayer) -> Void)?

    func makeUIView(context: Context) -> VideoPreviewView {
        let view = VideoPreviewView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.onCropFraction = onCropFraction
        view.onFocusTouch = onFocusTouch

        updateRotation(for: view.videoPreviewLayer)

        // Deferred past the current update so the receiver can store it in
        // view state without mutating mid-update.
        let layer = view.videoPreviewLayer
        DispatchQueue.main.async { onPreviewLayer?(layer) }

        return view
    }

    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        uiView.onCropFraction = onCropFraction
        uiView.onFocusTouch = onFocusTouch
        updateRotation(for: uiView.videoPreviewLayer)
    }

    private func updateRotation(for layer: AVCaptureVideoPreviewLayer) {
        // The app is iPhone-only and locked to portrait by the target's
        // supported-interface-orientations setting, so the preview is always
        // portrait — 90°. That build setting is what makes this constant safe;
        // supporting a rotating screen would mean driving this from the
        // interface orientation. Capture orientation is handled separately by
        // AVCaptureDevice.RotationCoordinator in CameraService.
        let angle: CGFloat = 90

        // Only touch the connection when the angle actually differs. While the
        // water moves, a new copied frame arrives ~30×/second and each one
        // re-runs `updateUIView`; re-setting an unchanged rotation on the live
        // capture connection that often is work the viewfinder should not pay.
        guard layer.connection?.videoRotationAngle != angle else { return }

        if layer.connection?.isVideoRotationAngleSupported(angle) == true {
            layer.connection?.videoRotationAngle = angle
        }
    }
}
