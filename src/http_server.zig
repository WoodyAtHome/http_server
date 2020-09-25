const std = @import("std");

pub const Server = struct {
    server_addr: std.net.Address,
    allocator: *std.mem.Allocator,
    stream_server: std.net.StreamServer,
    pages: *const Pages,
    contexts: ContextsBag,
    shutdownServer: std.atomic.Int(bool) = std.atomic.Int(bool).init(false),
    page_cnt: std.atomic.Int(usize) = std.atomic.Int(usize).init(0),
    server_thread: ?*std.Thread = null,

    pub fn init(allocator: *std.mem.Allocator, pages: Pages, addr: std.net.Address) !Server {
        return Server{
            .allocator = allocator,
            .stream_server = std.net.StreamServer.init(.{ .reuse_address = true }),
            .pages = &pages,
            .contexts = ContextsBag.init(allocator),
            .server_addr = addr,
        };
    }

    pub fn shutdown(self: *Server) !void {
        if (!self.shutdownServer.xchg(true)) {
            var file = try std.net.tcpConnectToAddress(self.server_addr);
            defer file.close();
        }
    }

    pub fn run(self: *Server) !void {
        self.server_thread = try std.Thread.spawn(self, runServer);
    }

    pub fn deinit(self: *Server) void {
        if (self.server_thread) |t| {
            self.server_thread = null;
            self.shutdown() catch return; // damit wait nicht blockiert, im Fehlerfall lieber hier zurück
            t.wait();
        }
    }

    pub const PageAction = struct {
        fktAlloc: fn (allocator: *std.mem.Allocator, ctx: *const ConnectionContext) ?[]const u8,
    };

    pub const Pages = std.StringHashMap(*const PageAction);

    pub const ConnectionContext = struct {
        conn: std.net.StreamServer.Connection,
        server: *Server, // const geht nicht wegen shutdownServer.get, braucht non-const
        thread: ?*std.Thread = null,
        finished: bool = false,

        fn set_finished(self: *ConnectionContext) void {
            const ptr: *volatile bool = &self.finished;
            ptr.* = true;
        }
        fn is_finished(self: *ConnectionContext) bool {
            const ptr: *volatile bool = &self.finished;
            return ptr.*;
        }
    };

    const ContextsBag = std.AutoHashMap(*ConnectionContext, void);

    fn cleanupFinishedThreads(self: *Server) usize {
        std.log.debug("server: cleanupFinishedThreads", .{});
        const allocator = self.allocator;
        var unfinished_threads: usize = 0;
        var it = self.contexts.iterator();
        while (it.next()) |entry| {
            const ctx = entry.key;
            if (ctx.is_finished()) {
                std.debug.assert(self.contexts.remove(ctx) != null);
                // if thread.spawn failed thread will be null and finished true
                if (ctx.thread) |thread|
                    thread.wait();
                allocator.destroy(ctx);
            } else {
                unfinished_threads += 1;
            }
        }
        return unfinished_threads;
    }

    fn waitForActiveThreadsAndCleanup(self: *Server) void {
        std.log.debug("server: waitForActiveThreadsAndCleanup", .{});
        const timeout_in_s = std.time.ns_per_s * 5;
        var cnt = cleanupFinishedThreads(self);
        const start_time = std.time.timestamp();

        while (cnt > 0 and ((std.time.timestamp() - start_time) < timeout_in_s)) {
            std.log.info("server: still waiting for {} unfinished threads", .{cnt});
            std.time.sleep(std.time.ns_per_ms * 100);
            cnt = cleanupFinishedThreads(self);
        }
        if (cnt == 0) {
            std.log.info("server: all threads finished, closing server now.", .{});
        } else {
            std.log.info("server: timeout waiting for {} unfinished threads =>abort waiting", .{cnt});
        }
    }

    fn runServer(self: *Server) !void {
        const allocator = self.allocator;

        defer self.contexts.deinit();
        defer self.stream_server.deinit();
        defer waitForActiveThreadsAndCleanup(self);

        try self.stream_server.listen(self.server_addr);

        while (!self.shutdownServer.get()) {
            const conn = self.stream_server.accept() catch |err| switch (err) {
                std.net.StreamServer.AcceptError.ConnectionAborted => continue,
                else => return err,
            };
            // between while and here shutdownServer will be set
            // if the exit Page is called (handleConn, )
            if (!self.shutdownServer.get()) {
                // main-thread owns new_ctx until successful thread.spawn

                // sicherstellen, dass der neu erzeugte Contex für den Thread auch gespeichert werden kann
                // sonst kann der später nicht mehr richtig aufgeräumt werden
                if (self.contexts.ensureCapacity(self.contexts.count() + 1)) |_| {
                    const new_ctx = try allocator.create(ConnectionContext);
                    errdefer allocator.destroy(new_ctx);

                    new_ctx.* = ConnectionContext{
                        .conn = conn,
                        .server = self,
                    };
                    // thread.wait won't be called assuming that it's not
                    // nessesary to do so.
                    // But the documentation says that you have to call wait
                    if (std.Thread.spawn(new_ctx, handleConn)) |thread| {
                        new_ctx.thread = thread;
                    } else |_| {
                        new_ctx.set_finished();
                    }
                    // muss klappen, wenn Pointer schon als key vorhanden => assert will fail
                    // und eine Allocation wird es dank ensureCapacity nicht mehr geben
                    self.contexts.putNoClobber(new_ctx, .{}) catch unreachable;
                } else |_| {
                    // ensureCapacity failed => nothing we can do, just let the old thread run
                }
            }
            _ =
                cleanupFinishedThreads(self);
        }
    }

    fn handleConn(ctx: *ConnectionContext) !void {
        defer ctx.set_finished(); // allerallerletzte Aktion, da dann sofort der ctx freigegeben wird!

        const request_size = 1024;
        std.log.info("server handleConn: connected to {}, thread id = {}", .{ ctx.conn.address, std.Thread.getCurrentId() });
        defer {
            std.log.info("server handleConn: closing connection to {}, thread id = {}", .{ ctx.conn.address, std.Thread.getCurrentId() });
            ctx.conn.file.close();
        }

        while (true) {
            var arena = std.heap.ArenaAllocator.init(ctx.server.allocator);
            const allocator = &arena.allocator;
            defer arena.deinit();

            const request_buffer = try allocator.alloc(u8, request_size);
            const answer_buffer = try allocator.alloc(u8, request_size);
            const conn = ctx.conn;
            var requestComplete = false;
            var idx: usize = 0;
            const start = std.time.timestamp();
            const timeout = std.time.ns_per_s * 60; // in max. 1 min the request has to be finished/completed
            var timeouted = false;
            while (!requestComplete) {
                if (std.time.timestamp() - start > timeout)
                    return error.Timeout;

                const len = try conn.file.reader().read(request_buffer[idx..]);
                idx += len;
                if (len == 0 and ctx.server.shutdownServer.get())
                    return; //return error.Aborted;
                requestComplete = std.mem.endsWith(u8, request_buffer[0..idx], "\r\n\r\n");
                if (!requestComplete and idx == request_size)
                    return error.BadRequestLength;
            }
            const request = request_buffer[0..idx];

            const cmd_pos = std.mem.indexOf(u8, request, "GET /");
            if (cmd_pos) |pos| {
                if ((pos != 0 and request.len < "GET / HTTP/1.1".len)) {
                    return error.BadRequestCmdStart;
                }
            } else {
                return error.BadRequestCmd;
            }

            const requested_page_end = std.mem.indexOf(u8, request, " HTTP/1.");
            if (requested_page_end == null)
                return error.BadRequestCmdEnd;

            const page_called = ctx.server.page_cnt.incr();
            const requested_page = request[4..requested_page_end.?];

            std.log.info("server handleConn: requested_page={}", .{requested_page});
            var code: []const u8 = undefined;
            var answer: []const u8 = undefined;

            if (ctx.server.pages.get(requested_page)) |action| {
                if (action.fktAlloc(allocator, ctx)) |txt| {
                    code = "200 OK"; // TODO
                    answer = txt;
                } else {
                    code = "404 ERROR"; // TODO
                    answer = try std.fmt.allocPrint(allocator, "internal server error.", .{});
                }
            } else {
                code = "404 ERROR"; // TODO
                answer = try std.fmt.allocPrint(allocator, "Page not found.", .{});
            }

            //const answer = try std.fmt.bufPrint(answer_buffer, "Hello world to {}\r\npage {} * requested\r\n", .{ conn.address, page_called });
            const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 {}\r\n" ++
                "Content-Length: {}\r\n" ++
                "Connection: keep-alive\r\n" ++
                "Content-Type: text/plain; charset=UTF-8\r\n" ++
                "Server: Example\r\n" ++
                "Date: Wed, 17 Apr 2013 12:00:00 GMT\r\n" ++
                "\r\n" ++
                "{}", .{ code, answer.len, answer });

            std.log.debug("Server: Response sent: {}", .{response});
            try conn.file.writeAll(response);

            if (std.mem.eql(u8, requested_page, "/exit")) {
                try ctx.server.shutdown();
            }
        }
    }
};
