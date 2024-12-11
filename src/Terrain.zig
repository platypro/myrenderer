const gpu = @import("zgpu");
const std = @import("std");
const img = @import("zigimg");
const Renderer = @import("Renderer.zig");
const App = @import("App.zig");
const math = @import("math.zig");
const mach = @import("mach");

pub const mach_module = .terrain;
pub const mach_systems = .{ .init, .draw, .deinit };

const Terrain = @This();

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
    \\struct UniformStruct {
    \\    size: u32,
    \\    xform: mat4x4<f32>,
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
    \\    out.pos = data.xform * vertex_out;
    \\    out.color = vec4(vertex_out.y, vertex_out.y, vertex_out.y, 1.0);
    \\
    \\    return out;
    \\}
    \\
    \\@fragment fn frag_main(input: FragPass) -> @location(0) vec4<f32> {
    \\    return input.color;
    \\}
;

const Uniform = extern struct {
    size: u32,
    padding1: u32 = 0,
    padding2: u32 = 0,
    padding3: u32 = 0,
    xform: math.Mat,
};

pipeline: mach.ObjectID,
instance: ?mach.ObjectID = null,
terrain_handle: ?gpu.BufferHandle = null,
terrain_size: u32 = 0,

pub fn load_terrain(self: *@This(), renderer: *Renderer, app: *App, filename: []const u8) !void {
    const image_file = try std.fs.cwd().openFile(filename, .{});
    defer image_file.close();
    var stream_source = std.io.StreamSource{ .file = image_file };
    var image = try img.png.load(&stream_source, app.allocator, .{ .temp_allocator = app.allocator });
    defer image.deinit(app.allocator);

    self.terrain_size = @intCast(image.width);
    const image_buf_size = self.terrain_size * self.terrain_size * 4;

    if (self.terrain_handle) |handle| {
        if (renderer.gctx.lookupResource(handle)) |buf| {
            buf.release();
            self.terrain_handle = null;
        }
    }

    self.terrain_handle = renderer.gctx.createBuffer(.{ .mapped_at_creation = false, .size = image_buf_size, .usage = .{ .copy_dst = true, .storage = true } });
    const image_buf = renderer.gctx.lookupResource(self.terrain_handle.?) orelse unreachable;

    const COPY_SIZE = 64;
    var counter: u32 = 0;
    while (counter < image.pixels.grayscale16.len) {
        const copy_amnt = if (counter + COPY_SIZE >= image.pixels.grayscale16.len) image.pixels.grayscale16.len - counter else COPY_SIZE;
        var converted_bytes: [COPY_SIZE]f32 = undefined;
        for (0..copy_amnt, counter..(counter + copy_amnt)) |i, sub| {
            converted_bytes[i] = 1.0 - @as(f32, @floatFromInt(image.pixels.grayscale16[sub].value)) / @as(f32, 65535.0);
        }

        renderer.gctx.queue.writeBuffer(image_buf, counter * 4, f32, converted_bytes[0..copy_amnt]);
        counter += COPY_SIZE;
    }

    if (self.instance) |instance_handle| {
        Renderer.Instance.destroy(renderer, app, instance_handle);
    }

    self.instance = try Renderer.Pipeline.spawn_instance(renderer, self.pipeline, app);
    Renderer.Instance.set_storage_buffer(renderer, self.instance.?, 1, self.terrain_handle.?, image_buf_size, 0);
}

pub fn init(self: *Terrain, terrain_mod: mach.Mod(Terrain), renderer: *Renderer) !void {
    const pipeline = try Renderer.Pipeline.create(renderer, .{
        .buffers = &.{
            gpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
            gpu.bufferEntry(1, .{ .vertex = true }, .read_only_storage, true, 0),
        },
        .shader_source = shader_render_src,
        .vtable = .{ .draw = terrain_mod.id.draw },
    });
    self.* = .{ .pipeline = pipeline };
}

pub fn draw(self: *Terrain, renderer: *Renderer) void {
    if (self.instance) |instance| {
        // Render
        const xform = math.matMult(&.{ renderer.current_render_pass.base_transform, math.Mat.scale(math.Vec3.init(1.0, 5.0, 1.0)) });
        Renderer.Instance.set_uniform(renderer, instance, 0, Uniform, Uniform{ .size = self.terrain_size, .xform = xform });
        renderer.current_render_pass.setInstance(renderer, instance);
        renderer.current_render_pass.draw(6 * self.terrain_size * self.terrain_size, 1, 0, 0);
    }
}

pub fn deinit(self: *@This(), renderer: *Renderer, app: *App) void {
    if (self.instance) |instance| {
        Renderer.Instance.destroy(renderer, app, instance);
    }
    Renderer.Pipeline.destroy(renderer, self.pipeline);
}
