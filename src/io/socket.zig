const std = @import("std");

const bun = @import("../bun.zig");
const JSC = bun.JSC;
const Environment = @import("../env.zig");
const base = @import("../bun.js/base.zig");
const Syscall = JSC.Node.Syscall;

pub const Socket = struct {
    vm_: *bun.JSC.VirtualMachine,
    // Holds the FileDescriptor, which we own and close.
    poll_: ?*base.FilePoll = null,

    // Nullity of read_cb_ and write_cb_ is our indicator of whether a read is waiting for
    // its callback or not.
    read_cb_: ?*const fn(ctx: ?*anyopaque, res: InterruptedError!JSC.Maybe(usize)) void = null,
    // Nullity of read_task_ and write_task_ is used for interruption.
    read_task_: ?JSC.AnyTask = null,
    read_buf_: ?[]u8 = null,
    read_ctx_: ?*anyopaque = null,
    read_interrupted_: bool = false,

    write_cb_: ?*const fn(ctx: ?*anyopaque, res: InterruptedError!JSC.Maybe(usize)) void = null,
    write_task_: ?JSC.AnyTask = null,
    write_buf_: ?[]u8 = null,
    write_ctx_: ?*anyopaque = null,
    write_interrupted_: bool = false,

    const LogicError = error {
        LogicError,
    };
    const InterruptedError = error {
        InterruptedError,
    };

    pub fn init(this: *Socket, vm: *JSC.VirtualMachine, fd: bun.FileDescriptor) JSC.Maybe(void) {
        std.debug.assert(fd != bun.invalid_fd);
        this.vm_ = vm;
        const flags: base.FilePoll.Flags.Struct = .{};
        this.poll_ = base.FilePoll.init(vm, fd, flags, Socket, this);
        // TODO: We should be able to register both readable and writable flags in one system call.
        const res: JSC.Maybe(void)
            = this.poll_.?.register(vm.uws_event_loop.?, base.FilePoll.Flags.readable, false);
        switch (res) {
            .err => { return res; },
            else => { },
        }
        const res2: JSC.Maybe(void)
            = this.poll_.?.register(vm.uws_event_loop.?, base.FilePoll.Flags.writable, false);
        switch (res2) {
            .err => { return res2; },
            else => { },
        }
        return .{.result = {}};
    }

    pub fn deinit(this: *Socket) void {
        const fd: bun.FileDescriptor = this.poll_.?.fd;
        this.poll_.?.deinit();
        if (fd != bun.invalid_fd) {
            _ = Syscall.close(fd);
        }

        if (this.read_cb_ != null or this.write_cb_ != null) {
            // We might call interruptRead and/or interruptWrite instead.
            // But for now, AnyTask usage doesn't take ownership of the ctx/cb pointer
            // pair; the callee has to clean it up -- and the correct fix would not be to add
            // allocations necessary to interrupt the read with InterruptedError or LogicError,
            // but rather to make the event loop hold both values of the AnyTask instead of
            // using a TaggedPointerUnion.
            std.debug.panic("Socket deinitted while pending callbacks exist", .{});
        }
    }

    pub fn onPoll(this: *Socket) void {
        if (this.read_cb_ != null) {
            if (this.poll_.?.isReadable()) {  // Removes .readable flag.
                this.performRead();
            }
        }
        if (this.write_cb_ != null) {
            if (this.poll_.?.isWritable()) {  // Removes .writable flag.
                this.performWrite();
            }
        }
    }

    pub fn interruptRead(this: *Socket) void {
        if (this.read_cb_ != null) {
            this.read_interrupted_ = true;
            if (this.read_task_ == null) {
                this.read_task_ = JSC.AnyTask.New(Socket, performRead).init(this);
                this.vm_.enqueueTask(JSC.Task.init(&this.read_task_));
            }
        }
    }

    pub fn interruptWrite(this: *Socket) void {
        if (this.write_cb_ != null) {
            this.write_interrupted_ = true;
            if (this.write_task_ == null) {
                this.write_task_ = JSC.AnyTask.New(Socket, performWrite).init(this);
                this.vm_.enqueueTask(JSC.Task.init(&this.write_task_));
            }
        }
    }

    pub fn read(this: *Socket, buf: []u8, ctx: *anyopaque,
            read_cb: *const fn(ctx: ?*anyopaque, res: InterruptedError!JSC.Maybe(usize)) void) LogicError!void {
        if (this.read_cb_ != null) {
            return error.LogicError;
        }
        this.read_buf_ = buf;
        this.read_ctx_ = ctx;
        this.read_cb_ = read_cb;
        if (this.poll_.?.isReadable()) {  // Removes .readable flag.
            this.read_task_ = JSC.AnyTask.New(Socket, performRead).init(this);
            this.vm_.enqueueTask(JSC.Task.init(&this.read_task_));
            return;
        }
    }

    pub fn performRead(this: *Socket) void {
        std.debug.assert(this.read_cb_ != null);
        this.read_task_ = null;
        const read_cb = this.read_cb_;
        this.read_cb_ = null;
        const ctx = this.read_ctx_;
        this.read_ctx_ = null;
        if (this.read_interrupted_) {
            this.read_buf_ = null;
            this.read_interrupted_ = false;
            read_cb.?(ctx, error.InterruptedError);
            return;
        }
        const res: JSC.Maybe(usize) = Syscall.read(this.poll_.?.fd, this.read_buf_.?);
        this.read_buf_ = null;
        read_cb.?(ctx, res);
    }

    pub fn write(this: *Socket, buf: []u8, ctx: *anyopaque,
            write_cb: *const fn(ctx: ?*anyopaque, res: InterruptedError!JSC.Maybe(usize)) void) LogicError!void {
        if (this.write_cb_ != null) {
            return error.LogicError;
        }
        this.write_buf_ = buf;
        this.write_ctx_ = ctx;
        this.write_cb_ = write_cb;
        if (this.poll_.?.isWritable()) {  // Removes .writable flag.
            this.write_task_ = JSC.AnyTask.New(Socket, performWrite).init(this);
            this.vm_.enqueueTask(JSC.Task.init(&this.write_task_));
            return;
        }
    }

    pub fn performWrite(this: *Socket) void {
        std.debug.assert(this.write_cb_ != null);
        this.write_task_ = null;
        const ctx = this.write_ctx_;
        this.write_ctx_ = null;
        const write_cb = this.write_cb_;
        this.write_cb_ = null;
        if (this.write_interrupted_) {
            this.write_buf_ = null;
            this.write_interrupted_ = false;
            write_cb.?(ctx, error.InterruptedError);
            return;
        }
        const res: JSC.Maybe(usize) = Syscall.write(this.poll_.?.fd, this.write_buf_.?);
        this.write_buf_ = null;
        write_cb.?(ctx, res);
    }

};

// TODO: The function testSocket is just to sanity-check compilation.

fn testSocket_cb(_: ?*anyopaque, _: Socket.InterruptedError!JSC.Maybe(usize)) void { return {}; }


pub fn testSocket(vm: *JSC.VirtualMachine) void {
    if (comptime Environment.isLinux) {
        const Random = std.rand.DefaultPrng;
        var rnd = Random.init(0);
        var some_random_num = rnd.random().int(i32);
        if (some_random_num != 0) {
            // We don't actually want to run this code.
            return;
        }

        const protocol: i32 = 0;
        var fds: [2]i32 = .{-1, -1};
        const res: usize = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC,
            protocol, &fds);
        std.debug.assert(std.os.linux.E.SUCCESS == std.os.linux.getErrno(res));
        
        var sock0: Socket = undefined;
        _ = sock0.init(vm, fds[0]);
        var sock1: Socket = undefined;
        _ = sock1.init(vm, fds[1]);
        sock0.deinit();
        sock1.deinit();
        var ctx_target: i32 = 0;
        var buf: [5]u8 = undefined;
        sock0.read(&buf, @ptrCast(*anyopaque, &ctx_target), &testSocket_cb) catch {};
        sock0.interruptRead();
        sock1.write(&buf, @ptrCast(*anyopaque, &ctx_target), &testSocket_cb) catch {};
        sock1.interruptWrite();
        std.debug.print("Exercising testSocket", .{});

    }
}
