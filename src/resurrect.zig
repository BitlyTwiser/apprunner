const std = @import("std");
const r_i = @import("runner.zig");
const runner = r_i.Runner;
const config = @import("config.zig");
const utils = @import("utils.zig");

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
const resurrect_wait_time = std.time.ns_per_min * 1; // 2 minutes
const format_delimiter: []const u8 = "\\t"; // Used to seperate the lines in the formatters from the returned tmux data
const format_delimiter_u8 = '\t';

// Invalid char set
const invalid_char_set = [_][]const u8{ " ", ",", "" };

// Chars for pane splitting:
const horizontal_start = "[";
const horizontal_end = "]";
const vertical_start = "{";
const vertical_end = "}";

const splitErr = error{ SplitError, OutOfMemory };

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

const paneSplitType = union(enum) {
    horizontal,
    vertical,
    empty, // Empty case where we only ahve initial window. In which case we can exit early when spawning windows
    none, // The case where we just have a base window, no splits

    const Self = @This();

    fn startToken(self: Self) ?[]const u8 {
        switch (self) {
            .horizontal => {
                return horizontal_start;
            },
            .vertical => {
                return vertical_start;
            },
            else => {
                return null;
            },
        }
    }

    fn endToken(self: Self) ?[]const u8 {
        switch (self) {
            .horizontal => {
                return horizontal_end;
            },
            .vertical => {
                return vertical_end;
            },
            else => {
                return null;
            },
        }
    }
};

const paneSplitDataMeta = struct {
    p_type: paneSplitType,
    coord_set: []const u8, // The X->Y value (i.e. 88X90) value for this type
};

const paneSplitData = struct {
    initial: []const u8 = "", // Default value of none since we set this early in iterations of parsing layout
    panes: std.ArrayList(paneSplitDataMeta),
    p_type: paneSplitType = .none,
    parent: paneSplitType = .none, // Track the parent so we can order things properly

    const Self = @This();

    fn addLeaf(self: *Self, p_type: paneSplitType, data: paneSplitDataMeta) !void {
        _ = p_type;
        try self.panes.append(data);
    }

    fn isEmpty(self: Self) bool {
        return self.p_type == .empty;
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
    fn convertJSON(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var w = std.ArrayList(u8).init(allocator);
        try std.json.stringify(self, .{ .emit_strings_as_arrays = true }, w.writer());

        return w.items;
    }

    /// parse tmux data and set the value sof the given T type
    fn parse(self: *Self, comptime T: type, res_type: resurrectDumpType, allocator: std.mem.Allocator) !T {
        var data: T = undefined;
        var data_set: bool = false;
        const parsed = @typeInfo(@TypeOf(data));

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

            // We totally break out when the name does not match apprunner session
            if (index == 0 and !std.mem.eql(u8, line, r_i.app_name)) break :i_for;

            // Ensure no char is from the invalid set
            for (invalid_char_set) |i_char| {
                if (std.mem.eql(u8, line, i_char)) invalid_char = true;
            }

            data_set.* = true;
            // Always dupe else the next pointer causes issues when iterating
            var dupe_i_line = try allocator.dupe(u8, line);

            // Now find the type of i_line_t and switch on that. Then parse for int, bool, or const etc..
            switch (@typeInfo(field.type)) {
                .Int => {
                    if (invalid_char) dupe_i_line = @constCast("0");
                    @field(&interface, field.name) = try std.fmt.parseInt(field.type, dupe_i_line, 10);
                },
                .Bool => {
                    if (invalid_char) dupe_i_line = @constCast("false");
                    @field(&interface, field.name) = try self.parseBool(dupe_i_line);
                },
                .Pointer => {
                    if (invalid_char) dupe_i_line = @constCast("");
                    @field(&interface, field.name) = dupe_i_line;
                },
                else => {
                    unreachable; // We do not support anything else here! This is a rather static set of fields
                },
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

        // Below is a little unique/messy - build out the []const []const u8 for the runCommand else commands fail to parse. Look at replacing this with the command creation like we do for the other commands (i.e. get shell etc..)
        const formatted_data = resDumpType.format();
        const a = try allocator.alloc([]const u8, formatted_data.len + 2);

        // First command is always a binary
        a[0] = "tmux";

        // Parse the formatted data and place in the respective sections in the formatted_data
        for (formatted_data, 1..) |value, i| {
            a[i] = value;
        }

        a[a.len - 1] = data.formatTmuxData();

        const tmux_data = try utils.runCommand(a, allocator);

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

    // Window layout is stored in a comma seperated string
    fn parseWindowLayout(self: Self, allocator: std.mem.Allocator) !paneSplitData {
        var pane_data = paneSplitData{
            .panes = std.ArrayList(paneSplitDataMeta).init(allocator),
        };
        // get first value to determine base pane sizes. The very first UUID that tmux passes is superfluous and used for internal tmux tracking. So we skip it.
        var tokens = std.mem.tokenize(u8, self.window_layout, ",");
        // Skip the first (tmux uuid value) and grab the initial pane data.
        _ = tokens.next();
        const initial_pane = tokens.next();

        // take remaining buffer after the index from first value parsing and determine horizontal/vertical layout
        pane_data.initial = initial_pane.?;
        const buffer = tokens.buffer[tokens.index..];

        // Exit early if there is nothing left to do
        if (!self.isHorizontal(buffer) and !self.isVertical(buffer)) {
            pane_data.p_type = .empty;

            return pane_data;
        }

        // Get first index of the offending character i.e. [ and then the last. Everthing in that sector is horiztonal until we hit another offending and differentiation bracket. I.e. {}
        // Split on every X. For each value we find that matches this, insert the leaf
        const h_start = std.mem.indexOf(u8, buffer, horizontal_start);
        const v_start = std.mem.indexOf(u8, buffer, vertical_start);

        // Determine where we start parsing the buffer value from. i.e. horizontal or vertical bucket split. If its neither, we would never reach this case based on the above check for vert/horizontal
        if (h_start != null and v_start != null and h_start.? < v_start.?) {
            try self.parseRecurse(buffer, .horizontal, &pane_data, allocator);
        } else if (h_start == null and v_start != null) {
            try self.parseRecurse(buffer, .vertical, &pane_data, allocator);
        } else if (v_start == null and h_start != null) {
            try self.parseRecurse(buffer, .horizontal, &pane_data, allocator);
        } else if (h_start != null and v_start != null and v_start.? < h_start.?) {
            try self.parseRecurse(buffer, .vertical, &pane_data, allocator);
        }

        return pane_data;
    }

    // Parses out the []const []const u8 values from a given chain of values. Performs a modified sliding window
    fn parseRecurse(self: Self, data: []const u8, p_type: paneSplitType, p_split_data: *paneSplitData, allocator: std.mem.Allocator) !void {
        var first_index: usize = 0;
        var last_index: usize = 0;
        var offending_index: ?usize = 0;
        var offending_type: ?paneSplitType = null;
        var stop_index: usize = 0;

        print("type {any}\n", .{p_type});

        // End recursion case as well
        if (data.len == 0) return;

        switch (p_type) {
            .horizontal => {
                first_index = std.mem.indexOf(u8, data, horizontal_start) orelse 0;
                last_index = std.mem.lastIndexOf(u8, data, horizontal_end) orelse 0;

                offending_index = std.mem.indexOf(u8, data, vertical_start);
                if (offending_index != null) {
                    offending_type = .vertical;
                }
            },
            .vertical => {
                first_index = std.mem.indexOf(u8, data, vertical_start) orelse 0;
                last_index = std.mem.lastIndexOf(u8, data, vertical_end) orelse 0;

                offending_index = std.mem.indexOf(u8, data, horizontal_start);
                if (offending_index != null) {
                    offending_type = .horizontal;
                }
            },
            else => {
                return;
            },
        }

        if (data.len == 0) return;
        const slice = data[first_index + 1 .. last_index];
        var iter = std.mem.tokenize(u8, slice, ",");

        // Calculate stop offset to ensure we do not miss values whilst sliding below
        const stop_offset = (data.len - slice.len);

        if (offending_index) |index| {
            stop_index = index;
        } else {
            stop_index = last_index;
        }

        var index: usize = 0;
        while (iter.next()) |val| {
            index += val.len;
            if (index >= stop_index - stop_offset and offending_type != null) {
                return try self.parseRecurse(slice[stop_index - stop_offset ..], offending_type.?, p_split_data, allocator);
            } else {
                if (std.mem.containsAtLeast(u8, val, 1, "x")) {
                    try p_split_data.addLeaf(p_type, paneSplitDataMeta{ .p_type = p_type, .coord_set = try allocator.dupe(u8, val) });
                }
            }
        }
    }

    // Very high (and shitty) level checks of horizontal or vertical. Used only for the very base case
    fn isHorizontal(self: Self, data: []const u8) bool {
        _ = self;
        return (std.mem.containsAtLeast(u8, data, 1, horizontal_start) and std.mem.containsAtLeast(u8, data, 1, horizontal_end));
    }

    fn isVertical(self: Self, data: []const u8) bool {
        _ = self;
        return (std.mem.containsAtLeast(u8, data, 1, vertical_start) and std.mem.containsAtLeast(u8, data, 1, vertical_end));
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
    pane_map: std.StringHashMap(std.ArrayList(paneData)),
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{ .allocator = allocator, .pane_map = std.StringHashMap(std.ArrayList(paneData)).init(allocator) };
    }

    /// Restores the given session data when called
    pub fn restoreSession(self: Self) !void {
        // Read from the given config file location and de-serialize the json data from slice
        const config_file_path = try self.configFilePath();

        const file = std.fs.openFileAbsolute(config_file_path, .{ .mode = .read_only }) catch |e| {
            switch (e) {
                error.FileNotFound => {
                    print("Tmux resurrect config file was not found at: {s}. Please run the application normally", .{config_file_path});
                },
                else => {
                    return e;
                },
            }
            return;
        };

        // Alloc print here. Might be a heapless way of doing this file io, but realloc is always fun
        const buf = try file.reader().readAllAlloc(self.allocator, 1024 * 2 * 2);
        const json_parsed = try std.json.parseFromSlice(ResurrectFileData, self.allocator, buf, .{});
        defer json_parsed.deinit();

        const res_data = json_parsed.value;

        try self.restore(res_data);
    }

    fn restore(self: Self, data: ResurrectFileData) !void {
        // Make a stringMap of the pane data so we can easily find N panes for a window name
        var pane_map = self.pane_map;

        // Lazily build out map for matching panes to windows below whilst restoring
        for (data.pane_data) |pane| {
            if (pane_map.contains(pane.window_name)) {
                if (pane_map.get(pane.window_name)) |pane_m| {
                    var p = pane_m;
                    try p.append(pane);
                }
            } else {
                var pane_array_list = std.ArrayList(paneData).init(self.allocator);
                try pane_array_list.append(pane);
                try pane_map.put(pane.window_name, pane_array_list);
            }
        }

        // Thread break down: 1 for session, N number of panes, N number of windows. Take number of windows, divide eavenly. Add 1 if odd.
        // Build thread count based on panes and the 1 session. Realloc based on window count.
        var thread_pool = std.ArrayList(std.Thread).init(self.allocator);

        // Spawns session to build all the windows and panes within. If this errors we should probably handle it and return gracefully
        try thread_pool.append(try self.sessionsCreateSpawnThread());

        std.time.sleep(100000 * 1024);

        // Iterate over all windows, if there are panes within the window, create/split the panes
        for (data.window_data, 0..) |window, index| {
            const layout_parsed = try window.parseWindowLayout(self.allocator);
            const window_thread_pool = try self.createWindow(window, @constCast(&layout_parsed), index);

            // Insert all threads into the pool
            for (window_thread_pool) |window_thread| {
                try thread_pool.append(window_thread);
            }
        }

        // Iterate over the panes creating each pane as we go.
        // var map_iter = pane_map.iterator();
        // while (map_iter.next()) |pm| {
        //     const pane_data = pane_map.get(pm.key_ptr.*) orelse continue;

        //     for (pane_data.items) |p_item| {
        //         try thread_pool.append(try std.Thread.spawn(.{}, createPane, .{ self, p_item }));
        //     }
        // }

        // print("tp len {d}\n", .{thread_pool.len});
        // Join is what actually runs stuff, so we attempt to slow down here with awaiting shells to spawn
        for (thread_pool.items) |i_thread| {
            i_thread.join();
        }
    }

    // Wrap sleep since we do this a fair bit awaiting windows and sessions to spawn.
    fn sleep(self: Self) void {
        _ = self;
        std.time.sleep(100000 * 1024);
    }

    // Tmux code is backwards (o.0) -v is horizontal -h is vertical. I have no idea why. So [] is horizontal, but you must run the -v command to split  horizontally
    fn createWindow(self: Self, window_data: windowData, layout: *paneSplitData, index: usize) ![]std.Thread {
        var thread_pool = std.ArrayList(std.Thread).init(self.allocator);
        // var thread_pool = try self.allocator.alloc(std.Thread, 1);

        const base_command = try r_i.commandBase(self.allocator);
        const sub_command = try r_i.subCommand();
        const command = try std.fmt.allocPrint(self.allocator, "tmux new-window -t {s} \\; rename-window -t {s}:{d} {s}", .{ r_i.app_name, r_i.app_name, index, window_data.window_name });

        try thread_pool.append(try std.Thread.spawn(.{}, utils.runCommandEmpty, .{ &[_][]const u8{ base_command, sub_command, command }, self.allocator }));

        self.sleep();

        // if there is nothing else, i.e. no panes in the window, just exit since there is nothing to split on anyway. This is really the case of only initial existing
        if (layout.isEmpty()) {
            return thread_pool.items;
        }

        // Split in orders of 2, find the largest value of the two and use that for split
        // Is it even? If not, we curate a pan from the last remianing value. Otherwise we evenly split into secors of 2 as the coordinates from the layout are always in pairs PER pane. (i.e. two values per pane for X&Y)
        const odd = (@mod(layout.panes.items.len, 2) != 0);
        var last_pane: ?paneSplitDataMeta = null;

        if (odd) {
            const len = layout.panes.items.len;
            last_pane = layout.panes.items[len];
            // resize to remove last value?
            try layout.panes.resize(len - 1);
        }

        // Calculated based on the entire length of windows ascertained from above after the odd removal and divided evenly

        // Dedup coord sets into their respective pairs. Pick the larger, send forth with command
        // parse the window layout, split all the windows as needed
        var i_val: usize = 0;
        var thread_pool_index: usize = 0;
        while (i_val < layout.panes.items.len) : (thread_pool_index += 1) {
            const first = layout.panes.items[i_val];
            const second = layout.panes.items[i_val + 1];

            var s_f = std.mem.tokenize(u8, first.coord_set, "x");
            var s_s = std.mem.tokenize(u8, second.coord_set, "x");

            // Some odd stuff to compare the size of the given coords of ether set
            const s_f_f = try std.fmt.parseInt(u8, s_f.next() orelse "0", 10);
            const s_s_s = try std.fmt.parseInt(u8, s_s.next() orelse "0", 10);

            const first_int = try std.fmt.parseInt(u8, s_f.next() orelse "0", 10);
            const second_int = try std.fmt.parseInt(u8, s_s.next() orelse "0", 10);

            //Split the window. Note: These are reversed, so its -v for horizontal and -h for vertical -_- fkn Tmux
            if (first_int > second_int or s_f_f > s_s_s) {
                try thread_pool.append(try std.Thread.spawn(.{}, runPaneCommand, .{ self, window_data, first, layout }));
            } else {
                try thread_pool.append(try std.Thread.spawn(.{}, runPaneCommand, .{ self, window_data, second, layout }));
            }

            i_val += 2;
        }

        // Run the odd man out if it exists so we do not miss any windows. This is quite an edge case and am unsure when this would even commence
        if (odd) {
            try thread_pool.append(try std.Thread.spawn(.{}, runPaneCommand, .{ self, window_data, last_pane.?, layout }));
        }

        return thread_pool.items;
    }

    // We might need to run all of these in threads to stop from early execution
    fn runPaneCommand(self: Self, window_data: windowData, data: paneSplitDataMeta, layout: *paneSplitData) !void {
        const base_command = try r_i.commandBase(self.allocator);
        const sub_command = try r_i.subCommand();
        const coord_data = data.coord_set;
        switch (data.p_type) {
            .horizontal => {
                const i_command = try std.fmt.allocPrint(self.allocator, "tmux split-window -t {s} -v -p {d}", .{ window_data.window_name, try self.calculateSplitPercentage(.horizontal, layout.initial, coord_data) });
                try utils.runCommandEmpty(&[_][]const u8{ base_command, sub_command, i_command }, self.allocator);
            },
            .vertical => {
                const i_command = try std.fmt.allocPrint(self.allocator, "tmux split-window -t {s} -h -p {d}", .{ window_data.window_name, try self.calculateSplitPercentage(.vertical, layout.initial, coord_data) });
                try utils.runCommandEmpty(&[_][]const u8{ base_command, sub_command, i_command }, self.allocator);
            },
            else => {
                return;
            },
        }

        self.sleep();
    }

    fn calculateSplitPercentage(self: Self, p_type: paneSplitType, base_val: []const u8, coord_set: []const u8) !usize {
        _ = self;
        var coords = std.mem.tokenize(u8, coord_set, "x");
        var base = std.mem.tokenize(u8, base_val, "x");

        const x = try std.fmt.parseInt(u8, coords.next() orelse "", 10);
        const y = try std.fmt.parseInt(u8, coords.next() orelse "", 10);

        const x_base = try std.fmt.parseInt(u8, base.next() orelse "", 10);
        const y_base = try std.fmt.parseInt(u8, base.next() orelse "", 10);

        // now divide based on type
        switch (p_type) {
            .horizontal => {
                return x / x_base;
            },
            .vertical => {
                return y / y_base;
            },
            else => {
                return 0;
            },
        }
    }

    //  Build the pane from the pane_data passed in
    fn createPane(self: Self, pane_data: paneData) !void {
        // Run this command to switch to the pane and run the command
        const command = try std.fmt.allocPrint(self.allocator, "tmux switch-client -t {s}:{d} \\; select-pane -t {d} \\; send-keys -t {s}:{d}.{d} '{s}' enter", .{ pane_data.session_name, pane_data.window_index, pane_data.pane_index, pane_data.session_name, pane_data.window_index, pane_data.pane_index, pane_data.pane_current_command });
        const base_command = try r_i.commandBase(self.allocator);
        const sub_command = try r_i.subCommand();
        try utils.runCommandEmpty(&[_][]const u8{ base_command, sub_command, command }, self.allocator);
    }

    // Wrapper to spawn thread so it does not exit.
    fn sessionsCreateSpawnThread(self: Self) !std.Thread {
        return try std.Thread.spawn(.{}, initialSessionCreate, .{self});
    }

    // Spawns the initial session that all windows and panes are placed into using default app name
    fn initialSessionCreate(self: Self) !void {
        const command = try std.fmt.allocPrint(self.allocator, "tmux new-session -s {s}", .{r_i.app_name});
        try utils.runCommandEmptyWithShell(command, self.allocator);
    }

    /// Wrapper around save to run this in a thread. Runs indefinitely until os.Exit()
    pub fn saveThread(self: Self) !void {
        const t = try std.Thread.spawn(.{}, save, .{self});
        t.detach();
    }

    /// ran in a thread on start of the application which stores session data every N Seconds/Minutes
    /// This is a rolling backup - no copies are stored
    pub fn save(self: Self) !void {
        print("we should definitely not be here", .{});

        // Write err to logfile - unsure if this even works lol
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

        const config_file_path = try self.configFilePath();

        var file = try std.fs.createFileAbsolute(config_file_path, .{});
        defer file.close();

        // Dump performs all IO/parsing of Tmux commands to aggregate the necessary data points to store the configuration file
        try self.dump(file);

        // Wait N minutes before running again
        std.time.sleep(resurrect_wait_time);
        // Recurse and retry/perform save
        try self.save();
    }

    fn configFilePath(self: Self) ![]u8 {
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
                    // Do nothing, this is good.
                },
                else => { // For any other error type, we want to return here.
                    return e;
                },
            }
        };

        var buf: [2048]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ definitive_dir_path.?, resurrect_file_name });

        return file_path;
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
        return utils.runCommand(&[_][]const u8{ "tmux", "-V" }, self.allocator);
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

fn test_sig_restore() !void {}

test test_sig_restore {
    var res = try Resurrect.init(std.heap.page_allocator);
    try res.restoreSession();

    print("I should never get hit", .{});
}

test "Store some json data" {
    const file_data = ResurrectFileData{ .pane_data = &[_]paneData{}, .window_data = &[_]windowData{}, .state_data = &[_]stateData{} };
    var w = std.ArrayList(u8).init(std.heap.page_allocator);
    try std.json.stringify(file_data, .{}, w.writer());

    // Test empty struct serializes as we expect
    assert(std.mem.eql(u8, "{\"pane_data\":[],\"window_data\":[],\"state_data\":[]}", w.items));
}
