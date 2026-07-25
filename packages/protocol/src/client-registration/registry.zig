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

const ClientRegistry = @This();
const schema = @import("kw-core").schema;
const RegistrationState = @import("kw-cr-schema").kwatcher.protocol.client_registration.RegistrationState;

state: RegistrationState = .unregistered,
assigned_id: ?[]const u8,

pub fn id(self: *const ClientRegistry, client: schema.ClientInfo) []const u8 {
    if (self.assigned_id) |aid| {
        return aid;
    } else {
        return client.id;
    }
}
