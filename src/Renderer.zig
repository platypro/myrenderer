const gpu = @import("zgpu");
const glfw = @import("zglfw");
const mach = @import("mach");
const std = @import("std");
const math = @import("math.zig");

pub const mach_module = .renderer;
pub const mach_systems = .{ .init, .render_begin, .render_end, .deinit };

const App = @import("App.zig");

const shadow_map_segments = 3;
const shadow_map_resolutions = .{ 512, 256, 128 };

const Renderer = @This();

camera_location: math.Vec3,
current_xform: math.Mat,
encoder: gpu.wgpu.CommandEncoder,
back_buffer_view: gpu.wgpu.TextureView,
depth_texture_view: gpu.wgpu.TextureView,
gctx: *gpu.GraphicsContext,
shadow_map: gpu.BufferHandle,

light_sources: mach.Objects(.{}, struct {
    position: math.Vec3,
    shadow_maps: [shadow_map_segments]gpu.BufferHandle,
}),

pipelines: mach.Objects(.{}, Pipeline),
instances: mach.Objects(.{}, Instance),

pub fn init(self: *@This(), app: *App) !void {
    self.gctx = try gpu.GraphicsContext.create(
        app.allocator,
        .{
            .window = app.window,
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
    errdefer self.gctx.destroy(app.allocator);

    const depth_texture_handle = self.gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .tdim_2d,
        .size = .{
            .width = self.gctx.swapchain_descriptor.width,
            .height = self.gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const depth_texture_view_handle = self.gctx.createTextureView(depth_texture_handle, .{});
    self.depth_texture_view = self.gctx.lookupResource(depth_texture_view_handle).?;

    self.light_sources.lock();
    defer self.light_sources.unlock();
    //    _ = try self.light_sources.new(.{ .position = math.Vec3.init(1.0, 8.0, 1.0) });
}

pub fn render_begin(self: *@This()) !void {
    const camX = math.std.cos(@as(f32, @floatCast(glfw.getTime()))) * 20.0;
    const camZ = math.std.sin(@as(f32, @floatCast(glfw.getTime()))) * 20.0;

    self.camera_location = math.Vec3.init(camX, 15.0, camZ);

    const view = math.lookAt(
        self.camera_location,
        math.Vec3.init(0.0, 0.0, 0.0),
        math.Vec3.init(0.0, 1.0, 0.0),
    );
    var perspective = math.Mat.projection2D(.{ .left = -1.0, .right = 1.0, .top = 1.0, .bottom = -1.0, .near = 0.1, .far = 100.0 });
    perspective.v[2].v[3] = 1;
    self.current_xform = math.matMult(&.{ math.Mat.rotateZ(-math.std.pi / 2.0), perspective, view });

    self.back_buffer_view = self.gctx.swapchain.getCurrentTextureView();
    self.encoder = self.gctx.device.createCommandEncoder(null);
}

pub fn render_end(self: *@This()) !void {
    const commands = self.encoder.finish(null);
    defer commands.release();
    self.gctx.submit(&.{commands});

    self.encoder.release();
    self.back_buffer_view.release();
}

pub fn deinit(self: *@This(), app: *App) void {
    self.gctx.destroy(app.allocator);
}

const PassType = enum {
    custom,
    shadow_map,
};

pub const Pipeline = struct {
    pipeline_handle: gpu.RenderPipelineHandle,
    bind_group_layout_handle: gpu.BindGroupLayoutHandle,
    num_bindings: u32 = 0,
    num_dynamic_bindings: u32 = 0,

    const Options = struct {
        shader_source: [*:0]const u8,
        buffers: []const gpu.wgpu.BindGroupLayoutEntry,
    };

    pub fn create(renderer: *Renderer, options: Options) !mach.ObjectID {
        const bind_group_layout_handle = renderer.gctx.createBindGroupLayout(options.buffers);

        const shader = gpu.createWgslShaderModule(renderer.gctx.device, options.shader_source, null);
        defer shader.release();

        const color_targets = [_]gpu.wgpu.ColorTargetState{.{
            .format = gpu.GraphicsContext.swapchain_format,
        }};

        const pipeline_layout = renderer.gctx.createPipelineLayout(&.{bind_group_layout_handle});
        defer renderer.gctx.releaseResource(pipeline_layout);

        const pipeline_descriptor = gpu.wgpu.RenderPipelineDescriptor{
            .vertex = gpu.wgpu.VertexState{
                .module = shader,
                .entry_point = "vertex_main",
            },
            .primitive = gpu.wgpu.PrimitiveState{
                .front_face = .cw,
                .cull_mode = .front,
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
        const pipeline = Pipeline{
            .pipeline_handle = renderer.gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor),
            .num_bindings = @intCast(options.buffers.len),
            .bind_group_layout_handle = bind_group_layout_handle,
        };

        renderer.pipelines.lock();
        defer renderer.pipelines.unlock();
        return try renderer.pipelines.new(pipeline);
    }

    pub fn destroy(renderer: *Renderer, pipeline_id: mach.ObjectID) void {
        renderer.pipelines.lock();
        defer renderer.pipelines.unlock();

        const pipeline_handle = renderer.pipelines.get(pipeline_id, .pipeline_handle);
        const pipeline = renderer.gctx.lookupResource(pipeline_handle);
        pipeline.?.release();

        const bind_group_layout_handle = renderer.pipelines.get(pipeline_id, .bind_group_layout_handle);
        const bind_group_layout = renderer.gctx.lookupResource(bind_group_layout_handle);
        bind_group_layout.?.release();

        renderer.pipelines.delete(pipeline_id);
    }

    pub fn spawn_instance(renderer: *Renderer, pipeline_id: mach.ObjectID, app: *App) !mach.ObjectID {
        const num_bindings = renderer.pipelines.get(pipeline_id, .num_bindings);
        const result = Instance{
            .pipeline = pipeline_id,
            .bind_group_descriptors = try app.allocator.alloc(gpu.BindGroupEntryInfo, num_bindings),
            .dynamic_offsets = try app.allocator.alloc(u32, num_bindings),
            .dirty_bind_group = true,
        };

        for (0.., result.bind_group_descriptors) |i, *layout| {
            layout.binding = @intCast(i);
            layout.offset = 0;
            layout.size = 0;
            layout.sampler_handle = null;
            layout.buffer_handle = null;
            layout.texture_view_handle = null;
        }

        renderer.instances.lock();
        defer renderer.instances.unlock();
        return try renderer.instances.new(result);
    }
};

pub const Instance = struct {
    pipeline: mach.ObjectID,
    bind_group_descriptors: []gpu.BindGroupEntryInfo,
    bind_group_handle: ?gpu.BindGroupHandle = null,
    dynamic_offsets: []u32,
    dirty_bind_group: bool = true,

    pub fn set_uniform(renderer: *Renderer, instance_id: mach.ObjectID, id: u32, T: type, value: T) void {
        var entry = renderer.gctx.uniformsAllocate(T, 1);
        entry.slice[0] = value;
        const dyn_offset_arr = renderer.instances.get(instance_id, .dynamic_offsets);
        dyn_offset_arr[id] = entry.offset;
        renderer.instances.set(instance_id, .dirty_bind_group, true);

        const bind_group_descriptors: []gpu.BindGroupEntryInfo = renderer.instances.get(instance_id, .bind_group_descriptors);
        bind_group_descriptors[id].buffer_handle = renderer.gctx.uniforms.buffer;
        bind_group_descriptors[id].size = @sizeOf(T);
    }

    pub fn set_storage_buffer(renderer: *Renderer, instance_id: mach.ObjectID, id: u32, buffer: gpu.BufferHandle, total_size: u32, offset: u32) void {
        const bind_group_descriptors: []gpu.BindGroupEntryInfo = renderer.instances.get(instance_id, .bind_group_descriptors);
        bind_group_descriptors[id].buffer_handle = buffer;
        bind_group_descriptors[id].size = total_size;

        const dynamic_offsets = renderer.instances.get(instance_id, .dynamic_offsets);
        dynamic_offsets[id] = offset;

        renderer.instances.set(instance_id, .dirty_bind_group, true);
    }

    pub fn get_bind_group(renderer: *Renderer, instance_id: mach.ObjectID) gpu.BindGroupHandle {
        if (renderer.instances.get(instance_id, .dirty_bind_group)) {
            const pipeline_id = renderer.instances.get(instance_id, .pipeline);

            renderer.instances.set(instance_id, .bind_group_handle, renderer.gctx.createBindGroup(
                renderer.pipelines.get(pipeline_id, .bind_group_layout_handle),
                renderer.instances.get(instance_id, .bind_group_descriptors),
            ));
        }
        return renderer.instances.get(instance_id, .bind_group_handle).?;
    }

    pub fn destroy(renderer: *Renderer, app: *App, instance_id: mach.ObjectID) void {
        app.allocator.free(renderer.instances.get(instance_id, .bind_group_descriptors));
        app.allocator.free(renderer.instances.get(instance_id, .dynamic_offsets));
        renderer.instances.delete(instance_id);
    }
};

pub const RenderPass = struct {
    pass: gpu.wgpu.RenderPassEncoder,
    base_transform: math.Mat,
    uniform_offset: u32 = 0,

    pub fn setInstance(self: *RenderPass, renderer: *Renderer, instance_id: mach.ObjectID) void {
        const bind_group_handle = Instance.get_bind_group(renderer, instance_id);
        const bind_group = renderer.gctx.lookupResource(bind_group_handle) orelse unreachable;
        const pipeline = renderer.instances.get(instance_id, .pipeline);
        const pipeline_handle = renderer.pipelines.get(pipeline, .pipeline_handle);

        self.pass.setPipeline(renderer.gctx.lookupResource(pipeline_handle) orelse unreachable);
        self.pass.setBindGroup(0, bind_group, renderer.instances.get(instance_id, .dynamic_offsets));
    }

    pub fn draw(self: *RenderPass, num_vertices: u32, num_instances: u32, first_vertex: u32, first_instance: u32) void {
        self.pass.draw(num_vertices, num_instances, first_vertex, first_instance);
    }

    pub fn end(self: *RenderPass) void {
        self.pass.end();
        self.pass.release();
    }

    pub fn begin_draw_pass(self: *Renderer) RenderPass {
        const color_attachments: []const gpu.wgpu.RenderPassColorAttachment = &.{.{
            .view = self.back_buffer_view,
            .load_op = .clear,
            .store_op = .store,
        }};

        const depth_attachment = gpu.wgpu.RenderPassDepthStencilAttachment{
            .view = self.depth_texture_view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .depth_clear_value = 0.0,
        };

        return RenderPass{
            .pass = self.encoder.beginRenderPass(.{
                .color_attachments = color_attachments.ptr,
                .color_attachment_count = color_attachments.len,
                .depth_stencil_attachment = &depth_attachment,
            }),
            .base_transform = self.current_xform,
        };
    }
};
