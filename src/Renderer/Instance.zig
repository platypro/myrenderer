const mach = @import("mach");
const Renderer = @import("../Renderer.zig");
const Instance = @This();
const VertexBuffer = Renderer.VertexBuffer;

pipeline: mach.ObjectID,
buffer: ?*mach.gpu.Buffer,
bind_group: ?*mach.gpu.BindGroup = null,
bind_group_entries: []mach.gpu.BindGroup.Entry,
vertex_buffer: VertexBuffer = .{},
dynamic_offsets: []u32,

pub const Binding = struct {
    location: u32,
    size: u64,
    texture_view: ?*mach.gpu.TextureView = null,
    texture_sampler: ?*mach.gpu.Sampler = null,
    buffer: ?*mach.gpu.Buffer = null,
};

pub const MAX_COPIES = 4;

pub fn create(renderer: *Renderer, pipeline_id: mach.ObjectID, bindings: []const Binding) !mach.ObjectID {
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

    var buffer: ?*mach.gpu.Buffer = null;
    if (buffer_size != 0) {
        const buffer_descriptor = mach.gpu.Buffer.Descriptor{
            .mapped_at_creation = .false,
            .size = buffer_size,
            .usage = .{ .copy_dst = true, .storage = true, .uniform = true },
        };
        buffer = device.createBuffer(&buffer_descriptor);
    }

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
                        entry.buffer = buffer.?;
                        entry.offset = walking_offset;
                        entry.size = pad_size(binding.size);
                        walking_offset += entry.size;
                    },
                    .managed_often => {
                        entry.buffer = buffer.?;
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

fn pad_size(size: u64) u64 {
    return ((size + 16) & (0xFFFF_FFFF_FFFF_FFF0));
}

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
