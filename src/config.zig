const std = @import("std");
const Ymlz = @import("ymlz").Ymlz;

pub const App = struct {
    name: []const u8,
    command: []const u8,
    stand: bool,
    location: []const u8, // For specific folder, if not standalone
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
