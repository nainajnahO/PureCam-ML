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

struct CameraFeedView: View {
    let cameraService: CameraService
    let showRAWPreview: Bool
    let rawPreviewImage: UIImage?
    let deviceOrientation: UIDeviceOrientation

    var body: some View {
        if cameraService.status == .configured {
            GeometryReader { geometry in
                ZStack {
                    CameraPreview(session: cameraService.session)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(showRAWPreview ? 0 : 1)

                    if showRAWPreview, let previewImage = rawPreviewImage {
                        let rotation = rotationAngle(for: deviceOrientation)
                        let isLandscape = abs(rotation.degrees) == 90

                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: isLandscape ? geometry.size.height : geometry.size.width,
                                height: isLandscape ? geometry.size.width : geometry.size.height
                            )
                            .rotationEffect(rotation)
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

    /// Calculate rotation angle for RAW preview based on device orientation
    private func rotationAngle(for orientation: UIDeviceOrientation) -> Angle {
        switch orientation {
        case .portrait:
            return .degrees(0)
        case .portraitUpsideDown:
            return .degrees(180)
        case .landscapeLeft:
            return .degrees(90)
        case .landscapeRight:
            return .degrees(-90)
        default:
            return .degrees(0)
        }
    }
}
