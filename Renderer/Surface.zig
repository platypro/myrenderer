const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const Surface = @This();
const mods = @import("root").getModules();

perspective_matrix: math.Mat = .ident,
dimensions: math.Vec2,
frame_counter: u32 = 0,
target: union(Type) {
    window_scene: struct {
        window_id: mach.ObjectID,
        depth_texture: *mach.gpu.Texture = undefined,
        depth_attachment: ?*mach.gpu.TextureView = null,
        base_node: Renderer.SceneNode.Handle,
        xform_cache: Renderer.SceneNode.XformCache = .empty,
    },
    window_compose: void,
    sub_compose: void,
    vr_scene: void,
},

const Type = enum {
    /// Draw a Scene Node on a Window
    window_scene,
    /// Draw a Compose Node on a Window
    window_compose,
    /// Draw a Compose Node onto a Reusable Surface
    sub_compose,
    /// Draw a Scene Node into VR (Future maybe?)
    vr_scene,
};

pub fn createWindowScene(window: mach.ObjectID, base_node: Renderer.SceneNode.Handle) !Handle {
    const result: Handle = @enumFromInt(try mods.renderer.surfaces.new(Surface{
        .target = .{ .window_scene = .{ .window_id = window, .base_node = base_node } },
        .dimensions = .init(0.0, 0.0),
    }));
    result.rebuild();
    return result;
}

pub const Handle = enum(mach.ObjectID) {
    _,
    pub const get = @import("root").generate_getter(Handle, Surface, &mods.renderer.surfaces);
    pub const set = @import("root").generate_setter(Handle, Surface, &mods.renderer.surfaces);

    pub fn set_perspective(surface: Handle, perspective: math.Mat) void {
        surface.set(.perspective_matrix, perspective);
    }

    fn resetTexture(surface: Handle, texture: **mach.gpu.Texture, view: *?*mach.gpu.TextureView, format: mach.gpu.Texture.Format) void {
        if (view.*) |texture_view| {
            texture_view.release();
            texture.*.release();
        }

        const dimensions = surface.get(.dimensions);

        texture.* = mods.renderer.device.createTexture(&.{
            .usage = .{ .render_attachment = true },
            .dimension = .dimension_2d,
            .size = .{
                .width = @intFromFloat(dimensions.x()),
                .height = @intFromFloat(dimensions.y()),
                .depth_or_array_layers = 1,
            },
            .format = format,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        view.* = texture.*.createView(&.{});
    }

    pub fn rebuild(surface: Handle) void {
        var data = surface.get(.target);
        switch (data) {
            .window_scene => |*window_scene| {
                const window_dimensions = math.Vec2.init(
                    @floatFromInt(mods.mach_core.windows.get(window_scene.window_id, .framebuffer_width)),
                    @floatFromInt(mods.mach_core.windows.get(window_scene.window_id, .framebuffer_height)),
                );
                if (!std.meta.eql(window_dimensions, surface.get(.dimensions))) {
                    surface.set(.dimensions, window_dimensions);
                    surface.resetTexture(&window_scene.depth_texture, &window_scene.depth_attachment, .depth32_float);
                }
            },
            .window_compose => {},
            .sub_compose => {},
            .vr_scene => {},
        }
        surface.set(.target, data);
    }

    pub fn resize(surface: Handle, renderer: *Renderer, new_size: math.Vec2) void {
        if (!std.meta.eql(new_size, renderer.surfaces.get(surface.id, .dimensions))) {
            renderer.surfaces.set(surface.id, .dimensions, new_size);
            rebuild(renderer, surface.id);
        }
    }

    pub fn begin_render(
        encoder: *mach.gpu.CommandEncoder,
        color: *mach.gpu.TextureView,
        depth: *mach.gpu.TextureView,
        clear_value: ?mach.gpu.Color,
    ) !*mach.gpu.RenderPassEncoder {
        const color_attachments: []const mach.gpu.RenderPassColorAttachment = if (clear_value) |clear| &.{.{
            .view = color,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = clear,
        }} else &.{.{
            .view = color,
            .load_op = .load,
            .store_op = .store,
            .clear_value = mach.gpu.Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
        }};

        const depth_attachment = mach.gpu.RenderPassDepthStencilAttachment{
            .view = depth,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .depth_clear_value = 1.0,
        };

        return encoder.beginRenderPass(&.{
            .color_attachments = color_attachments.ptr,
            .color_attachment_count = color_attachments.len,
            .depth_stencil_attachment = &depth_attachment,
        });
    }

    pub fn render(surface: Handle, encoder: *mach.gpu.CommandEncoder, clear_value: ?mach.gpu.Color) !void {
        if (surface.get(.frame_counter) == mods.renderer.frame_counter) {
            return;
        }
        const perspective = surface.get(.perspective_matrix);
        var data = surface.get(.target);
        switch (data) {
            .window_scene => |*window| {
                if (window.depth_attachment) |depth_attachment| {
                    const swap_chain = mods.mach_core.windows.get(window.window_id, .swap_chain);
                    const color_attachment = swap_chain.getCurrentTextureView().?;
                    const render_pass = try begin_render(encoder, color_attachment, depth_attachment, clear_value);
                    var nodePass = Renderer.SceneNode.NodePass{ .pass = render_pass, .xform = perspective, .xform_cache = &window.xform_cache };
                    try window.base_node.render(&nodePass);
                    render_pass.end();
                }
            },
            .window_compose => {},
            .sub_compose => {},
            .vr_scene => {},
        }
        surface.set(.target, data);
    }

    pub fn deinit(surface: Handle, renderer: *Renderer) void {
        switch (renderer.surfaces.get(surface.id, .target)) {
            .window => |window| {
                if (window.depth_attachment) |attachment| {
                    window.depth_texture.release();
                    attachment.release();
                }
            },
            .managed => |managed| {
                if (managed.depth_attachment) |attachment| {
                    managed.depth_texture.release();
                    attachment.release();
                }
                if (managed.color_attachment) |attachment| {
                    managed.color_texture.release();
                    attachment.release();
                }
            },
        }
    }
};
