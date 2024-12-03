@group(0) @binding(0) var<uniform> size: u32;

struct FragPass {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec4<f32>,
}

@vertex fn vertex_main(
    @builtin(vertex_index) VertexIndex : u32
) -> FragPass {
    var vertex_at = VertexIndex % 6;
    var quad_at = (VertexIndex - vertex_at) / 6;
    var quad_at_x = quad_at / size;
    var quad_at_y = quad_at % size;

    var quad_vals = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 1.0),
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 0.0),
        vec2<f32>(1.0, 1.0)
    );

    var quad_colors = array<vec4<f32>, 6>(
        vec4<f32>(1.0, 0.0, 0.0, 1.0),
        vec4<f32>(1.0, 1.0, 0.0, 1.0),
        vec4<f32>(0.0, 0.0, 1.0, 1.0),
        vec4<f32>(1.0, 0.0, 0.0, 1.0),
        vec4<f32>(1.0, 1.0, 0.0, 1.0),
        vec4<f32>(0.0, 0.0, 1.0, 1.0),
    );

    var scaled_offset = 2.0 / f32(size);
    var offset = vec2<f32>(f32(quad_at_x) * scaled_offset - 1.0, f32(quad_at_y) * scaled_offset - 1.0);

    var out: FragPass;
    out.pos = vec4<f32>(quad_vals[vertex_at] * (2.0 / f32(size)) + offset, 0.0, 1.0);
    out.color = quad_colors[vertex_at];

    return out;
}

@fragment fn frag_main(input: FragPass) -> @location(0) vec4<f32> {
    return input.color;
}
