const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const mods = @import("root").getModules();
const Draw = @This();

clear_color: ?mach.gpu.Color = null,
encoder: *mach.gpu.CommandEncoder = undefined,

pub const Handle = enum(mach.ObjectID) {
    _,
    pub const get = @import("root").generate_getter(Handle, Draw, &mods.renderer.draws);
    pub const set = @import("root").generate_setter(Handle, Draw, &mods.renderer.draws);

    pub fn begin(draw: Handle) void {
        draw.set(.encoder, mods.renderer.device.createCommandEncoder(null));
    }

    pub fn clear(draw: Handle, color: mach.gpu.Color) void {
        draw.set(.clear_color, color);
    }

    pub fn draw_surface(draw: Handle, surface: Renderer.Surface.Handle) !void {
        const encoder = draw.get(.encoder);
        try surface.render(encoder, draw.get(.clear_color));
        draw.set(.clear_color, null);
    }

    pub fn end(draw: Handle) void {
        const commands = draw.get(.encoder).finish(null);
        defer commands.release();
        mods.renderer.queue.submit(&.{commands});
        draw.get(.encoder).release();
    }
};

pub fn create() !Handle {
    return @enumFromInt(try mods.renderer.draws.new(.{}));
}
