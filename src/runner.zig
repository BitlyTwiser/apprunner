const std = @import("std");
const builtin = @import("builtin");
const config = @import("./config.zig");
const zdotenv_parser = @import("zdotenv").Parser;
const utils = @import("utils.zig");
const print = std.debug.print;

pub const app_name = "apprunner"; // This is public as we import the app_name (session name) into resurrect for controlling which sessions we capture.
const default_shell_nix = "bash";
const cmdline_path = "/proc/$$/cmdline";

pub const ShellError = error{ShellNotFound};

const session_base = "tmux new-session";
const window_base = "tmux new-window";

const baseType = union(enum) {
    session,
    window,

    const Self = @This();

    fn baseTypeString(self: Self) []const u8 {
        switch (self) {
            .session => {
                return session_base;
            },
            .window => {
                return window_base;
            },
        }
    }
};

// This is dumb - we can utilize a buffer [][]const u8. If the slice is growing out of brounds, call a grow function to allocate more space to the allotment of the given string.
// Effectively copy the strings.BUilder pattern in Go: https://github.com/golang/go/blob/master/src/strings/builder.go
const sessionBuilder = struct {
    allocator: std.mem.Allocator,
    command_path: []const u8, // Full, built command path
    base_type: baseType,
    const Self = @This();

    fn init(allocator: std.mem.Allocator, base_type: baseType) !Self {
        return Self{
            .allocator = allocator,
            .command_path = base_type.baseTypeString(),
            .base_type = base_type,
        };
    }

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
        self.command_path = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ self.command_path, s });

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
        for (apps, 0..) |app, i| {
            try self.spawnProcess(app.name, app.standalone, app.command, app.start_location, app.env_path, i);
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
        try utils.runCommandEmpty(&[_][]const u8{ self.shell_command, self.shell_sub_command, exec_command }, self.allocator);
    }

    // tmux specific configurations
    // You can send commands by name, not only index: tmux new-session -s test_sesh \; rename-window -t test_sesh:0 tester \; send-keys -t test_sesh:tester 'echo "hi" |base64' enter
    fn tmuxConfig(self: *Self, name: []const u8, standalone: bool, command: []const u8, location: []const u8, env_path: ?[]const u8, index: usize) ![]u8 {
        var r_command: []u8 = undefined;
        // index zero applies to only 1 app in the yaml or the initial app to spawn the sessions. After the session is spawned we need to also feed the .env into the windows
        // This leads to some duplication as can be seen below. Perhaps there is a better method around this we can investigate going forward
        if (index == 0) {
            var builder = try sessionBuilder.init(self.allocator, .session);
            // Load env data for injection
            if (env_path) |env| {
                builder = (try self.loadEnvData(env, &builder)).*;
            }
            if (standalone) {
                r_command = try std.fmt.allocPrint(self.allocator, "{s} -s {s} \\; rename-window -t {s}:{d} {s} \\; send-keys -t {s}:{s} '{s}' enter", .{ builder.print(), app_name, app_name, index, name, app_name, name, command });
            } else {
                builder = (try builder.withLocation(location)).*;
                r_command = try std.fmt.allocPrint(self.allocator, "{s} -s {s} \\; rename-window -t {s}:{d} {s} \\; send-keys -t {s}:{s} '{s}' enter", .{ builder.print(), app_name, app_name, index, name, app_name, name, command });
            }

            return r_command;
        }

        // Not a huge fan of the duplication here.
        var builder = try sessionBuilder.init(self.allocator, .window);
        if (env_path) |env| {
            builder = (try self.loadEnvData(env, &builder)).*;
        }

        if (standalone) {
            r_command = try std.fmt.allocPrint(self.allocator, "{s} -t {s} -n {s} \\; send-keys -t {s}:{s} '{s}' enter", .{ builder.print(), app_name, name, app_name, name, command });

            return r_command;
        }

        builder = (try builder.withLocation(location)).*;

        r_command = try std.fmt.allocPrint(self.allocator, "{s} -c {s} -t {s} -n {s} \\; send-keys -t {s}:{s} '{s}' enter", .{ builder.print(), location, app_name, name, app_name, name, command });

        return r_command;
    }

    fn loadEnvData(self: *Self, env_path: []const u8, builder: *sessionBuilder) !*sessionBuilder {
        // The session base, this expands in the given cases of env values being passed and is eventually insrted into the primary strings below
        // If the env  path is present, use the path to add .env values
        var file: std.fs.File = undefined;
        // Check if an absolute path else treat as relative
        if (std.fs.path.isAbsolute(env_path)) {
            file = try std.fs.openFileAbsolute(env_path, .{ .mode = .read_only });
        } else {
            file = try std.fs.cwd().openFile(env_path, .{ .mode = .read_only });
        }

        defer file.close();

        var zdotenv = try zdotenv_parser.init(self.allocator, file);
        // Deallocate the memory from parse
        defer zdotenv.deinit();

        const env_data = try zdotenv.parse();

        // Add data onto the session builder for .env data
        const formatted_data = try self.formatEnvData(env_data);

        for (formatted_data) |value| {
            builder.* = (try builder.withEnv(value)).*;
        }

        return builder;
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
pub fn commandBase(allocator: std.mem.Allocator) ![]const u8 {
    return try captureShell(allocator);
}

// Process sub-command for running command when spawning shell
pub fn subCommand() ![]const u8 {
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
