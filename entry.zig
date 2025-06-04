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

fn getter_fn(comptime handle: type, comptime T: type) type {
    return @TypeOf(struct {
        pub fn get(self: handle, comptime field: std.meta.FieldEnum(T)) std.meta.FieldType(handle, field) {
            _ = self;
            return undefined;
        }
    }.get);
}

pub fn generate_getter(comptime handle: type, comptime T: type, backing: *mach.Objects(.{}, T)) getter_fn(handle, T) {
    return struct {
        pub fn get(self: handle, comptime field: std.meta.FieldEnum(T)) std.meta.FieldType(T, field) {
            return backing.get(@intFromEnum(self), field);
        }
    }.get;
}

fn setter_fn(handle: type, T: type) type {
    return @TypeOf(struct {
        pub fn get(self: handle, comptime field: std.meta.FieldEnum(T), value: std.meta.FieldType(handle, field)) void {
            _ = self;
            _ = value;
        }
    }.get);
}

pub fn generate_setter(handle: type, T: type, backing: *mach.Objects(.{}, T)) setter_fn(handle, T) {
    return struct {
        pub fn set(self: handle, comptime field: std.meta.FieldEnum(T), value: std.meta.FieldType(T, field)) void {
            backing.set(@intFromEnum(self), field, value);
        }
    }.set;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    try mods.init(allocator);
    defer mods.deinit(allocator);

    const app = mods.get(.app);
    app.run(.main);
}
