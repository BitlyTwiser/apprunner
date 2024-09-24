const std = @import("std");
const builtin = @import("builtin");
const config = @import("./config.zig");
const zdotenv_parser = @import("zdotenv").Parser;
const print = std.debug.print;

const app_name = "apprunner";
const default_shell_nix = "bash";
const cmdline_path = "/proc/$$/cmdline";

pub const ShellError = error{ShellNotFound};

// Default shells
const shellType = enum {
    zsh,
    sh,
    bash,
};

// This is dumb - we can utilize a buffer [][]const u8. If the slice is growing out of brounds, call a grow function to allocate more space to the allotment of the given string.
// Effectively copy the strings.BUilder pattern in Go: https://github.com/golang/go/blob/master/src/strings/builder.go
const sessionBuilder = struct {
    allocator: std.mem.Allocator,
    command_path: []const u8, // Full, built command path
    const Self = @This();
    const session_base = "tmux new-session";

    fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .command_path = session_base, // Start with session base to build off of.
        };
    }

    // Note: The only reason the functions are named and not just Write() is for ease of reading. They both just wrap write for now

    /// Appends env values into the session start
    fn withEnv(self: *Self, env_data: []const u8) !*Self {
        return try self.write(env_data);
    }

    /// Adds a location on disk where the -c command is called. i.e. starting location of the shell
    fn withLocation(self: *Self, location: []const u8) !*Self {
        return try self.write(try std.fmt.allocPrint(self.allocator, "-c {s}", .{location}));
    }

    /// writes any data to the string
    fn write(self: *Self, s: []const u8) !*Self {
        self.command_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.command_path, s });

        return self;
    }

    /// Serializes the string that has been built using the builder
    fn print(self: *Self) []const u8 {
        return self.command_path;
    }
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
            thread_pool[i] = try std.Thread.spawn(.{ .allocator = self.allocator }, spawnProcess, .{ self, app.name, app.standalone, app.command, app.start_location, app.env_path, i });
            // Its too fast lol - Try sleeping for a moment to avoid missing shells
            std.time.sleep(100000 * 1024);
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
        env_path: ?[]const u8,
        index: usize,
    ) !void {
        // Base command to start tmux session
        const exec_command = try tmuxConfig(self, name, standalone, command, location, env_path, index);
        var child = std.process.Child.init(&[_][]const u8{ self.shell_command, self.shell_sub_command, exec_command }, self.allocator);
        try child.spawn();
        _ = try child.wait();
    }

    // tmux specific configurations
    // You can send commands by name, not only index: tmux new-session -s test_sesh \; rename-window -t test_sesh:0 tester \; send-keys -t test_sesh:tester 'echo "hi" |base64' enter
    fn tmuxConfig(self: *Self, name: []const u8, standalone: bool, command: []const u8, location: []const u8, env_path: ?[]const u8, index: usize) ![]u8 {
        var builder = try sessionBuilder.init(self.allocator);
        // The session base, this expands in the given cases of env values being passed and is eventually insrted into the primary strings below
        // If the env  path is present, use the path to add .env values
        if (env_path) |env| {
            var file: std.fs.File = undefined;
            // Check if an absolute path else treat as relative
            if (std.fs.path.isAbsolute(env)) {
                file = try std.fs.openFileAbsolute(env, .{ .mode = .read_only });
            } else {
                file = try std.fs.cwd().openFile(env, .{ .mode = .read_only });
            }

            defer file.close();

            var zdotenv = try zdotenv_parser.init(self.allocator, file);
            // Deallocate the memory from parse
            defer zdotenv.deinit();

            const env_data = try zdotenv.parse();

            // Add data onto the sesison builder for .env data
            const formatted_data = try self.formatEnvData(env_data);

            for (formatted_data) |value| {
                builder = (try builder.withEnv(value)).*;
            }
        }

        var r_command: []u8 = undefined;
        if (index == 0) {
            if (standalone) {
                r_command = try std.fmt.allocPrint(self.allocator, "{s} -s {s} \\; rename-window -t {s}:{d} {s} \\; send-keys -t {s}:{s} '{s}' enter", .{ builder.print(), app_name, app_name, index, name, app_name, name, command });
            } else {
                builder = (try builder.withLocation(location)).*;
                r_command = try std.fmt.allocPrint(self.allocator, "{s} -s {s} \\; rename-window -t {s}:{d} {s} \\; send-keys -t {s}:{s} '{s}' enter", .{ builder.print(), app_name, app_name, index, name, app_name, name, command });
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

    // Format the incoming .env data as `VARIABLE=value’
    // For multiple, you can specify multiple -e flags:
    /// tmux-session -e var1=asdasd -e var2=asdasd
    fn formatEnvData(self: *Self, env_data: std.StringHashMap([]const u8)) ![][]const u8 {
        var env_data_iter = env_data.iterator();
        var elements = try self.allocator.alloc([]const u8, env_data.count());
        var index: usize = 0;
        while (env_data_iter.next()) |env_value| : (index += 1) {
            const key = env_value.key_ptr.*;
            const value = env_value.value_ptr.*;

            const key_d = try self.allocator.dupe(u8, key);
            const value_d = try self.allocator.dupe(u8, value);

            // String concationation of the various elements of the env string
            elements[index] = try std.fmt.allocPrint(self.allocator, "-e {s}={s} ", .{ key_d, value_d });

            // Trim whitespace from end of last write, probably not needed but added for cleanliness
            if (index == env_data.count()) elements[index] = std.mem.trimRight(u8, elements[index], " ");
        }

        return elements;
    }
};

/// determines which base command to run depending on execution environment. I.e. linux/macOS
fn commandBase(allocator: std.mem.Allocator) ![]const u8 {
    return try captureShell(allocator);
}

// Process sub-command for running command when spawning shell
fn subCommand() ![]const u8 {
    // if (builtin.os.tag == .windows) return "-Command"; //No windows support

    return "-c";
}

// In nix systems, parse cmdline_path above to fine current shell.
fn captureShell(allocator: std.mem.Allocator) ![]const u8 {
    const env_map = try std.process.getEnvMap(allocator);
    const shell = env_map.get("SHELL");

    if (shell) |sh| {
        var split_shell = std.mem.splitBackwards(u8, sh, "/");

        // Shell type is always last
        return @as([]const u8, split_shell.first());
    } else {
        // Posix systems/macos do not have /proc, so the commands below fail to check the shell. So we fallback to bash on macos
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
