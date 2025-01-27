const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const VertexLayout = Renderer.VertexLayout;

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
