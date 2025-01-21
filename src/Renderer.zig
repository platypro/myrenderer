const mach = @import("mach");
const std = @import("std");
const math = @import("math.zig");

pub const mach_module = .renderer;
pub const mach_systems = .{ .preinit, .init, .draw, .deinit };

pub const VertexLayout = @import("Renderer/VertexLayout.zig");
pub const Pipeline = @import("Renderer/Pipeline.zig");
pub const Instance = @import("Renderer/Instance.zig");
pub const VertexBuffer = @import("Renderer/VertexBuffer.zig");

const App = @import("App.zig");
pub const Mod = mach.Mod(@This());

const Renderer = @This();

core: *mach.Core,

delta_time: f32,
delta_time_ns: u64,
elapsed_time: f32,
current_window: mach.ObjectID,
camera_location: math.Vec3,
current_buffer_slot: u32,
encoder: *mach.gpu.CommandEncoder,
back_buffer_view: *mach.gpu.TextureView,
depth_texture_view: *mach.gpu.TextureView,

pipelines: mach.Objects(.{}, Pipeline),
instances: mach.Objects(.{}, Instance),

shared_bind_group_layout: *mach.gpu.BindGroupLayout,
shared_bind_group: *mach.gpu.BindGroup,
shared_buffer: *mach.gpu.Buffer,

pub fn preinit(renderer: *Renderer, core: *mach.Core) !void {
    renderer.core = core;
    renderer.current_window = try renderer.core.windows.new(.{ .title = "Platypro's Thing", .width = 400, .height = 400 });
}

pub fn init(renderer: *Renderer) !void {
    const device: *mach.gpu.Device = renderer.core.windows.get(renderer.current_window, .device);
    const depth_texture = device.createTexture(&.{
        .usage = .{ .render_attachment = true },
        .dimension = .dimension_2d,
        .size = .{
            .width = renderer.core.windows.get(renderer.current_window, .framebuffer_width),
            .height = renderer.core.windows.get(renderer.current_window, .framebuffer_height),
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    renderer.depth_texture_view = depth_texture.createView(&.{});
    renderer.delta_time = 0.0;
    renderer.delta_time_ns = 0;
    renderer.elapsed_time = 0.0;
    renderer.current_buffer_slot = 0;

    renderer.core.frame.delta_time = &renderer.delta_time;
    renderer.core.frame.delta_time_ns = &renderer.delta_time_ns;

    const shared_bind_group_layout_descriptor_entries = [_]mach.gpu.BindGroupLayout.Entry{
        mach.gpu.BindGroupLayout.Entry.initBuffer(0, .{ .vertex = true }, .uniform, true, 0),
    };

    const shared_bind_group_layout_descriptor = mach.gpu.BindGroupLayout.Descriptor{
        .entries = &shared_bind_group_layout_descriptor_entries,
        .entry_count = shared_bind_group_layout_descriptor_entries.len,
    };

    renderer.shared_buffer = device.createBuffer(&.{ .mapped_at_creation = .true, .size = @sizeOf(math.Mat) * Instance.MAX_COPIES, .usage = .{ .vertex = true, .uniform = true } });
    renderer.shared_bind_group_layout = device.createBindGroupLayout(&shared_bind_group_layout_descriptor);

    const shared_bind_group_entries = [_]mach.gpu.BindGroup.Entry{.{
        .binding = 0,
        .buffer = renderer.shared_buffer,
        .offset = 0,
        .size = @sizeOf(math.Mat),
    }};

    renderer.shared_bind_group = device.createBindGroup(&.{
        .entries = &shared_bind_group_entries,
        .entry_count = shared_bind_group_entries.len,
        .layout = renderer.shared_bind_group_layout,
    });
}

pub fn draw(renderer: *Renderer) !void {
    const device: *mach.gpu.Device = renderer.core.windows.get(renderer.current_window, .device);
    const queue: *mach.gpu.Queue = renderer.core.windows.get(renderer.current_window, .queue);
    const swap_chain: *mach.gpu.SwapChain = renderer.core.windows.get(renderer.current_window, .swap_chain);

    // const camX = math.std.cos(@as(f32, @floatCast(renderer.elapsed_time / 2.0))) * 10.0;
    // const camZ = math.std.sin(@as(f32, @floatCast(renderer.elapsed_time / 2.0))) * 10.0;

    renderer.elapsed_time += renderer.delta_time;

    // renderer.camera_location = math.Vec3.init(camX, 10.0, camZ);

    // const view = math.lookAt(
    //     renderer.camera_location,
    //     math.Vec3.init(0.0, 0.0, 0.0),
    //     math.Vec3.init(0.0, 1.0, 0.0),
    // );
    const view = math.Mat.ident;

    const perspective = math.Mat.projection2D(.{ .left = 0, .right = 200, .top = 0, .bottom = 200, .near = 0.1, .far = 100 }); //math.perspective(math.std.degreesToRadians(120.0), 1.0, 0.1, 100.0);

    queue.writeBuffer(renderer.shared_buffer, renderer.current_buffer_slot * @sizeOf(math.Mat), @as([]const math.Mat, &.{math.matMult(&.{ perspective, view })}));

    renderer.back_buffer_view = swap_chain.getCurrentTextureView().?;
    renderer.encoder = device.createCommandEncoder(null);
    const color_attachments: []const mach.gpu.RenderPassColorAttachment = &.{.{
        .view = renderer.back_buffer_view,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .r = 0.4, .g = 0.4, .b = 0.4, .a = 0.4 },
    }};

    const depth_attachment = mach.gpu.RenderPassDepthStencilAttachment{
        .view = renderer.depth_texture_view,
        .depth_load_op = .clear,
        .depth_store_op = .store,
        .depth_clear_value = 1.0,
    };

    const render_pass = renderer.encoder.beginRenderPass(&.{
        .color_attachments = color_attachments.ptr,
        .color_attachment_count = color_attachments.len,
        .depth_stencil_attachment = &depth_attachment,
    });

    var pipeline_iter = renderer.pipelines.slice();
    while (pipeline_iter.next()) |pipeline_id| {
        const pipeline = renderer.pipelines.get(pipeline_id, .pipeline_handle);
        render_pass.setPipeline(pipeline);
        render_pass.setBindGroup(1, renderer.shared_bind_group, &.{renderer.current_buffer_slot * @sizeOf(math.Mat)});

        const instances = try renderer.pipelines.getChildren(pipeline_id);
        for (instances.items) |instance_id| {
            const draw_index: VertexBuffer = renderer.instances.get(instance_id, .vertex_buffer);
            if (draw_index.vertex_buffer) |vertex_buffer| {
                render_pass.setVertexBuffer(0, vertex_buffer, 0, vertex_buffer.getSize());
            }
            render_pass.setBindGroup(
                0,
                renderer.instances.get(instance_id, .bind_group).?,
                renderer.instances.get(instance_id, .dynamic_offsets),
            );
            render_pass.draw(draw_index.vertex_count, draw_index.instance_count, draw_index.first_vertex, draw_index.first_instance);
        }
    }
    render_pass.end();

    const commands = renderer.encoder.finish(null);
    defer commands.release();
    queue.submit(&.{commands});

    renderer.encoder.release();
    renderer.back_buffer_view.release();

    renderer.current_buffer_slot += 1;
    if (renderer.current_buffer_slot >= Instance.MAX_COPIES) {
        renderer.current_buffer_slot = 0;
    }
}

pub fn deinit() void {}
