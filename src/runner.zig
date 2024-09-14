const std = @import("std");
const config = @import("./config.zig");
const print = std.debug.print;

const app_name = "apprunner";

/// Runner is responsible for running all commands parsed from the yaml to TMUX
pub const Runner = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn spawner(self: *Self, apps: []config.App) !void {
        var thread_pool = try self.allocator.alloc(std.Thread, apps.len);
        for (apps, 0..) |app, i| {
            thread_pool[i] = try std.Thread.spawn(.{ .allocator = self.allocator }, spawnProcess, .{ self, app.name, app.stand, app.command, app.location, i });
        }

        // Wait for all threads to stop program from exiting
        // We could also detach and run forever with a loop
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
        var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", exec_command }, self.allocator);
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
