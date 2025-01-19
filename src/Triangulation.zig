const std = @import("std");
const math = @import("math.zig");
const unirand = @import("unirand.zig");

root_node: u32,
allocator: std.mem.Allocator,
nodes: std.ArrayListUnmanaged(TreeNode) = .empty,

/// Our points, as given to create_polygon
points: []const math.Vec2,

/// Segment Scratchpad
node_stack: std.ArrayListUnmanaged(NodeID),

const Triangulation = @This();

const PointID = u32;
const NodeID = u32;

/// A single node in the tree of points/segments/trapezoids
/// child1/child2/point1/point2 have different meaning depending on type
///        |    point    |   segment     |   trapezoid
///       -+-===========-+-=============-+-=============
/// crumb  | breadcrumb  | Outside Child | Undefined
/// child1 | Upper Child | Left Child    | Left Segment
/// child2 | Lower Child | Right Child   | Right Segment
/// point1 | Point ID    | Upper Point   | Upper Point
/// point2 | Undefined   | Lower Point   | Lower Point
const TreeNode = struct {
    type: Type = undefined,
    // If a point, this is used as scratch area for tree backtracking.
    // If a segment, this determines which child is "outside"
    crumb: ?NodeID = null,

    child1: ?NodeID = null,
    child2: ?NodeID = null,
    point1: ?PointID = null,
    point2: ?PointID = null,

    const Type = enum(u2) { point, segment, trapezoid };
};

const PointMap = struct {
    backend: MountainList,
    allocator: std.mem.Allocator,

    const Mountain = struct { p1: PointID, p2: PointID, list: List = .empty };
    const MountainList = std.ArrayListUnmanaged(Mountain);
    const List = std.ArrayListUnmanaged(PointID);

    fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .backend = .empty,
            .allocator = allocator,
        };
    }

    fn add_point(self: *@This(), tree: *Triangulation, key: NodeID, p1: PointID, p2: PointID) !void {
        var found_item: ?*Mountain = null;
        for (self.backend.items) |*item| {
            if (item.p1 == tree.get(key, .point1) and item.p2 == tree.get(key, .point2)) {
                found_item = item;
            }
        }
        if (found_item == null) {
            found_item = try self.backend.addOne(self.allocator);
            found_item.?.* = .{ .list = .empty, .p1 = tree.get(key, .point1).?, .p2 = tree.get(key, .point2).? };
        }
        try found_item.?.list.append(self.allocator, p1);
        try found_item.?.list.append(self.allocator, p2);
    }
};

pub fn get(self: *Triangulation, id: NodeID, comptime property: std.meta.FieldEnum(TreeNode)) std.meta.fieldInfo(TreeNode, property).type {
    return @field(self.nodes.items[id], @tagName(property));
}

pub fn set(self: *Triangulation, id: NodeID, comptime property: std.meta.FieldEnum(TreeNode), value: std.meta.fieldInfo(TreeNode, property).type) void {
    @field(self.nodes.items[id], @tagName(property)) = value;
}

fn print_segment(self: *Triangulation, node_opt: ?NodeID) void {
    if (node_opt) |node| {
        std.debug.print("Segment #{d} Between ({?}, {?})", .{ node, self.get(node, .point1), self.get(node, .point2) });
    } else std.debug.print("Null Segment", .{});
}

pub fn print_node(self: *Triangulation, node: NodeID, tag: []const u8) void {
    std.debug.print("{s} ", .{tag});

    switch (self.get(node, .type)) {
        .point => {
            std.debug.print("Point #{d} ({?})\n", .{ node, self.get(node, .point1) });
        },
        .segment => {
            print_segment(self, node);
            std.debug.print("\n", .{});
        },
        .trapezoid => {
            std.debug.print("Trapezoid #{d} between points {?} and {?} bound by ", .{
                node, self.get(node, .point1), self.get(node, .point2),
            });
            print_segment(self, self.get(node, .child1));
            std.debug.print(" and ", .{});
            print_segment(self, self.get(node, .child2));
            std.debug.print("\n", .{});
        },
    }
}

pub fn add_node(self: *Triangulation, typ: TreeNode.Type) !NodeID {
    const node_id: u32 = @intCast(self.nodes.items.len);
    const new_node = try self.nodes.addOne(self.allocator);
    new_node.* = .{ .type = typ };
    return node_id;
}

pub fn clone_node(self: *@This(), node: NodeID) !NodeID {
    const node_id: u32 = @intCast(self.nodes.items.len);
    const new_node = try self.nodes.addOne(self.allocator);
    new_node.* = self.nodes.items[node];

    return node_id;
}

fn is_left_of(tree: *Triangulation, point_id: PointID, segment_point_1_id: PointID, segment_point_2_id: PointID) bool {
    const point = tree.points[point_id];
    const a = tree.points[segment_point_1_id];
    const b = tree.points[segment_point_2_id];

    const mul1: f32 = (b.x() - a.x()) * (point.y() - a.y());
    const mul2: f32 = (b.y() - a.y()) * (point.x() - a.x());
    const d: f32 = mul1 - mul2;
    return (d > 0);
}

fn point_is_above(tree: *Triangulation, lhs: PointID, rhs: PointID) bool {
    const lhs_yval = tree.points[lhs].v[1];
    const rhs_yval = tree.points[rhs].v[1];
    return if (lhs_yval < rhs_yval) // LHS is above RHS
        true
    else if (lhs_yval == rhs_yval) {
        return tree.points[lhs].v[0] < tree.points[rhs].v[0];
    } else false;
}

// A point is located in one trapezoid. Find that trapezoid and split it vertically.
fn add_point(tree: *Triangulation, point_id: u32) !void {
    var base_node = tree.root_node;

    std.debug.print("Adding Point {}...\n", .{point_id});
    // Find the trapezoid which this point will break up vertically
    loop: while (true) {
        var next_node: NodeID = undefined;
        switch (tree.get(base_node, .type)) {
            .trapezoid => break :loop,
            .point => {
                if (tree.get(base_node, .point1) == point_id) {
                    // Point added already, return
                    return;
                }
                if (point_is_above(tree, point_id, tree.get(base_node, .point1).?)) {
                    next_node = tree.get(base_node, .child1).?;
                } else {
                    next_node = tree.get(base_node, .child2).?;
                }
            },
            .segment => {
                next_node = if (is_left_of(tree, point_id, tree.get(base_node, .point1).?, tree.get(base_node, .point2).?))
                    tree.get(base_node, .child1).?
                else
                    tree.get(base_node, .child2).?;
            },
        }
        base_node = next_node;
    }

    // 1) Create a new upper and lower trapezoid, copying all fields from the found
    //    trapezoid into both the new ones.
    // 2) Transform the found trapezoid into a point (Since many nodes may point to this
    //    trapezoid we want to keep the relations sound. If we created a new point node
    //    we would have to find all the parents and update them)
    // 3) Set upper point on the lower trapezoid and lower point on the upper trapezoid
    //    to point towards the point node

    // (1)
    const lower_trapezoid_node = try tree.clone_node(base_node);
    const upper_trapezoid_node = try tree.clone_node(base_node);

    tree.print_node(base_node, " - Split");
    // (2)
    tree.set(base_node, .type, .point);
    tree.set(base_node, .point1, point_id);
    tree.set(base_node, .point2, null);
    tree.set(base_node, .crumb, null);
    tree.set(base_node, .child1, upper_trapezoid_node);
    tree.set(base_node, .child2, lower_trapezoid_node);

    // (3)
    tree.set(upper_trapezoid_node, .point2, point_id);
    tree.set(lower_trapezoid_node, .point1, point_id);

    tree.print_node(upper_trapezoid_node, " -- Into Upper");
    tree.print_node(lower_trapezoid_node, " -- And Lower");
}

// Adding a segment is more involved than adding a point.
// A segment may split through multiple trapezoids. For each split trapezoid a new edge node
// is created and the two trapezoids are set as it's children
//
// The problem that arises is that for every one you split, you may be left with either one or both
// resulting trapezoids underdefined (With one or Zero points defined). We need to merge these.
//
// This is solved by running two passes. First just find all the trapezoids that are split and note them
// down.
//
// In the second pass we keep track of a 'right' trapezoid and a 'left' trapezoid. We go through the trapezoid
// list sorted by the lower .point2 field. Every time the lower point is on the right, we set the bottom point
// of our right trapezoid to be that point and create a new 'right' trapezoid with point1 set to be the same one.
// Similar is done whenever the lower point sits on the left.
//
// At the end we add our tracked right and left trapezoids, using the lower point of the added segment in the
// same way we used the lower points of the trapezoids.
fn add_segment(tree: *Triangulation, point1: PointID, point2: PointID) !void {
    var upper_segment_point: PointID = undefined;
    var lower_segment_point: PointID = undefined;
    if (point_is_above(tree, point1, point2)) {
        upper_segment_point = point1;
        lower_segment_point = point2;
    } else {
        upper_segment_point = point2;
        lower_segment_point = point1;
    }

    std.debug.print("Adding Segment Between ({},{})...\n", .{ upper_segment_point, lower_segment_point });
    var base_node = tree.root_node;
    var breadcrumb: ?NodeID = null;

    tree.node_stack.items.len = 0;
    loop1: while (true) {
        loop: while (true) {
            switch (tree.get(base_node, .type)) {
                .point => {
                    const point_compare = tree.get(base_node, .point1).?;
                    if (upper_segment_point == point_compare) {
                        // If is the upper point of this segment, look below
                        base_node = tree.get(base_node, .child2).?;
                    } else if (lower_segment_point == point_compare) {
                        // If it is the lower point of this segment, look above
                        base_node = tree.get(base_node, .child1).?;
                    } else {
                        const bottom_point_is_above = point_is_above(tree, lower_segment_point, point_compare);
                        const top_point_is_below = point_is_above(tree, point_compare, upper_segment_point);

                        if (top_point_is_below) {
                            // Line is wholly below the point
                            base_node = tree.get(base_node, .child2).?;
                        } else if (bottom_point_is_above) {
                            // Line is wholly above the point
                            base_node = tree.get(base_node, .child1).?;
                        } else {
                            // Line surrounds point vertically. Push breadcrumb and go to child 1
                            tree.set(base_node, .crumb, breadcrumb);
                            breadcrumb = base_node;
                            base_node = tree.get(base_node, .child1).?;
                        }
                    }
                },
                .segment => {
                    const other_p1 = tree.get(base_node, .point1).?;
                    const other_p2 = tree.get(base_node, .point2).?;

                    // Figure out which point to check
                    var is_left: bool = undefined;
                    if (upper_segment_point == other_p2 or upper_segment_point == other_p1) {
                        // Point 1 on the added segment matches a point on the other segment,
                        // Check which side the lower point is on to determine line side
                        is_left = is_left_of(tree, lower_segment_point, other_p1, other_p2);
                    } else if (lower_segment_point == other_p1 or lower_segment_point == other_p2) {
                        // Point 2 on the added segment matches a point on the other segment,
                        // Check which side the upper point is on to determine line side
                        is_left = is_left_of(tree, upper_segment_point, other_p1, other_p2);
                    } else {
                        const top_is_above = point_is_above(tree, upper_segment_point, other_p1);
                        const bottom_is_below = point_is_above(tree, lower_segment_point, other_p2);
                        if (top_is_above and bottom_is_below) {
                            // This segment contains the other one vertically. Use either point from
                            // the other line to determine side. Inverting it because we instead
                            // want to know if its on the right side.
                            is_left = !is_left_of(tree, other_p1, upper_segment_point, lower_segment_point);
                        } else if (top_is_above and !bottom_is_below) {
                            // Our bottom point is adjacent to the line, so use it to determine side
                            is_left = is_left_of(tree, lower_segment_point, other_p1, other_p2);
                        } else {
                            // Our top point is adjacent to the line, so use it to determine side
                            is_left = is_left_of(tree, upper_segment_point, other_p1, other_p2);
                        }
                    }

                    if (is_left) {
                        base_node = tree.get(base_node, .child1).?;
                    } else {
                        base_node = tree.get(base_node, .child2).?;
                    }
                },
                .trapezoid => break :loop,
            }
        }

        // We've found a trapezoid. Add it to the scratchpad
        try tree.node_stack.append(tree.allocator, base_node);

        // If we laid a breadcrumb go back to it and search the other path
        // If there are no breadcrumbs we're done this pass
        if (breadcrumb) |crumb| {
            breadcrumb = tree.get(crumb, .crumb);
            tree.set(crumb, .crumb, null);

            base_node = tree.get(crumb, .child2).?;
        } else {
            break :loop1;
        }
    }

    // Pass 2. Sorted iterate

    // We will have at least one trapezoid on either side.
    var left_trapezoid: NodeID = try tree.add_node(.trapezoid);
    tree.set(left_trapezoid, .point1, upper_segment_point);

    var right_trapezoid: NodeID = try tree.add_node(.trapezoid);
    tree.set(right_trapezoid, .point1, upper_segment_point);

    while (tree.node_stack.items.len > 0) {
        var base_node_index: u32 = 0;
        var base_id: PointID = tree.node_stack.items[0];
        var low_point: PointID = lower_segment_point;
        for (0.., tree.node_stack.items) |i, node| {
            const new_point = tree.get(node, .point2).?;

            if (point_is_above(tree, new_point, low_point)) {
                low_point = new_point;
                base_node_index = @intCast(i);
                base_id = node;
            }
        }

        // We are on the correct trapezoid so split it with a segment
        // 1) Push child1, child2, and breadcrumb to left and right trapezoids
        // 1) Transform the found trapezoid into a segment (Since many nodes may point to this
        //    trapezoid we want to keep the relations sound. If we created a new segment node
        //    we would have to find all the parents and update them)
        // 2) Set the segment children to be the two current trapezoids and set the points
        //    to match the segment we are adding
        tree.print_node(base_id, " - Split");
        tree.set(base_id, .type, .segment);
        tree.set(left_trapezoid, .child1, tree.get(base_id, .child1));
        tree.set(base_id, .child1, left_trapezoid);

        if (point1 == upper_segment_point) {
            tree.set(base_id, .crumb, left_trapezoid);
        } else {
            tree.set(base_id, .crumb, right_trapezoid);
        }

        tree.set(right_trapezoid, .child2, tree.get(base_id, .child2));
        tree.set(base_id, .child2, right_trapezoid);
        tree.set(base_id, .point1, upper_segment_point);
        tree.set(base_id, .point2, lower_segment_point);

        // If the lower point of the trapezoid sits on the left of the segment, reset left_trapezoid.
        // If the lower point of the trapezoid sits on the right of the segment, reset right_trapezoid.
        // Simply return if this is the last trapezoid (The lower point will match the lower segment
        // point)
        if (lower_segment_point == low_point) {
            tree.set(left_trapezoid, .child2, base_id);
            tree.set(left_trapezoid, .point2, low_point);
            tree.set(right_trapezoid, .child1, base_id);
            tree.set(right_trapezoid, .point2, low_point);
            tree.print_node(left_trapezoid, " -- Into Left");
            tree.print_node(right_trapezoid, " -- And Right");
            break;
        } else {
            if (is_left_of(tree, low_point, upper_segment_point, lower_segment_point)) {
                // trapezoid_id is now a segment and sits on the right
                // of the left trapezoid
                tree.set(left_trapezoid, .child2, base_id);
                tree.set(left_trapezoid, .point2, low_point);
                tree.print_node(left_trapezoid, " -- Into Left");
                left_trapezoid = try tree.add_node(.trapezoid);
                tree.set(left_trapezoid, .point1, low_point);
            } else {
                // trapezoid_id is now a segment and sits on the left of
                // the right trapezoid
                tree.set(right_trapezoid, .child1, base_id);
                tree.set(right_trapezoid, .point2, low_point);
                tree.print_node(right_trapezoid, " -- Into Right");
                right_trapezoid = try tree.add_node(.trapezoid);
                tree.set(right_trapezoid, .point1, low_point);
            }
        }

        _ = tree.node_stack.swapRemove(base_node_index);
    }
}

fn push_triangle_if_acute(tree: *Triangulation, point: PointID, axis1: PointID, axis2: PointID, context: anytype, emit: fn (context: @TypeOf(context), point: math.Vec2) void) bool {
    const normalized_x1 = tree.points[point].v[0] - tree.points[axis1].v[0];
    const normalized_y1 = tree.points[point].v[1] - tree.points[axis1].v[1];
    const normalized_x2 = tree.points[point].v[0] - tree.points[axis2].v[0];
    const normalized_y2 = tree.points[point].v[1] - tree.points[axis2].v[1];
    const is_acute = @abs(math.std.atan2(normalized_y1, normalized_x1) - math.std.atan2(normalized_y2, normalized_x2)) < math.std.pi;

    if (is_acute) {
        emit(context, tree.points[point]);
        if ((axis1 > point and axis2 > point) or (axis1 < point and axis2 < point)) {
            if (axis1 > axis2) {
                emit(context, tree.points[axis2]);
                emit(context, tree.points[axis1]);
            } else {
                emit(context, tree.points[axis1]);
                emit(context, tree.points[axis2]);
            }
        } else if (axis2 > point) {
            emit(context, tree.points[axis2]);
            emit(context, tree.points[axis1]);
        } else if (axis1 > point) {
            emit(context, tree.points[axis1]);
            emit(context, tree.points[axis2]);
        }
    }

    return is_acute;
}

pub fn new(allocator: std.mem.Allocator) Triangulation {
    return Triangulation{
        .allocator = allocator,
        .node_stack = .empty,
        .nodes = .empty,
        .points = undefined,
        .root_node = undefined,
    };
}

pub fn destroy(self: *Triangulation) void {
    self.node_stack.clearAndFree(self.allocator);
    self.nodes.clearAndFree(self.allocator);
}

/// Create a polygon
/// Vertices are listed clockwise around the polygon and implicitly have
/// segments between each pair of points (Point 0 -> Point 1 -> ... -> Point N -> Point 0)
/// Self intersecting polygons are not allowed
pub fn create_polygon(
    self: *Triangulation,
    points: []const math.Vec2,
    context: anytype,
    emit: fn (context: @TypeOf(context), point: math.Vec2) void,
) !void {
    // Reset node list lengths but keep capacity
    self.node_stack.items.len = 0;
    self.nodes.items.len = 0;
    self.points = points;

    // This algorithm operates is in 3 steps
    // 1) Trapezoidization
    //   Put it simply, we treat the whole area as
    //   one big trapezoid, then for every point we split
    //   vertically and for every edge we split horizontally.
    //   In the end we will have a mosaic of trapezoids.
    // 2) Creation of Monotone Mountains
    //   We take all trapezoids that are within the polygon
    //   and cut them into vertical strips of trapezoids
    //   called "Monotone mountains"
    // 3) Ear Clipping of Monotone Mountains
    //   We look at each monotone mountain and do an
    //   algorithm called "Ear Clipping" to snip it up into
    //   triangles. The points of these triangles are sent
    //   to the "emit" callback passed into this function in
    //   clockwise order.

    //
    // Part 1: Trapedoization
    //

    // Create a root trapezoid node representing the whole space
    self.root_node = try self.add_node(.trapezoid);

    // Iterate through all pairs of points.
    // Add them both and create an edge between them
    var rng = unirand.unirand_seed(@intCast(points.len));
    while (rng.next()) |edge| {
        const p1: u32 = edge;
        const p2: u32 = @intCast((edge + 1) % points.len);

        // Add points
        try self.add_point(p1);
        try self.add_point(p2);

        // Add edge
        try self.add_segment(p1, p2);
    }

    //
    // Part 2: Monotone Mountains
    //

    var monotone_mountains = PointMap.init(self.allocator);

    // Pass over trapezoids to generate monotone mountains.
    // 1) Determine if trapezoid is inside or outside. Look at the edge and see if
    //    it's on the interior side
    // 2) Do a check to see if this belongs to two monotone mountains or just one.
    //    If the two upper/lower points match the two upper/lower points of either
    //    enclosing segments it belongs to the mountain keyed by the opposite
    //    segment. If this is not the case, it belongs to the mountains keyed by
    //    both edges.
    for (0..self.nodes.items.len) |item_usize| {
        const item: u32 = @intCast(item_usize);
        if (self.get(item, .type) == .trapezoid) {
            self.print_node(item, "");

            // (1)
            if (self.get(item, .child1)) |child1| {
                const is_inside = self.get(child1, .crumb) == self.get(child1, .child2);
                if (!is_inside) {
                    continue;
                }
            } else continue;

            // (2)
            const point1 = self.get(item, .point1).?;
            const point2 = self.get(item, .point2).?;
            const child1 = self.get(item, .child1).?;
            const child2 = self.get(item, .child2).?;
            if ((point1 == self.get(child2, .point1)) and (point2 == self.get(child2, .point2))) {
                // Segment 1 is the key
                try monotone_mountains.add_point(self, child1, point1, point2);
            } else if ((point1 == self.get(child1, .point1)) and (point2 == self.get(child1, .point2))) {
                // Segment 2 is the key
                try monotone_mountains.add_point(self, child2, point1, point2);
            } else {
                // Add points to both segment 1 and 2.
                try monotone_mountains.add_point(self, child1, point1, point2);
                try monotone_mountains.add_point(self, child2, point1, point2);
            }
        }
    }

    //
    // Part 3: Ear Clippping of Monotone Mountains
    //
    // Iterate through monotone mountains to generate triangles
    // For each mountain:
    // 1) Sort and dedupe the vertices by y value
    // 2) For each point with a convex inner angles (Look at neighbours,
    //    looping around the buffer if necessary.):
    //    2a) Add a triangle with that point and the two others to the triangle list.
    //    2b) Remove the point
    //    2c) If only 2 points are left, this mountain is done.
    for (monotone_mountains.backend.items) |*mountain| {
        // 1)
        std.sort.insertion(PointID, mountain.list.items, self, point_is_above);

        // 2)
        loop: while (mountain.list.items.len > 2) {
            var p1: usize = mountain.list.items.len - 2;
            var p2: usize = mountain.list.items.len - 1;
            var p3: usize = 0;
            for (1..mountain.list.items.len) |item| {
                if (mountain.list.items[p1] == mountain.list.items[p2]) {
                    _ = mountain.list.orderedRemove(p1);
                    continue :loop;
                }
                if (mountain.list.items[p2] == mountain.list.items[p3]) {
                    _ = mountain.list.orderedRemove(p2);
                    continue :loop;
                }
                if (push_triangle_if_acute(
                    self,
                    mountain.list.items[p2],
                    mountain.list.items[p1],
                    mountain.list.items[p3],
                    context,
                    emit,
                )) {
                    _ = mountain.list.orderedRemove(p2);
                    continue :loop;
                }
                p1 = p2;
                p2 = p3;
                p3 = item;
            }
        }
    }
}
