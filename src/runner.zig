const std = @import("std");
const config = @import("./config.zig");
const print = std.debug.print;
// We are basically going to
// 1: Parse yaml file for commands, start location, and if standalone (i.e. no specific folder)
// 2: spawn new windows for each command, rename (with name variable), and run command.
// 3: $$$ profit

// Basically do this
// # Start a new tmux session named 'my_session'
// tmux new-session -s sesssion  // Take name of session from YAML

// # Rename the first window and run a command in it
// tmux rename-window -t my_session:0 'Window1'
// tmux send-keys -t my_session:0 'top' C-m

// # Create a second window, name it, and run a command
// tmux new-window -t my_session -n 'Window2'
// tmux send-keys -t my_session:1 'htop' C-m

// # Create a third window, name it, and run a command
// tmux new-window -t my_session -n 'Window3'
// tmux send-keys -t my_session:2 'ping google.com' C-m

// # Create a fourth window, name it, and run a command
// tmux new-window -t my_session -n 'Window4'
// tmux send-keys -t my_session:3 'tail -f /var/log/syslog' C-m

// # Attach to the session (if you want to interact with it immediately)
// tmux attach -t my_session

// Find shell type, sh, bash, zsh etc..

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
        // Add 1 for the additional spawner for the windows
        var thread_pool = try self.allocator.alloc(std.Thread, apps.len + 1);
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
    // tmux new-window -t my_session -n 'Window4'
    // tmux send-keys -t my_session:3 'tail -f /var/log/syslog' C-m
    fn tmuxConfig(self: *Self, name: []const u8, standalone: bool, command: []const u8, location: []const u8, index: usize) ![]u8 {
        var r_command: []u8 = undefined;

        if (index == 0) {
            return try std.fmt.allocPrint(self.allocator, "tmux new-session -s {s}", .{app_name});
        }

        if (standalone) {
            r_command = try std.fmt.allocPrint(self.allocator, "tmux new-window -t {s} -n {s} && tmux send-keys -t {s}:{d} `{s}` C-m", .{ app_name, name, name, index, command });

            return r_command;
        }

        // CD to a dir as not standalone
        r_command = try std.fmt.allocPrint(self.allocator, "tmux new-window -t {s} -n {s} && tmux send-keys -t {s}:{d} `cd {s} && {s}` C-m", .{ app_name, name, name, index, location, command });
        return r_command;
    }
};