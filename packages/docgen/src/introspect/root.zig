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

//! `kw-introspect` — the generic, pluggable introspection UI core.
//!
//! `Assemble` merges per-kind introspection backends (e.g. `kw-introspect--http`) into one
//! kind-keyed set of routes the consumer splats into each driver. The generic driver chrome
//! (list, page, icons, JSON render) lives here; protocol-specific browsers live in backends.
//! Runtime-only: depends on the generated `kw-gen--docs` manifest, injected by the consumer's
//! build — never imported by the build-time `kw-docgen` codegen tool.

const assemble = @import("assemble.zig");

/// The opinionated, hardcoded introspection mount (a `.private` HTTP driver serving the UI).
pub const Mount = @import("private_mount.zig").Mount;
pub const MountWith = @import("private_mount.zig").MountWith;
pub const security = @import("security.zig");

pub const Assemble = assemble.Assemble;
pub const Entry = assemble.Entry;
pub const Build = assemble.Build;
pub const collect = assemble.collect;
pub const build = assemble.build;
