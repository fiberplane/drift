const std = @import("std");

/// drift compares a working-tree file against a fingerprint recorded in
/// `drift.lock`, and that lockfile is shared by every platform that checks the
/// repo out. Git rewrites LF to CRLF in the working tree when `core.autocrlf`
/// is on — the Windows default — so the same commit yields different bytes on
/// different machines. Fingerprints would then track the checkout rather than
/// the content, and every anchor would read stale on Windows.
///
/// Reading CRLF as LF makes the fingerprint depend on content alone. Files that
/// are already LF-only come back byte-identical, so lockfiles written before
/// this normalization stay valid.
///
/// A lone CR (classic Mac line ending) is left alone: no tooling in this
/// pipeline produces it, and rewriting it would change fingerprints for repos
/// that genuinely contain one.
pub fn normalizeLineEndings(buf: []u8) []u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\r' and i + 1 < buf.len and buf[i + 1] == '\n') continue;
        buf[out] = buf[i];
        out += 1;
    }
    return buf[0..out];
}

test "normalizeLineEndings strips CR only before LF" {
    var crlf = "a\r\nb\r\n".*;
    try std.testing.expectEqualStrings("a\nb\n", normalizeLineEndings(&crlf));

    var lf = "a\nb\n".*;
    try std.testing.expectEqualStrings("a\nb\n", normalizeLineEndings(&lf));

    var lone_cr = "a\rb".*;
    try std.testing.expectEqualStrings("a\rb", normalizeLineEndings(&lone_cr));

    var trailing_cr = "a\r".*;
    try std.testing.expectEqualStrings("a\r", normalizeLineEndings(&trailing_cr));
}

test "normalizeLineEndings makes CRLF and LF sources hash alike" {
    var crlf = "const a = 1;\r\n// note\r\n".*;
    var lf = "const a = 1;\n// note\n".*;
    try std.testing.expectEqualStrings(
        normalizeLineEndings(&lf),
        normalizeLineEndings(&crlf),
    );
}
