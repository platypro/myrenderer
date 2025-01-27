const mach = @import("root").mach;
const Renderer = @import("root").Renderer;
const VertexBuffer = @This();

vertex_buffer: ?*mach.gpu.Buffer = null,
vertex_count: u32 = 3,
instance_count: u32 = 1,
first_vertex: u32 = 0,
first_instance: u32 = 0,

pub fn new(renderer: *Renderer, offset: u32, primitive_count: u32, T: type) VertexBuffer {
    if (T != void) {
        const device: *mach.gpu.Device = renderer.device;
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
