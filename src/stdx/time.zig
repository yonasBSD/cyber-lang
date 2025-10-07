const std = @import("std");
const builtin = @import("builtin");

const time_wasm = @import("time_wasm.zig");
const IsWasm = builtin.target.cpu.arch.isWasm() and builtin.os.tag != .wasi;

pub usingnamespace if (IsWasm) struct {
    pub const Timer = time_wasm.Timer;
} else struct {
    pub const Timer = std.time.Timer;
};

pub const Duration = struct {
    const Self = @This();

    ns: u64,

    pub fn initSecsF(secs: f32) Self {
        return .{
            .ns = @intFromFloat(secs * 1e9),
        };
    }

    pub fn toMillis(self: Self) u32 {
        return @intCast(self.ns / 1000000);
    }
};

pub fn getMilliTimestamp() i64 {
    if (IsWasm) {
        return time_wasm.getMilliTimestamp();
    } else {
        return std.time.milliTimestamp();
    }
}
