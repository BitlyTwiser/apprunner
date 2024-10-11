const std = @import("std");
const assert = std.debug.assert;
const Ymlz = @import("ymlz").Ymlz;

pub const App = struct {
    name: []const u8,
    command: []const u8,
    standalone: bool,
    start_location: []const u8, // For specific folder, if not standalone
    env_path: ?[]const u8,
};

pub const Config = struct {
    apps: []App,
};

pub const YamlConfig = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    yml_location: []const u8,

    pub fn init(allocator: std.mem.Allocator, yml_location: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .yml_location = yml_location,
        };
    }

    pub fn parseConfig(self: *Self) !Config {
        const yml_path = try std.fs.cwd().realpathAlloc(
            self.allocator,
            self.yml_location,
        );

        var ymlz = try Ymlz(Config).init(self.allocator);
        const result = try ymlz.loadFile(yml_path);

        return result;
    }
};
