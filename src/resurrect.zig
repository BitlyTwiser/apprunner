const std = @import("std");
const runner = @import("runner.zig");

const assert = std.debug.assert;
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
const resurrect_file_name = "config.json";
const resurrect_wait_time = std.time.ms_per_min * 2;
const format_delimiter: []const u8 = "\\t"; // Used to seperate the lines in the formatters from the returned tmux data
const format_delimiter_u8 = '\t';

const resurrectDumpType = union(enum) {
    window,
    state,
    pane,

    const Self = @This();

    // We will need to tokenize the commands since its [][]const u8 that is passed to runCommand
    fn format(self: Self) []const []const u8 {
        switch (self) {
            .window => {
                return &[_][]const u8{ "list-windows", "-a", "-F" };
            },
            .state => {
                return &[_][]const u8{ "display-message", "-p" };
            },
            .pane => {
                return &[_][]const u8{ "list-panes", "-a", "-F" };
            },
        }
    }
};

// Resurrect File structure - Used for serializing the struct data into and out of the stored resurrect file.
const ResurrectFileData = struct {
    pane_data: []paneData,
    window_data: []windowData,
    state_data: stateData,

    const Self = @This();

    // Sets all the fields using the parsing from each specific data type
    fn set(self: *Self, allocator: std.mem.Allocator) !void {
        // Set all values from structs after reading tmux data
        // Look at making this a more generic interface itself so we can avoid this duplication

        @field(self, "pane_data") = try self.parse([]paneData, .pane, allocator);
        @field(self, "window_data") = try self.parse([]windowData, .window, allocator);
        @field(self, "state_data") = try self.parse(stateData, .state, allocator);
    }

    /// Performs JSON serialization and file storage from the resurrectFileData
    fn stringify(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var string = std.ArrayList(u8).init(allocator);
        try std.json.stringify(self, .{}, string.writer());

        return string.items;
    }

    // re-write to avoid setting all of the cli output initially. First split on the types to determine if we have a slice or struct
    // THat would mean changing the tyes of ResurrectData back to slices
    fn parse(self: *Self, comptime T: type, res_type: resurrectDumpType, allocator: std.mem.Allocator) !T {
        var data: T = undefined;
        const parsed = @typeInfo(@TypeOf(data));

        // We only expect slices (pointer) or Sructs in this particular case since we control the type upstream
        switch (parsed) {
            .Struct => {
                inline for (parsed.Struct.fields) |field| {
                    var iter = try self.innerParseData(@TypeOf(data), res_type, allocator);
                    while (iter.next()) |split_line| {
                        // After all the splitting, parse the individual fields
                        var i_split = std.mem.split(u8, split_line, format_delimiter);

                        while (i_split.next()) |i_line| {
                            print("parsing line - {s}\n", .{i_line});
                            const i_line_t = std.mem.trim(u8, i_line, " ");

                            // Now find the type of i_line_t and switch on that. Then parse for int, bool, or const etc..
                            switch (@typeInfo(field.type)) {
                                .Int => {
                                    const parsed_int = try std.fmt.parseInt(field.type, i_line_t, 10);
                                    @field(&data, field.name) = parsed_int;
                                },
                                .Bool => {
                                    @field(&data, field.name) = try self.parseBool(i_line_t);
                                },
                                .Pointer => {
                                    @field(&data, field.name) = i_line_t;
                                },
                                else => {
                                    unreachable; // We do not support anything else here! This is a rather static set of fields
                                },
                            }
                        }
                    }
                }
            },
            .Pointer => {
                const child = parsed.Pointer.child;
                var child_slice = std.ArrayList(child).init(allocator);
                // Parse the child resursively, this should hit the .Struct block to deserialize the values into the slice
                const parsed_child = try self.parse(child, res_type, allocator);

                // Build an array list of items of the child since the type is a Pointer
                try child_slice.append(parsed_child);

                // Now set the slice to the ascertained, destructered items
                data = child_slice.items;
            },
            else => {},
        }

        return data;
    }

    fn parseBool(self: Self, parse_value: []const u8) !bool {
        _ = self;
        if (std.mem.eql(u8, parse_value, "True") or std.mem.eql(u8, parse_value, "true") or std.mem.eql(u8, parse_value, "On") or std.mem.eql(u8, parse_value, "on")) {
            return true;
        } else if (std.mem.eql(u8, parse_value, "False") or std.mem.eql(u8, parse_value, "false") or std.mem.eql(u8, parse_value, "Off") or std.mem.eql(u8, parse_value, "off")) {
            return false;
        }

        return error.NotBoolean;
    }

    fn innerParseData(self: Self, comptime T: type, resDumpType: resurrectDumpType, allocator: std.mem.Allocator) !std.mem.SplitIterator(u8, .sequence) {
        _ = self;
        // ensure that the declaration exists else we error
        const has_decl = @hasDecl(T, "formatTmuxData");
        assert(has_decl);

        var data: T = undefined;

        // Below is a little unique - build out the []const []const u8 for the runCommand else commands fail to parse for some reason (with multiple flags?)
        const formatted_data = resDumpType.format();
        const a = try allocator.alloc([]const u8, formatted_data.len + 2);

        // First command is always a binary
        a[0] = "tmux";

        // Parse the formatted data and place in the respective sections in the formatted_data
        for (formatted_data, 1..) |value, i| {
            a[i] = value;
        }

        a[a.len - 1] = data.formatTmuxData();

        const tmux_data = try runCommand(a, std.heap.page_allocator);

        return std.mem.split(u8, tmux_data, "\n");
    }
};

const paneData = struct {
    session_name: []const u8 = "",
    window_index: u8 = 0,
    window_name: []const u8 = "",
    window_active: bool = false,
    window_flags: []const u8 = "",
    pane_index: u8 = 0,
    pane_title: []const u8 = "",
    pane_current_path: []const u8 = "",
    pane_active: bool = false,
    pane_current_command: []const u8 = "",
    pane_pid: []const u8 = "",
    history_size: []const u8 = "",

    const Self = @This();

    // Called in the parsing function, this must exist
    fn formatTmuxData(self: Self) []const u8 {
        _ = self;
        return "'" ++ "#{session_name}" ++ format_delimiter ++ "#{window_index}" ++ format_delimiter ++ "#{window_active}" ++ format_delimiter ++ ":#{window_flags}" ++ format_delimiter ++ "#{pane_index}" ++ format_delimiter ++ "#{pane_title}" ++ format_delimiter ++ ":#{pane_current_path}" ++ format_delimiter ++ "#{pane_active}" ++ format_delimiter ++ "#{pane_current_command}" ++ format_delimiter ++ "#{pane_pid}" ++ format_delimiter ++ "#{history_size}" ++ "'";
    }
};

const windowData = struct {
    session_name: []const u8 = "",
    window_index: u8 = 0,
    window_name: []const u8 = "",
    window_active: bool = false,
    window_flags: []const u8 = "",
    window_layout: []const u8 = "",

    const Self = @This();

    // Called in the parsing function, this must exist
    fn formatTmuxData(self: Self) []const u8 {
        _ = self;
        return "'" ++ "#{session_name}" ++ format_delimiter ++ "#{window_index}" ++ format_delimiter ++ "#{window_active}" ++ format_delimiter ++ ":#{window_flags}" ++ format_delimiter ++ "#{window_layout}" ++ "'";
    }
};

const stateData = struct {
    client_session: []const u8 = "",
    client_last_sessions: []const u8 = "",

    const Self = @This();

    // Called in the parsing function, this must exist
    fn formatTmuxData(self: Self) []const u8 {
        _ = self;
        return "'" ++ "#{client_session}" ++ format_delimiter ++ "#{client_last_session}" ++ "'";
    }
};

/// Resurrect is in charge of snapshotting current user state and restoring state on load.
pub const Resurrect = struct {
    allocator: std.mem.Allocator,
    const Self = @This();

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
        // Write err to logfile
        errdefer |err| {
            var file: ?std.fs.File = undefined;
            file = std.fs.createFileAbsolute("/var/log/resurrect_error.log", .{}) catch null;

            if (file) |f| {
                var buf: [1024]u8 = undefined;
                const err_string = std.fmt.bufPrint(&buf, "error: {any}", .{err}) catch "";
                _ = f.write(err_string) catch print("error writing file on save", .{});
                f.close();
            }
        }

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

        var dir = std.fs.Dir{ .fd = 0 };
        _ = dir.makeOpenPath(definitive_dir_path.?, .{}) catch |e| {
            switch (e) {
                error.PathAlreadyExists => {
                    print("Here?\n", .{});
                    // Do nothing, this is good.
                },
                else => { // For any other error type, we want to return here.
                    print("return {any}\n", .{e});
                    return;
                },
            }
            return;
        };

        var buf: [2048]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ definitive_dir_path.?, resurrect_file_name });

        var file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();

        // Dump performs all IO/parsing of Tmux commands to aggregate the necessary data points to store the configuration file
        try self.dump(file);

        // Wait N minutes before running again
        std.time.sleep(resurrect_wait_time);
        // Recurse
        try self.save();
    }

    // Helper functions for capturing sessions/state data from Tmux
    //  Functionality is (somewhat) replicated from here: https://github.com/tmux-plugins/tmux-resurrect/blob/cff343cf9e81983d3da0c8562b01616f12e8d548/scripts/save.sh
    fn dump(self: Self, file: std.fs.File) !void {
        // Dump all 3 formatters here into the respective structs, stringify the data, write to file
        var file_data = ResurrectFileData{ .pane_data = &[_]paneData{}, .window_data = &[_]windowData{}, .state_data = stateData{} };

        // Set all file data
        try file_data.set(self.allocator);

        // Capture JSON data and pass to file
        const json_parsed_data = try file_data.stringify(self.allocator);

        //  Dump JSON data to given file.
        try file.writer().writeAll(json_parsed_data);
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
        return runCommand(&[_][]const u8{ "tmux", "-V" }, self.allocator);
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

// run arbitrary cli commands and collect stderr & stdout
fn runCommand(command_data: []const []const u8, allocator: std.mem.Allocator) ![]u8 {
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

// test "command" {
//     const data = try runCommand(&[_][]const u8{ "tmux", "list-windows", "-a", "-F", "'#{session_name}\\t#{window_index}\\t#{window_active}\\t:#{window_flags}\\t#{window_layout}'" }, std.heap.page_allocator);

//     print("{s}", .{data});
// }

fn test_sig() !void {}

test test_sig {
    var res = try Resurrect.init(std.heap.page_allocator);

    // Should end up with save file
    try res.save();
}
