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
/// this normalization stay valid for them; a text file whose committed bytes
/// genuinely contain CRLF re-fingerprints once and needs a relink.
///
/// Content that looks binary is left untouched: autocrlf never rewrites
/// binaries, so their bytes already match across platforms — and collapsing
/// CRLF there would make a CR-only difference invisible to the raw-byte
/// fallback hash.
///
/// A lone CR (classic Mac line ending) is left alone: no tooling in this
/// pipeline produces it, and rewriting it would change fingerprints for repos
/// that genuinely contain one.
pub fn normalizeLineEndings(buf: []u8) []u8 {
    if (looksBinary(buf)) return buf;
    const first_cr = std.mem.indexOfScalar(u8, buf, '\r') orelse return buf;
    var out: usize = first_cr;
    var i: usize = first_cr;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\r' and i + 1 < buf.len and buf[i + 1] == '\n') continue;
        buf[out] = buf[i];
        out += 1;
    }
    return buf[0..out];
}

/// Git's heuristic: a NUL byte in the first 8000 bytes marks content binary.
fn looksBinary(buf: []const u8) bool {
    const window = buf[0..@min(buf.len, 8000)];
    return std.mem.indexOfScalar(u8, window, 0) != null;
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

test "normalizeLineEndings leaves binary content untouched" {
    // A NUL byte marks the buffer binary; the CRLF must survive so the
    // raw-byte fallback hash can still see a CR-only change.
    var binary = "PK\x00\x03header\r\npayload".*;
    try std.testing.expectEqualStrings("PK\x00\x03header\r\npayload", normalizeLineEndings(&binary));

    // NUL past the 8000-byte window does not mark the buffer binary.
    var big: [8002]u8 = @splat('a');
    big[8000] = 0;
    big[0] = '\r';
    big[1] = '\n';
    const normalized = normalizeLineEndings(&big);
    try std.testing.expectEqual(@as(usize, 8001), normalized.len);
    try std.testing.expectEqual(@as(u8, '\n'), normalized[0]);
}
