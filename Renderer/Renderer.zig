const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;

pub const mach_module = .renderer;
pub const mach_systems = .{ .init, .update, .deinit };

pub const VertexLayout = @import("VertexLayout.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const Instance = @import("Instance.zig");
pub const VertexBuffer = @import("VertexBuffer.zig");
pub const Surface = @import("Surface.zig");
pub const Node = @import("Node.zig");
pub const Draw = @import("Draw.zig");

pub const Mod = mach.Mod(@This());

const Renderer = @This();

core: *mach.Core,

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
nodes: mach.Objects(.{}, Node),
draws: mach.Objects(.{}, Draw),

pub fn init(renderer: *Renderer, core: *mach.Core) !void {
    renderer.core = core;

    renderer.delta_time = 0.0;
    renderer.delta_time_ns = 0;
    renderer.elapsed_time = 0.0;
    renderer.current_buffer_slot = 0;

    renderer.core.frame.delta_time = &renderer.delta_time;
    renderer.core.frame.delta_time_ns = &renderer.delta_time_ns;
}

pub fn adopt_window(renderer: *Renderer, window: mach.ObjectID) void {
    renderer.device = renderer.core.windows.get(window, .device);
    renderer.queue = renderer.core.windows.get(window, .queue);
    renderer.framebuffer_format = renderer.core.windows.get(window, .framebuffer_format);
}

pub fn update(renderer: *Renderer) !void {
    renderer.current_buffer_slot = (renderer.current_buffer_slot + 1) % Instance.MAX_COPIES;
    renderer.frame_counter += 1;
}

pub fn deinit() void {}
