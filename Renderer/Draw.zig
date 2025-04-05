const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const mods = @import("root").getModules();

clear_color: ?mach.gpu.Color = null,
encoder: *mach.gpu.CommandEncoder = undefined,

pub const Handle = struct {
    id: mach.ObjectID,

    pub fn begin(draw: Handle) void {
        mods.renderer.draws.set(draw.id, .encoder, mods.renderer.device.createCommandEncoder(null));
    }

    pub fn clear(draw: Handle, color: mach.gpu.Color) void {
        mods.renderer.draws.set(draw.id, .clear_color, color);
    }

    pub fn draw_surface(draw: Handle, surface: Renderer.Surface.Handle) !void {
        const encoder = mods.renderer.draws.get(draw.id, .encoder);
        try surface.render(encoder, mods.renderer.draws.get(draw.id, .clear_color));
        mods.renderer.draws.set(draw.id, .clear_color, null);
    }

    pub fn end(draw: Handle) void {
        const commands = mods.renderer.draws.get(draw.id, .encoder).finish(null);
        defer commands.release();
        mods.renderer.queue.submit(&.{commands});
        mods.renderer.draws.get(draw.id, .encoder).release();
    }
};

pub fn create() !Handle {
    return Handle{ .id = try mods.renderer.draws.new(.{}) };
}
