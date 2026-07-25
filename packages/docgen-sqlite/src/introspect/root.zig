// This file is part of the kwatcher project.
//
// Copyright (C) 2025-2026 Borislav Atanasov
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, version 3 of the License only.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

//! `kw-introspect--sqlite` — the sqlite introspection backend.
//!
//! A plugin for `kw-introspect`'s `Assemble`: it declares the driver kind it documents, an
//! embedded default icon for that kind, and a `generate` that returns the sqlite
//! queries/tables/console/migrations routes (already template-wrapped).

const routes = @import("routes.zig");

/// The driver kind this backend documents.
pub const introspected_kind: []const u8 = "sqlite";

/// Embedded default icon for the sqlite kind (consumer `static/icons/sqlite/<key>.svg` overrides).
pub const icon: []const u8 = @embedFile("assets/sqlite.svg");

/// Kind-level route generator
pub const generate = routes.generate;
