const std = @import("std");
const Renderer = @import("Renderer.zig");
const App = @import("App.zig");
const math = @import("math.zig");
const mach = @import("mach");

pub const mach_module = .polygon;
pub const mach_systems = .{ .init, .tick, .deinit };

const Polygon = @This();
pub const Mod = mach.Mod(@This());

const Triangulation = @import("Triangulation.zig");

renderer: *Renderer,

triangulation: Triangulation,
pipeline: mach.ObjectID,
polygons: mach.Objects(.{}, struct {
    vertex_buffer: Renderer.VertexBuffer,
    instance: mach.ObjectID,
}),

const GPUVertex = struct {
    x: math.Vec2,
    color: math.Vec3,
};

const shader_render_src =
    Renderer.fragment_pass_struct_source ++
    \\ @group(1) @binding(0) var<uniform> world_xform: mat4x4<f32>;
    \\
    \\ @vertex fn vertex_main(@location(0) Vertex: vec2<f32>, @location(1) Color: vec3<f32>) -> FragPass {
    \\     return fragPass(world_xform * vec4(Vertex.x, Vertex.y, 1.0, 1.0), vec4(Color,1.0));
    \\ }
;

fn color_from_hex(hex: u32) math.Vec3 {
    const hexvals = [_]u8{ @truncate(hex), @truncate(hex >> 8), @truncate(hex >> 16) };
    return math.Vec3.init(
        @as(f32, @floatFromInt(hexvals[0])) / 255.0,
        @as(f32, @floatFromInt(hexvals[1])) / 255.0,
        @as(f32, @floatFromInt(hexvals[2])) / 255.0,
    );
}

fn render_point(context: *std.ArrayListUnmanaged(GPUVertex), point: math.Vec2) void {
    const colors: []const math.Vec3 = &.{
        comptime color_from_hex(0x5e315b),
        comptime color_from_hex(0xcfff70),
        comptime color_from_hex(0x3ca370),
        comptime color_from_hex(0x4b5bab),
    };

    context.appendAssumeCapacity(.{ .x = point, .color = colors[(context.items.len / 3) % colors.len] });
}

pub fn create_polygon(self: *Polygon, vertices: []const math.Vec2) !mach.ObjectID {
    var vertex_buffer = Renderer.VertexBuffer.new(self.renderer, 0, @intCast(vertices.len - 2), GPUVertex);
    const vertex_buffer_map = vertex_buffer.map(GPUVertex).?;
    var vertex_buffer_arraylist = std.ArrayListUnmanaged(GPUVertex){ .capacity = vertex_buffer_map.len, .items = vertex_buffer_map };
    vertex_buffer_arraylist.items.len = 0;

    try self.triangulation.create_polygon(vertices, &vertex_buffer_arraylist, render_point);

    const instance = try Renderer.Pipeline.spawn_instance(self.renderer, self.pipeline, &.{});
    Renderer.Instance.set_vertex_buffer(self.renderer, instance, vertex_buffer);

    return self.polygons.new(.{
        .vertex_buffer = vertex_buffer,
        .instance = instance,
    });
}

pub fn init(self: *Polygon, renderer: *Renderer) !void {
    self.renderer = renderer;
    self.pipeline = try Renderer.Pipeline.create(self.renderer, .{
        .vertex_source = shader_render_src,
        .bindings = &.{},
        .vertex_layout = Renderer.VertexLayout.create(GPUVertex),
    });
    self.triangulation = Triangulation.new(self.renderer.core.allocator);
}

pub fn tick(self: *Polygon) !void {
    _ = self;
}

pub fn deinit(self: *Polygon) void {
    Renderer.Pipeline.destroy(self.renderer, self.pipeline);
}
