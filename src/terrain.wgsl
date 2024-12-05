@group(0) @binding(0) var<uniform> data: UniformStruct;
@group(0) @binding(1) var<storage,read> heightmap: array<f32>;

struct UniformStruct {
    size: u32,
    xform: mat4x4<f32>,
}

struct FragPass {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec4<f32>,
}

@vertex fn vertex_main(
    @builtin(vertex_index) VertexIndex : u32
) -> FragPass {
    var vertex_at = VertexIndex % 6;
    var quad_at = (VertexIndex - vertex_at) / 6;
    var quad_at_coords = vec2<f32>(f32(quad_at / data.size), f32(quad_at % data.size));

    const quad_vals = array<vec2<f32>, 6>(
        vec2<f32>(1.0, 0.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 1.0),
        vec2<f32>(0.0, 0.0)
    );
    var quadValue = 0.2 * (quad_vals[vertex_at] + quad_at_coords) - 0.1 * f32(data.size);

    var quad_lookup = array<u32, 6>(
        quad_at + data.size,
        quad_at + data.size + 1,
        quad_at,
        quad_at + data.size + 1,
        quad_at + 1,
        quad_at,
    );
    var mapValue = heightmap[quad_lookup[vertex_at]];

    var out: FragPass;
    out.pos = data.xform * vec4<f32>(quadValue.x, mapValue * 5.0, quadValue.y, 1.0);
    out.color = vec4(mapValue, mapValue, mapValue, 1.0);

    return out;
}

@fragment fn frag_main(input: FragPass) -> @location(0) vec4<f32> {
    return input.color;
}
