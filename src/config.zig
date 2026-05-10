const std = @import("std");

pub const Config = struct {
    port: u16 = 8080,
    /// Filesystem directory under which bare repos are stored.
    repo_root: []const u8 = "repos",

    pub const ParseError = error{
        MissingValue,
        UnknownArgument,
        HelpRequested,
    } || std.fmt.ParseIntError;

    pub fn fromArgs(args: []const []const u8) ParseError!Config {
        var cfg: Config = .{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (eq(arg, "--port") or eq(arg, "-p")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                cfg.port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (eq(arg, "--repo-root") or eq(arg, "-r")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                cfg.repo_root = args[i];
            } else if (eq(arg, "--help") or eq(arg, "-h")) {
                return error.HelpRequested;
            } else {
                return error.UnknownArgument;
            }
        }
        return cfg;
    }

    pub fn printUsage(w: *std.Io.Writer, prog: []const u8) std.Io.Writer.Error!void {
        try w.print(
            \\usage: {s} [options]
            \\
            \\options:
            \\  -p, --port <port>          listen port (default 8080)
            \\  -r, --repo-root <dir>      directory holding bare repos (default ./repos)
            \\  -h, --help                 show this help
            \\
            \\repos are stored on disk under <repo-root>/<name>.git and auto-created
            \\on first push.
            \\
        , .{prog});
    }
};

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "fromArgs defaults" {
    const args = [_][]const u8{"gitblob"};
    const cfg = try Config.fromArgs(&args);
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqualStrings("repos", cfg.repo_root);
}

test "fromArgs port" {
    const args = [_][]const u8{ "gitblob", "--port", "9000" };
    const cfg = try Config.fromArgs(&args);
    try std.testing.expectEqual(@as(u16, 9000), cfg.port);
}

test "fromArgs repo-root" {
    const args = [_][]const u8{ "gitblob", "--repo-root", "/var/lib/gitblob" };
    const cfg = try Config.fromArgs(&args);
    try std.testing.expectEqualStrings("/var/lib/gitblob", cfg.repo_root);
}

test "fromArgs unknown arg" {
    const args = [_][]const u8{ "gitblob", "--bogus" };
    try std.testing.expectError(error.UnknownArgument, Config.fromArgs(&args));
}
