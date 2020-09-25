const std = @import("std");

pub const Client = struct {
    file: ?std.fs.File = null,
    allocator: *std.mem.Allocator,
    host: []u8,

    pub fn init(allocator: *std.mem.Allocator, host: []const u8, port: u16) !Client {
        const result = Client{
            .file = try std.net.tcpConnectToHost(allocator, host, port),
            .allocator = allocator,
            .host = try allocator.alloc(u8, host.len),
        };
        std.mem.copy(u8, result.host, host);
        return result;
    }

    pub fn deinit(self: *Client) void {
        if (self.file) |f| {
            self.allocator.free(self.host);
            f.close();
            self.file = null;
        }
    }

    pub fn requestAlloc(self: Client, url: []const u8) ![]const u8 {
        errdefer std.log.err("Client requestAlloc: verlasse die Funktion wegen Fehler", .{});
        defer std.log.debug("Client requestAlloc: Ende", .{});

        std.log.debug("Client requestAlloc: Anfang", .{});
        if (self.file) |f| {
            try f.outStream().print("GET {} HTTP/1.1\r\n" ++ // try f.outStream().
                "host: {}\r\n" ++
                "\r\n", .{ url, self.host });
            std.log.debug("Request sent", .{});
            var response_code: ?u8 = null;
            var content_length: ?u32 = null;
            var eofHeader = false;

            while (!eofHeader) {
                var line = std.ArrayList(u8).init(self.allocator);
                defer line.deinit();

                try f.inStream().readUntilDelimiterArrayList(&line, '\n', 100_000);
                std.log.debug("Client Zeile gelesen: {}", .{line.items});
                eofHeader = std.mem.eql(u8, line.items, "\r");
                if (!eofHeader) {
                    const response_code_start = "HTTP/1.1 ";
                    const content_length_start = "Content-Length: ";
                    if (std.mem.indexOf(u8, line.items, response_code_start)) |pos| {
                        if (pos == 0) {
                            response_code = std.fmt.parseInt(u8, line.items[response_code_start.len .. response_code_start.len + 3], 10) catch return error.BadHeader;
                            std.log.debug("Client response code erfolgreich empfangen ({})", .{response_code});
                        }
                    }
                    if (std.mem.indexOf(u8, line.items, content_length_start)) |pos| {
                        if (pos == 0) {
                            // line.items.len-1 wg \r
                            content_length = std.fmt.parseInt(u8, line.items[content_length_start.len .. line.items.len - 1], 10) catch return error.BadHeader;
                            std.log.debug("Client content-length empfangen ({})", .{content_length});
                        }
                    }
                }
            }
            if (content_length == null or response_code == null)
                return error.BadHeader;
            const response = try self.allocator.alloc(u8, content_length.?);
            errdefer self.allocator.free(response);

            if ((try f.readAll(response)) != response.len)
                return error.BadBodyLength;
            return response;
        } else {
            return error.NoConnection;
        }
    }
};
