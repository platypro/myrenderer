const std = @import("std");
const mach = @import("root").mach;
const Renderer = @import("root").Renderer;
const Pipeline = @This();
const VertexLayout = Renderer.VertexLayout;
const mods = @import("root").getModules();

pipeline_handle: *mach.gpu.RenderPipeline,
bind_group_layout: *mach.gpu.BindGroupLayout,
bindings: []BindingLayout,

pub const fragment_pass_struct_source =
    \\struct FragPass {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) color: vec4<f32>,
    \\}
    \\
    \\ fn fragPass(pos: vec4<f32>, color: vec4<f32>) -> FragPass {
    \\   var result: FragPass;
    \\   result.pos = pos;
    \\   result.color = color;
    \\   return result;
    \\ }
    \\
;

const fragment_source =
    fragment_pass_struct_source ++
    \\@fragment fn fragment(input: FragPass) -> @location(0) vec4<f32> {
    \\    return input.color;
    \\}
;

pub const BindingLayout = struct {
    location: u32,
    type: union(Type) {
        managed_buffer: mach.gpu.Buffer.BindingType,
        unmanaged_buffer: mach.gpu.Buffer.BindingType,
        builtin: Builtin,
        texture_view: void,
        texture_sampler: void,
    },

    pub const Builtin = enum {
        transform,
    };

    const Type = enum {
        managed_buffer,
        unmanaged_buffer,
        builtin,
        texture_view,
        texture_sampler,
    };
};

pub const Handle = struct {
    id: mach.ObjectID,

    pub fn get_builtin_location(pipeline: Handle, builtin: BindingLayout.Builtin) ?u32 {
        const bindings = mods.renderer.pipelines.get(pipeline.id, .bindings);
        for (bindings) |binding| {
            if (std.meta.eql(binding.type, .{ .builtin = builtin })) {
                return binding.location;
            }
        }
        return null;
    }

    pub fn destroy(pipeline: Handle, renderer: *Renderer) void {
        renderer.pipelines.lock();
        defer renderer.pipelines.unlock();

        mods.renderer.pipelines.get(pipeline.id, .pipeline_handle).release();
        mods.renderer.pipelines.get(pipeline.id, .bind_group_layout).release();
        mods.mach_core.allocator.free(mods.renderer.pipelines.get(pipeline.id, .bindings));
        mods.renderer.pipelines.delete(pipeline.id);
    }
};

pub const Options = struct {
    vertex_source: [*:0]const u8,
    vertex_entry: [*:0]const u8 = "vertex",
    fragment_source: ?[*:0]const u8 = null,
    fragment_entry: [*:0]const u8 = "fragment",
    bindings: []const BindingLayout,
    vertex_layout: ?VertexLayout = null,
};

pub fn create(options: Options) !Handle {
    const device: *mach.gpu.Device = mods.renderer.device;
    const framebuffer_format = mods.renderer.framebuffer_format;
    const vertex_shader = device.createShaderModuleWGSL(null, options.vertex_source);
    defer vertex_shader.release();

    const fragment_shader = device.createShaderModuleWGSL(null, if (options.fragment_source) |src| src else fragment_source);
    defer fragment_shader.release();

    const bind_group_entries = try mods.mach_core.allocator.alloc(mach.gpu.BindGroupLayout.Entry, options.bindings.len);
    defer mods.mach_core.allocator.free(bind_group_entries);

    for (bind_group_entries, options.bindings) |*entry, binding| {
        const visibility = mach.gpu.ShaderStageFlags{ .vertex = true, .fragment = true };
        entry.* = switch (binding.type) {
            .managed_buffer, .unmanaged_buffer => |inner| mach.gpu.BindGroupLayout.Entry.initBuffer(binding.location, visibility, inner, true, 0),
            .texture_sampler => mach.gpu.BindGroupLayout.Entry.initSampler(binding.location, visibility, .filtering),
            .texture_view => mach.gpu.BindGroupLayout.Entry.initTexture(binding.location, visibility, .float, .dimension_2d, false),
            .builtin => |inside| switch (inside) {
                .transform => mach.gpu.BindGroupLayout.Entry.initBuffer(binding.location, visibility, .uniform, true, 0),
            },
        };
    }

    const bind_group_layout = device.createBindGroupLayout(&mach.gpu.BindGroupLayout.Descriptor{
        .entries = bind_group_entries.ptr,
        .entry_count = bind_group_entries.len,
    });

    const color_targets = [_]mach.gpu.ColorTargetState{.{
        .format = framebuffer_format,
    }};

    const pipeline_layout_descriptor = mach.gpu.PipelineLayout.Descriptor{
        .bind_group_layout_count = 1,
        .bind_group_layouts = &.{
            bind_group_layout,
        },
    };

    const pipeline_layout = device.createPipelineLayout(&pipeline_layout_descriptor);
    defer pipeline_layout.release();

    const vertex_layouts = if (options.vertex_layout) |layout| &[_]mach.gpu.VertexBufferLayout{layout.native} else &[_]mach.gpu.VertexBufferLayout{};

    const pipeline_descriptor = mach.gpu.RenderPipeline.Descriptor{
        .layout = pipeline_layout,
        .vertex = mach.gpu.VertexState{
            .module = vertex_shader,
            .entry_point = options.vertex_entry,
            .buffers = vertex_layouts.ptr,
            .buffer_count = vertex_layouts.len,
        },
        .primitive = mach.gpu.PrimitiveState{
            .front_face = .cw,
            .cull_mode = .back,
            .topology = .triangle_list,
        },
        .depth_stencil = &.{
            .format = .depth32_float,
            .depth_write_enabled = .true,
            .depth_compare = .less,
        },
        .fragment = &mach.gpu.FragmentState{
            .module = fragment_shader,
            .entry_point = options.fragment_entry,
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
    };

    const pipeline = Pipeline{
        .bindings = try mods.mach_core.allocator.dupe(BindingLayout, options.bindings),
        .pipeline_handle = device.createRenderPipeline(&pipeline_descriptor),
        .bind_group_layout = bind_group_layout,
    };

    mods.renderer.pipelines.lock();
    defer mods.renderer.pipelines.unlock();
    return .{ .id = try mods.renderer.pipelines.new(pipeline) };
}
