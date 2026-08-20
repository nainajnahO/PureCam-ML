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

extension View {
    /// Shows this view through `surface`, as if it were the bottom of a pool.
    /// Applied to the app-drawn copy of the viewfinder — see `WaterRefraction`.
    func waterRefraction(surface: WaterSurface) -> some View {
        modifier(WaterRefraction(surface: surface))
    }
}

/// Refracts the viewfinder through `WaterSurface` (`WaterRefraction.metal`)
/// and floats the dot matrix on top of it.
///
/// The shader displaces where each pixel is *sampled from*, so the scene itself
/// bends rather than having anything drawn over it — a picture of what the
/// hardware is doing, since a lens is curved glass and it is refocusing.
///
/// **Why this is applied to a copy and not the viewfinder.** A shader effect
/// needs SwiftUI to rasterize the view it is attached to. The live viewfinder is
/// an `AVCaptureVideoPreviewLayer` inside a `UIViewRepresentable` — a video pane
/// the system paints straight to the screen, whose pixels SwiftUI's renderer
/// never has. Attaching a shader to it replaced the whole preview with SwiftUI's
/// unavailable-view placeholder. So for as long as the water moves the app
/// draws the camera itself and distorts what it draws. See
/// `CameraViewModel.focusTouch`.
///
/// Only this modifier reads `surface.field`, which changes every display
/// frame, so the per-frame re-evaluation stops here and never reaches the view
/// that owns the copy.
struct WaterRefraction: ViewModifier {
    let surface: WaterSurface

    func body(content: Content) -> some View {
        let field = surface.field
        content
            .distortionEffect(
                ShaderLibrary.waterRefraction(
                    .floatArray(field.slopes),
                    .boundingRect,
                    .float2(Float(field.cellsWide), Float(field.cellsHigh)),
                    .float(Float(WaterTuning.cellSize)),
                    .float(Float(WaterTuning.strength))
                ),
                maxSampleOffset: CGSize(width: WaterTuning.strength, height: WaterTuning.strength),
                // Off at rest, so the copy is never shown through an idle shader pass.
                isEnabled: !surface.isCalm
            )
            // The dot matrix stays *outside* the warp — the distortion pass
            // clamps extended-range colour to SDR, so the dots displace
            // themselves with the same surface instead (see `RippleDotMatrix`).
            .overlay {
                if !surface.isCalm {
                    RippleDotMatrix(field: field)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// The halftone sheen on the water: a fixed mesh of HDR-white dots over the
/// whole viewfinder, lit only where the finger is or has just been, each dot
/// carried by the wave under it.
///
/// The mesh does not follow the finger — water does not. What moves is the
/// light: the surface keeps the finger's trace (`WaterField.trace`), rising
/// under the contact and fading once it has passed, so a drag leaves a glowing
/// tail and the lift point keeps its dots lit until the lens lands. Dots the trace
/// has not reached are not drawn at all, which is what keeps an 8,000-dot mesh
/// cheap: only the lit patch is ever filled.
///
/// **Why the dots move themselves instead of sitting under the warp.** Running
/// them through the shader would keep them in lockstep with the scene for
/// free — but the distortion pass rasterizes what it wraps and clamps
/// extended-range colour to SDR (verified on device: the same dots glow outside
/// the warp and go flat inside it). Dots are discrete objects, so they don't
/// need the shader: each frame this view asks the field for the sample offset
/// at every lit dot's rest position — the same array, the same bilinear blend
/// the shader uses — and draws it already-moved, in a plain SwiftUI layer the
/// renderer keeps in extended range.
///
/// The field is captured as a value in the view, not read inside the drawing
/// closure: that is what makes the body depend on it, so a new field each
/// display frame means a new drawing each display frame.
///
/// The glow is per-dot alpha rather than a `.mask` layer: every extra
/// compositing layer is another place the extended-range white could get
/// silently clamped to SDR.
private struct RippleDotMatrix: View {
    let field: WaterField

    /// Grid pitch, in points.
    private static let spacing: CGFloat = 7
    private static let dotDiameter: CGFloat = 2
    /// White pushed two stops past SDR white. `headroom(_:)` annotates the
    /// extended-range components so the renderer raises display headroom (or
    /// tone-maps) instead of clamping.
    private static let hdrWhite = Color(.sRGBLinear, red: 4, green: 4, blue: 4)
        .headroom(4)
    /// Below this a dot is invisible even as a two-stops-up white.
    private static let visible: Double = 1 / 255

    var body: some View {
        Canvas { context, size in
            let columns = Int(size.width / Self.spacing)
            let rows = Int(size.height / Self.spacing)

            for row in 0...rows {
                for col in 0...columns {
                    let rest = CGPoint(
                        x: (CGFloat(col) + 0.5) * Self.spacing,
                        y: (CGFloat(row) + 0.5) * Self.spacing
                    )
                    let glow = field.glow(at: rest)
                    guard glow > Self.visible else { continue }

                    // The shader moves where a pixel is *sampled from*, which
                    // moves the visible content the opposite way. The dots are
                    // content, so they take the negative.
                    let offset = field.displacement(at: rest)
                    let rect = CGRect(
                        x: rest.x - offset.dx - Self.dotDiameter / 2,
                        y: rest.y - offset.dy - Self.dotDiameter / 2,
                        width: Self.dotDiameter,
                        height: Self.dotDiameter
                    )
                    // Glow via the context's compositing alpha, not
                    // `Color.opacity`, so the colour value handed to the
                    // renderer — extended components and headroom annotation —
                    // is never rebuilt along the way.
                    context.opacity = glow
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(Self.hdrWhite)
                    )
                }
            }
        }
    }
}
