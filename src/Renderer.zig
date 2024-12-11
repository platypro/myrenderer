const gpu = @import("zgpu");
const glfw = @import("zglfw");
const mach = @import("mach");
const std = @import("std");
const math = @import("math.zig");

pub const mach_module = .renderer;
pub const mach_systems = .{ .init, .draw, .generate_shadow_maps, .deinit };

const App = @import("App.zig");

const ShadowMapSegment = struct {
    resolution: u32,
    cutoff: f32,
};

const shadow_map_segments: []ShadowMapSegment = &.{
    .{ .resolution = 512, .cutoff = 0.4 },
    .{ .resolution = 128, .cutoff = 0.7 },
    .{ .resolution = 64, .cutoff = 1.0 },
};
const shadow_map_count = shadow_map_segments.len;

const Renderer = @This();

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

current_render_pass: RenderPass,
camera_location: math.Vec3,
current_xform: math.Mat,
encoder: gpu.wgpu.CommandEncoder,
back_buffer_view: gpu.wgpu.TextureView,
depth_texture_view: gpu.wgpu.TextureView,
gctx: *gpu.GraphicsContext,

point_light_sources: mach.Objects(.{}, PointLight),
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
}

pub fn render_begin(self: *@This()) !void {
    const camX = math.std.cos(@as(f32, @floatCast(glfw.getTime() / 2.0))) * 10.0;
    const camZ = math.std.sin(@as(f32, @floatCast(glfw.getTime() / 2.0))) * 10.0;

    self.camera_location = math.Vec3.init(camX, 10.0, camZ);

    const view = math.lookAt(
        self.camera_location,
        math.Vec3.init(0.0, 0.0, 0.0),
        math.Vec3.init(0.0, 1.0, 0.0),
    );

    const perspective = math.perspective(math.std.degreesToRadians(120.0), 1.0, 0.1, 100.0);

    self.current_xform = math.matMult(&.{ perspective, view });

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

pub fn draw(renderer: *Renderer, renderer_mod: mach.Mod(Renderer)) !void {
    try render_begin(renderer);

    renderer.current_render_pass = RenderPass.begin_draw_pass(renderer);
    var instance_iter = renderer.instances.slice();
    while (instance_iter.next()) |instance_id| {
        Instance.draw(renderer, instance_id, renderer_mod);
    }
    renderer.current_render_pass.end();

    try render_end(renderer);
}

pub fn generate_shadow_maps(renderer: *Renderer) void {
    renderer.point_light_sources.lock();
    defer renderer.point_light_sources.unlock();
    // var light_iter = renderer.point_light_sources.slice();
    // while (light_iter.next()) |light_id| {
    //     const light = light_iter.get(light_id);
    //     var pass = RenderPass.begin_shadow_map_generation_pass(renderer, light);
    //     pass.end();
    // }
}

pub fn deinit(self: *@This(), app: *App) void {
    self.gctx.destroy(app.allocator);
}

const PassType = enum {
    custom,
    shadow_map,
};

pub const PointLight = struct {
    transform: math.Mat,
    color: Color,
    shadow_map: ?gpu.TextureHandle = null,

    const shadow_map_size = 128;

    pub fn create(renderer: *Renderer, base: PointLight) !mach.ObjectID {
        const light_id = renderer.light_sources.new(base);

        const descriptor = gpu.wgpu.TextureDescriptor{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .format = .depth32_float,
            .size = .{
                .height = shadow_map_size,
                .width = shadow_map_size,
                .depth_or_array_layers = 6,
            },
        };
        renderer.light_sources.set(light_id, .shadow_maps, renderer.gctx.createTexture(descriptor));
    }

    pub fn destroy(renderer: *Renderer, light_id: mach.ObjectID) void {
        const shadow_map = renderer.light_sources.get(light_id, .shadow_maps);
        const buffer = renderer.gctx.lookupResource(shadow_map.?);
        buffer.?.release();

        renderer.light_sources.delete(light_id);
    }
};

pub const Pipeline = struct {
    pipeline_handle: gpu.RenderPipelineHandle,
    bind_group_layout_handle: gpu.BindGroupLayoutHandle,
    num_bindings: u32 = 0,
    num_dynamic_bindings: u32 = 0,
    vtable: VTable,

    const VTable = struct {
        draw: ?mach.FunctionID = null,
    };

    const Options = struct {
        shader_source: [*:0]const u8,
        buffers: []const gpu.wgpu.BindGroupLayoutEntry,
        vtable: VTable,
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
                .depth_compare = .less,
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
            .vtable = options.vtable,
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

    pub fn draw(renderer: *Renderer, instance_id: mach.ObjectID, renderer_mod: mach.Mod(Renderer)) void {
        const pipeline_id = renderer.instances.get(instance_id, .pipeline);
        const vtable = renderer.pipelines.get(pipeline_id, .vtable);
        renderer_mod.run(vtable.draw.?);
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
            .clear_value = .{ .r = 0.4, .g = 0.4, .b = 0.4, .a = 0.4 },
        }};

        const depth_attachment = gpu.wgpu.RenderPassDepthStencilAttachment{
            .view = self.depth_texture_view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .depth_clear_value = 1.0,
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

    // pub fn begin_shadow_map_generation_pass(self: *Renderer, light: PointLight) RenderPass {
    //     _ = self;
    //     _ = light;
    // }
};
