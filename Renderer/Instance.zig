const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const Instance = @This();
const VertexBuffer = Renderer.VertexBuffer;

pipeline: Renderer.Pipeline.Handle,
buffer: ?*mach.gpu.Buffer,
bind_group: ?*mach.gpu.BindGroup = null,
bind_group_entries: []mach.gpu.BindGroup.Entry,
vertex_buffer: VertexBuffer = .{},
dynamic_offsets: []u32,

pub const Binding = struct {
    location: u32,
    size: u64,
    attachment: union(AttachmentType) {
        none: void,
        texture_view: ?*mach.gpu.TextureView,
        texture_sampler: ?*mach.gpu.Sampler,
        buffer: ?*mach.gpu.Buffer,
    } = .none,

    const AttachmentType = enum {
        none,
        texture_view,
        texture_sampler,
        buffer,
    };
};

pub const MAX_COPIES = 4;

pub const CreateOptions = struct {
    pipeline: Renderer.Pipeline.Handle,
    bindings: []const Binding = &.{},
    bounding_box_p0: math.Vec3,
    bounding_box_p1: math.Vec3,
};

fn find_binding(layout: Renderer.Pipeline.BindingLayout, bindings: []const Binding) ?Binding {
    switch (layout.type) {
        .builtin => |inner| switch (inner) {
            .transform => return Binding{
                .location = layout.location,
                .size = @sizeOf(math.Mat),
            },
        },
        else => {
            for (bindings) |binding| {
                if (binding.location == layout.location) {
                    return binding;
                }
            }
            return null;
        },
    }
}

pub fn createNode(renderer: *Renderer, options: CreateOptions) !Renderer.Node.Handle {
    const device: *mach.gpu.Device = renderer.device;
    const bind_group_layout = renderer.pipelines.get(options.pipeline.id, .bind_group_layout);
    const binding_layout = renderer.pipelines.get(options.pipeline.id, .bindings);

    // Find size needed for Managed Buffers
    var buffer_size: u64 = 0;
    for (binding_layout) |layout| {
        if (find_binding(layout, options.bindings)) |binding| {
            if (std.meta.activeTag(binding.attachment) == .none)
                buffer_size += pad_size(binding.size) * MAX_COPIES;
        }
    }

    var buffer: ?*mach.gpu.Buffer = null;
    if (buffer_size != 0) {
        const buffer_descriptor = mach.gpu.Buffer.Descriptor{
            .mapped_at_creation = .false,
            .size = buffer_size,
            .usage = .{ .copy_dst = true, .storage = true, .uniform = true },
        };
        buffer = device.createBuffer(&buffer_descriptor);
    }

    const bind_group_entries = try renderer.core.allocator.alloc(mach.gpu.BindGroup.Entry, binding_layout.len);

    var walking_offset: u64 = 0;
    for (binding_layout, bind_group_entries) |layout, *entry| {
        if (find_binding(layout, options.bindings)) |binding| {
            entry.binding = binding.location;
            entry.offset = 0;
            entry.size = binding.size;
            entry.elem_size = 0;
            entry.sampler = null;
            entry.texture_view = null;
            entry.buffer = null;

            switch (binding.attachment) {
                .none => {
                    entry.buffer = buffer;
                    entry.offset = walking_offset;
                    entry.size = pad_size(binding.size);
                    walking_offset += (entry.size * MAX_COPIES);
                },
                .buffer => |attachment| entry.buffer = attachment,
                .texture_view => |attachment| entry.texture_view = attachment,
                .texture_sampler => |attachment| entry.sampler = attachment,
            }
        }
    }

    const result = Instance{
        .pipeline = options.pipeline,
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

    const node_id = try Renderer.Node.create(renderer, .{ .backing_object = instance_id, .bounding_box_p0 = options.bounding_box_p0, .bounding_box_p1 = options.bounding_box_p1 });
    return node_id;
}

fn pad_size(size: u64) u64 {
    return ((size + 16) & (0xFFFF_FFFF_FFFF_FFF0));
}

pub const Handle = struct {
    id: mach.ObjectID,

    pub fn update_buffer(instance: Handle, renderer: *Renderer, binding_id: u32, base_offset: u32, T: type, value: []const T) void {
        const pipeline = renderer.instances.get(instance.id, .pipeline);
        const current_buffer_slot = renderer.current_buffer_slot;
        const queue: *mach.gpu.Queue = renderer.queue;
        const bind_group_entries = renderer.instances.get(instance.id, .bind_group_entries);
        const bindings = renderer.pipelines.get(pipeline.id, .bindings);

        const entry_opt = entry_loop: {
            for (bind_group_entries) |entry| {
                if (entry.binding == binding_id) break :entry_loop entry;
            }
            break :entry_loop null;
        };

        if (entry_opt) |entry| {
            const current_offset = switch (bindings[binding_id].type) {
                .managed_buffer, .builtin => base_offset + entry.offset + (current_buffer_slot * bind_group_entries[binding_id].size),
                .unmanaged_buffer => base_offset + entry.offset,
                else => 0,
            };
            queue.writeBuffer(bind_group_entries[binding_id].buffer.?, current_offset, value);
        }
    }

    pub fn set_vertex_buffer(instance: Handle, renderer: *Renderer, vertex_buffer: VertexBuffer) void {
        if (renderer.instances.get(instance.id, .vertex_buffer).vertex_buffer) |old_vertex_buffer| {
            old_vertex_buffer.release();
        }

        renderer.instances.set(instance.id, .vertex_buffer, vertex_buffer);
        if (vertex_buffer.vertex_buffer) |new_vertex_buffer| {
            new_vertex_buffer.reference();
        }
    }

    pub fn get_pipeline(instance: Handle, renderer: *Renderer) Renderer.Pipeline.Handle {
        return renderer.instances.get(instance.id, .pipeline);
    }

    pub fn destroy(instance: Handle, renderer: *Renderer) void {
        renderer.core.allocator.free(renderer.instances.get(instance.id, .bind_group_descriptors));
        renderer.core.allocator.free(renderer.instances.get(instance.id, .dynamic_offsets));
        renderer.instances.delete(instance.id);
    }
};
