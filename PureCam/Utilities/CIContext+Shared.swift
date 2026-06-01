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

import CoreImage

extension CIContext {
    /// Single shared, GPU-backed CIContext for the whole app.
    ///
    /// A CIContext is expensive to create and is designed to be reused, so we
    /// build one here and share it across the preview pipeline and the ML
    /// feature extractor instead of allocating a new context per call.
    static let shared = CIContext(options: [.useSoftwareRenderer: false])
}
