const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;

clear_color: ?mach.gpu.Color = null,
encoder: *mach.gpu.CommandEncoder = undefined,

pub const Handle = struct {
    id: mach.ObjectID,

    pub fn begin(draw: Handle, renderer: *Renderer) void {
        renderer.draws.set(draw.id, .encoder, renderer.device.createCommandEncoder(null));
    }

    pub fn clear(draw: Handle, renderer: *Renderer, color: mach.gpu.Color) void {
        renderer.draws.set(draw.id, .clear_color, color);
    }

    pub fn draw_surface(draw: Handle, renderer: *Renderer, surface: Renderer.Surface.Handle) !void {
        const encoder = renderer.draws.get(draw.id, .encoder);
        try surface.render(renderer, encoder, renderer.draws.get(draw.id, .clear_color));
        renderer.draws.set(draw.id, .clear_color, null);
    }

    pub fn end(draw: Handle, renderer: *Renderer) void {
        const commands = renderer.draws.get(draw.id, .encoder).finish(null);
        defer commands.release();
        renderer.queue.submit(&.{commands});
        renderer.draws.get(draw.id, .encoder).release();
    }
};

pub fn create(renderer: *Renderer) !Handle {
    return Handle{ .id = try renderer.draws.new(.{}) };
}
