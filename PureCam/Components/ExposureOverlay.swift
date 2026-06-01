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

struct ExposureOverlay: View {
    let activeControl: ExposureControl?
    let currentISO: Float
    let currentShutterSpeed: Double
    let deviceOrientation: UIDeviceOrientation

    private var exposureText: String {
        guard let active = activeControl else { return "" }
        switch active {
        case .iso:
            return String(format: "ISO: %.0f", currentISO)
        case .shutter:
            let shutterFraction = 1.0 / currentShutterSpeed
            return String(format: "Shutter Speed: 1/%.0f", shutterFraction)
        }
    }

    private var exposureTextColor: Color {
        guard let active = activeControl else { return .white }
        return active == .iso ? .white : .yellow
    }

    private var textRotation: Angle {
        switch deviceOrientation {
        case .landscapeLeft:
            return .degrees(90)
        case .landscapeRight:
            return .degrees(-90)
        default:
            return .degrees(0)
        }
    }

    var body: some View {
        if let active = activeControl {
            let isLandscape = deviceOrientation.isLandscape

            Group {
                if isLandscape {
                    // Landscape: stack vertically (prefix on top)
                    VStack(spacing: 2) {
                        switch active {
                        case .iso:
                            Text("ISO:")
                            Text(String(format: "%.0f", currentISO))
                        case .shutter:
                            Text("Shutter:")
                            let shutterFraction = 1.0 / currentShutterSpeed
                            Text(String(format: "1/%.0f", shutterFraction))
                        }
                    }
                } else {
                    // Portrait: horizontal text
                    Text(exposureText)
                }
            }
            .font(.system(size: 18, weight: .medium, design: .monospaced))
            .foregroundStyle(exposureTextColor)
            .rotationEffect(textRotation)
            .allowsHitTesting(false)
        }
    }
}
