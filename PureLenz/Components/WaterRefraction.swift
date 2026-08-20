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
/// Only this modifier reads `surface.slopes`, which changes every display
/// frame, so the per-frame re-evaluation stops here and never reaches the view
/// that owns the copy.
struct WaterRefraction: ViewModifier {
    let surface: WaterSurface

    func body(content: Content) -> some View {
        content
            .distortionEffect(
                ShaderLibrary.waterRefraction(
                    .floatArray(surface.slopes),
                    .boundingRect,
                    .float2(Float(surface.cellsWide), Float(surface.cellsHigh)),
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
                if let contact = surface.contactPoint {
                    RippleDotMatrix(surface: surface, center: contact)
                        .position(contact)
                        .opacity(surface.pressed ? 1 : 0)
                        // Fast in: a quick lens can settle in well under a
                        // second, and the extended-range glow only registers if
                        // the dots are at full strength for most of that.
                        .animation(.easeOut(duration: surface.pressed ? 0.15 : 0.32), value: surface.pressed)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// The halftone sheen on the dent: a fine grid of HDR-white dots centred on
/// the finger, fully lit over the dent and faded out past where it dies.
///
/// **Why the dots move themselves instead of sitting under the warp.** Running
/// them through the shader would keep them in lockstep with the scene for
/// free — but the distortion pass rasterizes what it wraps and clamps
/// extended-range colour to SDR (verified on device: the same dots glow outside
/// the warp and go flat inside it). Dots are discrete objects, so they don't
/// need the shader: each frame this view asks the surface for the sample offset
/// at every dot's rest position — the same array, the same bilinear blend the
/// shader uses — and draws it already-moved, in a plain SwiftUI layer the
/// renderer keeps in extended range.
///
/// Drawn inside a `TimelineView` because a `Canvas` closure does not reliably
/// register what it reads as a dependency; the timeline redraws it every frame
/// while the surface moves and not at all once it is calm.
///
/// The edge fade is per-dot alpha rather than a `.mask` layer: every extra
/// compositing layer is another place the extended-range white could get
/// silently clamped to SDR.
private struct RippleDotMatrix: View {
    let surface: WaterSurface
    /// The dent's position in the view the surface covers; dots sample the
    /// surface relative to this.
    let center: CGPoint

    /// Grid pitch, in points.
    private static let spacing: CGFloat = 7
    private static let dotDiameter: CGFloat = 2
    /// Brightness decays exponentially from the centre; ~63% is gone by this
    /// distance, halved every ~36pt. Judged on device: 45 died too hard, 60
    /// reached too far.
    private static let falloff: CGFloat = 52
    /// Grid extent, and where the fade lands on exactly zero. The exponential
    /// alone never reaches zero — and a few percent of a two-stops-up white is
    /// still visible — so the last stretch is windowed down to nothing (see
    /// `fade`) instead of cut.
    private static let fadeEnd: CGFloat = 150
    /// Where that closing window starts.
    private static let windowStart: CGFloat = 90
    /// White pushed two stops past SDR white. `headroom(_:)` annotates the
    /// extended-range components so the renderer raises display headroom (or
    /// tone-maps) instead of clamping.
    private static let hdrWhite = Color(.sRGBLinear, red: 4, green: 4, blue: 4)
        .headroom(4)

    var body: some View {
        TimelineView(.animation(paused: surface.isCalm)) { _ in
            Canvas { context, size in
                let local = CGPoint(x: size.width / 2, y: size.height / 2)
                let steps = Int(Self.fadeEnd / Self.spacing)

                for row in -steps...steps {
                    for col in -steps...steps {
                        let dx = CGFloat(col) * Self.spacing
                        let dy = CGFloat(row) * Self.spacing
                        // Fade uses the dot's rest position, so the fade circle
                        // stays put while the dots move.
                        let dist = hypot(dx, dy)
                        guard dist < Self.fadeEnd else { continue }

                        let t = max(0, (dist - Self.windowStart) / (Self.fadeEnd - Self.windowStart))
                        let window = 1 - t * t * (3 - 2 * t)
                        let fade = exp(-dist / Self.falloff) * window

                        // The shader moves where a pixel is *sampled from*,
                        // which moves the visible content the opposite way.
                        // The dots are content, so they take the negative.
                        let offset = surface.displacement(
                            at: CGPoint(x: center.x + dx, y: center.y + dy)
                        )
                        let rect = CGRect(
                            x: local.x + dx - offset.dx - Self.dotDiameter / 2,
                            y: local.y + dy - offset.dy - Self.dotDiameter / 2,
                            width: Self.dotDiameter,
                            height: Self.dotDiameter
                        )
                        // Fade via the context's compositing alpha, not
                        // `Color.opacity`, so the colour value handed to the
                        // renderer — extended components and headroom annotation —
                        // is never rebuilt along the way.
                        context.opacity = fade
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(Self.hdrWhite)
                        )
                    }
                }
            }
        }
        .frame(width: Self.fadeEnd * 2, height: Self.fadeEnd * 2)
    }
}
