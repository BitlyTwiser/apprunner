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
const resurrect_wait_time = std.time.ns_per_min * 2; // 2 minutes
const format_delimiter: []const u8 = "\\t"; // Used to seperate the lines in the formatters from the returned tmux data
const format_delimiter_u8 = '\t';

// Invalid char set
const invalid_char_set = [_][]const u8{ "-", " ", ",", "" };

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
    state_data: []stateData,

    const Self = @This();

    // Sets all the fields using the parsing from each specific data type
    fn set(self: *Self, allocator: std.mem.Allocator) !void {

        // Set all values from structs after reading tmux data
        @field(self, "pane_data") = try self.parse([]paneData, .pane, allocator);
        @field(self, "window_data") = try self.parse([]windowData, .window, allocator);
        @field(self, "state_data") = try self.parse([]stateData, .state, allocator);
    }

    /// Performs JSON serialization and file storage from the resurrectFileData
    fn convertJSON(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        var w = std.ArrayList(u8).init(allocator);
        try std.json.stringify(self, .{}, w.writer());

        return w.items;
    }

    /// parse tmux data and set the value sof the given T type
    fn parse(self: *Self, comptime T: type, res_type: resurrectDumpType, allocator: std.mem.Allocator) !T {
        var data: T = undefined;
        var data_set: bool = false;
        const parsed = @typeInfo(@TypeOf(data));

        print("{any}", .{res_type});

        switch (parsed) {
            // We are only ever dealing with .Pointer types
            .Pointer => {
                // Make ArrayList, iterate through all lines for each child and set value in ArrayList. 1 -> N values expected from the iter
                const child = parsed.Pointer.child;
                var child_slice = std.ArrayList(child).init(allocator);

                var iter = try self.innerTmuxData(child, res_type, allocator);

                while (iter.next()) |line| {
                    if (std.mem.eql(u8, line, "")) continue;

                    const split_line_i = std.mem.trim(u8, line, "'");
                    const it = std.mem.split(u8, split_line_i, format_delimiter);

                    const data_c = try self.innerParseTmuxData(child, u8, it, allocator, &data_set);

                    try child_slice.append(data_c);
                }

                // Now set the slice to the ascertained, destructered items
                data = child_slice.items;
            },
            else => {
                unreachable;
            },
        }

        // This is a major hack. We set T to undefiend above which would cause issues when we skipped assiging data to field due to non-matching app name.
        // So, we have to ensure data is set else an undefined struct is passed back causing havoc
        if (!data_set) {
            switch (parsed) {
                .Struct => {
                    return T{};
                },
                else => {
                    return data;
                },
            }
        }

        return data;
    }

    fn parseBool(self: Self, parse_value: []const u8) !bool {
        _ = self;
        if (std.mem.eql(u8, parse_value, "True") or std.mem.eql(u8, parse_value, "true") or std.mem.eql(u8, parse_value, "On") or std.mem.eql(u8, parse_value, "on") or std.mem.eql(u8, parse_value, "1")) {
            return true;
        } else if (std.mem.eql(u8, parse_value, "False") or std.mem.eql(u8, parse_value, "false") or std.mem.eql(u8, parse_value, "Off") or std.mem.eql(u8, parse_value, "off") or std.mem.eql(u8, parse_value, "0")) {
            return false;
        }

        return error.NotBoolean;
    }

    /// Parses Tmux data (iterator) into passed Struct (T). Its always assumed this is a struct as the parent calling function performs the validation of this fact
    fn innerParseTmuxData(self: Self, comptime T: type, comptime iter_type: type, iter: std.mem.SplitIterator(iter_type, .sequence), allocator: std.mem.Allocator, data_set: *bool) !T {
        // Avoid any case where somehow this is not a struct
        if (@typeInfo(T) != .Struct) return undefined;

        var iter_c = iter;
        var interface: T = undefined;
        const interface_parsed = @typeInfo(@TypeOf(interface));

        i_for: inline for (interface_parsed.Struct.fields, 0..) |field, index| {
            var invalid_char: bool = false;
            const line = iter_c.next() orelse "";
            print("Line value: {s} - Index: {d}\n", .{ line, index });

            // We totally break out when the name does not match apprunner session
            if (index == 0 and !std.mem.eql(u8, line, runner.app_name)) break :i_for;

            // Ensure no char is from the invalid set
            for (invalid_char_set) |i_char| {
                if (std.mem.eql(u8, line, i_char)) invalid_char = true;
            }

            if (!invalid_char) {
                data_set.* = true;
                // Always dupe else the next pointer causes issues when iterating
                const dupe_i_line = try allocator.dupe(u8, line);

                print("Line {s}\n", .{dupe_i_line});
                // Now find the type of i_line_t and switch on that. Then parse for int, bool, or const etc..
                switch (@typeInfo(field.type)) {
                    .Int => {
                        @field(&interface, field.name) = try std.fmt.parseInt(field.type, dupe_i_line, 10);
                    },
                    .Bool => {
                        @field(&interface, field.name) = try self.parseBool(dupe_i_line);
                    },
                    .Pointer => {
                        @field(&interface, field.name) = dupe_i_line;
                    },
                    else => {
                        unreachable; // We do not support anything else here! This is a rather static set of fields
                    },
                }
            }
        }

        return interface;
    }

    /// obtains the data from the tmux command based on the dumpType and returns an iter to the calling function
    fn innerTmuxData(self: Self, comptime T: type, resDumpType: resurrectDumpType, allocator: std.mem.Allocator) !std.mem.SplitIterator(u8, .sequence) {
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

    /// Counts the length of values (next pointers) in an iter
    fn iterLen(self: Self, comptime T: type, iter: std.mem.SplitIterator(T, .sequence)) usize {
        _ = self;
        // we have to do this else Zig complains about constant -_-
        var iter_c = iter;
        var count: usize = 0;

        while (iter_c.next()) |l| {
            if (std.mem.eql(u8, l, "")) continue;
            print("{s}\n", .{l});
            count += 1;
        }

        return count;
    }
};

// Note: All data fields sart with session_name to avoid grabbing data from bad sessions (i.e. not apprunner sessions)
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
        return "'" ++ "#{session_name}" ++ format_delimiter ++ "#{window_index}" ++ format_delimiter ++ "#{window_name}" ++ format_delimiter ++ "#{window_active}" ++ format_delimiter ++ "#{window_flags}" ++ format_delimiter ++ "#{pane_index}" ++ format_delimiter ++ "#{pane_title}" ++ format_delimiter ++ "#{pane_current_path}" ++ format_delimiter ++ "#{pane_active}" ++ format_delimiter ++ "#{pane_current_command}" ++ format_delimiter ++ "#{pane_pid}" ++ format_delimiter ++ "#{history_size}" ++ "'";
    }
};

const windowData = struct {
    session_name: []const u8 = "",
    window_index: u8 = 0,
    window_name: []const u8 = "",
    window_active: bool = false,
    window_flags: []const u8 = "",
    window_layout: []const u8 = "", // Window layout is seperacted by ',' .i.e.  the value will look like: 142x43,0,0,1

    const Self = @This();

    // Called in the parsing function, this must exist
    fn formatTmuxData(self: Self) []const u8 {
        _ = self;
        return "'" ++ "#{session_name}" ++ format_delimiter ++ "#{window_index}" ++ format_delimiter ++ "#{window_name}" ++ format_delimiter ++ "#{window_active}" ++ format_delimiter ++ "#{window_flags}" ++ format_delimiter ++ "#{window_layout}" ++ "'";
    }
};

const stateData = struct {
    session_name: []const u8 = "",
    client_session: []const u8 = "",
    client_last_sessions: []const u8 = "",

    const Self = @This();

    // Called in the parsing function, this must exist
    fn formatTmuxData(self: Self) []const u8 {
        _ = self;
        return "'" ++ "#{session_name}" ++ format_delimiter ++ "#{client_session}" ++ format_delimiter ++ "#{client_last_session}" ++ "'";
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
        // Read from the given config file location and de-serialize the json data from slice
        const json_parsed = try std.json.parseFromSlice(ResurrectFileData, self.allocator, "", .{});
        defer json_parsed.deinit();

        // DO something with the value when we go to restore. This is the long process
        print("{any}", .{json_parsed.value});
    }

    /// Wrapper around save to run this in a thread. Runs indefinitely until os.Exit()
    pub fn saveThread(self: Self) !void {
        const t = try std.Thread.spawn(.{}, save, .{self});
        t.detach();
    }

    /// Ascertains the parsed json data in the form of the ResurrectFileData struct to restore the processes and sessions within
    pub fn restore(self: Self, restore_data: ResurrectFileData) !void {
        _ = self;
        _ = restore_data;
    }

    /// ran in a thread on start of the application which stores session data every N Seconds/Minutes
    /// This is a rolling backup - no copies are stored
    pub fn save(self: Self) !void {
        // Write err to logfile
        errdefer |err| {
            var file: ?std.fs.File = undefined;
            file = std.fs.createFileAbsolute("/var/tmp/apprunner_error.log", .{}) catch null;

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
        // Recurse and retry/perform save
        try self.save();
    }

    // Helper functions for capturing sessions/state data from Tmux
    //  Functionality is (somewhat) replicated from here: https://github.com/tmux-plugins/tmux-resurrect/blob/cff343cf9e81983d3da0c8562b01616f12e8d548/scripts/save.sh
    fn dump(self: Self, file: std.fs.File) !void {
        // Dump all 3 formatters here into the respective structs, stringify the data, write to file
        var file_data = ResurrectFileData{ .pane_data = &[_]paneData{}, .window_data = &[_]windowData{}, .state_data = &[_]stateData{} };

        // Set all file data
        try file_data.set(self.allocator);

        // Capture JSON data and pass to file
        const json_parsed_data = try file_data.convertJSON(self.allocator);

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

fn test_sig() !void {}

test test_sig {
    var res = try Resurrect.init(std.heap.page_allocator);

    // Should end up with save file
    try res.save();
}

test "Store some json data" {
    const file_data = ResurrectFileData{ .pane_data = &[_]paneData{}, .window_data = &[_]windowData{}, .state_data = stateData{} };
    var w = std.ArrayList(u8).init(std.heap.page_allocator);
    try std.json.stringify(file_data, .{}, w.writer());

    // Test empty struct serializes as we expect
    assert(std.mem.eql(u8, "{\"pane_data\":[],\"window_data\":[],\"state_data\":{\"session_name\":\"\",\"client_session\":\"\",\"client_last_sessions\":\"\"}}", w.items));
}
