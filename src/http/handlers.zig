const std = @import("std");
const httpz = @import("httpz");

const App = @import("server.zig").App;
const pkt = @import("../pkt/line.zig");
const git = @import("../git/lib.zig");
const Store = @import("../repo/store.zig").Store;

const agent = "gitblob/0.0.0";
const zero_oid_hex = "0" ** git.oid_hex_len;

const upload_pack_caps = "ofs-delta agent=" ++ agent;
const receive_pack_caps = "report-status delete-refs ofs-delta agent=" ++ agent;

const Service = enum {
    upload_pack,
    receive_pack,

    fn fromQuery(s: []const u8) ?Service {
        if (std.mem.eql(u8, s, "git-upload-pack")) return .upload_pack;
        if (std.mem.eql(u8, s, "git-receive-pack")) return .receive_pack;
        return null;
    }
};

const Endpoint = struct {
    suffix: []const u8,
    method: httpz.Method,
    handler: *const fn (*App, []const u8, *httpz.Request, *httpz.Response) anyerror!void,
};

const endpoints = [_]Endpoint{
    .{ .suffix = "/info/refs", .method = .GET, .handler = infoRefs },
    .{ .suffix = "/git-upload-pack", .method = .POST, .handler = uploadPack },
    .{ .suffix = "/git-receive-pack", .method = .POST, .handler = receivePack },
};

/// Suffix-based dispatcher. Mounted as App.notFound so every request flows
/// through here. Allows multi-segment repo paths (e.g. `/group/sub/foo.git`)
/// which httpz's mid-path globs can't express.
pub fn dispatch(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const path = req.url.path;

    for (endpoints) |ep| {
        if (!std.mem.endsWith(u8, path, ep.suffix)) continue;

        if (req.method != ep.method) {
            res.status = 405;
            res.body = "method not allowed";
            return;
        }

        const prefix = path[0 .. path.len - ep.suffix.len];
        const url_repo = std.mem.trim(u8, prefix, "/");
        if (url_repo.len == 0) return badRequest(res, "missing repo");

        return ep.handler(app, url_repo, req, res);
    }

    std.log.info("404 {s} {s}", .{ @tagName(req.method), path });
    res.status = 404;
    res.body = "not found";
}

// ─── info/refs ──────────────────────────────────────────────────────────────

pub fn infoRefs(app: *App, url_repo: []const u8, req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const service_str = query.get("service") orelse {
        res.status = 403;
        res.body = "dumb HTTP not supported; pass ?service=git-upload-pack or git-receive-pack";
        return;
    };
    const service = Service.fromQuery(service_str) orelse return badRequest(res, "unknown service");

    // Push flows auto-create the repo on first contact; fetch flows do not.
    var handle = (switch (service) {
        .upload_pack => openOrRespond(app, res, url_repo),
        .receive_pack => openOrCreateOrRespond(app, res, url_repo),
    }) orelse return;
    defer handle.deinit();

    std.log.info("info/refs repo={s} service={s}", .{ handle.name, service_str });

    var aw = std.Io.Writer.Allocating.init(res.arena);
    const w = &aw.writer;

    const service_header = switch (service) {
        .upload_pack => "# service=git-upload-pack",
        .receive_pack => "# service=git-receive-pack",
    };
    try pkt.writeLineLn(w, service_header);
    try pkt.writeFlush(w);

    try writeRefAdvertisement(&handle.repo, service, w);

    res.status = 200;
    res.headers.add("content-type", switch (service) {
        .upload_pack => "application/x-git-upload-pack-advertisement",
        .receive_pack => "application/x-git-receive-pack-advertisement",
    });
    res.body = aw.written();
}

/// Write the v0 ref advertisement: `<oid> <ref>` per line, first line carries
/// the capability list. Empty repos emit a single `capabilities^{}` placeholder.
fn writeRefAdvertisement(repo: *git.Repository, service: Service, w: *std.Io.Writer) !void {
    const caps = switch (service) {
        .upload_pack => upload_pack_caps,
        .receive_pack => receive_pack_caps,
    };

    var first = true;
    var oid_buf: [git.oid_hex_len]u8 = undefined;

    // For upload-pack we lead with HEAD so clients can pick a default
    // branch. We also append `symref=HEAD:<target>` to the capability list
    // so the client doesn't have to guess.
    if (service == .upload_pack) {
        if (try repo.headRef()) |*head_const| {
            var head = head_const.*;
            defer head.deinit();
            if (try head.resolveOid()) |oid| {
                var symref_buf: [256]u8 = undefined;
                const symref_target = (try repo.headSymbolicTarget(&symref_buf));

                if (symref_target) |target| {
                    var line_buf: [512]u8 = undefined;
                    const line = try std.fmt.bufPrint(&line_buf, "{s} HEAD\x00{s} symref=HEAD:{s}", .{
                        oid.hexBuf(&oid_buf),
                        caps,
                        target,
                    });
                    try pkt.writeLineLn(w, line);
                } else {
                    var line_buf: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&line_buf, "{s} HEAD\x00{s}", .{ oid.hexBuf(&oid_buf), caps });
                    try pkt.writeLineLn(w, line);
                }
                first = false;
            }
        }
    }

    var it = try repo.refIterator();
    defer it.deinit();
    while (try it.next()) |ref_const| {
        var ref = ref_const;
        defer ref.deinit();
        const name = ref.name();
        // Only branch and tag refs are advertised; skip notes, stash, etc.
        if (!std.mem.startsWith(u8, name, "refs/heads/") and
            !std.mem.startsWith(u8, name, "refs/tags/"))
            continue;

        const oid = (try ref.resolveOid()) orelse continue;
        const oid_hex = oid.hexBuf(&oid_buf);

        if (first) {
            var line_buf: [1024]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buf, "{s} {s}\x00{s}", .{ oid_hex, name, caps });
            try pkt.writeLineLn(w, line);
            first = false;
        } else {
            var line_buf: [1024]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buf, "{s} {s}", .{ oid_hex, name });
            try pkt.writeLineLn(w, line);
        }
    }

    if (first) {
        // Empty repo: emit the placeholder so clients still get capabilities.
        var line_buf: [256]u8 = undefined;
        const placeholder = try std.fmt.bufPrint(&line_buf, "{s} capabilities^{{}}\x00{s}", .{
            zero_oid_hex,
            caps,
        });
        try pkt.writeLineLn(w, placeholder);
    }

    try pkt.writeFlush(w);
}

// ─── git-receive-pack (push) ────────────────────────────────────────────────

const RefCommand = struct {
    old_oid: git.Oid,
    new_oid: git.Oid,
    /// Owned by the request arena (the streaming pkt buffer is reused).
    refname: []const u8,
};

/// Per-read socket timeout for streaming the request body. Bigger than a
/// typical TCP RTT but small enough to bound a stuck client.
const body_read_timeout_ms: usize = 30_000;

/// Chunk size for pumping pack bytes into the indexer. Big enough to amortise
/// syscall overhead, small enough to keep peak RSS bounded regardless of
/// pack size.
const pack_chunk_size: usize = 64 * 1024;

pub fn receivePack(app: *App, url_repo: []const u8, req: *httpz.Request, res: *httpz.Response) !void {
    var handle = openOrCreateOrRespond(app, res, url_repo) orelse return;
    defer handle.deinit();
    std.log.info("git-receive-pack repo={s}", .{handle.name});

    var body_reader = req.reader(body_read_timeout_ms) catch {
        return badRequest(res, "missing body");
    };
    var pkt_buf: [pkt.min_buffer_capacity]u8 = undefined;
    var io = pkt.IoReader(@TypeOf(body_reader)).init(&body_reader, &pkt_buf);
    const r = &io.interface;

    var commands = std.ArrayList(RefCommand).empty;
    defer commands.deinit(res.arena);

    // 1. Read ref-update commands (one pkt-line each) up to the flush packet.
    while (true) {
        const line = (pkt.nextLine(r) catch |err| {
            std.log.warn("receive-pack parse error: {s}", .{@errorName(err)});
            return badRequest(res, "malformed receive-pack request");
        }) orelse return badRequest(res, "missing body");

        switch (line.kind) {
            .flush => break,
            .delim => continue,
            .data => {
                // `<old-oid> SP <new-oid> SP <refname>[\0<caps>][\n]`
                var payload = line.payload;
                if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                    payload = payload[0 .. payload.len - 1];
                }
                if (std.mem.indexOfScalar(u8, payload, 0)) |nul| {
                    payload = payload[0..nul];
                }
                if (payload.len < git.oid_hex_len * 2 + 3)
                    return badRequest(res, "malformed receive-pack request");
                const old_hex = payload[0..git.oid_hex_len];
                if (payload[git.oid_hex_len] != ' ')
                    return badRequest(res, "malformed receive-pack request");
                const new_hex = payload[git.oid_hex_len + 1 .. git.oid_hex_len * 2 + 1];
                if (payload[git.oid_hex_len * 2 + 1] != ' ')
                    return badRequest(res, "malformed receive-pack request");
                const refname_src = payload[git.oid_hex_len * 2 + 2 ..];

                // The pkt buffer is reused on the next read, so the refname
                // must outlive it. Copy into the request arena.
                const refname = try res.arena.dupe(u8, refname_src);

                try commands.append(res.arena, .{
                    .old_oid = try git.Oid.fromHex(old_hex),
                    .new_oid = try git.Oid.fromHex(new_hex),
                    .refname = refname,
                });
            },
        }
    }

    const has_writes = blk: {
        for (commands.items) |cmd| if (!cmd.new_oid.isZero()) break :blk true;
        break :blk false;
    };

    // 2. Ingest the packfile (if any) by streaming the rest of the body
    //    directly into libgit2's indexer. No buffering of the full pack.
    var unpack_ok = true;
    var unpack_err_msg: []const u8 = "";
    var pack_bytes: usize = 0;

    if (has_writes) {
        // libgit2's indexer writes pack-XXXXX.{pack,idx} into the directory
        // we pass. For the ODB to see them on the next lookup, that directory
        // must be `<repo>/objects/pack/`. libgit2 creates it on first append.
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const pack_dir = try std.fmt.bufPrintZ(&path_buf, "{s}/objects/pack", .{handle.fs_path});

        var indexer = try git.Indexer.init(pack_dir);
        defer indexer.deinit();

        var chunk: [pack_chunk_size]u8 = undefined;
        while (true) {
            const n = r.readSliceShort(&chunk) catch |err| {
                unpack_ok = false;
                unpack_err_msg = @errorName(err);
                break;
            };
            if (n == 0) break;
            pack_bytes += n;
            indexer.append(chunk[0..n]) catch |err| {
                unpack_ok = false;
                unpack_err_msg = @errorName(err);
                break;
            };
            if (n < chunk.len) break;
        }

        if (unpack_ok and pack_bytes == 0) {
            unpack_ok = false;
            unpack_err_msg = "no pack data";
        }
        if (unpack_ok) {
            indexer.commit() catch |err| {
                unpack_ok = false;
                unpack_err_msg = @errorName(err);
            };
        }
        if (unpack_ok) {
            // Make freshly-written objects visible to the ref-update step.
            handle.repo.refreshOdb() catch |err| {
                unpack_ok = false;
                unpack_err_msg = @errorName(err);
            };
        }
    }

    std.log.info("receive-pack: commands={d} pack={d}B", .{ commands.items.len, pack_bytes });

    // 3. Apply ref updates and report status. Even on unpack failure we still
    //    send report-status so the client can render an error.
    var aw = std.Io.Writer.Allocating.init(res.arena);
    const w = &aw.writer;

    if (unpack_ok) {
        try pkt.writeLineLn(w, "unpack ok");
    } else {
        var line_buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "unpack {s}", .{unpack_err_msg});
        try pkt.writeLineLn(w, line);
    }

    for (commands.items) |cmd| {
        const result = if (!unpack_ok)
            CmdResult{ .ng = "unpacker error" }
        else
            applyCommand(&handle.repo, cmd);

        var line_buf: [1024]u8 = undefined;
        const line = switch (result) {
            .ok => try std.fmt.bufPrint(&line_buf, "ok {s}", .{cmd.refname}),
            .ng => |reason| try std.fmt.bufPrint(&line_buf, "ng {s} {s}", .{ cmd.refname, reason }),
        };
        try pkt.writeLineLn(w, line);
    }
    try pkt.writeFlush(w);

    res.status = 200;
    res.headers.add("content-type", "application/x-git-receive-pack-result");
    res.body = aw.written();
}

const CmdResult = union(enum) {
    ok,
    ng: []const u8,
};

fn applyCommand(repo: *git.Repository, cmd: RefCommand) CmdResult {
    // Reject refs the validator wouldn't accept (we only allow refs/heads/*
    // and refs/tags/* — keep symbolic refs and HEAD updates out of band).
    if (!std.mem.startsWith(u8, cmd.refname, "refs/heads/") and
        !std.mem.startsWith(u8, cmd.refname, "refs/tags/"))
    {
        return .{ .ng = "refusing to update ref outside refs/heads or refs/tags" };
    }

    // Make a NUL-terminated copy of the refname for the C API. The arena
    // path is awkward here; use a stack buffer (refnames are bounded).
    if (cmd.refname.len > 255) return .{ .ng = "refname too long" };
    var name_buf: [256]u8 = undefined;
    @memcpy(name_buf[0..cmd.refname.len], cmd.refname);
    name_buf[cmd.refname.len] = 0;
    const name_z: [:0]const u8 = name_buf[0..cmd.refname.len :0];

    if (cmd.new_oid.isZero()) {
        repo.deleteReference(name_z) catch |err| return .{ .ng = errorReason(err) };
        return .ok;
    }

    repo.createReference(name_z, cmd.new_oid, true) catch |err| return .{ .ng = errorReason(err) };
    return .ok;
}

fn errorReason(err: git.Error) []const u8 {
    return switch (err) {
        git.Error.NotFound => "ref not found",
        git.Error.Exists => "ref exists",
        git.Error.InvalidArg => "invalid argument",
        git.Error.OutOfMemory => "out of memory",
        git.Error.Libgit2 => "libgit2 error",
    };
}

// ─── git-upload-pack (clone/fetch) ──────────────────────────────────────────

pub fn uploadPack(app: *App, url_repo: []const u8, req: *httpz.Request, res: *httpz.Response) !void {
    var handle = openOrRespond(app, res, url_repo) orelse return;
    defer handle.deinit();
    std.log.info("git-upload-pack repo={s}", .{handle.name});

    var body_reader = req.reader(body_read_timeout_ms) catch {
        return badRequest(res, "missing body");
    };
    var pkt_buf: [pkt.min_buffer_capacity]u8 = undefined;
    var io = pkt.IoReader(@TypeOf(body_reader)).init(&body_reader, &pkt_buf);
    const r = &io.interface;

    var wants = std.ArrayList(git.Oid).empty;
    defer wants.deinit(res.arena);

    // Read pkt-lines up to the first flush. Anything past it (haves, done)
    // is ignored; without multi_ack advertised the response is just NAK + pack
    // and httpz drains the rest of the body for us before keepalive.
    while (true) {
        const line = (pkt.nextLine(r) catch |err| {
            std.log.warn("upload-pack parse error: {s}", .{@errorName(err)});
            return badRequest(res, "malformed upload-pack request");
        }) orelse break;

        switch (line.kind) {
            .flush => break,
            .delim => continue,
            .data => {
                var payload = line.payload;
                if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                    payload = payload[0 .. payload.len - 1];
                }

                if (!std.mem.startsWith(u8, payload, "want ")) continue;
                payload = payload["want ".len..];

                if (payload.len < git.oid_hex_len) return badRequest(res, "malformed upload-pack request");
                const oid = try git.Oid.fromHex(payload[0..git.oid_hex_len]);
                try wants.append(res.arena, oid);
            },
        }
    }

    if (wants.items.len == 0) return badRequest(res, "no want lines");

    var aw = std.Io.Writer.Allocating.init(res.arena);
    const w = &aw.writer;

    // Without `multi_ack` advertised, the response shape is just NAK + pack.
    try pkt.writeLineLn(w, "NAK");

    var pb = git.PackBuilder.init(&handle.repo) catch |err| {
        std.log.warn("packbuilder init failed: {s}", .{@errorName(err)});
        res.status = 500;
        res.body = "internal error";
        return;
    };
    defer pb.deinit();

    // Walk every commit reachable from the wants (history closure) and
    // insert each one. `insert_commit` adds the commit + its tree; the
    // packbuilder takes care of including blobs reachable through the tree.
    var walk = git.RevWalk.init(&handle.repo) catch |err| {
        std.log.warn("revwalk init failed: {s}", .{@errorName(err)});
        res.status = 500;
        res.body = "internal error";
        return;
    };
    defer walk.deinit();

    for (wants.items) |oid| {
        walk.push(oid) catch |err| {
            std.log.warn("revwalk push failed: {s}", .{@errorName(err)});
            res.status = 500;
            res.body = "internal error";
            return;
        };
    }

    var commit_count: usize = 0;
    while (walk.next() catch |err| {
        std.log.warn("revwalk next failed: {s}", .{@errorName(err)});
        res.status = 500;
        res.body = "internal error";
        return;
    }) |oid| {
        pb.insertCommitRecursive(oid) catch |err| {
            std.log.warn("packbuilder insert commit failed: {s}", .{@errorName(err)});
            res.status = 500;
            res.body = "internal error";
            return;
        };
        commit_count += 1;
    }
    std.log.info("upload-pack: walked {d} commits", .{commit_count});

    const Ctx = struct { w: *std.Io.Writer };
    var ctx: Ctx = .{ .w = w };

    const Cb = struct {
        fn cb(c: *Ctx, bytes: []const u8) anyerror!void {
            try c.w.writeAll(bytes);
        }
    };

    pb.foreach(Ctx, &ctx, Cb.cb) catch |err| {
        std.log.warn("packbuilder foreach failed: {s}", .{@errorName(err)});
        res.status = 500;
        res.body = "internal error";
        return;
    };

    res.status = 200;
    res.headers.add("content-type", "application/x-git-upload-pack-result");
    res.body = aw.written();
}

// ─── store helpers ──────────────────────────────────────────────────────────

const Handle = @import("../repo/store.zig").Handle;

fn openOrRespond(app: *App, res: *httpz.Response, url_repo: []const u8) ?Handle {
    return app.store.open(res.arena, url_repo) catch |err| {
        respondWithError(res, err);
        return null;
    };
}

fn openOrCreateOrRespond(app: *App, res: *httpz.Response, url_repo: []const u8) ?Handle {
    return app.store.openOrCreate(res.arena, url_repo) catch |err| {
        respondWithError(res, err);
        return null;
    };
}

fn respondWithError(res: *httpz.Response, err: anyerror) void {
    switch (err) {
        error.InvalidPath => {
            res.status = 400;
            res.body = "invalid repo path";
        },
        error.NotFound => {
            res.status = 404;
            res.body = "repository not found";
        },
        error.OutOfMemory => {
            res.status = 500;
            res.body = "internal error";
        },
        else => {
            res.status = 500;
            res.body = "internal error";
        },
    }
}

fn badRequest(res: *httpz.Response, msg: []const u8) void {
    res.status = 400;
    res.body = msg;
}
