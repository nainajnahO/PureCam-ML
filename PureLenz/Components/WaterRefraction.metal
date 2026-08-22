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

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/// Refracts the viewfinder through a water surface, as a `distortionEffect`.
///
/// The surface itself lives on the CPU (`WaterSurface`), which simulates the
/// wave equation and ships its *slope* here, one (∂h/∂x, ∂h/∂y) pair per grid
/// cell. Water refracts by slope, not by height: a flat patch, however deep,
/// shows the bottom where it is, and a tilted one shifts it sideways. So each
/// destination pixel is sampled from `position` shifted along the local slope,
/// and the scene bends exactly where the surface tilts.
///
/// The slope comes as a float array rather than a texture on purpose: an image
/// argument goes through SwiftUI's colour pipeline, which on device decoded the
/// bytes as sRGB and turned "flat" into a constant sideways shift. Floats are
/// passed through untouched, and a bilinear blend between the four nearest
/// cells is all the smoothing the sampler would have done anyway.
///
/// - Parameters:
///   - position: Destination pixel, in the view's own points.
///   - slopes: `count` floats: `gridCells.x * gridCells.y` pairs, row-major,
///     already normalised to ±1 by `WaterSurface` (see `WaterTuning.maxSlope`).
///   - bounds: `boundingRect` of the view the effect is attached to.
///   - gridCells: Grid dimensions in cells.
///   - cellSize: Cell pitch in points. Cell `(x, y)` is centred at
///     `((x + 0.5), (y + 0.5)) * cellSize`.
///   - strength: Sample offset, in points, per unit of slope. The CPU clamps
///     slopes to ±1, so this also bounds `maxSampleOffset`.
[[ stitchable ]] float2 waterRefraction(
    float2 position,
    device const float *slopes,
    int count,
    float4 bounds,
    float2 gridCells,
    float cellSize,
    float strength
) {
    int w = int(gridCells.x);
    int h = int(gridCells.y);
    float2 f = (position - bounds.xy) / cellSize - 0.5;
    int2 c0 = int2(floor(f));
    float2 t = f - float2(c0);
    int x0 = clamp(c0.x, 0, w - 1), x1 = clamp(c0.x + 1, 0, w - 1);
    int y0 = clamp(c0.y, 0, h - 1), y1 = clamp(c0.y + 1, 0, h - 1);

    float2 s00 = float2(slopes[(y0 * w + x0) * 2], slopes[(y0 * w + x0) * 2 + 1]);
    float2 s10 = float2(slopes[(y0 * w + x1) * 2], slopes[(y0 * w + x1) * 2 + 1]);
    float2 s01 = float2(slopes[(y1 * w + x0) * 2], slopes[(y1 * w + x0) * 2 + 1]);
    float2 s11 = float2(slopes[(y1 * w + x1) * 2], slopes[(y1 * w + x1) * 2 + 1]);
    float2 g = mix(mix(s00, s10, t.x), mix(s01, s11, t.x), t.y);

    return position + strength * g;
}
