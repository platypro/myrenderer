const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const mods = @import("root").getModules();
const SceneNode = @This();

backing_instance: ?Renderer.Instance.Handle = null,
scissor: ?math.Vec4 = null,
xform: math.Mat = .ident,
bounding_box_p0: math.Vec4 = math.Vec4.init(
    -math.std.inf(f32),
    -math.std.inf(f32),
    -math.std.inf(f32),
    1.0,
),
bounding_box_p1: math.Vec4 = math.Vec4.init(
    math.std.inf(f32),
    math.std.inf(f32),
    math.std.inf(f32),
    1.0,
),
should_render: bool = false,
updated: bool = false,
onRender: RenderFunction,

pub const RenderFunction = *const fn (Renderer.Instance.Handle, *NodePass) void;
pub const XformCache = std.AutoArrayHashMapUnmanaged(mach.ObjectID, math.Mat);

pub const NodePass = struct {
    xform_cache: *XformCache,
    pass: *mach.gpu.RenderPassEncoder,
    should_update: bool = false,
    xform: math.Mat,
};

pub const Handle = enum(mach.ObjectID) {
    _,
    pub const get = @import("root").generate_getter(Handle, SceneNode, &mods.renderer.scene_nodes);
    pub const set = @import("root").generate_setter(Handle, SceneNode, &mods.renderer.scene_nodes);

    pub fn set_xform(node: @This(), xform: math.Mat) void {
        node.set(.xform, xform);
        node.set(.updated, false);
    }

    pub fn set_bounding_box(node: @This(), p0: math.Vec3, p1: math.Vec3) void {
        node.set(.bounding_box_p0, p0);
        node.set(.bounding_box_p1, p1);
        node.set(.dirty_bounding_box, true);
        node.set(.updated, false);
    }

    pub fn add_child(node: @This(), child: anytype) !void {
        const child_p0 = child.get(.bounding_box_p0);
        const child_p1 = child.get(.bounding_box_p1);
        const parent_p0 = node.get(.bounding_box_p0);
        const parent_p1 = node.get(.bounding_box_p1);

        node.set(.bounding_box_p0, child_p0.min(&parent_p0));
        node.set(.bounding_box_p1, child_p1.max(&parent_p1));
        node.set(.updated, false);

        try mods.renderer.scene_nodes.addChild(@intFromEnum(node), @intFromEnum(child));
    }

    pub fn remove_child(node: @This(), renderer: *Renderer, child: anytype) !void {
        renderer.scene_nodes.removeChild(node.id, child.id);

        var new_bounding_box_p0 = math.Vec3.init(0.0, 0.0, 0.0);
        var new_bounding_box_p1 = math.Vec3.init(0.0, 0.0, 0.0);
        for (renderer.scene_nodes.getChildren(child.id)) |child_index| {
            new_bounding_box_p0 = renderer.scene_nodes.get(child_index, .bounding_box_p0).min(&new_bounding_box_p0);
            new_bounding_box_p1 = renderer.scene_nodes.get(child_index, .bounding_box_p1).max(&new_bounding_box_p1);
        }
        renderer.scene_nodes.set(node, .bounding_box_p0, new_bounding_box_p0);
        renderer.scene_nodes.set(node, .bounding_box_p1, new_bounding_box_p1);
    }

    fn print_vector(text: []const u8, vec: math.Vec4) void {
        std.debug.print("{s}: ({d:4.2},{d:4.2},{d:4.2},{d:4.2})\n", .{ text, vec.v[0], vec.v[1], vec.v[2], vec.v[3] });
    }

    fn print_matrix(text: []const u8, mat: math.Mat) void {
        std.debug.print("{s}:\n", .{text});
        for (mat.v) |vec| {
            print_vector("    ", vec);
        }
    }

    pub fn render(node: @This(), pass: *NodePass) !void {
        const backing_instance = node.get(.backing_instance);
        const old_should_update = pass.should_update;
        if (!node.get(.updated) or pass.should_update) {
            // print_matrix("Passed xform", pass.xform);
            const new_xform = math.Mat.mul(&pass.xform, &node.get(.xform));
            try pass.xform_cache.put(mods.mach_core.allocator, @intFromEnum(node), new_xform);

            var bounding_box_p0 = node.get(.bounding_box_p0);
            if (@reduce(.Min, bounding_box_p0.v) != -math.std.inf(f32))
                bounding_box_p0 = math.Mat.mulVec(&new_xform, &bounding_box_p0);

            var bounding_box_p1 = node.get(.bounding_box_p1);
            if (@reduce(.Max, bounding_box_p1.v) != math.std.inf(f32))
                bounding_box_p1 = math.Mat.mulVec(&new_xform, &bounding_box_p1);

            // print_matrix("Xform", new_xform);
            // print_vector("Bounding box p0", node.get(.bounding_box_p0));
            // print_vector("Bounding box p1", node.get(.bounding_box_p1));

            node.set(.should_render, (@reduce(.And, bounding_box_p1.v > math.Vec4.splat(0.0).v) or @reduce(.And, bounding_box_p0.v < math.Vec4.splat(1.0).v)));
            pass.should_update = true;
            node.set(.updated, true);
            // std.debug.print("Updating!\n", .{});
        }

        pass.xform = pass.xform_cache.get(@intFromEnum(node)).?;

        if (node.get(.should_render)) {
            if (backing_instance) |obj| {
                node.get(.onRender)(obj, pass);
            }

            const children = mods.renderer.scene_nodes.getChildren(@intFromEnum(node)) catch return;
            for (children.items) |child| {
                const handle: Handle = @enumFromInt(child);
                handle.render(pass) catch return;
            }
        }

        pass.should_update = old_should_update;
    }

    pub fn get_backing(node: @This()) Renderer.Instance.Handle {
        return node.get(.backing_instance).?;
    }
};

pub fn create(backing_instance: ?Renderer.Instance.Handle, onRender: ?RenderFunction) !Handle {
    return @enumFromInt(try mods.renderer.scene_nodes.new(.{ .backing_instance = backing_instance, .onRender = onRender orelse undefined }));
}
