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

    func makeUIView(context: Context) -> VideoPreviewView {
        let view = VideoPreviewView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.onCropFraction = onCropFraction

        updateRotation(for: view.videoPreviewLayer)

        return view
    }

    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        uiView.onCropFraction = onCropFraction
        updateRotation(for: uiView.videoPreviewLayer)
    }

    private func updateRotation(for layer: AVCaptureVideoPreviewLayer) {
        // The app is locked to portrait (see AppDelegate), so the preview is
        // always portrait — 90°. Capture orientation is handled separately by
        // AVCaptureDevice.RotationCoordinator in CameraService.
        let angle: CGFloat = 90

        if layer.connection?.isVideoRotationAngleSupported(angle) == true {
            layer.connection?.videoRotationAngle = angle
        }
    }
}
