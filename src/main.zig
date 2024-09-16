const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const assert = std.debug.assert;
const config = @import("./config.zig");
const runner = @import("./runner.zig");
const shell_err = runner.ShellError;

// Functions from std
const print = std.debug.print;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Please provide a path to the config.yml file", .{});
        return;
    }

    var yml_config = try config.YamlConfig.init(allocator, args[1]);
    const results = try yml_config.parseConfig();
    defer allocator.free(results.apps);

    // Spawns all threads and waits
    var run = runner.Runner.init(allocator) catch |err| {
        switch (err) {
            runner.ShellError.ShellNotFound => {
                print("error finding appropriate shell to run tmux commands. Please change shells and try again", .{});
            },
        }
        return;
    };
    try run.spawner(results.apps);

    // Listen for the exit events on ctrl+c to gracefully exit
    try setAbortSignalHandler(handleAbortSignal);
}

// Gracefully exit on signal termination events
fn setAbortSignalHandler(comptime handler: *const fn () void) !void {
    const internal_handler = struct {
        fn internal_handler(sig: c_int) callconv(.C) void {
            assert(sig == os.linux.SIG.INT);
            handler();
        }
    }.internal_handler;
    const act = os.linux.Sigaction{
        .handler = .{ .handler = internal_handler },
        .mask = os.linux.empty_sigset,
        .flags = 0,
    };
    _ = os.linux.sigaction(os.linux.SIG.INT, &act, null);
}

fn handleAbortSignal() void {
    print("Goodbye! Thanks for using apprunner", .{});
    std.process.exit(0);
}

test "test yaml file parsing" {}
