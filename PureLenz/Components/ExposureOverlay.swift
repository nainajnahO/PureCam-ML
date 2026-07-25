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

struct ExposureOverlay: View {
    let activeControl: ExposureControl?
    let currentISO: Float
    let currentShutterSpeed: Double
    let deviceOrientation: UIDeviceOrientation

    /// The formatted current value for the active control, shared by the
    /// portrait and landscape layouts so the number can't drift between them.
    /// Deliberately String(format:) rather than a locale-aware FormatStyle:
    /// the HUD is a fixed-format monospaced readout.
    private var valueText: String {
        guard let active = activeControl else { return "" }
        switch active {
        case .iso:
            return String(format: "%.0f", currentISO)
        case .shutter:
            return String(format: "1/%.0f", 1.0 / currentShutterSpeed)
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
        case .portraitUpsideDown:
            return .degrees(180)
        default:
            return .degrees(0)
        }
    }

    var body: some View {
        if let active = activeControl {
            Group {
                if deviceOrientation.isLandscape {
                    // Landscape: stack vertically (short prefix on top)
                    VStack(spacing: 2) {
                        Text(active == .iso ? "ISO:" : "Shutter:")
                        Text(valueText)
                    }
                } else {
                    // Portrait: horizontal text
                    Text(active == .iso ? "ISO: \(valueText)" : "Shutter Speed: \(valueText)")
                }
            }
            .font(.system(size: 18, weight: .medium, design: .monospaced))
            .foregroundStyle(exposureTextColor)
            .rotationEffect(textRotation)
            .allowsHitTesting(false)
        }
    }
}
