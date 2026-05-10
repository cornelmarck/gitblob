//! Thin Zig wrapper around libgit2. Owns process-wide init/shutdown and
//! exposes a small Repository/Oid surface for the bits we use server-side.

const std = @import("std");
const c = @import("c.zig").c;

pub const oid_hex_len = 40;
pub const ZeroOid: Oid = .{ .raw = std.mem.zeroes(c.git_oid) };

pub const Error = error{
    Libgit2,
    NotFound,
    Exists,
    InvalidArg,
    OutOfMemory,
};

/// Pull libgit2's last error (thread-local) into the log and map to a Zig
/// error. Always returns an error — callers use it as `return mapErr(rc)`.
pub fn mapErr(rc: c_int) Error {
    const klass: c_int = -1;
    _ = klass;
    const e = c.git_error_last();
    const msg: []const u8 = if (e != null and e.*.message != null)
        std.mem.sliceTo(e.*.message, 0)
    else
        "(no message)";
    std.log.warn("libgit2 error rc={d}: {s}", .{ rc, msg });

    return switch (rc) {
        c.GIT_ENOTFOUND => Error.NotFound,
        c.GIT_EEXISTS => Error.Exists,
        c.GIT_EINVALIDSPEC, c.GIT_EAMBIGUOUS => Error.InvalidArg,
        else => Error.Libgit2,
    };
}

pub fn init() Error!void {
    const rc = c.git_libgit2_init();
    if (rc < 0) return mapErr(rc);
}

pub fn shutdown() void {
    _ = c.git_libgit2_shutdown();
}

pub const Oid = struct {
    raw: c.git_oid,

    pub fn fromHex(hex: []const u8) Error!Oid {
        if (hex.len != oid_hex_len) return Error.InvalidArg;
        var oid: c.git_oid = undefined;
        const rc = c.git_oid_fromstrn(&oid, hex.ptr, hex.len);
        if (rc < 0) return mapErr(rc);
        return .{ .raw = oid };
    }

    pub fn toHex(self: Oid, out: *[oid_hex_len]u8) void {
        _ = c.git_oid_tostr(out, oid_hex_len + 1, &self.raw);
    }

    /// Hex string suitable for embedding in pkt-lines. Buffer is owned by
    /// the caller and must outlive the slice.
    pub fn hexBuf(self: Oid, buf: *[oid_hex_len]u8) []const u8 {
        self.toHex(buf);
        return buf[0..oid_hex_len];
    }

    pub fn isZero(self: Oid) bool {
        for (self.raw.id) |b| if (b != 0) return false;
        return true;
    }

    pub fn equal(a: Oid, b: Oid) bool {
        return c.git_oid_cmp(&a.raw, &b.raw) == 0;
    }
};

pub const Repository = struct {
    raw: *c.git_repository,

    /// Open an existing bare repo. NotFound if the directory isn't one.
    pub fn openBare(path_z: [:0]const u8) Error!Repository {
        var raw: ?*c.git_repository = null;
        const rc = c.git_repository_open_bare(&raw, path_z.ptr);
        if (rc < 0) return mapErr(rc);
        return .{ .raw = raw.? };
    }

    /// Initialize a bare repo at `path_z`, creating parent directories.
    /// HEAD is set to refs/heads/main (consistent with modern git defaults).
    pub fn initBare(path_z: [:0]const u8) Error!Repository {
        var opts: c.git_repository_init_options = undefined;
        const init_rc = c.git_repository_init_options_init(
            &opts,
            c.GIT_REPOSITORY_INIT_OPTIONS_VERSION,
        );
        if (init_rc < 0) return mapErr(init_rc);

        opts.flags = c.GIT_REPOSITORY_INIT_BARE | c.GIT_REPOSITORY_INIT_MKDIR | c.GIT_REPOSITORY_INIT_MKPATH | c.GIT_REPOSITORY_INIT_NO_REINIT;
        opts.initial_head = "main";

        var raw: ?*c.git_repository = null;
        const rc = c.git_repository_init_ext(&raw, path_z.ptr, &opts);
        if (rc < 0) return mapErr(rc);
        return .{ .raw = raw.? };
    }

    pub fn deinit(self: *Repository) void {
        c.git_repository_free(self.raw);
    }

    pub fn isEmpty(self: *const Repository) bool {
        return c.git_repository_is_empty(self.raw) == 1;
    }

    /// Path on disk to the repo (for indexer scratch files etc.).
    pub fn path(self: *const Repository) []const u8 {
        const p = c.git_repository_path(self.raw);
        return std.mem.sliceTo(p, 0);
    }

    /// Resolve HEAD to its concrete ref. Returns null if HEAD is unborn
    /// (typical for a freshly-initialized empty repo).
    pub fn headRef(self: *Repository) Error!?Reference {
        var raw: ?*c.git_reference = null;
        const rc = c.git_repository_head(&raw, self.raw);
        if (rc == c.GIT_EUNBORNBRANCH or rc == c.GIT_ENOTFOUND) return null;
        if (rc < 0) return mapErr(rc);
        return .{ .raw = raw.? };
    }

    /// Lookup the symbolic target of HEAD without resolving (e.g. the
    /// literal `refs/heads/main`). Returns null if HEAD is detached.
    pub fn headSymbolicTarget(self: *Repository, buf: *[256]u8) Error!?[]const u8 {
        var raw: ?*c.git_reference = null;
        const rc = c.git_reference_lookup(&raw, self.raw, "HEAD");
        if (rc < 0) return mapErr(rc);
        defer c.git_reference_free(raw);

        const target = c.git_reference_symbolic_target(raw);
        if (target == null) return null;
        const slice = std.mem.sliceTo(target, 0);
        if (slice.len > buf.len) return Error.Libgit2;
        @memcpy(buf[0..slice.len], slice);
        return buf[0..slice.len];
    }

    pub fn refIterator(self: *Repository) Error!RefIterator {
        var raw: ?*c.git_reference_iterator = null;
        const rc = c.git_reference_iterator_new(&raw, self.raw);
        if (rc < 0) return mapErr(rc);
        return .{ .raw = raw.? };
    }

    pub fn createReference(
        self: *Repository,
        name_z: [:0]const u8,
        target: Oid,
        force: bool,
    ) Error!void {
        var ref_raw: ?*c.git_reference = null;
        const rc = c.git_reference_create(
            &ref_raw,
            self.raw,
            name_z.ptr,
            &target.raw,
            if (force) 1 else 0,
            null,
        );
        if (rc < 0) return mapErr(rc);
        c.git_reference_free(ref_raw);
    }

    pub fn deleteReference(self: *Repository, name_z: [:0]const u8) Error!void {
        const rc = c.git_reference_remove(self.raw, name_z.ptr);
        if (rc < 0) return mapErr(rc);
    }

    pub fn objectExists(self: *Repository, id: Oid) Error!bool {
        var odb: ?*c.git_odb = null;
        const orc = c.git_repository_odb(&odb, self.raw);
        if (orc < 0) return mapErr(orc);
        defer c.git_odb_free(odb);
        return c.git_odb_exists(odb, &id.raw) != 0;
    }

    /// Reload the repo's ODB so freshly-indexed packfiles become visible.
    /// Call this after `git_indexer_commit` writes a new pack to disk.
    pub fn refreshOdb(self: *Repository) Error!void {
        var odb: ?*c.git_odb = null;
        const orc = c.git_repository_odb(&odb, self.raw);
        if (orc < 0) return mapErr(orc);
        defer c.git_odb_free(odb);
        const rc = c.git_odb_refresh(odb);
        if (rc < 0) return mapErr(rc);
    }
};

pub const Reference = struct {
    raw: *c.git_reference,

    pub fn deinit(self: *Reference) void {
        c.git_reference_free(self.raw);
    }

    pub fn name(self: *const Reference) []const u8 {
        return std.mem.sliceTo(c.git_reference_name(self.raw), 0);
    }

    /// Resolve a (possibly symbolic) reference to its underlying oid.
    /// Returns null if the ref is symbolic and points to an unborn target.
    pub fn resolveOid(self: *const Reference) Error!?Oid {
        var resolved: ?*c.git_reference = null;
        const rc = c.git_reference_resolve(&resolved, self.raw);
        if (rc == c.GIT_ENOTFOUND) return null;
        if (rc < 0) return mapErr(rc);
        defer c.git_reference_free(resolved);
        const target = c.git_reference_target(resolved);
        if (target == null) return null;
        return .{ .raw = target.* };
    }
};

pub const RefIterator = struct {
    raw: *c.git_reference_iterator,

    pub fn deinit(self: *RefIterator) void {
        c.git_reference_iterator_free(self.raw);
    }

    /// Advance the iterator. Returns null on end-of-iteration. The returned
    /// Reference must be deinit'd by the caller.
    pub fn next(self: *RefIterator) Error!?Reference {
        var raw: ?*c.git_reference = null;
        const rc = c.git_reference_next(&raw, self.raw);
        if (rc == c.GIT_ITEROVER) return null;
        if (rc < 0) return mapErr(rc);
        return .{ .raw = raw.? };
    }
};

pub const Indexer = struct {
    raw: *c.git_indexer,
    /// Single progress struct reused across append/commit. libgit2 reads
    /// `total_objects + local_objects` during commit to fix the pack
    /// header — passing two distinct uninitialized structs corrupts the
    /// written count (Zig's debug `undefined` fill is `0xAA`, summed in
    /// the C code that yields `0x55555554` in the on-disk header).
    stats: c.git_indexer_progress,

    pub fn init(repo_path: [:0]const u8) Error!Indexer {
        var raw: ?*c.git_indexer = null;
        const rc = c.git_indexer_new(&raw, repo_path.ptr, 0, null, null);
        if (rc < 0) return mapErr(rc);
        return .{
            .raw = raw.?,
            .stats = std.mem.zeroes(c.git_indexer_progress),
        };
    }

    pub fn deinit(self: *Indexer) void {
        c.git_indexer_free(self.raw);
    }

    pub fn append(self: *Indexer, data: []const u8) Error!void {
        const rc = c.git_indexer_append(self.raw, data.ptr, data.len, &self.stats);
        if (rc < 0) return mapErr(rc);
    }

    pub fn commit(self: *Indexer) Error!void {
        const rc = c.git_indexer_commit(self.raw, &self.stats);
        if (rc < 0) return mapErr(rc);
    }
};

pub const RevWalk = struct {
    raw: *c.git_revwalk,

    pub fn init(repo: *Repository) Error!RevWalk {
        var raw: ?*c.git_revwalk = null;
        const rc = c.git_revwalk_new(&raw, repo.raw);
        if (rc < 0) return mapErr(rc);
        return .{ .raw = raw.? };
    }

    pub fn deinit(self: *RevWalk) void {
        c.git_revwalk_free(self.raw);
    }

    pub fn push(self: *RevWalk, id: Oid) Error!void {
        const rc = c.git_revwalk_push(self.raw, &id.raw);
        if (rc < 0) return mapErr(rc);
    }

    pub fn hide(self: *RevWalk, id: Oid) Error!void {
        const rc = c.git_revwalk_hide(self.raw, &id.raw);
        if (rc < 0) return mapErr(rc);
    }

    /// Yield the next commit oid in the walk, or null when done.
    pub fn next(self: *RevWalk) Error!?Oid {
        var oid: c.git_oid = undefined;
        const rc = c.git_revwalk_next(&oid, self.raw);
        if (rc == c.GIT_ITEROVER) return null;
        if (rc < 0) return mapErr(rc);
        return .{ .raw = oid };
    }
};

pub const PackBuilder = struct {
    raw: *c.git_packbuilder,

    pub fn init(repo: *Repository) Error!PackBuilder {
        var raw: ?*c.git_packbuilder = null;
        const rc = c.git_packbuilder_new(&raw, repo.raw);
        if (rc < 0) return mapErr(rc);
        return .{ .raw = raw.? };
    }

    pub fn deinit(self: *PackBuilder) void {
        c.git_packbuilder_free(self.raw);
    }

    /// Insert a commit and walk its history to include every reachable
    /// object (commits + trees + blobs).
    pub fn insertCommitRecursive(self: *PackBuilder, id: Oid) Error!void {
        const rc = c.git_packbuilder_insert_commit(self.raw, &id.raw);
        if (rc < 0) return mapErr(rc);
    }

    pub fn insertTreeRecursive(self: *PackBuilder, id: Oid) Error!void {
        const rc = c.git_packbuilder_insert_tree(self.raw, &id.raw);
        if (rc < 0) return mapErr(rc);
    }

    pub fn insertRecursive(self: *PackBuilder, id: Oid) Error!void {
        const rc = c.git_packbuilder_insert_recur(self.raw, &id.raw, null);
        if (rc < 0) return mapErr(rc);
    }

    /// Stream the built packfile through `cb`. The callback receives
    /// successive byte chunks and must return 0 on success, non-zero to
    /// abort. The callback's return value is propagated back as ENONFASTFORWARD
    /// (we just surface it as Libgit2 if non-zero — caller errors out earlier).
    pub fn foreach(
        self: *PackBuilder,
        comptime Ctx: type,
        ctx: *Ctx,
        comptime callback: fn (ctx: *Ctx, bytes: []const u8) anyerror!void,
    ) Error!void {
        const Wrapper = struct {
            fn cb(buf: ?*anyopaque, size: usize, payload: ?*anyopaque) callconv(.c) c_int {
                const c_ctx: *Ctx = @ptrCast(@alignCast(payload.?));
                const bytes = @as([*]const u8, @ptrCast(buf.?))[0..size];
                callback(c_ctx, bytes) catch return -1;
                return 0;
            }
        };
        const rc = c.git_packbuilder_foreach(self.raw, Wrapper.cb, ctx);
        if (rc < 0) return mapErr(rc);
    }
};
