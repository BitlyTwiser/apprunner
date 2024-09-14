const std = @import("std");
const config = @import("./config.zig");
const runner = @import("./runner.zig");

// Functions from std
const print = std.debug.print;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Please provide a path to the config.yml file", .{});
        return;
    }

    var yml_config = try config.YamlConfig.init(allocator, args[1]);
    const results = try yml_config.parseConfig();
    defer allocator.free(results.apps);

    // Spawns all threads and waits
    var run = try runner.Runner.init(allocator);
    try run.spawner(results.apps);
}

test "simple test" {}
