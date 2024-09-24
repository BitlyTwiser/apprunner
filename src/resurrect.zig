const std = @import("std");
const print = std.debug.print;

const supported_tmux_version = "1.9"; // Restore/resurrect flags do not work on older versions of tmux

// Ansi escape codes
//ansi escape codes
const esc = "\x1B";
const csi = esc ++ "[";
const color_reset = csi ++ "0m";
const color_fg = "38;5;";
const color_bg = "48;5;";

const color_fg_def = csi ++ color_fg ++ "15m"; // white
const color_bg_def = csi ++ color_bg ++ "0m"; // black
const color_red = csi ++ "31m"; // red

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

    /// ran in a thread on start of the application which stores session data every N Seconds/Minutes
    pub fn storeSessionData(self: Self) !void {
        _ = self;
    }

    /// Check the current tmux version to ensure we can run resurrect
    pub fn checkSupportedVersion(self: Self) !bool {
        _ = self;
        return false;
    }

    // Run tmux -V to get  version and collect output
    fn getTmuxVersion(self: Self) ![]u8 {
        var child = std.process.Child.init(&[_][]const u8{ "tmux", "-V" }, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        var stdout = std.ArrayList(u8).init(self.allocator);
        var stderr = std.ArrayList(u8).init(self.allocator);

        try child.collectOutput(&stdout, &stderr, 1024 * 2 * 2);
        _ = try child.wait();

        return stdout.items;
    }

    // CLeans incoming tmux version string from tmux 3.2a => 32 etc..
    fn cleanTmuxString(self: Self, s_val: []const u8) u8 {
        _ = self;
        _ = s_val;
    }

    /// Print warning re: non-functional tmux version
    fn printWarning(self: Self) void {
        print("{s}", self.colorRed("Warning: Old version of tmux present, cannot store session state! Resurrect will not work"));
    }

    // Colors text red
    fn colorRed(self: Self, a: anytype) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}{c}{s}", .{ color_red, a, color_reset });
    }
};

test "Get tmux version and clean" {
    var resurrect = try Resurrect.init(std.heap.page_allocator);

    const version = try resurrect.getTmuxVersion();

    print("{s}", .{version});
}
