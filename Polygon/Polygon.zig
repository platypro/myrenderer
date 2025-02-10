const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const Polygon = @This();
const mods = @import("root").getModules();

pub const mach_module = .polygon;
pub const mach_systems = .{ .init, .deinit };

pub const Mod = mach.Mod(@This());

const Triangulation = @import("Triangulation.zig");
pub const Point = Triangulation.Point;

renderer: *Renderer,

triangulation: Triangulation,
pipeline: Renderer.Pipeline.Handle,
polygons: mach.Objects(.{}, struct {
    vertex_buffer: Renderer.VertexBuffer,
    node: Renderer.Node.Handle,
}),

const GPUVertex = struct {
    x: math.Vec2,
    color: math.Vec3,
};

const shader_render_src =
    Renderer.Pipeline.fragment_pass_struct_source ++
    \\ @group(0) @binding(0) var<uniform> world_xform: mat4x4<f32>;
    \\
    \\ @vertex fn vertex(@location(0) Vertex: vec2<f32>, @location(1) Color: vec3<f32>) -> FragPass {
    \\     return fragPass(world_xform * vec4(Vertex.x, Vertex.y, 1.0, 1.0), vec4(Color,1.0));
    \\ }
;

pub const Handle = struct {
    id: mach.ObjectID,
    pub fn getNode(self: Handle, module: *Polygon) Renderer.Node.Handle {
        return module.polygons.get(self.id, .node);
    }
};

fn color_from_hex(hex: u32) math.Vec3 {
    const hexvals = [_]u8{ @truncate(hex), @truncate(hex >> 8), @truncate(hex >> 16) };
    return math.Vec3.init(
        @as(f32, @floatFromInt(hexvals[0])) / 255.0,
        @as(f32, @floatFromInt(hexvals[1])) / 255.0,
        @as(f32, @floatFromInt(hexvals[2])) / 255.0,
    );
}

const RenderContext = struct {
    vertex_array: std.ArrayListUnmanaged(GPUVertex),
    boundary_p1: math.Vec2,
    boundary_p2: math.Vec2,
};

fn render_point(context: *RenderContext, point: Point) void {
    const colors: []const math.Vec3 = &.{
        comptime color_from_hex(0x5e315b),
        comptime color_from_hex(0xcfff70),
        comptime color_from_hex(0x3ca370),
        comptime color_from_hex(0x4b5bab),
    };

    context.boundary_p1.v[0] = @min(context.boundary_p1.v[0], point[0]);
    context.boundary_p1.v[1] = @min(context.boundary_p1.v[0], point[1]);
    context.boundary_p2.v[0] = @max(context.boundary_p2.v[0], point[0]);
    context.boundary_p2.v[1] = @max(context.boundary_p2.v[0], point[1]);

    context.vertex_array.appendAssumeCapacity(.{ .x = .{ .v = point }, .color = colors[(context.vertex_array.items.len / 3) % colors.len] });
}

pub fn create_polygon(self: *Polygon, vertices: []const Triangulation.Point) !Handle {
    var vertex_buffer = Renderer.VertexBuffer.new(self.renderer, 0, @intCast(vertices.len - 2), GPUVertex);
    const vertex_buffer_map = vertex_buffer.map(GPUVertex).?;

    var ctx = RenderContext{
        .vertex_array = std.ArrayListUnmanaged(GPUVertex){ .capacity = vertex_buffer_map.len, .items = vertex_buffer_map },
        .boundary_p1 = math.Vec2.init(0.0, 0.0),
        .boundary_p2 = math.Vec2.init(0.0, 0.0),
    };
    ctx.vertex_array.items.len = 0;

    try self.triangulation.create_polygon(vertices, &ctx, render_point);

    const node = try Renderer.Instance.createNode(.{
        .pipeline = self.pipeline,
        .bounding_box_p0 = math.Vec3.init(ctx.boundary_p1.x(), ctx.boundary_p1.y(), 0.0),
        .bounding_box_p1 = math.Vec3.init(ctx.boundary_p2.x(), ctx.boundary_p2.y(), 0.0),
    });

    const instance = Renderer.Instance.Handle{ .id = node.get_backing() };
    instance.set_vertex_buffer(vertex_buffer);

    return .{ .id = try self.polygons.new(.{
        .vertex_buffer = vertex_buffer,
        .node = node,
    }) };
}

pub fn init(self: *Polygon, renderer: *Renderer) !void {
    self.renderer = renderer;
    self.pipeline = try Renderer.Pipeline.create(.{
        .vertex_source = shader_render_src,
        .bindings = &.{.{ .location = 0, .type = .{ .builtin = .transform } }},
        .vertex_layout = Renderer.VertexLayout.create(GPUVertex),
    });
    self.triangulation = Triangulation.new(mods.mach_core.allocator);
}

pub fn deinit(self: *Polygon) void {
    self.pipeline.destroy(self.renderer);
}
