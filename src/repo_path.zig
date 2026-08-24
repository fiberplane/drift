const std = @import("std");

/// Repo-relative paths are drift's canonical identity: they are written to
/// `drift.lock`, printed in reports, and matched against `git ls-files` output.
/// Git speaks POSIX separators on every platform, while `std.Io.Dir.path`
/// speaks the host separator, so on Windows the two disagree and a doc
/// discovered as `docs/a.md` never matches a binding stored as `docs\a.md`.
///
/// Normalizing where a repo-relative path is produced keeps a lockfile written
/// on Windows byte-identical to one written on Linux.
const host_sep = std.Io.Dir.path.sep;

/// Rewrites host separators to `/` in place and returns the same buffer.
///
/// A no-op on POSIX hosts, where a backslash is a legal filename byte and must
/// be preserved.
pub fn normalize(path: []u8) []u8 {
    if (host_sep != '/') std.mem.replaceScalar(u8, path, host_sep, '/');
    return path;
}

test "normalize rewrites host separators only" {
    var already_posix = "docs/a.md".*;
    try std.testing.expectEqualStrings("docs/a.md", normalize(&already_posix));

    var host_form = ("docs" ++ std.Io.Dir.path.sep_str ++ "nested" ++ std.Io.Dir.path.sep_str ++ "a.md").*;
    try std.testing.expectEqualStrings("docs/nested/a.md", normalize(&host_form));
}
