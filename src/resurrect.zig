const std = @import("std");
const runner = @import("runner.zig");

const print = std.debug.print;

// The proper version is 1.9. We use 19 for a int comparison below
const supported_tmux_version = "1.9"; // Restore/resurrect flags do not work on older versions of tmux

// Ansi escape codes
const esc = "\x1B";
const csi = esc ++ "[";
const color_reset = csi ++ "0m";
const color_fg = "38;5;";
const color_bg = "48;5;";

const color_fg_def = csi ++ color_fg ++ "15m"; // white
const color_bg_def = csi ++ color_bg ++ "0m"; // black
const color_red = csi ++ "31m"; // red

// Resurrect File paths
const resurrect_folder_path = "/.tmux/resurrect";
const resurrect_wait_time = std.time.ms_per_min * 2;

const resurrectDumpType = union(enum) {
    window,
    state,
    pane,

    const Self = @This();

    fn format(self: Self, formatted_data: []const u8) []const u8 {
        var buf: [1024]u8 = undefined;
        var base: []const u8 = undefined;
        switch (self) {
            .window => {
                base = "tmux list-windows -a -F ";
            },
            .state => {
                base = "tmux display-message -p ";
            },
            .pane => {
                base = "tmux list-panes -a -F ";
            },
        }

        return try std.fmt.bufPrint(&buf, "{s}{s}", .{ base, formatted_data });
    }
};

// Perhaps an interface to serailize the data from each struct type below

// Resurrect File structure - Used for serializing the struct data into and out of the stored resurrect file.
const ResurrectFileData = struct {
    pane_data: paneData,
    window_data: windowData,
    state_data: stateData,

    const Self = @This();

    /// Performs JSON serialization and file storage from the resurrectFileData
    fn stringify(self: Self, allocator: std.mem.Allocator) !void {
        var string = std.ArrayList(u8).init(allocator);
        try std.json.stringify(self, .{}, string.writer());
    }
};

// Structs for panes, state, and window session management
const paneData = struct {
    window_data: genericWindowStruct,
    pane_index: u8,
    pane_title: []const u8,
    pane_current_path: []const u8,
    pane_active: bool,
    pane_current_command: []const u8,
    pane_pid: []const u8,
    history_size: []const u8,

    const Self = @This();

    fn parse(self: Self) !Self {
        return self;
    }

    fn runTmuxCommand(self: Self) []const u8 {
        _ = self;

        return "";
    }
};

const windowData = struct {
    window_data: genericWindowStruct,
    window_layout: []const u8,

    const Self = @This();

    fn parse(self: Self) !Self {
        return self;
    }

    fn runTmuxCommand(self: Self) []const u8 {
        _ = self;

        return "";
    }
};

const stateData = struct {
    client_session: []const u8,
    client_last_sessions: []const u8,

    const Self = @This();

    fn parse(self: Self) !Self {
        return self;
    }

    fn runTmuxCommand(self: Self) []const u8 {
        _ = self;

        return "";
    }
};

// Pane data and Window data share this
const genericWindowStruct = struct { session_name: []const u8, window_index: u8, window_name: []const u8, window_active: bool, window_flags: []const u8 };

/// Resurrect is in charge of snapshotting current user state and restoring state on load.
pub const Resurrect = struct {
    allocator: std.mem.Allocator,
    const Self = @This();
    const format_delimiter = '\t'; // Used to seperate the lines in the formatters from the returned tmux data

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Restores the given session data when called
    pub fn restoreSession(self: Self) !void {
        _ = self;
    }

    /// Wrapper around save to run this in a thread. Runs indefinitely until os.Exit()
    pub fn saveThread(self: Self) !void {
        const t = try std.Thread.spawn(.{}, save, .{self});
        t.detach();
    }

    /// ran in a thread on start of the application which stores session data every N Seconds/Minutes
    /// This is a rolling backup - no copies are stored
    pub fn save(self: Self) !void {
        // Created during the processes below in order to ascertain the actual path where the resurrect file will be installed
        var definitive_dir_path: ?[]const u8 = null;
        const env = try std.process.getEnvMap(self.allocator);
        // Get $HOME env var and check dir exists
        if (env.get("HOME")) |home| {
            const dir_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, resurrect_folder_path });
            definitive_dir_path = dir_path;
        } else {
            // We make up a path if $HOME is not set to anything
            const folder_path = "/home" ++ resurrect_folder_path;
            definitive_dir_path = folder_path;
        }

        std.fs.makeDirAbsolute(definitive_dir_path.?) catch |e| {
            switch (e) {
                error.PathAlreadyExists => {
                    // Do nothing, this is good.
                },
                else => { // For any other error type, we want to return here.
                    return e;
                },
            }
        };

        // Dump performs all IO/parsing of Tmux commands to aggregate the necessary data points to store the configuration file
        try self.dump();

        // Wait N minutes before running again
        std.time.sleep(resurrect_wait_time);
        // Recurse
        try self.save();
    }

    // Helper functions for capturing sessions/state data from Tmux
    //  Functionality is (somewhat) replicated from here: https://github.com/tmux-plugins/tmux-resurrect/blob/cff343cf9e81983d3da0c8562b01616f12e8d548/scripts/save.sh
    fn dump(self: Self) !void {
        // Dump all 3 formatters here into the respective structs, stringify the data, write to file
        _ = self;
        // Use res dump type and dump data for all 3 types
    }

    // Formatters - These are used for interacting with the tmux API to format the exracted data for storing
    fn formatPane(self: Self) []const u8 {
        _ = self;
        return "pane" ++ format_delimiter ++ "#{session_name}" ++ format_delimiter ++ "#{window_index}" ++ format_delimiter ++ "#{window_active}" ++ format_delimiter ++ ":#{window_flags}" ++ format_delimiter ++ "#{pane_index}" ++ format_delimiter ++ "#{pane_title}" ++ format_delimiter ++ ":#{pane_current_path}" ++ format_delimiter ++ "#{pane_active}" ++ format_delimiter ++ "#{pane_current_command}" ++ format_delimiter ++ "#{pane_pid}" ++ format_delimiter ++ "#{history_size}";
    }

    fn formatWindow(self: Self) []const u8 {
        _ = self;
        return "window" ++ format_delimiter ++ "#{session_name}" ++ format_delimiter ++ "#{window_index}" ++ format_delimiter ++ "#{window_active}" ++ format_delimiter ++ ":#{window_flags}" ++ format_delimiter ++ "#{window_layout}";
    }

    fn formatState(self: Self) []const u8 {
        _ = self;
        return "state" ++ format_delimiter ++ "#{client_session}" ++ format_delimiter + "#{client_last_session}";
    }

    /// Check the current tmux version to ensure we can run resurrect
    pub fn checkSupportedVersion(self: Self) !bool {
        const cur_version = try self.cleanTmuxString(try self.getTmuxVersion());
        const supported_version = try self.cleanTmuxString(supported_tmux_version);

        return (cur_version > supported_version);
    }

    // Simple timestamp wrapper
    fn timestamp(self: Self) i64 {
        _ = self;
        std.time.timestamp();
    }

    // Run tmux -V to get  version and collect output
    fn getTmuxVersion(self: Self) ![]u8 {
        var commands = try self.allocator.alloc([]const u8, 2);
        commands[0] = "tmux";
        commands[1] = "-V";
        return runCommand(commands, self.allocator);
    }

    // CLeans incoming tmux version string from tmux 3.2a => 32 etc..
    fn cleanTmuxString(self: Self, s_val: []const u8) !u8 {
        // Parse all the ASCII charaters to infer if they are ints or not. Leave *only* the ints as we check those for version comparision
        var version = std.ArrayList([]const u8).init(self.allocator);
        for (s_val) |value| {
            // 48 <-> 57 is the ascii char range for int's (we could also use std.ascii.isDigit() to parse this in a different way)
            if (value >= 48 and value <= 57) {
                // Convert back to char representation of utf-8 ascii value
                try version.append(try std.fmt.allocPrint(self.allocator, "{c}", .{value}));
            }
        }

        var parsed_version: []const u8 = undefined;
        for (version.items, 0..) |value, i| {
            if (i == 0) {
                parsed_version = try std.fmt.allocPrint(self.allocator, "{s}", .{value});
            } else {
                parsed_version = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ parsed_version, value });
            }
        }

        return try std.fmt.parseInt(u8, parsed_version, 10);
    }

    /// Print warning re: non-functional tmux version
    pub fn printWarning(self: Self) !void {
        print("{s}", .{try self.colorRed("Warning: Old version of tmux present, cannot store session state! Resurrect will not work!\n")});
    }

    pub fn printDisabledWarning(self: Self) !void {
        print("{s}", .{try self.colorRed("Warning: Resurrect is disabled via -disabled flag.\n")});
    }

    // Colors text red
    fn colorRed(self: Self, a: anytype) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ color_red, a, color_reset });
    }
};

// Generic helpers not stored in a struct
fn runCommand(command_data: [][]const u8, allocator: std.mem.Allocator) ![]u8 {
    var child = std.process.Child.init(command_data, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout = std.ArrayList(u8).init(allocator);
    var stderr = std.ArrayList(u8).init(allocator);

    try child.collectOutput(&stdout, &stderr, 1024 * 2 * 2);
    _ = try child.wait();

    return stdout.items;
}

test "Get tmux version and clean" {
    var resurrect = try Resurrect.init(std.heap.page_allocator);

    const version = try resurrect.getTmuxVersion();

    const int_ver = try resurrect.cleanTmuxString(version);

    print("{d}", .{int_ver});
}

test "tmux version check" {
    var resurrect = try Resurrect.init(std.heap.page_allocator);
    const version = try resurrect.getTmuxVersion();

    const int_ver = try resurrect.cleanTmuxString(version);

    const sup_ver = try resurrect.cleanTmuxString(supported_tmux_version);

    std.debug.assert(int_ver > sup_ver);
}

test "print warning on bad version" {
    var res = try Resurrect.init(std.heap.page_allocator);
    const res_supported = try res.checkSupportedVersion();

    std.debug.assert(res_supported);
    try res.printWarning();
}
