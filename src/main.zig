const std = @import("std");
const http = @import("http_server.zig");
const httpc = @import("http_client.zig");

pub fn main() !void {
    errdefer std.log.err("Fehler!", .{});
    defer std.log.debug("main korrekt beendet.", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;
    //const allocator = std.testing.allocator;
    var pages = http.Server.Pages.init(allocator);
    defer pages.deinit();

    _ = try pages.put("/index.html", &http.Server.PageAction{ .fktAlloc = index });
    _ = try pages.put("/about.html", &http.Server.PageAction{ .fktAlloc = about });
    _ = try pages.put("/shutdown.html", &http.Server.PageAction{ .fktAlloc = shutdown });

    const server_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000);
    var server = try http.Server.init(allocator, pages, server_addr);
    try server.run();
    defer server.deinit();
    std.time.sleep(std.time.ns_per_s * 1); // warten bis Server läuft

    if (true) {
        var client = try httpc.Client.init(allocator, "localhost", 9000);
        defer client.deinit();
        std.log.debug("client init done", .{});

        if (true) {
            const response = try client.requestAlloc("/index.html");
            defer allocator.free(response);
            const expected = "Hallo, das hier ist Index.html\r\nPage count = 1";
            std.testing.expectEqualStrings(expected, response);
        }
        if (true) {
            if (true) {
                const response = try client.requestAlloc("/index.html");
                defer allocator.free(response);
                const expected = "Hallo, das hier ist Index.html\r\nPage count = 2";
                std.testing.expectEqualStrings(expected, response);
            }
        }
        if (true) {
            if (true) {
                const response = try client.requestAlloc("/shutdown.html");
                defer allocator.free(response);
                const expected = "Hallo, das hier ist Index.html\r\nPage count = 2";
                std.testing.expectEqualStrings(expected, response);
            }
        }
    }
    std.log.info("zurück in Main", .{});
}

fn index(allocator: *std.mem.Allocator, ctx: *const http.Server.ConnectionContext) ?[]const u8 {
    return std.fmt.allocPrint(allocator, "Hallo, das hier ist Index.html\r\nPage count = {}", .{ctx.server.page_cnt.get()}) catch {
        return null;
    };
}

fn about(allocator: *std.mem.Allocator, ctx: *const http.Server.ConnectionContext) ?[]const u8 {
    return std.fmt.allocPrint(allocator, "Hallo, das hier ist About.html\r\nPage count = {}", .{ctx.server.page_cnt.get()}) catch {
        return null;
    };
}

fn shutdown(allocator: *std.mem.Allocator, ctx: *const http.Server.ConnectionContext) ?[]const u8 {
    if (ctx.server.shutdown()) |_| {
        return std.fmt.allocPrint(allocator, "Ok, HTML server shutdown now.", .{}) catch {
            return null;
        };
    } else |err| {
        return std.fmt.allocPrint(allocator, "can not signal HTML shutdown, err = {}\r\n", .{err}) catch {
            return null;
        };
    }
}

test "single client to server" {
    const allocator = std.testing.allocator;

    var pages = http.Server.Pages.init(allocator);
    defer pages.deinit();

    _ = try pages.put("/index.html", &http.Server.PageAction{ .fktAlloc = index });
    _ = try pages.put("/about.html", &http.Server.PageAction{ .fktAlloc = about });
    _ = try pages.put("/shutdown.html", &http.Server.PageAction{ .fktAlloc = shutdown });

    const server_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000);
    var server = try http.Server.init(allocator, pages, server_addr);
    try server.run();
    defer server.deinit();
    std.time.sleep(std.time.ns_per_s * 1); // warten bis Server läuft

    if (true) {
        var client = try httpc.Client.init(allocator, "localhost", 9000);
        defer client.deinit();
        std.log.debug("client init done", .{});

        if (true) {
            const response = try client.requestAlloc("/index.html");
            defer allocator.free(response);
            const expected = "Hallo, das hier ist Index.html\r\nPage count = 1";
            std.testing.expectEqualStrings(expected, response);
        }
        if (true) {
            if (true) {
                const response = try client.requestAlloc("/index.html");
                defer allocator.free(response);
                const expected = "Hallo, das hier ist Index.html\r\nPage count = 2";
                std.testing.expectEqualStrings(expected, response);
            }
        }
        if (true) {
            if (true) {
                const response = try client.requestAlloc("/shutdown.html");
                defer allocator.free(response);
                const expected = "Ok, HTML server shutdown now.";
                std.testing.expectEqualStrings(expected, response);
            }
        }
    }
}
