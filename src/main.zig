const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const config = @import("./config.zig");
const runner = @import("./runner.zig");
const resurrect = @import("./resurrect.zig").Resurrect;
const shell_err = runner.ShellError;
const snek = @import("snek").Snek;

const print = std.debug.print;
const assert = std.debug.assert;

const CliArguments = struct { config_path: ?[]const u8, restore: ?bool, disable: ?bool };

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cli = try snek(CliArguments).init(allocator);
    const parsed_cli = try cli.parse();

    // Check tmux version and print warning if we cannot start resurrect
    const res = try resurrect.init(allocator);
    const res_supported = try res.checkSupportedVersion();

    const disabled = (parsed_cli.disable orelse false);

    // If disabled is not set, we obviously defualt to false
    if (res_supported and !disabled) {
        // Start the thread to store session data every N minutes/seconds
        try res.saveThread();
    } else {
        if (disabled) {
            try res.printDisabledWarning();
        } else {
            try res.printWarning();
            // Sleep for 3 seconds to display the warning to the user
            std.time.sleep(std.time.ns_per_s * 3);
        }
    }

    // Cli application path parsing. Either restore or run the application normally using config file path
    if (parsed_cli.config_path) |config_path| {
        if (parsed_cli.restore != null) {
            print("{s}", .{"Cannot use restore flag with config path.\n"});
            return;
        }

        var yml_config = try config.YamlConfig.init(allocator, config_path);
        const results = try yml_config.parseConfig();
        defer allocator.free(results.apps);

        // Spawns all threads and waits
        var run = runner.Runner.init(allocator) catch |err| {
            switch (err) {
                runner.ShellError.ShellNotFound => {
                    print("error finding appropriate shell to run tmux commands. Please change shells and try again\n", .{});
                },
            }
            return;
        };
        try run.spawner(results.apps);

        // Listen for the exit events on ctrl+c to gracefully exit
        try setAbortSignalHandler(handleAbortSignal);
    } else if (parsed_cli.restore != null and parsed_cli.config_path == null) {
        // Do not allow resurrection on non-supported version of tmux
        if (!res_supported) {
            print("Invalid version of Tmux. You must use Tmux version 1.9 or greater for resurrection", .{});

            return;
        }
        // Restore stored session after crash
        try res.restoreSession();
    } else {
        print("Invalid commands specified, please pass either config file path or restore flag as an argument to apprunner. Use apprunner -h for help\n", .{});
    }
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
