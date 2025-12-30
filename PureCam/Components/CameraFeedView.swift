import SwiftUI

struct CameraFeedView: View {
    let cameraService: CameraService
    let showRAWPreview: Bool
    let rawPreviewImage: UIImage?

    var body: some View {
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
    }
}