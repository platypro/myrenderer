const std = @import("std");
pub const mach = @import("mach");
pub const math = @import("math.zig");

pub const Core = mach.Core;
pub const App = @import("app");
pub const Renderer = @import("renderer");
pub const Terrain = @import("terrain");
pub const Polygon = @import("polygon");

const Modules = mach.Modules(.{
    Core,
    App,
    Renderer,
    Terrain,
    Polygon,
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var mods: Modules = undefined;
    try mods.init(allocator);
    defer mods.deinit(allocator);

    const app = mods.get(.app);
    app.run(.main);
}
