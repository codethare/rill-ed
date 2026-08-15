const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Queue(comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Task = struct {
            deadline: i64,
            context: Context,
            callback: *const fn (Context) void,
        };

        tasks: std.PriorityQueue(Task, void, struct {
            fn compare(_: void, a: Task, b: Task) std.math.Order {
                return std.math.order(a.deadline, b.deadline);
            }
        }.compare),

        pub const empty: Self = .{
            .tasks = .empty,
        };

        pub fn init() Self {
            return .{ .tasks = .empty };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.tasks.deinit(allocator);
        }

        /// Schedule `callback(context)` to run after `delay_ms` milliseconds.
        pub fn schedule(
            self: *Self,
            allocator: Allocator,
            delay_ms: i64,
            now_ms: i64,
            context: Context,
            callback: *const fn (Context) void,
        ) !void {
            const task: Task = .{
                .deadline = now_ms + delay_ms,
                .context = context,
                .callback = callback,
            };
            try self.tasks.push(allocator, task);
        }

        /// Run every task whose deadline has passed, in deadline order.
        pub fn runDue(self: *Self, now_ms: i64) void {
            while (self.tasks.peek()) |task| {
                if (task.deadline > now_ms) break;
                const due = self.tasks.pop().?;
                due.callback(due.context);
            }
        }

        /// Earliest scheduled deadline, or null if the queue is empty.
        pub fn nextDeadline(self: *const Self) ?i64 {
            const task = self.tasks.peek() orelse return null;
            return task.deadline;
        }

        /// Milliseconds until the next task, capped at `max_ms`.
        pub fn timeoutMs(self: *const Self, now_ms: i64, max_ms: i32) i32 {
            const deadline = self.nextDeadline() orelse return max_ms;
            const remaining = deadline - now_ms;
            if (remaining <= 0) return 0;
            const capped = @min(remaining, max_ms);
            return @intCast(capped);
        }
    };
}


test "timer queue runs tasks in deadline order" {
    const Counter = struct {
        var early: usize = 0;
        var late: usize = 0;
    };

    const Context = usize;
    var q = Queue(Context).empty;
    defer q.deinit(std.testing.allocator);

    try q.schedule(std.testing.allocator, 100, 0, 7, struct {
        fn cb(ctx: Context) void {
            Counter.late = ctx;
        }
    }.cb);
    try q.schedule(std.testing.allocator, 50, 0, 3, struct {
        fn cb(ctx: Context) void {
            Counter.early = ctx;
        }
    }.cb);

    try std.testing.expectEqual(@as(?i64, 50), q.nextDeadline());

    q.runDue(60);
    try std.testing.expectEqual(@as(usize, 3), Counter.early);
    try std.testing.expectEqual(@as(usize, 0), Counter.late);

    q.runDue(100);
    try std.testing.expectEqual(@as(usize, 7), Counter.late);
}
