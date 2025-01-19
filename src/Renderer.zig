const mach = @import("mach");
const std = @import("std");
const math = @import("math.zig");

pub const mach_module = .renderer;
pub const mach_systems = .{ .preinit, .init, .draw, .deinit };

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

pub const fragment_pass_struct_source =
    \\struct FragPass {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) color: vec4<f32>,
    \\}
    \\
    \\ fn fragPass(pos: vec4<f32>, color: vec4<f32>) -> FragPass {
    \\   var result: FragPass;
    \\   result.pos = pos;
    \\   result.color = color;
    \\   return result;
    \\ }
    \\
;

const fragment_source =
    fragment_pass_struct_source ++
    \\@fragment fn frag_main(input: FragPass) -> @location(0) vec4<f32> {
    \\    return input.color;
    \\}
;

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

    renderer.shared_buffer = device.createBuffer(&.{ .mapped_at_creation = .true, .size = @sizeOf(math.Mat) * Pipeline.MAX_COPIES, .usage = .{ .vertex = true, .uniform = true } });
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
    if (renderer.current_buffer_slot >= Pipeline.MAX_COPIES) {
        renderer.current_buffer_slot = 0;
    }
}

pub fn deinit() void {}

pub const VertexLayout = struct {
    native: mach.gpu.VertexBufferLayout,

    pub fn create(comptime T: type) VertexLayout {
        comptime var attributes: []const mach.gpu.VertexAttribute = &.{};

        inline for (0.., @typeInfo(T).@"struct".fields) |i, field| {
            const attrib = comptime mach.gpu.VertexAttribute{
                .offset = @offsetOf(T, field.name),
                .format = switch (field.type) {
                    math.Vec2 => .float32x2,
                    math.Vec3 => .float32x3,
                    math.Vec4 => .float32x4,
                    else => .undefined,
                },
                .shader_location = i,
            };
            attributes = attributes ++ [_]mach.gpu.VertexAttribute{attrib};
        }
        return VertexLayout{ .native = .{
            .array_stride = @sizeOf(T),
            .attribute_count = attributes.len,
            .attributes = attributes.ptr,
            .step_mode = .vertex,
        } };
    }
};

pub const Pipeline = struct {
    pipeline_handle: *mach.gpu.RenderPipeline,
    bind_group_layout: *mach.gpu.BindGroupLayout,
    bindings: []BindingLayout,

    pub const BindingLayout = struct {
        location: u32,
        type: Type,
        management: Management = .managed_often,

        const Type = enum {
            uniform,
            storage,
            read_only_storage,
            texture_view,
            texture_sampler,
        };

        const Management = enum { unmanaged, managed_single, managed_often };
    };

    pub const Binding = struct {
        location: u32,
        size: u64,
        texture_view: ?*mach.gpu.TextureView = null,
        texture_sampler: ?*mach.gpu.Sampler = null,
        buffer: ?*mach.gpu.Buffer = null,
    };

    const MAX_COPIES = 4;

    const Options = struct {
        vertex_source: [*:0]const u8,
        bindings: []const BindingLayout,
        vertex_layout: ?VertexLayout = null,
    };

    pub fn create(renderer: *Renderer, options: Options) !mach.ObjectID {
        const device: *mach.gpu.Device = renderer.core.windows.get(renderer.current_window, .device);
        const framebuffer_format = renderer.core.windows.get(renderer.current_window, .framebuffer_format);
        const vertex_shader = device.createShaderModuleWGSL(null, options.vertex_source);
        defer vertex_shader.release();

        const fragment_shader = device.createShaderModuleWGSL(null, fragment_source);
        defer fragment_shader.release();

        const bind_group_entries = try renderer.core.allocator.alloc(mach.gpu.BindGroupLayout.Entry, options.bindings.len);
        defer renderer.core.allocator.free(bind_group_entries);

        for (bind_group_entries, options.bindings) |*entry, binding| {
            const visibility = mach.gpu.ShaderStageFlags{ .vertex = true, .fragment = true };
            switch (binding.type) {
                .storage => entry.* = mach.gpu.BindGroupLayout.Entry.initBuffer(binding.location, visibility, .storage, true, 0),
                .read_only_storage => entry.* = mach.gpu.BindGroupLayout.Entry.initBuffer(binding.location, visibility, .read_only_storage, true, 0),
                .uniform => entry.* = mach.gpu.BindGroupLayout.Entry.initBuffer(binding.location, visibility, .uniform, true, 0),
                .texture_view => entry.* = mach.gpu.BindGroupLayout.Entry.initTexture(binding.location, visibility, .uint, .dimension_2d, false),
                .texture_sampler => entry.* = mach.gpu.BindGroupLayout.Entry.initSampler(binding.location, visibility, .filtering),
            }
        }

        const bind_group_layout = device.createBindGroupLayout(&mach.gpu.BindGroupLayout.Descriptor{
            .entries = bind_group_entries.ptr,
            .entry_count = bind_group_entries.len,
        });

        const color_targets = [_]mach.gpu.ColorTargetState{.{
            .format = framebuffer_format,
        }};

        const pipeline_layout_descriptor = mach.gpu.PipelineLayout.Descriptor{
            .bind_group_layout_count = 2,
            .bind_group_layouts = &.{
                bind_group_layout,
                renderer.shared_bind_group_layout,
            },
        };

        const pipeline_layout = device.createPipelineLayout(&pipeline_layout_descriptor);
        defer pipeline_layout.release();

        const vertex_layouts = if (options.vertex_layout) |layout| &[_]mach.gpu.VertexBufferLayout{layout.native} else &[_]mach.gpu.VertexBufferLayout{};

        const pipeline_descriptor = mach.gpu.RenderPipeline.Descriptor{
            .layout = pipeline_layout,
            .vertex = mach.gpu.VertexState{
                .module = vertex_shader,
                .entry_point = "vertex_main",
                .buffers = vertex_layouts.ptr,
                .buffer_count = vertex_layouts.len,
            },
            .primitive = mach.gpu.PrimitiveState{
                .front_face = .cw,
                .cull_mode = .back,
                .topology = .triangle_list,
            },
            .depth_stencil = &.{
                .format = .depth32_float,
                .depth_write_enabled = .true,
                .depth_compare = .less,
            },
            .fragment = &mach.gpu.FragmentState{
                .module = fragment_shader,
                .entry_point = "frag_main",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
        };

        const pipeline = Pipeline{
            .bindings = try renderer.core.allocator.dupe(BindingLayout, options.bindings),
            .pipeline_handle = device.createRenderPipeline(&pipeline_descriptor),
            .bind_group_layout = bind_group_layout,
        };

        renderer.pipelines.lock();
        defer renderer.pipelines.unlock();
        return try renderer.pipelines.new(pipeline);
    }

    pub fn destroy(renderer: *Renderer, pipeline_id: mach.ObjectID) void {
        renderer.pipelines.lock();
        defer renderer.pipelines.unlock();

        renderer.pipelines.get(pipeline_id, .pipeline_handle).release();
        renderer.pipelines.get(pipeline_id, .bind_group_layout).release();
        renderer.core.allocator.free(renderer.pipelines.get(pipeline_id, .bindings));
        renderer.pipelines.delete(pipeline_id);
    }

    fn pad_size(size: u64) u64 {
        return ((size + 16) & (0xFFFF_FFFF_FFFF_FFF0));
    }

    pub fn spawn_instance(renderer: *Renderer, pipeline_id: mach.ObjectID, bindings: []const Binding) !mach.ObjectID {
        const device: *mach.gpu.Device = renderer.core.windows.get(renderer.current_window, .device);
        const bind_group_layout = renderer.pipelines.get(pipeline_id, .bind_group_layout);
        const binding_layout = renderer.pipelines.get(pipeline_id, .bindings);

        // Find size needed for Managed Buffers
        var buffer_size: u64 = 0;
        for (binding_layout, bindings) |layout, binding| {
            switch (layout.type) {
                .uniform, .storage, .read_only_storage => {
                    switch (layout.management) {
                        .unmanaged => {},
                        .managed_single => {
                            buffer_size += pad_size(binding.size);
                        },
                        .managed_often => {
                            buffer_size += pad_size(binding.size) * MAX_COPIES;
                        },
                    }
                },
                else => {},
            }
        }

        const buffer_descriptor = mach.gpu.Buffer.Descriptor{
            .mapped_at_creation = .false,
            .size = buffer_size,
            .usage = .{ .copy_dst = true, .storage = true, .uniform = true },
        };
        const buffer = device.createBuffer(&buffer_descriptor);

        const bind_group_entries = try renderer.core.allocator.alloc(mach.gpu.BindGroup.Entry, bindings.len);

        var walking_offset: u64 = 0;
        for (binding_layout, bind_group_entries, bindings) |layout, *entry, binding| {
            entry.binding = binding.location;
            entry.offset = 0;
            entry.size = binding.size;
            entry.elem_size = 0;
            entry.sampler = null;
            entry.texture_view = null;

            switch (layout.type) {
                .uniform, .storage, .read_only_storage => {
                    switch (layout.management) {
                        .unmanaged => {
                            entry.buffer = binding.buffer.?;
                        },
                        .managed_single => {
                            entry.buffer = buffer;
                            entry.offset = walking_offset;
                            entry.size = pad_size(binding.size);
                            walking_offset += entry.size;
                        },
                        .managed_often => {
                            entry.buffer = buffer;
                            entry.offset = walking_offset;
                            entry.size = pad_size(binding.size) * MAX_COPIES;
                            walking_offset += entry.size;
                        },
                    }
                },
                .texture_view => {
                    entry.texture_view = binding.texture_view;
                },
                .texture_sampler => {
                    entry.sampler = binding.texture_sampler;
                },
            }
        }

        const result = Instance{
            .pipeline = pipeline_id,
            .buffer = buffer,
            .bind_group_entries = bind_group_entries,
            .bind_group = device.createBindGroup(&.{
                .entries = bind_group_entries.ptr,
                .entry_count = bind_group_entries.len,
                .layout = bind_group_layout,
            }),
            .dynamic_offsets = try renderer.core.allocator.alloc(u32, bind_group_entries.len),
        };

        for (result.dynamic_offsets) |*offset| {
            offset.* = 0;
        }

        renderer.instances.lock();
        defer renderer.instances.unlock();
        const instance_id = try renderer.instances.new(result);
        try renderer.pipelines.addChild(pipeline_id, instance_id);

        return instance_id;
    }
};

pub const VertexBuffer = struct {
    vertex_buffer: ?*mach.gpu.Buffer = null,
    vertex_count: u32 = 3,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,

    pub fn new(renderer: *Renderer, offset: u32, primitive_count: u32, T: type) VertexBuffer {
        if (T != void) {
            const device: *mach.gpu.Device = renderer.core.windows.get(renderer.current_window, .device);
            const buf = device.createBuffer(&mach.gpu.Buffer.Descriptor{
                .mapped_at_creation = .true,
                .size = primitive_count * @sizeOf(T) * 3,
                .usage = .{ .copy_dst = true, .map_write = true, .vertex = true },
            });

            return VertexBuffer{
                .vertex_count = primitive_count * 3,
                .first_vertex = offset * 3,
                .vertex_buffer = buf,
            };
        } else {
            return VertexBuffer{
                .vertex_count = primitive_count * 3,
                .first_vertex = offset * 3,
            };
        }
    }

    pub fn map(self: *@This(), T: type) ?[]T {
        return self.vertex_buffer.?.getMappedRange(T, 0, self.vertex_buffer.?.getSize() / @sizeOf(T));
    }

    pub fn free(self: *VertexBuffer) void {
        if (self.vertex_buffer) |vertex_buffer| {
            vertex_buffer.release();
        }
    }
};

pub const Instance = struct {
    pipeline: mach.ObjectID,
    buffer: *mach.gpu.Buffer,
    bind_group: ?*mach.gpu.BindGroup = null,
    bind_group_entries: []mach.gpu.BindGroup.Entry,
    vertex_buffer: VertexBuffer = .{},
    dynamic_offsets: []u32,

    pub fn update_buffer(renderer: *Renderer, instance_id: mach.ObjectID, binding_id: u32, base_offset: u32, T: type, value: []const T) void {
        const pipeline_id = renderer.instances.get(instance_id, .pipeline);
        const current_buffer_slot = renderer.current_buffer_slot;
        const queue: *mach.gpu.Queue = renderer.core.windows.get(renderer.current_window, .queue);
        const bind_group_entries = renderer.instances.get(instance_id, .bind_group_entries);
        const management = renderer.pipelines.get(pipeline_id, .bindings)[binding_id].management;
        const current_offset = base_offset + bind_group_entries[binding_id].offset + ((if (management == .managed_often) current_buffer_slot else 0) * bind_group_entries[binding_id].size);
        queue.writeBuffer(bind_group_entries[binding_id].buffer.?, current_offset, value);
    }

    pub fn set_vertex_buffer(renderer: *Renderer, instance_id: mach.ObjectID, vertex_buffer: VertexBuffer) void {
        if (renderer.instances.get(instance_id, .vertex_buffer).vertex_buffer) |old_vertex_buffer| {
            old_vertex_buffer.release();
        }

        renderer.instances.set(instance_id, .vertex_buffer, vertex_buffer);
        if (vertex_buffer.vertex_buffer) |new_vertex_buffer| {
            new_vertex_buffer.reference();
        }
    }

    pub fn destroy(renderer: *Renderer, instance_id: mach.ObjectID) void {
        renderer.core.allocator.free(renderer.instances.get(instance_id, .bind_group_descriptors));
        renderer.core.allocator.free(renderer.instances.get(instance_id, .dynamic_offsets));
        renderer.instances.delete(instance_id);
    }
};
