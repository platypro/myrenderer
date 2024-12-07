const gpu = @import("zgpu");
const std = @import("std");
const img = @import("zigimg");
const Renderer = @import("Renderer.zig");
const App = @import("App.zig");
const math = @import("math.zig");

pub const mach_module = .terrain;
pub const mach_systems = .{ .init, .draw };

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
    padding1: u32,
    padding2: u32,
    padding3: u32,
    xform: math.Mat,
};

bind_group_layout_handle: ?gpu.BindGroupLayoutHandle = null,
bind_group_handle: ?gpu.BindGroupHandle = null,
pipeline_handle: ?gpu.RenderPipelineHandle = null,
terrain_handle: ?gpu.BufferHandle = null,
terrain_size: u32 = 0,

pub fn load_terrain(self: *@This(), renderer: *Renderer, allocator: std.mem.Allocator, filename: []const u8) !void {
    const image_file = try std.fs.cwd().openFile(filename, .{});
    defer image_file.close();
    var stream_source = std.io.StreamSource{ .file = image_file };
    var image = try img.png.load(&stream_source, allocator, .{ .temp_allocator = allocator });
    defer image.deinit(allocator);

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
            converted_bytes[i] = @as(f32, @floatFromInt(image.pixels.grayscale16[sub].value)) / @as(f32, 65535.0);
        }

        renderer.gctx.queue.writeBuffer(image_buf, counter * 4, f32, converted_bytes[0..copy_amnt]);
        counter += COPY_SIZE;
    }

    self.bind_group_handle = renderer.gctx.createBindGroup(self.bind_group_layout_handle.?, &.{
        .{ .binding = 0, .buffer_handle = renderer.gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(Uniform) },
        .{ .binding = 1, .buffer_handle = self.terrain_handle, .offset = 0, .size = image_buf_size },
    });
}

pub fn init(self: *@This(), renderer: *Renderer) !void {
    const gctx = renderer.gctx;

    self.* = .{};

    self.bind_group_layout_handle = renderer.gctx.createBindGroupLayout(&.{
        gpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
        gpu.bufferEntry(1, .{ .vertex = true }, .read_only_storage, false, 0),
    });
    errdefer renderer.gctx.releaseResource(self.bind_group_layout_handle.?);

    self.pipeline_handle = pipeline: {
        const shader_source = shader_render_src;
        const shader = gpu.createWgslShaderModule(gctx.device, shader_source, null);
        defer shader.release();

        const color_targets = [_]gpu.wgpu.ColorTargetState{.{
            .format = gpu.GraphicsContext.swapchain_format,
        }};

        const pipeline_layout = gctx.createPipelineLayout(&.{self.bind_group_layout_handle.?});
        defer gctx.releaseResource(pipeline_layout);

        const pipeline_descriptor = gpu.wgpu.RenderPipelineDescriptor{
            .vertex = gpu.wgpu.VertexState{
                .module = shader,
                .entry_point = "vertex_main",
            },
            .primitive = gpu.wgpu.PrimitiveState{
                .front_face = .cw,
                .cull_mode = .front,
                .topology = .triangle_list,
            },
            .depth_stencil = &.{
                .format = .depth32_float,
                .depth_write_enabled = true,
                .depth_compare = .greater,
            },
            .fragment = &gpu.wgpu.FragmentState{
                .module = shader,
                .entry_point = "frag_main",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
        };
        break :pipeline gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
    };
}

pub fn draw(self: *@This(), renderer: *Renderer) void {
    const gctx = renderer.gctx;
    const pipeline = gctx.lookupResource(self.pipeline_handle.?) orelse unreachable;
    const bind_group = gctx.lookupResource(self.bind_group_handle.?) orelse unreachable;

    var pass = renderer.begin_pass(.{});

    const alloc = gctx.uniformsAllocate(Uniform, 1);
    const xform = math.matMult(&.{ renderer.current_xform, math.Mat.scale(math.Vec3.init(1.0, 5.0, 1.0)) });

    alloc.slice[0].size = self.terrain_size;
    alloc.slice[0].xform = xform;

    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bind_group, &.{alloc.offset});
    pass.draw(6 * self.terrain_size * self.terrain_size, 1, 0, 0);

    pass.end();
    pass.release();
}
