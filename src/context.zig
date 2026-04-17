const std = @import("std");

/// Per-command memory scope: `run` owns command-lifetime data; `scratch` holds
/// loop-local temporaries and is reset between iterations (see docs/DECISIONS.md).
pub const CommandContext = struct {
    io: std.Io,
    run_arena: std.mem.Allocator,
    scratch_arena: *std.heap.ArenaAllocator,

    pub fn scratch(self: CommandContext) std.mem.Allocator {
        return self.scratch_arena.allocator();
    }

    pub fn resetScratch(self: CommandContext) void {
        _ = self.scratch_arena.reset(.retain_capacity);
    }
};
