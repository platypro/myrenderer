pub const mach = @import("mach").math;
pub const std = @import("std").math;

pub const Mat = mach.Mat4x4;
pub const Vec2 = mach.Vec2;
pub const Vec3 = mach.Vec3;
pub const Vec4 = mach.Vec4;

pub fn lookAt(camera: Vec3, target: Vec3, up_ref: Vec3) Mat {
    const forward = target.sub(&camera).normalize(0.0);
    const right = up_ref.cross(&forward).normalize(0.0);
    const up = forward.cross(&right).normalize(0.0);

    return Mat.init(
        &Vec4.init(right.v[0], right.v[1], right.v[2], -right.dot(&camera)),
        &Vec4.init(up.v[0], up.v[1], up.v[2], -up.dot(&camera)),
        &Vec4.init(forward.v[0], forward.v[1], forward.v[2], -forward.dot(&camera)),
        &Vec4.init(0.0, 0.0, 0.0, 1.0),
    );
}

pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat {
    const halftan = std.tan(fovy / 2.0);

    return Mat.init(
        &Vec4.init(1.0 / (aspect * halftan), 0.0, 0.0, 0.0),
        &Vec4.init(0.0, 1.0 / halftan, 0.0, 0.0),
        &Vec4.init(0.0, 0.0, far / (far - near), -far * near / (far - near)),
        &Vec4.init(0.0, 0.0, 1.0, 0.0),
    );
}

pub fn matMult(mats: []const Mat) Mat {
    var result = Mat.ident;
    for (mats) |mat| {
        result = result.mul(&mat);
    }
    return result;
}
