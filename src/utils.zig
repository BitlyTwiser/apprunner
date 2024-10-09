const std = @import("std");
const r_i = @import("runner.zig");

// run arbitrary cli commands and collect stderr & stdout
pub fn runCommand(command_data: []const []const u8, allocator: std.mem.Allocator) ![]u8 {
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

// Returns no data from stderr or stdout, just runs command blind
pub fn runCommandEmpty(command_data: []const []const u8, allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(command_data, allocator);
    try child.spawn();

    _ = try child.wait();
}

// Wraps the shell around the calling code
pub fn runCommandEmptyWithShell(command_data: []u8, allocator: std.mem.Allocator) !void {
    const base_command = try r_i.commandBase(allocator);
    const sub_command = try r_i.subCommand();
    var child = std.process.Child.init(&[_][]const u8{ base_command, sub_command, command_data }, allocator);
    try child.spawn();

    _ = try child.wait();
}
