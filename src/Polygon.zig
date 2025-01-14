const std = @import("std");
const Renderer = @import("Renderer.zig");
const App = @import("App.zig");
const math = @import("math.zig");
const mach = @import("mach");

pub const mach_module = .polygon;
pub const mach_systems = .{ .init, .tick, .deinit };

const Polygon = @This();
pub const Mod = mach.Mod(@This());

renderer: *Renderer,

pipeline: mach.ObjectID,
polygons: mach.Objects(.{}, struct {
    vertex_buffer: Renderer.VertexBuffer,
    instance: mach.ObjectID,
}),

const Vertex = struct {
    x: math.Vec2,
};

const shader_render_src =
    Renderer.fragment_pass_struct_source ++
    \\ @group(1) @binding(0) var<uniform> world_xform: mat4x4<f32>;
    \\
    \\ @vertex fn vertex_main(@location(0) Vertex: vec2<f32>) -> FragPass {
    \\     return fragPass(world_xform * vec4(Vertex.x, 0.0, Vertex.y, 1.0), vec4(1.0,1.0,1.0,1.0));
    \\ }
;

pub fn create_polygon(self: *Polygon, vertices: []const Vertex) !mach.ObjectID {
    const vertex_buffer = Renderer.VertexBuffer.alloc(self.renderer, 0, @intCast(vertices.len), Vertex, vertices);
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
        .vertex_layout = Renderer.VertexLayout.create(Vertex),
    });
}

pub fn tick(self: *Polygon) !void {
    _ = self;
}

pub fn deinit(self: *Polygon) void {
    Renderer.Pipeline.destroy(self.renderer, self.pipeline);
}
