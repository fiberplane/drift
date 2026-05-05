test {
    _ = @import("src/main.zig");
    _ = @import("src/lockfile.zig");
    _ = @import("test/payload_validate_test.zig");

    // Integration tests
    _ = @import("test/integration/lint_test.zig");
    _ = @import("test/integration/status_test.zig");
    _ = @import("test/integration/link_test.zig");
    _ = @import("test/integration/unlink_test.zig");
    _ = @import("test/integration/refs_test.zig");

    // Property tests
    _ = @import("test/property/smoke_test.zig");
    _ = @import("test/property/lockfile_reorder_test.zig");
}
