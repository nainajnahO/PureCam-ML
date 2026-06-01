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

struct UIConstants {
    // Global UI scale factor - adjust this single value to resize entire interface
    static let globalScale: CGFloat = 1.5  // 1.0 = baseline, >1.0 = larger, <1.0 = smaller

    // Calculate responsive button sizes based on screen dimensions
    static func buttonSizes(for geometry: GeometryProxy) -> ButtonSizes {
        // Uses harmonic mean of width and height
        let screenDimension = (2 * geometry.size.width * geometry.size.height) /
                             (geometry.size.width + geometry.size.height)
        let captureButtonSize: CGFloat = screenDimension * 0.15 * globalScale
        let captureButtonVisualSize = captureButtonSize * 0.75
        let previewButtonSize: CGFloat = captureButtonSize * 0.2

        // Control dot sizing (relative to button size)
        let dotSize: CGFloat = captureButtonSize * 0.067  // ~8pt on standard iPhone
        let isoRingRadius = captureButtonSize * 0.3       // Inner ring
        let shutterRingRadius = captureButtonSize * 0.433 // Outer ring
        let isoZoneRadius = captureButtonSize * 0.35      // Threshold between ISO and shutter zones

        return ButtonSizes(
            captureButtonSize: captureButtonSize,
            captureButtonVisualSize: captureButtonVisualSize,
            previewButtonSize: previewButtonSize,
            dotSize: dotSize,
            isoRingRadius: isoRingRadius,
            shutterRingRadius: shutterRingRadius,
            isoZoneRadius: isoZoneRadius
        )
    }

    // Calculate button positions
    static func buttonPositions(for geometry: GeometryProxy) -> ButtonPositions {
        let captureX = geometry.size.width * 1 / 2
        let buttonSpacing = geometry.size.width * 0.19
        let previewX = captureX + buttonSpacing
        let bottomMargin = geometry.size.height * 0.12
        let buttonY = geometry.size.height - bottomMargin

        return ButtonPositions(
            captureX: captureX,
            previewX: previewX,
            buttonY: buttonY
        )
    }

    // Calculate text positioning
    static func textPosition(
        captureX: CGFloat,
        buttonY: CGFloat,
        captureButtonSize: CGFloat,
        deviceOrientation: UIDeviceOrientation
    ) -> CGPoint {
        let isLandscape = deviceOrientation.isLandscape
        let textY = buttonY - (captureButtonSize * (isLandscape ? 0.8 : 0.6))
        return CGPoint(x: captureX, y: textY)
    }
}

struct ButtonSizes {
    let captureButtonSize: CGFloat
    let captureButtonVisualSize: CGFloat
    let previewButtonSize: CGFloat
    let dotSize: CGFloat
    let isoRingRadius: CGFloat
    let shutterRingRadius: CGFloat
    let isoZoneRadius: CGFloat
}

struct ButtonPositions {
    let captureX: CGFloat
    let previewX: CGFloat
    let buttonY: CGFloat
}
