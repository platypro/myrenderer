const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;

pub const mach_module = .renderer;
pub const mach_systems = .{ .init, .update, .deinit };
const mods = @import("root").getModules();

pub const VertexLayout = @import("VertexLayout.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const Instance = @import("Instance.zig");
pub const VertexBuffer = @import("VertexBuffer.zig");
pub const Surface = @import("Surface.zig");
pub const SceneNode = @import("SceneNode.zig");
pub const Draw = @import("Draw.zig");

pub const Mod = mach.Mod(@This());

const Renderer = @This();

delta_time: f32,
delta_time_ns: u64,
elapsed_time: f32,
frame_counter: u32 = 1,
current_buffer_slot: u32,
device: *mach.gpu.Device,
queue: *mach.gpu.Queue,
framebuffer_format: mach.gpu.Texture.Format,

pipelines: mach.Objects(.{}, Pipeline),
instances: mach.Objects(.{}, Instance),
surfaces: mach.Objects(.{}, Surface),
scene_nodes: mach.Objects(.{}, SceneNode),
draws: mach.Objects(.{}, Draw),

pub fn init() !void {
    mods.renderer.delta_time = 0.0;
    mods.renderer.delta_time_ns = 0;
    mods.renderer.elapsed_time = 0.0;
    mods.renderer.current_buffer_slot = 0;

    mods.mach_core.frame.delta_time = &mods.renderer.delta_time;
    mods.mach_core.frame.delta_time_ns = &mods.renderer.delta_time_ns;
}

pub fn adopt_window(window: mach.ObjectID) void {
    mods.renderer.device = mods.mach_core.windows.get(window, .device);
    mods.renderer.queue = mods.mach_core.windows.get(window, .queue);
    mods.renderer.framebuffer_format = mods.mach_core.windows.get(window, .framebuffer_format);
}

pub fn update() !void {
    mods.renderer.current_buffer_slot = (mods.renderer.current_buffer_slot + 1) % Instance.MAX_COPIES;
    mods.renderer.frame_counter += 1;
    mods.renderer.elapsed_time += mods.renderer.delta_time;
}

pub fn deinit() void {}
