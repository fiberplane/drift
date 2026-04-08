test {
    _ = @import("src/main.zig");
    _ = @import("test/payload_validate_test.zig");

    // Integration tests
    _ = @import("test/integration/lint_test.zig");
    _ = @import("test/integration/status_test.zig");
    _ = @import("test/integration/link_test.zig");
    _ = @import("test/integration/unlink_test.zig");
}
