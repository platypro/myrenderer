const std = @import("std");
const mach = @import("root").mach;
const math = @import("root").math;
const Renderer = @import("root").Renderer;
const mods = @import("root").getModules();

backing_object: ?mach.ObjectID = null,
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

pub const RenderFunction = *const fn (mach.ObjectID, *NodePass) void;

pub const NodePass = struct {
    xform_cache: *Renderer.Surface.XformCache,
    pass: *mach.gpu.RenderPassEncoder,
    should_update: bool = false,
    xform: math.Mat,
};

pub const Handle = struct {
    id: mach.ObjectID,

    pub fn set_xform(node: @This(), xform: math.Mat) void {
        mods.renderer.nodes.set(node.id, .xform, xform);
        mods.renderer.nodes.set(node.id, .updated, false);
    }

    pub fn set_bounding_box(node: @This(), p0: math.Vec3, p1: math.Vec3) void {
        mods.renderer.nodes.set(node.id, .bounding_box_p0, p0);
        mods.renderer.nodes.set(node.id, .bounding_box_p1, p1);
        mods.renderer.nodes.set(node.id, .dirty_bounding_box, true);
        mods.renderer.nodes.set(node.id, .updated, false);
    }

    pub fn add_child(node: @This(), child: anytype) !void {
        const child_p0 = mods.renderer.nodes.get(child.id, .bounding_box_p0);
        const child_p1 = mods.renderer.nodes.get(child.id, .bounding_box_p1);
        const parent_p0 = mods.renderer.nodes.get(node.id, .bounding_box_p0);
        const parent_p1 = mods.renderer.nodes.get(node.id, .bounding_box_p1);

        mods.renderer.nodes.set(node.id, .bounding_box_p0, child_p0.min(&parent_p0));
        mods.renderer.nodes.set(node.id, .bounding_box_p1, child_p1.max(&parent_p1));
        mods.renderer.nodes.set(node.id, .updated, false);

        try mods.renderer.nodes.addChild(node.id, child.id);
    }

    pub fn remove_child(node: @This(), renderer: *Renderer, child: anytype) !void {
        renderer.nodes.removeChild(node.id, child.id);

        var new_bounding_box_p0 = math.Vec3.init(0.0, 0.0, 0.0);
        var new_bounding_box_p1 = math.Vec3.init(0.0, 0.0, 0.0);
        for (renderer.nodes.getChildren(child.id)) |child_index| {
            new_bounding_box_p0 = renderer.nodes.get(child_index, .bounding_box_p0).min(&new_bounding_box_p0);
            new_bounding_box_p1 = renderer.nodes.get(child_index, .bounding_box_p1).max(&new_bounding_box_p1);
        }
        renderer.nodes.set(node, .bounding_box_p0, new_bounding_box_p0);
        renderer.nodes.set(node, .bounding_box_p1, new_bounding_box_p1);
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
        const backing_object = mods.renderer.nodes.get(node.id, .backing_object);
        const old_should_update = pass.should_update;
        if (!mods.renderer.nodes.get(node.id, .updated) or pass.should_update) {
            // print_matrix("Passed xform", pass.xform);
            const new_xform = math.Mat.mul(&pass.xform, &mods.renderer.nodes.get(node.id, .xform));
            try pass.xform_cache.put(mods.mach_core.allocator, node.id, new_xform);

            var bounding_box_p0 = mods.renderer.nodes.get(node.id, .bounding_box_p0);
            if (@reduce(.Min, bounding_box_p0.v) != -math.std.inf(f32))
                bounding_box_p0 = math.Mat.mulVec(&new_xform, &bounding_box_p0);

            var bounding_box_p1 = mods.renderer.nodes.get(node.id, .bounding_box_p1);
            if (@reduce(.Max, bounding_box_p1.v) != math.std.inf(f32))
                bounding_box_p1 = math.Mat.mulVec(&new_xform, &bounding_box_p1);

            // print_matrix("Xform", new_xform);
            // print_vector("Bounding box p0", mods.renderer.nodes.get(node.id, .bounding_box_p0));
            // print_vector("Bounding box p1", mods.renderer.nodes.get(node.id, .bounding_box_p1));

            mods.renderer.nodes.set(node.id, .should_render, (@reduce(.And, bounding_box_p1.v > math.Vec4.splat(0.0).v) or @reduce(.And, bounding_box_p0.v < math.Vec4.splat(1.0).v)));
            pass.should_update = true;
            mods.renderer.nodes.set(node.id, .updated, true);
            // std.debug.print("Updating!\n", .{});
        }

        pass.xform = pass.xform_cache.get(node.id).?;

        if (mods.renderer.nodes.get(node.id, .should_render)) {
            if (backing_object) |obj| {
                mods.renderer.nodes.get(node.id, .onRender)(obj, pass);
            }

            const children = mods.renderer.nodes.getChildren(node.id) catch return;
            for (children.items) |child| {
                const handle = Handle{ .id = child };
                handle.render(pass) catch return;
            }
        }

        pass.should_update = old_should_update;
    }

    pub fn get_backing(node: @This()) mach.ObjectID {
        return mods.renderer.nodes.get(node.id, .backing_object).?;
    }
};

pub fn create(backing_object: ?mach.ObjectID, onRender: ?RenderFunction) !Handle {
    return Handle{ .id = try mods.renderer.nodes.new(.{ .backing_object = backing_object, .onRender = onRender orelse undefined }) };
}
