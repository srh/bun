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

    pub const LogicError = error {
        LogicError,
    };
    pub const InterruptedError = error {
        InterruptedError,
    };

    pub fn init(this: *Socket, vm_: *JSC.VirtualMachine, fd: bun.FileDescriptor) JSC.Maybe(void) {
        std.debug.assert(fd != bun.invalid_fd);
        this.vm_ = vm_;
        const flags: base.FilePoll.Flags.Struct = .{};
        this.poll_ = base.FilePoll.init(vm_, fd, flags, Socket, this);
        // TODO: We should be able to register both readable and writable flags in one system call.
        const res: JSC.Maybe(void)
            = this.poll_.?.register(vm_.uws_event_loop.?, base.FilePoll.Flags.readable, false);
        switch (res) {
            .err => { return res; },
            else => { },
        }
        const res2: JSC.Maybe(void)
            = this.poll_.?.register(vm_.uws_event_loop.?, base.FilePoll.Flags.writable, false);
        switch (res2) {
            .err => { return res2; },
            else => { },
        }
        return .{.result = {}};
    }

    pub fn deinit(this: *Socket) void {
        if (this.poll_ == null) {
            return;
        }
        const fd: bun.FileDescriptor = this.poll_.?.fd;
        // Note that deinit() invalidates the pointer.
        this.poll_.?.deinit();
        this.poll_ = null;
        _ = Syscall.close(fd);

        if (this.read_cb_ != null or this.write_cb_ != null) {
            // We can't interrupt the reads or writes because the object gets invalidated.
            // The caller should know if it has pending reads or writes.
            std.debug.panic("Socket deinitted while pending callbacks exist", .{});
        }
    }

    pub fn interruptAndClose(this: *Socket) void {
        if (this.poll_ == null) {
            std.debug.panic("Tried to close a Socket that is already closed", .{});
            return;
        }
        const fd: bun.FileDescriptor = this.poll_.?.fd;

        // TODO: Consider this question.  Currently the function is named interruptAndClose beacuse it interrupts pending operations.
        // Maybe, we should say this can't be called if there are pending reads and writes.  The caller should know if it has pending operations.
        // But for now, we just interrupt any pending operations.
        this.interruptRead();
        this.interruptWrite();

        // Note that deinit() invalidates the pointer.
        this.poll_.?.deinit();
        this.poll_ = null;
        _ = Syscall.close(fd);
    }

    pub fn isClosed(this: *Socket) bool {
        return this.poll_ == null;
    }

    pub fn vm(this: *const Socket) *bun.JSC.VirtualMachine {
        return this.vm_;
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

