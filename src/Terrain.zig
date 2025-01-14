const std = @import("std");
const img = @import("zigimg");
const Renderer = @import("Renderer.zig");
const App = @import("App.zig");
const math = @import("math.zig");
const mach = @import("mach");

pub const mach_module = .terrain;
pub const mach_systems = .{ .init, .tick, .deinit };

const Terrain = @This();
pub const Mod = mach.Mod(@This());

// Shader inputs:
//    vertex_index (u32)      - The current vertex ID
//    heightmap (array<f32>) - The heightmap data
//    size (u32)             - The heightmap width
// Shader Outputs:
//    vertex_out (vec4<f32>) - The output vertex
const shader_genvertices_src =
    \\ var vertex_out: vec4<f32>;
    \\ {
    \\    var vertex_at = vertex_index % 6;
    \\    var quad_at = (vertex_index - vertex_at) / 6;
    \\    var quad_at_coords = vec2<f32>(f32(quad_at / data.size), f32(quad_at % data.size));
    \\
    \\    const quad_vals = array<vec2<f32>, 6>(
    \\        vec2<f32>(1.0, 0.0),
    \\        vec2<f32>(1.0, 1.0),
    \\        vec2<f32>(0.0, 0.0),
    \\        vec2<f32>(1.0, 1.0),
    \\        vec2<f32>(0.0, 1.0),
    \\        vec2<f32>(0.0, 0.0)
    \\    );
    \\    var quadValue = 0.2 * (quad_vals[vertex_at] + quad_at_coords) - 0.1 * f32(data.size);
    \\
    \\    var quad_lookup = array<u32, 6>(
    \\        quad_at + data.size,
    \\        quad_at + data.size + 1,
    \\        quad_at,
    \\        quad_at + data.size + 1,
    \\        quad_at + 1,
    \\        quad_at,
    \\    );
    \\
    \\    var vertex_value = heightmap[quad_lookup[vertex_at]];
    \\    vertex_out = vec4<f32>(quadValue.x, vertex_value, quadValue.y, 1.0);
    \\ }
;

const shader_render_src =
    \\@group(0) @binding(0) var<uniform> data: UniformStruct;
    \\@group(0) @binding(1) var<storage,read> heightmap: array<f32>;
    \\
    \\@group(1) @binding(0) var<uniform> world_xform: mat4x4<f32>;
    \\
    \\struct UniformStruct {
    \\    xform: mat4x4<f32>,
    \\    size: u32,
    \\}
    \\
    \\struct FragPass {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) color: vec4<f32>,
    \\}
    \\
    \\@vertex fn vertex_main(
    \\    @builtin(vertex_index) vertex_index : u32
    \\) -> FragPass {
++ shader_genvertices_src ++
    \\    var out: FragPass;
    \\    out.pos = world_xform * data.xform * vertex_out;
    \\    out.color = vec4(vertex_out.y, vertex_out.y, vertex_out.y, 1.0);
    \\
    \\    return out;
    \\}
    \\
;

const Uniform = extern struct {
    xform: math.Mat,
    size: u32,
};

pipeline: mach.ObjectID,

pub fn create_terrain(self: *@This(), renderer: *Renderer, core: *mach.Core, filename: []const u8) !mach.ObjectID {
    const image_file = try std.fs.cwd().openFile(filename, .{});
    defer image_file.close();
    var stream_source = std.io.StreamSource{ .file = image_file };
    var image = try img.png.load(&stream_source, core.allocator, .{ .temp_allocator = core.allocator });
    defer image.deinit(core.allocator);

    const terrain_size: u32 = @intCast(image.width);
    const image_buf_size = terrain_size * terrain_size * 4;

    const bindings = [_]Renderer.Pipeline.Binding{
        .{ .location = 0, .size = @sizeOf(Uniform) },
        .{ .location = 1, .size = image_buf_size },
    };

    const result = try Renderer.Pipeline.spawn_instance(renderer, self.pipeline, &bindings);

    const COPY_SIZE = 64;
    var counter: u32 = 0;
    while (counter < image.pixels.grayscale16.len) {
        const copy_amnt = if (counter + COPY_SIZE >= image.pixels.grayscale16.len) image.pixels.grayscale16.len - counter else COPY_SIZE;
        var converted_bytes: [COPY_SIZE]f32 = undefined;
        for (0..copy_amnt, counter..(counter + copy_amnt)) |i, sub| {
            converted_bytes[i] = 1.0 - @as(f32, @floatFromInt(image.pixels.grayscale16[sub].value)) / @as(f32, 65535.0);
        }
        Renderer.Instance.update_buffer(renderer, result, 1, counter * 4, f32, converted_bytes[0..copy_amnt]);
        counter += COPY_SIZE;
    }

    Renderer.Instance.set_vertex_buffer(renderer, result, .{ .first_instance = 0, .first_vertex = 0, .instance_count = 1, .vertex_count = terrain_size * terrain_size * 6 });
    Renderer.Instance.update_buffer(renderer, result, 0, 0, Uniform, &.{Uniform{ .size = terrain_size, .xform = math.Mat.ident }});
    return result;
}

pub fn init(self: *Terrain, renderer: *Renderer) !void {
    const pipeline = try Renderer.Pipeline.create(renderer, .{
        .bindings = &.{
            .{
                .location = 0,
                .type = .uniform,
                .management = .managed_single,
            },
            .{
                .location = 1,
                .type = .read_only_storage,
                .management = .managed_single,
            },
        },
        .vertex_source = shader_render_src,
    });
    self.pipeline = pipeline;
}

pub fn tick(self: *Terrain, renderer: *Renderer) !void {
    const instances = try renderer.pipelines.getChildren(self.pipeline);
    for (instances.items) |instance| {
        // Render
        Renderer.Instance.update_buffer(renderer, instance, 0, 0, math.Mat, &.{math.Mat.scale(math.Vec3.init(1.0, 5.0, 1.0))});
    }
}

pub fn deinit(self: *@This(), renderer: *Renderer) void {
    Renderer.Pipeline.destroy(renderer, self.pipeline);
}
