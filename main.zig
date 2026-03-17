const std = @import("std");
const fs = std.fs;
const time = std.time;

const PORT = 8080;
const MAX_FILE_SIZE = 2 * 1024 * 1024 * 1024;
const DEFAULT_RETENTION_SEC = 2 * 24 * 60 * 60;
const DATA_DIR = "/data";

fn parseTtl(ttl: []const u8) i64 {
    if (ttl.len < 2) return DEFAULT_RETENTION_SEC;
    const num = std.fmt.parseInt(i64, ttl[0 .. ttl.len - 1], 10) catch return DEFAULT_RETENTION_SEC;
    const unit = ttl[ttl.len - 1];
    return switch (unit) {
        'm' => num * 60,
        'h' => num * 60 * 60,
        'd' => num * 24 * 60 * 60,
        'w' => num * 7 * 24 * 60 * 60,
        'y' => num * 365 * 24 * 60 * 60,
        else => DEFAULT_RETENTION_SEC,
    };
}

const FileMeta = struct {
    path: []const u8,
    name: []const u8,
    size: u64,
    expires: i64,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var files = std.StringHashMap(FileMeta).init(allocator);
var mutex = std.Thread.Mutex{};

pub fn main() !void {
    try fs.cwd().makePath(DATA_DIR);

    const cleanup_thread = try std.Thread.spawn(.{}, cleanupTask, .{});
    _ = cleanup_thread;

    var server = std.net.StreamServer.init(.{ .reuse_address = true });
    try server.listen(try std.net.Address.parseIp4("0.0.0.0", PORT));

    std.log.info("Server listening on :{d}", .{PORT});

    while (true) {
        const conn = try server.accept();
        const thread = try std.Thread.spawn(.{}, handleConnection, .{conn});
        thread.detach();
    }
}

fn handleConnection(conn: std.net.StreamServer.Connection) !void {
    defer conn.stream.close();

    var buf: [8192]u8 = undefined;
    const n = try conn.stream.read(&buf);
    if (n == 0) return;

    const request = buf[0..n];
    const end_of_header = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return;

    const req_line = request[0..end_of_header];
    var parts = std.mem.split(u8, req_line, " ");
    const method = parts.next() orelse return;
    const path = parts.next() orelse return;

    if (std.mem.eql(u8, method, "GET")) {
        if (std.mem.eql(u8, path, "/")) {
            try serveIndex(conn);
        } else if (std.mem.startsWith(u8, path, "/s/")) {
            try serveFile(conn, path[3..]);
        } else {
            try send404(conn);
        }
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/upload")) {
        try handleUpload(conn, request, end_of_header + 4);
    } else {
        try send404(conn);
    }
}

fn serveIndex(conn: std.net.StreamServer.Connection) !void {
    const html = @embedFile("index.html");
    const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{html.len});
    defer allocator.free(response);
    try conn.stream.writeAll(response);
    try conn.stream.writeAll(html);
}

fn serveFile(conn: std.net.StreamServer.Connection, id: []const u8) !void {
    mutex.lock();
    const meta = files.get(id);
    mutex.unlock();

    if (meta == null) return send404(conn);
    const m = meta.?;

    if (time.timestamp() > m.expires) {
        mutex.lock();
        _ = files.remove(id);
        mutex.unlock();
        fs.cwd().deleteFile(m.path) catch {};
        const folder_path = fs.path.dirname(m.path);
        if (folder_path) |p| {
            fs.cwd().deleteDir(p) catch {};
        }
        return send404(conn);
    }

    const file = fs.cwd().openFile(m.path, .{}) catch return send404(conn);
    defer file.close();
    const stat = try file.stat();

    const header = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"{s}\"\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ m.name, stat.size });
    defer allocator.free(header);
    try conn.stream.writeAll(header);

    var buf: [8192]u8 = undefined;
    while (true) {
        const bytes = try file.read(&buf);
        if (bytes == 0) break;
        try conn.stream.writeAll(buf[0..bytes]);
    }
}

fn handleUpload(conn: std.net.StreamServer.Connection, request: []const u8, body_start: usize) !void {
    const header_end = std.mem.indexOf(u8, request, "\r\n\r\n").?;
    const headers = request[0..header_end];

    const content_len = blk: {
        var iter = std.mem.split(u8, headers, "\r\n");
        while (iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                break :blk try std.fmt.parseInt(u64, line[16..], 10);
            }
        }
        return sendError(conn, "Missing Content-Length");
    };

    const filename = blk: {
        var iter = std.mem.split(u8, headers, "\r\n");
        while (iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "X-Filename: ")) {
                break :blk try allocator.dupe(u8, line[12..]);
            }
        }
        break :blk try allocator.dupe(u8, "unnamed");
    };
    defer allocator.free(filename);

    const ttl = blk: {
        var iter = std.mem.split(u8, headers, "\r\n");
        while (iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "X-Ttl: ")) {
                break :blk try allocator.dupe(u8, line[7..]);
            }
        }
        break :blk try allocator.dupe(u8, "48h");
    };
    defer allocator.free(ttl);

    if (content_len > MAX_FILE_SIZE) return sendError(conn, "File too large");

    const id = try generateId();
    const folder_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ DATA_DIR, id });
    defer allocator.free(folder_path);
    try fs.cwd().makePath(folder_path);

    const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}.bin", .{ folder_path, id });
    defer allocator.free(filepath);

    const file = try fs.cwd().createFile(filepath, .{});
    defer file.close();

    var body_read: usize = 0;
    if (body_start < request.len) {
        const first_chunk = request[body_start..];
        try file.writeAll(first_chunk);
        body_read = first_chunk.len;
    }

    var buf: [8192]u8 = undefined;
    while (body_read < content_len) {
        const bytes = try conn.stream.read(&buf);
        if (bytes == 0) break;
        try file.writeAll(buf[0..bytes]);
        body_read += bytes;
    }

    const id_copy = try allocator.dupe(u8, id);
    const path_copy = try allocator.dupe(u8, filepath);

    mutex.lock();
    try files.put(id_copy, .{
        .path = path_copy,
        .name = try allocator.dupe(u8, filename),
        .size = body_read,
        .expires = time.timestamp() + parseTtl(ttl),
    });
    mutex.unlock();

    const resp = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"url\":\"/s/{s}\",\"name\":\"{s}\"}}", .{ id, id, filename });
    defer allocator.free(resp);

    const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ resp.len, resp });
    defer allocator.free(response);
    try conn.stream.writeAll(response);
}

fn send404(conn: std.net.StreamServer.Connection) !void {
    const body = "Not Found";
    const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
    defer allocator.free(response);
    try conn.stream.writeAll(response);
}

fn sendError(conn: std.net.StreamServer.Connection, msg: []const u8) !void {
    const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ msg.len, msg });
    defer allocator.free(response);
    try conn.stream.writeAll(response);
}

fn generateId() ![]const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var id: [8]u8 = undefined;
    var rand = std.rand.DefaultPrng.init(@intCast(time.milliTimestamp()));
    for (&id) |*c| {
        c.* = chars[rand.random().int(u8) % chars.len];
    }
    return try allocator.dupe(u8, &id);
}

fn cleanupTask() !void {
    while (true) {
        time.sleep(60 * time.ns_per_s);
        const now = time.timestamp();

        mutex.lock();
        var to_delete = std.ArrayList([]const u8).init(allocator);
        defer to_delete.deinit();

        var iter = files.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.expires < now) try to_delete.append(entry.key_ptr.*);
        }

        for (to_delete.items) |id| {
            if (files.getEntry(id)) |entry| {
                const path_copy = try allocator.dupe(u8, entry.value_ptr.path);
                const folder = fs.path.dirname(path_copy);
                fs.cwd().deleteFile(entry.value_ptr.path) catch {};
                if (folder) |p| {
                    fs.cwd().deleteDir(p) catch {};
                }
                allocator.free(path_copy);
                allocator.free(entry.value_ptr.path);
                allocator.free(entry.value_ptr.name);
                _ = files.remove(id);
                allocator.free(id);
            }
        }
        mutex.unlock();
    }
}
