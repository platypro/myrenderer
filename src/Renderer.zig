const gpu = @import("zgpu");
const glfw = @import("zglfw");
const math = @import("mach").math;
const std = @import("std");

pub const mach_module = .renderer;
pub const mach_systems = .{ .init, .tick };

const Mat = math.Mat4x4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;

const App = @import("App.zig");

current_xform: Mat,
depth_texture_view_handle: gpu.TextureViewHandle,
gctx: *gpu.GraphicsContext,

fn lookAt(camera_: Vec3, target: Vec3, up_ref: Vec3) Mat {
    const camera = camera_.mulScalar(-1);
    const forward = target.sub(&camera).normalize(0.0);
    const up = up_ref.cross(&forward).normalize(0.0);
    const right = forward.cross(&up).normalize(0.0);

    return Mat.init(
        &Vec4.init(right.v[0], right.v[1], right.v[2], -camera.dot(&right)),
        &Vec4.init(up.v[0], up.v[1], up.v[2], -camera.dot(&up)),
        &Vec4.init(forward.v[0], forward.v[1], forward.v[2], -camera.dot(&forward)),
        &Vec4.init(0.0, 0.0, 0.0, 1.0),
    );
}

fn matMult(mats: []const Mat) Mat {
    var result = Mat.ident;
    for (mats) |mat| {
        result = result.mul(&mat);
    }
    return result;
}

pub fn init(self: *@This(), app: *App) !void {
    self.gctx = try gpu.GraphicsContext.create(
        app.allocator,
        .{
            .window = app.window,
            .fn_getTime = @ptrCast(&glfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&glfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&glfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&glfw.getX11Display),
            .fn_getX11Window = @ptrCast(&glfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&glfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&glfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&glfw.getCocoaWindow),
        },
        .{},
    );
    errdefer self.gctx.destroy(app.allocator);

    const depth_texture_handle = self.gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .tdim_2d,
        .size = .{
            .width = self.gctx.swapchain_descriptor.width,
            .height = self.gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    self.depth_texture_view_handle = self.gctx.createTextureView(depth_texture_handle, .{});
}

pub fn tick(self: *@This()) !void {
    const camX = std.math.cos(@as(f32, @floatCast(glfw.getTime()))) * 20.0;
    const camZ = std.math.sin(@as(f32, @floatCast(glfw.getTime()))) * 20.0;
    const model = lookAt(
        Vec3.init(camX, 15.0, camZ),
        Vec3.init(0.0, 0.0, 0.0),
        Vec3.init(0.0, 1.0, 0.0),
    );
    var perspective = Mat.projection2D(.{ .left = -1.0, .right = 1.0, .top = 1.0, .bottom = -1.0, .near = 0.1, .far = 100.0 });
    perspective.v[2].v[3] = 1;
    self.current_xform = matMult(&.{ Mat.rotateZ(-std.math.pi / 2.0), perspective, model });
}
