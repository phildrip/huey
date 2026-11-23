const std = @import("std");
const linux = std.os.linux;

pub const CAPACITY: usize = 256;
pub const MAX_PAYLOAD_BYTES: usize = 64;

/// Fixed-size message passed from background worker threads to the main loop.
pub const AsyncMessage = struct {
    tag: u32 = 0,
    u64_val: u64 = 0,
    f32_val: f32 = 0.0,
    payload: [MAX_PAYLOAD_BYTES]u8 = [_]u8{0} ** MAX_PAYLOAD_BYTES,
    payload_len: u8 = 0,

    /// Returns the active slice of `payload`, clamped to `MAX_PAYLOAD_BYTES`.
    pub fn payloadSlice(self: *const AsyncMessage) []const u8 {
        const clamped = @min(@as(usize, self.payload_len), MAX_PAYLOAD_BYTES);
        return self.payload[0..clamped];
    }
};

/// Bounded, thread-safe MPSC ring buffer backed by a Linux `eventfd` for
/// zero-tick `epoll` / `ALooper_addFd` main-thread wakeup.
///
/// Consumer ordering invariant: the event loop MUST call `acknowledgeWake()`
/// BEFORE `drain()`. `push()` signals `wake_fd` on empty -> non-empty
/// transitions outside the spinlock, and `drain()` re-signals `wake_fd`
/// outside the spinlock whenever items remain (`still_pending`), ensuring
/// level-triggered `epoll` / `ALooper_pollOnce` never misses a wakeup.
pub const AsyncWakeQueue = struct {
    buf: [CAPACITY]AsyncMessage = undefined,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    dropped: usize = 0,
    lock_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    wake_fd: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    pub fn init() !AsyncWakeQueue {
        const flags: u32 = linux.EFD.NONBLOCK | linux.EFD.CLOEXEC;
        const rc = linux.eventfd(0, flags);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            return switch (err) {
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOMEM => error.SystemResources,
                .INVAL => error.InvalidArgument,
                else => error.EventFdFailed,
            };
        }
        return .{
            .wake_fd = std.atomic.Value(i32).init(@intCast(rc)),
        };
    }

    pub fn deinit(self: *AsyncWakeQueue) void {
        const fd = self.wake_fd.swap(-1, .acq_rel);
        if (fd >= 0) {
            _ = linux.close(fd);
        }
    }

    pub fn wakeFd(self: *const AsyncWakeQueue) i32 {
        return self.wake_fd.load(.acquire);
    }

    fn lock(self: *AsyncWakeQueue) void {
        while (self.lock_state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            while (self.lock_state.load(.monotonic) != 0) {
                std.atomic.spinLoopHint();
            }
        }
    }

    fn unlock(self: *AsyncWakeQueue) void {
        self.lock_state.store(0, .release);
    }

    fn signalWake(self: *const AsyncWakeQueue) void {
        const fd = self.wake_fd.load(.acquire);
        if (fd < 0) return;
        const val: u64 = 1;
        const bytes = std.mem.asBytes(&val);
        while (true) {
            const rc = linux.write(fd, bytes.ptr, bytes.len);
            const err = linux.errno(rc);
            switch (err) {
                .SUCCESS, .AGAIN => return,
                .INTR => continue,
                else => return,
            }
        }
    }

    /// Thread-safe non-blocking push. Returns `false` and saturating-increments
    /// `dropped` when the ring buffer is full; otherwise enqueues `msg` and
    /// signals `wake_fd` after releasing the spinlock on empty -> non-empty.
    pub fn push(self: *AsyncWakeQueue, msg: AsyncMessage) bool {
        self.lock();
        if (self.len >= CAPACITY) {
            self.dropped +|= 1;
            self.unlock();
            return false;
        }
        const was_empty = (self.len == 0);
        self.buf[self.tail] = msg;
        self.tail = (self.tail + 1) % CAPACITY;
        self.len += 1;
        self.unlock();

        if (was_empty) {
            self.signalWake();
        }
        return true;
    }

    /// Non-blocking 8-byte read from `eventfd`. Must be called BEFORE `drain()`
    /// on each wakeup cycle. Returns `true` if a wakeup was pending, or `false`
    /// on `EAGAIN` or closed `wake_fd`.
    pub fn acknowledgeWake(self: *AsyncWakeQueue) bool {
        const fd = self.wake_fd.load(.acquire);
        if (fd < 0) return false;
        var val: u64 = 0;
        const bytes = std.mem.asBytes(&val);
        while (true) {
            const rc = linux.read(fd, bytes.ptr, bytes.len);
            const err = linux.errno(rc);
            switch (err) {
                .SUCCESS => return rc == @sizeOf(u64),
                .AGAIN => return false,
                .INTR => continue,
                else => return false,
            }
        }
    }

    /// Pops up to `out.len` messages in FIFO order. Must be called AFTER
    /// `acknowledgeWake()`. Re-signals `wake_fd` outside the spinlock if items
    /// remain so level-triggered loops wake immediately for the remainder.
    pub fn drain(self: *AsyncWakeQueue, out: []AsyncMessage) usize {
        if (out.len == 0) return 0;
        self.lock();
        const count = @min(out.len, self.len);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            out[i] = self.buf[self.head];
            self.head = (self.head + 1) % CAPACITY;
        }
        self.len -= count;
        const still_pending = (self.len > 0);
        self.unlock();

        if (still_pending) {
            self.signalWake();
        }
        return count;
    }

    pub fn droppedCount(self: *AsyncWakeQueue) usize {
        self.lock();
        defer self.unlock();
        return self.dropped;
    }

    pub fn pendingCount(self: *AsyncWakeQueue) usize {
        self.lock();
        defer self.unlock();
        return self.len;
    }
};
