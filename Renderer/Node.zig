const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;

backing_object: ?mach.ObjectID = null,
scissor: ?math.Vec4 = null,
xform: math.Mat = .ident,
bounding_box_p0: math.Vec3 = math.Vec3.init(
    -math.std.inf(f32),
    -math.std.inf(f32),
    -math.std.inf(f32),
),
bounding_box_p1: math.Vec3 = math.Vec3.init(
    math.std.inf(f32),
    math.std.inf(f32),
    math.std.inf(f32),
),

pub const Handle = struct {
    id: mach.ObjectID,

    pub fn set_xform(node: Handle, renderer: *Renderer, xform: math.Mat) void {
        renderer.nodes.set(node, .xform, xform);
    }

    pub fn render(node: Handle, renderer: *Renderer, pass: *mach.gpu.RenderPassEncoder, base_xform: math.Mat) !void {
        const xform = math.Mat.mul(&base_xform, &renderer.nodes.get(node.id, .xform));
        for ((try renderer.nodes.getChildren(node.id)).items) |item| {
            try render(.{ .id = item }, renderer, pass, xform);
        }

        if (renderer.nodes.get(node.id, .backing_object)) |backing_object| {
            if (renderer.instances.is(backing_object)) {
                const instance = Renderer.Instance.Handle{ .id = backing_object };
                const pipeline = instance.get_pipeline(renderer);
                if (pipeline.get_builtin_location(renderer, .transform)) |transform_location| {
                    instance.update_buffer(renderer, transform_location, 0, math.Mat, &.{xform});
                }

                pass.setPipeline(renderer.pipelines.get(pipeline.id, .pipeline_handle));
                const draw_index: Renderer.VertexBuffer = renderer.instances.get(backing_object, .vertex_buffer);
                if (draw_index.vertex_buffer) |vertex_buffer| {
                    pass.setVertexBuffer(0, vertex_buffer, 0, vertex_buffer.getSize());
                }
                pass.setBindGroup(
                    0,
                    renderer.instances.get(instance.id, .bind_group).?,
                    renderer.instances.get(instance.id, .dynamic_offsets),
                );
                pass.draw(draw_index.vertex_count, draw_index.instance_count, draw_index.first_vertex, draw_index.first_instance);
            }
        }
    }

    pub fn getInstance(node: Handle, renderer: *Renderer) Renderer.Instance.Handle {
        const backing_object_opt = renderer.nodes.get(node.id, .backing_object);

        if (backing_object_opt) |backing_object|
            if (renderer.instances.is(backing_object))
                return .{ .id = backing_object };

        @panic("Node does not have an instance!");
    }
};

pub fn create(renderer: *Renderer, base: @This()) !Handle {
    return .{ .id = try renderer.nodes.new(base) };
}
