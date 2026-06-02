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
    }
    
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> VideoPreviewView {
        let view = VideoPreviewView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        updateRotation(for: view.videoPreviewLayer)
        
        return view
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
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
