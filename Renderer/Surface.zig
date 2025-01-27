const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const Surface = @This();

root_node: Renderer.Node.Handle,
perspective_matrix: math.Mat = .ident,
dimensions: math.Vec2,
frame_counter: u32 = 0,
data: union(Type) {
    window: struct {
        window_id: mach.ObjectID,
        depth_texture: *mach.gpu.Texture = undefined,
        depth_attachment: ?*mach.gpu.TextureView = null,
    },
    managed: struct {
        format: mach.gpu.Texture.Format = .undefined,
        color_texture: *mach.gpu.Texture = undefined,
        color_attachment: ?*mach.gpu.TextureView = null,
        depth_texture: *mach.gpu.Texture = undefined,
        depth_attachment: ?*mach.gpu.TextureView = null,
    },
},

const Type = enum {
    /// Use the color target from the window's swapchain, and rebuild the depth buffer when necessary
    window,
    /// This surface manages both the color buffer and the depth buffer
    managed,
};

pub fn createFromWindow(renderer: *Renderer, root_node: Renderer.Node.Handle, window: mach.ObjectID) !Handle {
    const result = Handle{ .id = try renderer.surfaces.new(Surface{
        .data = .{ .window = .{ .window_id = window } },
        .root_node = root_node,
        .dimensions = .init(0.0, 0.0),
    }) };
    result.rebuild(renderer);
    return result;
}

pub fn createManaged(renderer: *Renderer, root_node: Renderer.Node.Handle, size: math.Vec2, format: mach.gpu.Texture.Format) !Handle {
    const result = Handle{ .id = renderer.surfaces.new(Surface{
        .root_node = root_node,
        .dimensions = size,
        .data = .{ .managed = .{ .format = format } },
    }) };
    result.rebuild(renderer);
    return result;
}

pub const Handle = struct {
    id: mach.ObjectID,

    pub fn set_perspective(surface: Handle, renderer: *Renderer, perspective: math.Mat) void {
        renderer.surfaces.set(surface.id, .perspective_matrix, perspective);
    }

    fn resetTexture(surface: Handle, renderer: *Renderer, texture: **mach.gpu.Texture, view: *?*mach.gpu.TextureView, format: mach.gpu.Texture.Format) void {
        if (view.*) |texture_view| {
            texture_view.release();
            texture.*.release();
        }

        const dimensions = renderer.surfaces.get(surface.id, .dimensions);

        texture.* = renderer.device.createTexture(&.{
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

    pub fn rebuild(surface: Handle, renderer: *Renderer) void {
        var data = renderer.surfaces.get(surface.id, .data);
        switch (data) {
            .window => |*window| {
                const window_dimensions = math.Vec2.init(
                    @floatFromInt(renderer.core.windows.get(window.window_id, .framebuffer_width)),
                    @floatFromInt(renderer.core.windows.get(window.window_id, .framebuffer_height)),
                );
                if (!std.meta.eql(window_dimensions, renderer.surfaces.get(surface.id, .dimensions))) {
                    renderer.surfaces.set(surface.id, .dimensions, window_dimensions);
                    surface.resetTexture(renderer, &window.depth_texture, &window.depth_attachment, .depth32_float);
                }
            },
            .managed => |*managed| {
                surface.resetTexture(renderer, &managed.color_texture, &managed.color_attachment, managed.format);
                surface.resetTexture(renderer, &managed.depth_texture, &managed.depth_attachment, .depth32_float);
            },
        }
        renderer.surfaces.set(surface.id, .data, data);
    }

    pub fn resize(surface: Handle, renderer: *Renderer, new_size: math.Vec2) void {
        if (!std.meta.eql(new_size, renderer.surfaces.get(surface.id, .dimensions))) {
            renderer.surfaces.set(surface.id, .dimensions, new_size);
            rebuild(renderer, surface.id);
        }
    }

    pub fn run_render_pass(
        surface: Handle,
        renderer: *Renderer,
        encoder: *mach.gpu.CommandEncoder,
        color: *mach.gpu.TextureView,
        depth: *mach.gpu.TextureView,
        clear_value: ?mach.gpu.Color,
        perspective: math.Mat,
    ) !void {
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

        const render_pass = encoder.beginRenderPass(&.{
            .color_attachments = color_attachments.ptr,
            .color_attachment_count = color_attachments.len,
            .depth_stencil_attachment = &depth_attachment,
        });

        const node = renderer.surfaces.get(surface.id, .root_node);
        try node.render(renderer, render_pass, perspective);

        render_pass.end();
    }

    pub fn render(surface: Handle, renderer: *Renderer, encoder: *mach.gpu.CommandEncoder, clear_value: ?mach.gpu.Color) !void {
        if (renderer.surfaces.get(surface.id, .frame_counter) == renderer.frame_counter) {
            return;
        }
        const perspective = renderer.surfaces.get(surface.id, .perspective_matrix);
        switch (renderer.surfaces.get(surface.id, .data)) {
            .window => |window| {
                if (window.depth_attachment) |depth_attachment| {
                    const swap_chain = renderer.core.windows.get(window.window_id, .swap_chain);
                    const color_attachment = swap_chain.getCurrentTextureView().?;
                    try surface.run_render_pass(renderer, encoder, color_attachment, depth_attachment, clear_value, perspective);
                }
            },
            .managed => |managed| {
                if (managed.depth_attachment) |depth_attachment| {
                    if (managed.color_attachment) |color_attachment| {
                        try surface.run_render_pass(renderer, encoder, color_attachment, depth_attachment, clear_value, perspective);
                    }
                }
            },
        }
    }

    pub fn deinit(surface: Handle, renderer: *Renderer) void {
        switch (renderer.surfaces.get(surface.id, .data)) {
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
