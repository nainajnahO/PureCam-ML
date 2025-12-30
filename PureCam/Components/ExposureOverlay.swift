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