const std = @import("std");
const glfw = @import("zglfw");
const gpu = @import("zgpu");

const terrain_size = 100;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    try glfw.init();
    defer glfw.terminate();

    const window = try glfw.Window.create(600, 600, "zig-gamedev: minimal_glfw_gl", null);
    defer window.destroy();

    const gctx = try gpu.GraphicsContext.create(
        allocator,
        .{
            .window = window,
            .fn_getTime = @ptrCast(&glfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&glfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&glfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&glfw.getX11Display),
            .fn_getX11Window = @ptrCast(&glfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&glfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&glfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&glfw.getCocoaWindow),
        },
        .{},
    );
    defer gctx.destroy(allocator);

    const bind_group_layout = gctx.createBindGroupLayout(&.{
        gpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
    });
    defer gctx.releaseResource(bind_group_layout);

    const pipeline_handle = pipeline: {
        const shader_source_file = try std.fs.cwd().openFile("terrain.wgsl", .{});
        defer shader_source_file.close();
        const shader_source = try shader_source_file.readToEndAllocOptions(allocator, 2048, null, @alignOf(u8), 0);
        defer allocator.free(shader_source);
        const shader = gpu.createWgslShaderModule(gctx.device, shader_source, null);
        defer shader.release();

        const color_targets = [_]gpu.wgpu.ColorTargetState{.{
            .format = gpu.GraphicsContext.swapchain_format,
        }};

        const pipeline_layout = gctx.createPipelineLayout(&.{bind_group_layout});
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
            .depth_stencil = null,
            .fragment = &gpu.wgpu.FragmentState{
                .module = shader,
                .entry_point = "frag_main",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
        };
        break :pipeline gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
    };

    const uniform = gctx.uniformsAllocate(u32, 1);
    uniform.slice[0] = terrain_size;

    const bind_group_handle = gctx.createBindGroup(bind_group_layout, &.{.{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = 4 }});

    while (!window.shouldClose()) {
        glfw.pollEvents();

        const pipeline = gctx.lookupResource(pipeline_handle) orelse return;
        const bind_group = gctx.lookupResource(bind_group_handle) orelse return;

        const back_buffer_view = gctx.swapchain.getCurrentTextureView();
        defer back_buffer_view.release();

        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        const color_attachments = [_]gpu.wgpu.RenderPassColorAttachment{.{
            .view = back_buffer_view,
            .load_op = .clear,
            .store_op = .store,
        }};

        const pass = encoder.beginRenderPass(.{ .color_attachments = &color_attachments, .color_attachment_count = 1 });

        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bind_group, &.{0});
        pass.draw(6 * terrain_size * terrain_size, 1, 0, 0);

        pass.end();
        pass.release();

        const commands = encoder.finish(null);
        defer commands.release();
        gctx.submit(&.{commands});
        _ = gctx.present();

        window.swapBuffers();
    }
}
