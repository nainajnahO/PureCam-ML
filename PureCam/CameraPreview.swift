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
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let orientation = windowScene.effectiveGeometry.interfaceOrientation
        
        // Map UI orientation to the required camera rotation angle (standard for Back Camera)
        let angle: CGFloat = switch orientation {
        case .portrait: 90
        case .portraitUpsideDown: 270
        case .landscapeLeft: 180 // Home button left
        case .landscapeRight: 0  // Home button right
        default: 90
        }
        
        if layer.connection?.isVideoRotationAngleSupported(angle) == true {
            layer.connection?.videoRotationAngle = angle
        }
    }
}
