const std = @import("std");
const glfw = @import("zglfw");
const gpu = @import("zgpu");
const img = @import("zigimg");
const math = @import("mach").math;

const Mat = math.Mat4x4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;

const Uniform = extern struct {
    size: u32,
    padding1: u32,
    padding2: u32,
    padding3: u32,
    xform: Mat,
};

fn lookAt(camera_: Vec3, target: Vec3, up_ref: Vec3) Mat {
    const camera = camera_.mulScalar(-1);
    const forward = target.sub(&camera).normalize(0.0);
    const up = up_ref.cross(&forward).normalize(0.0);
    const right = forward.cross(&up).normalize(0.0);

    return Mat.init(
        &Vec4.init(right.v[0], right.v[1], right.v[2], -camera.dot(&right)),
        &Vec4.init(up.v[0], up.v[1], up.v[2], -camera.dot(&up)),
        &Vec4.init(forward.v[0], forward.v[1], forward.v[2], -camera.dot(&forward)),
        &Vec4.init(0.0, 0.0, 0.0, 1.0),
    );
}

fn matMult(mats: []const Mat) Mat {
    var result = Mat.ident;
    for (mats) |mat| {
        result = result.mul(&mat);
    }
    return result;
}

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

    const depth_texture = gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .tdim_2d,
        .size = .{
            .width = gctx.swapchain_descriptor.width,
            .height = gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const depth_texture_view_handle = gctx.createTextureView(depth_texture, .{});

    const image_file = try std.fs.cwd().openFile("HEIGHTMAP.png", .{});
    defer image_file.close();
    var stream_source = std.io.StreamSource{ .file = image_file };
    var image = try img.png.load(&stream_source, allocator, .{ .temp_allocator = allocator });
    defer image.deinit(allocator);

    const terrain_size: u32 = @intCast(image.width);
    const image_buf_size = terrain_size * terrain_size * 4;

    const image_buf_handle = gctx.createBuffer(.{ .mapped_at_creation = false, .size = image_buf_size, .usage = .{ .copy_dst = true, .storage = true } });
    const image_buf = gctx.lookupResource(image_buf_handle) orelse unreachable;

    const COPY_SIZE = 64;
    var counter: u32 = 0;
    while (counter < image.pixels.grayscale16.len) {
        const copy_amnt = if (counter + COPY_SIZE >= image.pixels.grayscale16.len) image.pixels.grayscale16.len - counter else COPY_SIZE;
        var converted_bytes: [COPY_SIZE]f32 = undefined;
        for (0..copy_amnt, counter..(counter + copy_amnt)) |i, sub| {
            converted_bytes[i] = @as(f32, @floatFromInt(image.pixels.grayscale16[sub].value)) / @as(f32, 65535.0);
        }

        gctx.queue.writeBuffer(image_buf, counter * 4, f32, converted_bytes[0..copy_amnt]);
        counter += COPY_SIZE;
    }

    const bind_group_layout = gctx.createBindGroupLayout(&.{
        gpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
        gpu.bufferEntry(1, .{ .vertex = true }, .read_only_storage, false, 0),
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

    const bind_group_handle = gctx.createBindGroup(bind_group_layout, &.{
        .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(Uniform) },
        .{ .binding = 1, .buffer_handle = image_buf_handle, .offset = 0, .size = image_buf_size },
    });

    while (!window.shouldClose()) {
        glfw.pollEvents();
        const camX = std.math.cos(@as(f32, @floatCast(glfw.getTime()))) * 20.0;
        const camZ = std.math.sin(@as(f32, @floatCast(glfw.getTime()))) * 20.0;
        const model = lookAt(
            Vec3.init(camX, 15.0, camZ),
            Vec3.init(0.0, 0.0, 0.0),
            Vec3.init(0.0, 1.0, 0.0),
        );
        var perspective = Mat.projection2D(.{ .left = -1.0, .right = 1.0, .top = 1.0, .bottom = -1.0, .near = 0.1, .far = 100.0 });
        perspective.v[2].v[3] = 1;
        const mvp = matMult(&.{ Mat.rotateZ(-std.math.pi / 2.0), perspective, model });
        // const mvp = .mul(&perspective.mul(&model));
        //const mvp = perspective.mul(&model);
        const uniform = gctx.uniformsAllocate(Uniform, 1);

        uniform.slice[0].xform = mvp;
        uniform.slice[0].size = terrain_size;

        const pipeline = gctx.lookupResource(pipeline_handle) orelse unreachable;
        const bind_group = gctx.lookupResource(bind_group_handle) orelse unreachable;
        const depth_texture_view = gctx.lookupResource(depth_texture_view_handle) orelse unreachable;

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

        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bind_group, &.{uniform.offset});
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
