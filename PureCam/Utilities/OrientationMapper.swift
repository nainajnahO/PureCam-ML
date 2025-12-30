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

import UIKit

/// Utility for mapping device/interface orientation to camera rotation angles
/// Consolidates orientation handling across the app
enum OrientationMapper {
    /// Map UIDeviceOrientation to camera rotation angle
    /// Used by CameraService for video output rotation
    /// - Parameter orientation: The device's physical orientation
    /// - Returns: Rotation angle in degrees, or nil if orientation should not trigger a change
    static func rotationAngle(for orientation: UIDeviceOrientation) -> CGFloat? {
        switch orientation {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeLeft:      // Device tilted left → home button on RIGHT
            return 0
        case .landscapeRight:     // Device tilted right → home button on LEFT
            return 180
        default:
            return nil  // Keep existing rotation for unknown/flat/faceUp/faceDown
        }
    }

    /// Map UIInterfaceOrientation to camera rotation angle
    /// Used by CameraPreview for preview layer rotation
    /// - Parameter orientation: The interface orientation from window scene
    /// - Returns: Rotation angle in degrees
    static func rotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeLeft:      // Interface left → home button on LEFT
            return 180
        case .landscapeRight:     // Interface right → home button on RIGHT
            return 0
        default:
            return 90  // Default to portrait
        }
    }
}
