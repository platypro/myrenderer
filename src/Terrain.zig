const gpu = @import("zgpu");
const std = @import("std");
const img = @import("zigimg");
const math = @import("mach").math;
const Renderer = @import("Renderer.zig");
const App = @import("App.zig");

const Mat = math.Mat4x4;

pub const mach_module = .terrain;
pub const mach_systems = .{ .init, .draw };

const Uniform = extern struct {
    size: u32,
    padding1: u32,
    padding2: u32,
    padding3: u32,
    xform: Mat,
};

bind_group_layout_handle: ?gpu.BindGroupLayoutHandle = null,
bind_group_handle: ?gpu.BindGroupHandle = null,
pipeline_handle: ?gpu.RenderPipelineHandle = null,
terrain_handle: ?gpu.BufferHandle = null,
terrain_size: u32 = 0,

pub fn load_terrain(self: *@This(), renderer: *Renderer, allocator: std.mem.Allocator, filename: []const u8) !void {
    const image_file = try std.fs.cwd().openFile(filename, .{});
    defer image_file.close();
    var stream_source = std.io.StreamSource{ .file = image_file };
    var image = try img.png.load(&stream_source, allocator, .{ .temp_allocator = allocator });
    defer image.deinit(allocator);

    self.terrain_size = @intCast(image.width);
    const image_buf_size = self.terrain_size * self.terrain_size * 4;

    if (self.terrain_handle) |handle| {
        if (renderer.gctx.lookupResource(handle)) |buf| {
            buf.release();
            self.terrain_handle = null;
        }
    }

    self.terrain_handle = renderer.gctx.createBuffer(.{ .mapped_at_creation = false, .size = image_buf_size, .usage = .{ .copy_dst = true, .storage = true } });
    const image_buf = renderer.gctx.lookupResource(self.terrain_handle.?) orelse unreachable;

    const COPY_SIZE = 64;
    var counter: u32 = 0;
    while (counter < image.pixels.grayscale16.len) {
        const copy_amnt = if (counter + COPY_SIZE >= image.pixels.grayscale16.len) image.pixels.grayscale16.len - counter else COPY_SIZE;
        var converted_bytes: [COPY_SIZE]f32 = undefined;
        for (0..copy_amnt, counter..(counter + copy_amnt)) |i, sub| {
            converted_bytes[i] = @as(f32, @floatFromInt(image.pixels.grayscale16[sub].value)) / @as(f32, 65535.0);
        }

        renderer.gctx.queue.writeBuffer(image_buf, counter * 4, f32, converted_bytes[0..copy_amnt]);
        counter += COPY_SIZE;
    }

    self.bind_group_handle = renderer.gctx.createBindGroup(self.bind_group_layout_handle.?, &.{
        .{ .binding = 0, .buffer_handle = renderer.gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(Uniform) },
        .{ .binding = 1, .buffer_handle = self.terrain_handle, .offset = 0, .size = image_buf_size },
    });
}

pub fn init(self: *@This(), app: *App, renderer: *Renderer) !void {
    const gctx = renderer.gctx;

    self.* = .{};

    self.bind_group_layout_handle = renderer.gctx.createBindGroupLayout(&.{
        gpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
        gpu.bufferEntry(1, .{ .vertex = true }, .read_only_storage, false, 0),
    });
    errdefer renderer.gctx.releaseResource(self.bind_group_layout_handle.?);

    self.pipeline_handle = pipeline: {
        const shader_source_file = try std.fs.cwd().openFile("terrain.wgsl", .{});
        defer shader_source_file.close();
        const shader_source = try shader_source_file.readToEndAllocOptions(app.allocator, 2048, null, @alignOf(u8), 0);
        defer app.allocator.free(shader_source);
        const shader = gpu.createWgslShaderModule(gctx.device, shader_source, null);
        defer shader.release();

        const color_targets = [_]gpu.wgpu.ColorTargetState{.{
            .format = gpu.GraphicsContext.swapchain_format,
        }};

        const pipeline_layout = gctx.createPipelineLayout(&.{self.bind_group_layout_handle.?});
        defer gctx.releaseResource(pipeline_layout);

        const pipeline_descriptor = gpu.wgpu.RenderPipelineDescriptor{
            .vertex = gpu.wgpu.VertexState{
                .module = shader,
                .entry_point = "vertex_main",
            },
            .primitive = gpu.wgpu.PrimitiveState{
                .front_face = .cw,
                .cull_mode = .none,
                .topology = .triangle_list,
            },
            .depth_stencil = &.{
                .format = .depth32_float,
                .depth_write_enabled = true,
                .depth_compare = .greater,
            },
            .fragment = &gpu.wgpu.FragmentState{
                .module = shader,
                .entry_point = "frag_main",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
        };
        break :pipeline gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
    };
}

pub fn draw(self: *@This(), renderer: *Renderer) void {
    const gctx = renderer.gctx;
    const pipeline = gctx.lookupResource(self.pipeline_handle.?) orelse unreachable;
    const bind_group = gctx.lookupResource(self.bind_group_handle.?) orelse unreachable;
    const depth_texture_view = gctx.lookupResource(renderer.depth_texture_view_handle) orelse unreachable;

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const encoder = gctx.device.createCommandEncoder(null);
    defer encoder.release();

    const color_attachments = [_]gpu.wgpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .load_op = .clear,
        .store_op = .store,
    }};

    const depth_attachment = gpu.wgpu.RenderPassDepthStencilAttachment{
        .view = depth_texture_view,
        .depth_load_op = .clear,
        .depth_store_op = .store,
        .depth_clear_value = 0.0,
    };

    const pass = encoder.beginRenderPass(.{
        .color_attachments = &color_attachments,
        .color_attachment_count = 1,
        .depth_stencil_attachment = &depth_attachment,
    });

    const alloc = gctx.uniformsAllocate(Uniform, 1);
    alloc.slice[0].size = self.terrain_size;
    alloc.slice[0].xform = renderer.current_xform;

    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bind_group, &.{alloc.offset});
    pass.draw(6 * self.terrain_size * self.terrain_size, 1, 0, 0);

    pass.end();
    pass.release();

    const commands = encoder.finish(null);
    defer commands.release();
    gctx.submit(&.{commands});
}