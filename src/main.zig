const std = @import("std");
const glfw = @import("zglfw");
const gpu = @import("zgpu");
const img = @import("zigimg");
const mach = @import("mach");

const Modules = mach.Modules(.{
    @import("App.zig"),
    @import("Renderer.zig"),
    @import("Terrain.zig"),
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var mods: Modules = undefined;
    try mods.init(allocator);

    const app = mods.get(.app);
    app.run(.main);
}
