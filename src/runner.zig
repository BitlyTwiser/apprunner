const std = @import("std");
const builtin = @import("builtin");
const config = @import("./config.zig");
const print = std.debug.print;

const app_name = "apprunner";
const default_shell_nix = "bash";
const default_shell_win = "powershell";
const cmdline_path = "/proc/$$/cmdline";

pub const ShellError = error{ShellNotFound};

// Default shells
const shellType = enum {
    zsh,
    sh,
    bash,
    powershell,
};

/// Runner is responsible for running all commands parsed from the yaml to TMUX
pub const Runner = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    shell_command: []const u8,
    shell_sub_command: []const u8,

    pub fn init(allocator: std.mem.Allocator) ShellError!Self {
        // Get shell information here so we can exit gracefully
        const command_base = commandBase(allocator) catch return ShellError.ShellNotFound;
        const sub_command = subCommand() catch return ShellError.ShellNotFound;

        return Self{
            .allocator = allocator,
            .shell_command = command_base,
            .shell_sub_command = sub_command,
        };
    }

    pub fn spawner(self: *Self, apps: []config.App) !void {
        var thread_pool = try self.allocator.alloc(std.Thread, apps.len);
        for (apps, 0..) |app, i| {
            thread_pool[i] = try std.Thread.spawn(.{ .allocator = self.allocator }, spawnProcess, .{ self, app.name, app.stand, app.command, app.location, i });
            // Its too fast lol - Try sleeping for a moment to avoid missing shells
            std.time.sleep(5000 * 3);
        }

        // Wait for all threads to stop program from exiting
        // We could also detach and run forever with a loop
        // Ctrl+C event is handled from main
        for (thread_pool) |thread| {
            thread.join();
        }
    }

    // Thead that is spawning the processes
    fn spawnProcess(
        self: *Self,
        name: []const u8,
        standalone: bool,
        command: []const u8,
        location: []const u8,
        index: usize,
    ) !void {
        // Base command to start tmux session
        const exec_command = try tmuxConfig(self, name, standalone, command, location, index);
        var child = std.process.Child.init(&[_][]const u8{ self.shell_command, self.shell_sub_command, exec_command }, self.allocator);
        try child.spawn();
        _ = try child.wait();
    }

    // tmux specific configurations
    // You can send commands by name, not only index: tmux new-session -s test_sesh \; rename-window -t test_sesh:0 tester \; send-keys -t test_sesh:tester 'echo "hi" |base64' enter
    fn tmuxConfig(self: *Self, name: []const u8, standalone: bool, command: []const u8, location: []const u8, index: usize) ![]u8 {
        var r_command: []u8 = undefined;

        if (index == 0) {
            if (standalone) {
                r_command = try std.fmt.allocPrint(self.allocator, "tmux new-session -s {s} \\; rename-window -t {s}:{d} {s} \\; send-keys -t {s}:{s} '{s}' enter", .{ app_name, app_name, index, name, app_name, name, command });
            } else {
                r_command = try std.fmt.allocPrint(self.allocator, "tmux new-session -c {s} -s {s} \\; rename-window -t {s}:{d} {s} \\; send-keys -t {s}:{s} '{s}' enter", .{ location, app_name, app_name, index, name, app_name, name, command });
            }

            return r_command;
        }

        if (standalone) {
            r_command = try std.fmt.allocPrint(self.allocator, "tmux new-window -t {s} -n {s} \\; send-keys -t {s}:{s} '{s}' enter", .{ app_name, name, app_name, name, command });

            return r_command;
        }

        r_command = try std.fmt.allocPrint(self.allocator, "tmux new-window -c {s} -t {s} -n {s} \\; send-keys -t {s}:{s} '{s}' enter", .{ location, app_name, name, app_name, name, command });

        return r_command;
    }
};

/// determines which base command to run depending on execution environment. I.e. windows/linux/macOS
fn commandBase(allocator: std.mem.Allocator) ![]const u8 {
    return try captureShell(allocator);
}

// Process sub-command for running command when spawning shell
fn subCommand() ![]const u8 {
    if (builtin.os.tag == .windows) return "-Command";

    return "-c";
}

// In nix systems, parse cmdline_path above to fine current shell.
// Windows its assumed powershell lol
fn captureShell(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) return "powershell";

    const env_map = try std.process.getEnvMap(allocator);
    const shell = env_map.get("SHELL");

    if (shell) |sh| {
        var split_shell = std.mem.splitBackwards(u8, sh, "/");

        // Shell type is always last
        return @as([]const u8, split_shell.first());
    } else {
        // Posix systems/macos do not have /proc, so the commands below fail to check the shell
        if (builtin.os.tag == .macos) return "bash";

        const file = try std.fs.openFileAbsolute(cmdline_path, .{ .mode = .read_only });
        defer file.close();

        // Rather small, but this should only be a single line
        var buf: [512]u8 = undefined;
        _ = try file.reader().read(&buf);

        return &buf;
    }
}

test "get env variables for shell" {
    const env_map = try std.process.getEnvMap(std.heap.page_allocator);
    const shell = env_map.get("SHELL") orelse "";
    var split_shell = std.mem.splitBackwards(u8, shell, "/");

    print("{s}", .{split_shell.first()});
}
