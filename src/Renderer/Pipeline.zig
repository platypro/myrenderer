const mach = @import("mach");
const Renderer = @import("../Renderer.zig");
const Pipeline = @This();
const VertexLayout = Renderer.VertexLayout;

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
    \\@fragment fn frag_main(input: FragPass) -> @location(0) vec4<f32> {
    \\    return input.color;
    \\}
;

pub const BindingLayout = struct {
    location: u32,
    type: Type,
    management: Management = .managed_often,

    const Type = enum {
        uniform,
        storage,
        read_only_storage,
        texture_view,
        texture_sampler,
    };

    const Management = enum { unmanaged, managed_single, managed_often };
};

pub const Options = struct {
    vertex_source: [*:0]const u8,
    bindings: []const BindingLayout,
    vertex_layout: ?VertexLayout = null,
};

pub fn create(renderer: *Renderer, options: Options) !mach.ObjectID {
    const device: *mach.gpu.Device = renderer.core.windows.get(renderer.current_window, .device);
    const framebuffer_format = renderer.core.windows.get(renderer.current_window, .framebuffer_format);
    const vertex_shader = device.createShaderModuleWGSL(null, options.vertex_source);
    defer vertex_shader.release();

    const fragment_shader = device.createShaderModuleWGSL(null, fragment_source);
    defer fragment_shader.release();

    const bind_group_entries = try renderer.core.allocator.alloc(mach.gpu.BindGroupLayout.Entry, options.bindings.len);
    defer renderer.core.allocator.free(bind_group_entries);

    for (bind_group_entries, options.bindings) |*entry, binding| {
        const visibility = mach.gpu.ShaderStageFlags{ .vertex = true, .fragment = true };
        switch (binding.type) {
            .storage => entry.* = mach.gpu.BindGroupLayout.Entry.initBuffer(binding.location, visibility, .storage, true, 0),
            .read_only_storage => entry.* = mach.gpu.BindGroupLayout.Entry.initBuffer(binding.location, visibility, .read_only_storage, true, 0),
            .uniform => entry.* = mach.gpu.BindGroupLayout.Entry.initBuffer(binding.location, visibility, .uniform, true, 0),
            .texture_view => entry.* = mach.gpu.BindGroupLayout.Entry.initTexture(binding.location, visibility, .uint, .dimension_2d, false),
            .texture_sampler => entry.* = mach.gpu.BindGroupLayout.Entry.initSampler(binding.location, visibility, .filtering),
        }
    }

    const bind_group_layout = device.createBindGroupLayout(&mach.gpu.BindGroupLayout.Descriptor{
        .entries = bind_group_entries.ptr,
        .entry_count = bind_group_entries.len,
    });

    const color_targets = [_]mach.gpu.ColorTargetState{.{
        .format = framebuffer_format,
    }};

    const pipeline_layout_descriptor = mach.gpu.PipelineLayout.Descriptor{
        .bind_group_layout_count = 2,
        .bind_group_layouts = &.{
            bind_group_layout,
            renderer.shared_bind_group_layout,
        },
    };

    const pipeline_layout = device.createPipelineLayout(&pipeline_layout_descriptor);
    defer pipeline_layout.release();

    const vertex_layouts = if (options.vertex_layout) |layout| &[_]mach.gpu.VertexBufferLayout{layout.native} else &[_]mach.gpu.VertexBufferLayout{};

    const pipeline_descriptor = mach.gpu.RenderPipeline.Descriptor{
        .layout = pipeline_layout,
        .vertex = mach.gpu.VertexState{
            .module = vertex_shader,
            .entry_point = "vertex_main",
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
            .entry_point = "frag_main",
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
    };

    const pipeline = Pipeline{
        .bindings = try renderer.core.allocator.dupe(BindingLayout, options.bindings),
        .pipeline_handle = device.createRenderPipeline(&pipeline_descriptor),
        .bind_group_layout = bind_group_layout,
    };

    renderer.pipelines.lock();
    defer renderer.pipelines.unlock();
    return try renderer.pipelines.new(pipeline);
}

pub fn destroy(renderer: *Renderer, pipeline_id: mach.ObjectID) void {
    renderer.pipelines.lock();
    defer renderer.pipelines.unlock();

    renderer.pipelines.get(pipeline_id, .pipeline_handle).release();
    renderer.pipelines.get(pipeline_id, .bind_group_layout).release();
    renderer.core.allocator.free(renderer.pipelines.get(pipeline_id, .bindings));
    renderer.pipelines.delete(pipeline_id);
}
