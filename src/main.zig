const std = @import("std");
const Io = std.Io;

const Config = @import("config.zig").Config;
const server = @import("http/server.zig");
const git = @import("git/lib.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const prog = if (args.len > 0) std.fs.path.basename(args[0]) else "gitblob";

    const config = Config.fromArgs(args) catch |err| {
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
        const w = &stderr_writer.interface;
        switch (err) {
            error.HelpRequested => {
                try Config.printUsage(w, prog);
                try w.flush();
                return;
            },
            else => {
                try w.print("error: {s}\n\n", .{@errorName(err)});
                try Config.printUsage(w, prog);
                try w.flush();
                std.process.exit(2);
            },
        }
    };

    try git.init();
    defer git.shutdown();

    try server.run(io, gpa, config);
}
