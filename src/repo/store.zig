//! Disk-backed bare-repo registry. Repos live on disk under `root/<name>.git`
//! and are opened on demand via libgit2 (GIT_REPOSITORY_INIT_MKPATH).

const std = @import("std");
const Allocator = std.mem.Allocator;

const git = @import("../git/lib.zig");

pub const ResolveError = error{
    InvalidPath,
    NotFound,
    OutOfMemory,
    Libgit2,
};

pub const Store = struct {
    gpa: Allocator,
    root: []const u8,

    pub fn init(gpa: Allocator, root: []const u8) Store {
        return .{ .gpa = gpa, .root = root };
    }

    pub fn deinit(_: *Store) void {}

    /// Open an existing repo identified by `url_path` (witout .git suffix).
    pub fn open(self: *Store, arena: Allocator, url_path: []const u8) ResolveError!Handle {
        const canonical = try canonicalize(arena, url_path);
        const fs_path = try self.repoPath(arena, canonical);

        const repo = git.Repository.openBare(fs_path) catch |err| return mapErr(err);
        return .{ .name = canonical, .fs_path = fs_path, .repo = repo };
    }
    pub fn openOrCreate(self: *Store, arena: Allocator, url_path: []const u8) ResolveError!Handle {
        const canonical = try canonicalize(arena, url_path);
        const fs_path = try self.repoPath(arena, canonical);

        const repo = git.Repository.openBare(fs_path) catch |open_err| switch (open_err) {
            git.Error.NotFound => blk: {
                std.log.info("creating repo: {s} at {s}", .{ canonical, fs_path });
                break :blk git.Repository.initBare(fs_path) catch |err| return mapErr(err);
            },
            else => return mapErr(open_err),
        };
        return .{ .name = canonical, .fs_path = fs_path, .repo = repo };
    }

    fn repoPath(self: *Store, arena: Allocator, canonical: []const u8) ResolveError![:0]const u8 {
        const dir = std.fmt.allocPrint(arena, "{s}.git", .{canonical}) catch return error.OutOfMemory;
        return std.fs.path.joinZ(arena, &.{ self.root, dir }) catch return error.OutOfMemory;
    }
};

/// Open repository handle. Caller must call `deinit` when done.
pub const Handle = struct {
    /// Canonical name (without `.git` suffix). Owned by request arena.
    name: []const u8,
    /// On-disk path to the bare repo. Owned by request arena.
    fs_path: [:0]const u8,
    repo: git.Repository,

    pub fn deinit(self: *Handle) void {
        self.repo.deinit();
    }
};

fn canonicalize(arena: Allocator, url_path: []const u8) ResolveError![]const u8 {
    try validate(url_path);
    const stripped = if (std.mem.endsWith(u8, url_path, ".git"))
        url_path[0 .. url_path.len - 4]
    else
        url_path;
    if (stripped.len == 0) return error.InvalidPath;
    return arena.dupe(u8, stripped) catch error.OutOfMemory;
}

fn validate(url_path: []const u8) ResolveError!void {
    if (url_path.len == 0) return error.InvalidPath;
    if (url_path[0] == '/') return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, url_path, 0) != null) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, url_path, '\\') != null) return error.InvalidPath;

    var it = std.mem.splitScalar(u8, url_path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, seg, "..")) return error.InvalidPath;
        if (std.mem.eql(u8, seg, ".")) return error.InvalidPath;
    }
}

fn mapErr(err: git.Error) ResolveError {
    return switch (err) {
        git.Error.NotFound => error.NotFound,
        git.Error.OutOfMemory => error.OutOfMemory,
        git.Error.InvalidArg => error.InvalidPath,
        else => error.Libgit2,
    };
}

test "validate rejects traversal" {
    try std.testing.expectError(error.InvalidPath, validate(""));
    try std.testing.expectError(error.InvalidPath, validate("/abs"));
    try std.testing.expectError(error.InvalidPath, validate(".."));
    try std.testing.expectError(error.InvalidPath, validate("a/../b"));
    try std.testing.expectError(error.InvalidPath, validate("a//b"));
    try std.testing.expectError(error.InvalidPath, validate("a/./b"));
    try std.testing.expectError(error.InvalidPath, validate("a\\b"));
    try validate("foo");
    try validate("foo.git");
    try validate("group/sub/foo.git");
}

test "canonicalize strips .git" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("foo", try canonicalize(arena, "foo"));
    try std.testing.expectEqualStrings("foo", try canonicalize(arena, "foo.git"));
    try std.testing.expectEqualStrings("group/sub/foo", try canonicalize(arena, "group/sub/foo.git"));
    try std.testing.expectError(error.InvalidPath, canonicalize(arena, ".git"));
}
