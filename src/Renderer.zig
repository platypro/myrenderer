const gpu = @import("zgpu");
const glfw = @import("zglfw");
const mach = @import("mach");
const std = @import("std");
const math = @import("math.zig");

pub const mach_module = .renderer;
pub const mach_systems = .{ .init, .render_begin, .render_end };

const App = @import("App.zig");

const shadow_map_segments = 3;
const shadow_map_resolutions = .{ 512, 256, 128 };

camera_location: math.Vec3,
current_xform: math.Mat,
encoder: gpu.wgpu.CommandEncoder,
back_buffer_view: gpu.wgpu.TextureView,
depth_texture_view: gpu.wgpu.TextureView,
gctx: *gpu.GraphicsContext,
shadow_map: gpu.BufferHandle,

light_sources: mach.Objects(.{}, struct {
    position: math.Vec3,
    shadow_maps: [shadow_map_segments]gpu.BufferHandle,
}),

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
    const depth_texture_view_handle = self.gctx.createTextureView(depth_texture_handle, .{});
    self.depth_texture_view = self.gctx.lookupResource(depth_texture_view_handle).?;

    self.light_sources.lock();
    defer self.light_sources.unlock();
    //    _ = try self.light_sources.new(.{ .position = math.Vec3.init(1.0, 8.0, 1.0) });
}

pub fn render_begin(self: *@This()) !void {
    const camX = math.std.cos(@as(f32, @floatCast(glfw.getTime()))) * 20.0;
    const camZ = math.std.sin(@as(f32, @floatCast(glfw.getTime()))) * 20.0;

    self.camera_location = math.Vec3.init(camX, 15.0, camZ);

    const view = math.lookAt(
        self.camera_location,
        math.Vec3.init(0.0, 0.0, 0.0),
        math.Vec3.init(0.0, 1.0, 0.0),
    );
    var perspective = math.Mat.projection2D(.{ .left = -1.0, .right = 1.0, .top = 1.0, .bottom = -1.0, .near = 0.1, .far = 100.0 });
    perspective.v[2].v[3] = 1;
    self.current_xform = math.matMult(&.{ math.Mat.rotateZ(-math.std.pi / 2.0), perspective, view });

    self.back_buffer_view = self.gctx.swapchain.getCurrentTextureView();
    self.encoder = self.gctx.device.createCommandEncoder(null);
}

pub fn render_end(self: *@This()) !void {
    const commands = self.encoder.finish(null);
    defer commands.release();
    self.gctx.submit(&.{commands});

    self.encoder.release();
    self.back_buffer_view.release();
}

const PassOptions = struct {
    stencil: bool = true,
    color: bool = true,
};

pub fn begin_pass(
    self: *@This(),
    options: PassOptions,
) gpu.wgpu.RenderPassEncoder {
    const color_attachments: []const gpu.wgpu.RenderPassColorAttachment = if (options.color) &.{.{
        .view = self.back_buffer_view,
        .load_op = .clear,
        .store_op = .store,
    }} else &.{};

    const depth_attachment = gpu.wgpu.RenderPassDepthStencilAttachment{
        .view = self.depth_texture_view,
        .depth_load_op = .clear,
        .depth_store_op = .store,
        .depth_clear_value = 0.0,
    };

    return self.encoder.beginRenderPass(.{
        .color_attachments = color_attachments.ptr,
        .color_attachment_count = color_attachments.len,
        .depth_stencil_attachment = if (options.stencil) &depth_attachment else null,
    });
}
