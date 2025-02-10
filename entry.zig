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

var mods: Modules = undefined;

pub fn getModules() *@TypeOf(mods.mods) {
    return &mods.mods;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    try mods.init(allocator);
    defer mods.deinit(allocator);

    const app = mods.get(.app);
    app.run(.main);
}
