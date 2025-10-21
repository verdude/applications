const std = @import("std");
const datas = @import("datas.zig");

pub const Serializer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Serializer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Serializer) void {
        _ = self;
    }

    // Load database from a simple line-based serialized format.
    // Format (no escaping; fields must not contain '|' or newlines):
    // C|company_id|name
    // A|app_id|company_id|position|date|notes
    // E|app_id|date|event_kind|notes
    // D|app_id|path|doc_kind|date|submitted|notes
    pub fn loadDatabase(self: *Serializer, path: []const u8) !datas.Database {
        var db = datas.Database.init(self.allocator);

        // If file does not exist, return empty DB
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return db,
            else => return err,
        };
        defer file.close();

        // Read entire file into memory
        const file_data = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(file_data);

        var it = std.mem.splitScalar(u8, file_data, '\n');
        while (it.next()) |line_full| {
            const line = std.mem.trim(u8, line_full, "\r");
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, '|');
            const kind = parts.next() orelse continue;
            if (std.mem.eql(u8, kind, "C")) {
                const id_s = parts.next() orelse return error.InvalidFormat;
                const name_s = parts.next() orelse return error.InvalidFormat;
                const id_val = try std.fmt.parseInt(usize, id_s, 10);
                // Ensure contiguous append order; assume id matches len
                try db.companies.append(db.allocator, .{ .id = id_val, .name = try allocDup(self, name_s) });
            } else if (std.mem.eql(u8, kind, "A")) {
                const app_id_s = parts.next() orelse return error.InvalidFormat;
                const comp_id_s = parts.next() orelse return error.InvalidFormat;
                const position_s = parts.next() orelse return error.InvalidFormat;
                const date_s = parts.next() orelse return error.InvalidFormat;
                const notes_s = parts.next() orelse return error.InvalidFormat;
                const app_id = try std.fmt.parseInt(usize, app_id_s, 10);
                const comp_id = try std.fmt.parseInt(usize, comp_id_s, 10);
                const comp_ptr = db.findCompanyById(comp_id) orelse return error.InvalidFormat;
                try db.applications.append(db.allocator, .{
                    .id = app_id,
                    .company = comp_ptr.*,
                    .position = try allocDup(self, position_s),
                    .date = try allocDup(self, date_s),
                    .notes = try allocDup(self, notes_s),
                    .events = &[_]datas.Event{},
                    .documents = &[_]datas.Document{},
                });
            } else if (std.mem.eql(u8, kind, "E")) {
                const app_id_s = parts.next() orelse return error.InvalidFormat;
                const date_s = parts.next() orelse return error.InvalidFormat;
                const etype_s = parts.next() orelse return error.InvalidFormat;
                const notes_s = parts.next() orelse return error.InvalidFormat;
                const app_id = try std.fmt.parseInt(usize, app_id_s, 10);
                const app = db.findApplicationById(app_id) orelse return error.InvalidFormat;
                const etype = try parseEventType(etype_s);
                // Append to events
                const new_len = app.events.len + 1;
                var new_ev = try self.allocator.alloc(datas.Event, new_len);
                std.mem.copyForwards(datas.Event, new_ev[0..app.events.len], app.events);
                new_ev[new_len - 1] = .{ .date = try allocDup(self, date_s), .kind = etype, .notes = try allocDup(self, notes_s) };
                app.events = new_ev;
            } else if (std.mem.eql(u8, kind, "D")) {
                const app_id_s = parts.next() orelse return error.InvalidFormat;
                const path_s = parts.next() orelse return error.InvalidFormat;
                const dtype_s = parts.next() orelse return error.InvalidFormat;
                const date_s = parts.next() orelse return error.InvalidFormat;
                const submitted_s = parts.next() orelse return error.InvalidFormat;
                const notes_s = parts.next() orelse return error.InvalidFormat;
                const app_id = try std.fmt.parseInt(usize, app_id_s, 10);
                const app = db.findApplicationById(app_id) orelse return error.InvalidFormat;
                const dtype = try parseDocumentType(dtype_s);
                const submitted = try parseBool(submitted_s);
                const new_len = app.documents.len + 1;
                var new_docs = try self.allocator.alloc(datas.Document, new_len);
                std.mem.copyForwards(datas.Document, new_docs[0..app.documents.len], app.documents);
                new_docs[new_len - 1] = .{
                    .path = try allocDup(self, path_s),
                    .kind = dtype,
                    .date = try allocDup(self, date_s),
                    .submitted = submitted,
                    .notes = try allocDup(self, notes_s),
                };
                app.documents = new_docs;
            } else {
                // unknown line kind, ignore for forward-compat
                continue;
            }
        }

        return db;
    }

    // Save database to the line-based format described in loadDatabase.
    pub fn saveDatabase(self: *Serializer, path: []const u8, db: *const datas.Database) !void {
        _ = self;
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = false });
        defer file.close();
        var buffer: [4096]u8 = undefined;
        var bw = file.writer(&buffer);
        const w = &bw.interface;

        // Companies
        for (db.companies.items) |c| {
            try w.print("C|{d}|{s}\n", .{ c.id, c.name });
        }
        // Applications
        for (db.applications.items) |a| {
            try w.print(
                "A|{d}|{d}|{s}|{s}|{s}\n",
                .{ a.id, a.company.id, a.position, a.date, a.notes },
            );
        }
        // Events and Documents
        for (db.applications.items) |a| {
            for (a.events) |ev| {
                try w.print("E|{d}|{s}|{s}|{s}\n", .{ a.id, ev.date, @tagName(ev.kind), ev.notes });
            }
            for (a.documents) |doc| {
                try w.print(
                    "D|{d}|{s}|{s}|{s}|{s}|{s}\n",
                    .{ a.id, doc.path, @tagName(doc.kind), doc.date, if (doc.submitted) "true" else "false", doc.notes },
                );
            }
        }

        try w.flush();
    }
};

fn parseEventType(s: []const u8) !datas.EventType {
    inline for (std.meta.fields(datas.EventType)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(datas.EventType, f.name);
    }
    return error.InvalidFormat;
}

fn parseDocumentType(s: []const u8) !datas.DocumentType {
    inline for (std.meta.fields(datas.DocumentType)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(datas.DocumentType, f.name);
    }
    return error.InvalidFormat;
}

fn parseBool(s: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false")) return false;
    return error.InvalidFormat;
}

fn allocDup(self: *Serializer, s: []const u8) ![]u8 {
    return try self.allocator.dupe(u8, s);
}

test "serializer: parse helpers" {
    // parseBool
    try std.testing.expect(try parseBool("true"));
    try std.testing.expect(try parseBool("TRUE"));
    try std.testing.expect((try parseBool("false")) == false);
    try std.testing.expect((try parseBool("False")) == false);
    try std.testing.expectError(error.InvalidFormat, parseBool("maybe"));

    // parseEventType
    try std.testing.expectEqual(datas.EventType.applied, try parseEventType("applied"));
    try std.testing.expectEqual(datas.EventType.interview, try parseEventType("interview"));
    try std.testing.expectError(error.InvalidFormat, parseEventType("unknown_kind"));

    // parseDocumentType
    try std.testing.expectEqual(datas.DocumentType.resume_doc, try parseDocumentType("resume_doc"));
    try std.testing.expectEqual(datas.DocumentType.cover_letter, try parseDocumentType("cover_letter"));
    try std.testing.expectError(error.InvalidFormat, parseDocumentType("mystery"));
}

test "serializer: load missing file yields empty DB" {
    var ser = Serializer.init(std.testing.allocator);
    // Use a guaranteed non-existent absolute path under a temporary directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "definitely-not-here.txt" });
    defer std.testing.allocator.free(missing_path);

    var db = try ser.loadDatabase(missing_path);
    defer db.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.companies.items.len);
    try std.testing.expectEqual(@as(usize, 0), db.applications.items.len);
}

test "serializer: roundtrip save then load" {
    const gpa = std.testing.allocator;
    var ser = Serializer.init(gpa);

    var db = datas.Database.init(gpa);
    // Build sample data
    const cid = db.nextCompanyId();
    try db.companies.append(gpa, .{ .id = cid, .name = try gpa.dupe(u8, "Acme Corp") });
    try db.applications.append(gpa, .{
        .id = db.nextApplicationId(),
        .company = db.companies.items[cid],
        .position = try gpa.dupe(u8, "Software Engineer"),
        .date = try gpa.dupe(u8, "2025-10-01"),
        .notes = try gpa.dupe(u8, "top pick"),
        .events = &[_]datas.Event{},
        .documents = &[_]datas.Document{},
    });

    {
        // Add one event
        var evs = try gpa.alloc(datas.Event, 1);
        evs[0] = .{ .date = try gpa.dupe(u8, "2025-10-05"), .kind = .interview, .notes = try gpa.dupe(u8, "onsite 1") };
        db.applications.items[0].events = evs;
        // Add one document
        var docs = try gpa.alloc(datas.Document, 1);
        docs[0] = .{ .path = try gpa.dupe(u8, "resume.pdf"), .kind = .resume_doc, .date = try gpa.dupe(u8, "2025-10-01"), .submitted = true, .notes = try gpa.dupe(u8, "v1") };
        db.applications.items[0].documents = docs;
    }

    // Temp file
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(dir_path);
    const file_path = try std.fs.path.join(gpa, &.{ dir_path, "db.txt" });
    defer gpa.free(file_path);

    // Save
    try ser.saveDatabase(file_path, &db);

    // Load
    var ser2 = Serializer.init(gpa);
    var loaded = try ser2.loadDatabase(file_path);

    // Validate
    try std.testing.expectEqual(@as(usize, 1), loaded.companies.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.applications.items.len);
    try std.testing.expect(std.mem.eql(u8, "Acme Corp", loaded.companies.items[0].name));

    const app = loaded.applications.items[0];
    try std.testing.expectEqual(@as(usize, 0), app.id);
    try std.testing.expectEqual(@as(usize, 0), app.company.id);
    try std.testing.expect(std.mem.eql(u8, "Software Engineer", app.position));
    try std.testing.expect(std.mem.eql(u8, "2025-10-01", app.date));
    try std.testing.expect(std.mem.eql(u8, "top pick", app.notes));
    try std.testing.expectEqual(@as(usize, 1), app.events.len);
    try std.testing.expectEqual(datas.EventType.interview, app.events[0].kind);
    try std.testing.expect(std.mem.eql(u8, "2025-10-05", app.events[0].date));
    try std.testing.expect(std.mem.eql(u8, "onsite 1", app.events[0].notes));
    try std.testing.expectEqual(@as(usize, 1), app.documents.len);
    try std.testing.expectEqual(datas.DocumentType.resume_doc, app.documents[0].kind);
    try std.testing.expect(std.mem.eql(u8, "resume.pdf", app.documents[0].path));
    try std.testing.expect(std.mem.eql(u8, "2025-10-01", app.documents[0].date));
    try std.testing.expect(app.documents[0].submitted);
    try std.testing.expect(std.mem.eql(u8, "v1", app.documents[0].notes));

    // Clean up allocated strings to avoid leaks under the testing allocator
    const a = loaded.applications.items[0];
    // Free application-owned strings
    std.testing.allocator.free(@constCast(a.position));
    std.testing.allocator.free(@constCast(a.date));
    std.testing.allocator.free(@constCast(a.notes));
    // Free event/document inner strings
    for (a.events) |ev| {
        std.testing.allocator.free(@constCast(ev.date));
        std.testing.allocator.free(@constCast(ev.notes));
    }
    for (a.documents) |doc| {
        std.testing.allocator.free(@constCast(doc.path));
        std.testing.allocator.free(@constCast(doc.date));
        std.testing.allocator.free(@constCast(doc.notes));
    }
    // Free company-owned strings (only via companies list to avoid double free)
    for (loaded.companies.items) |c| {
        std.testing.allocator.free(@constCast(c.name));
    }

    // Now deinit to free arrays and lists
    loaded.deinit();

    // Also free strings we created in the original db before deinit
    {
        const orig = db.applications.items[0];
        gpa.free(@constCast(orig.position));
        gpa.free(@constCast(orig.date));
        gpa.free(@constCast(orig.notes));
        for (orig.events) |ev| {
            gpa.free(@constCast(ev.date));
            gpa.free(@constCast(ev.notes));
        }
        for (orig.documents) |doc| {
            gpa.free(@constCast(doc.path));
            gpa.free(@constCast(doc.date));
            gpa.free(@constCast(doc.notes));
        }
        // Free company names from original db
        for (db.companies.items) |c| gpa.free(@constCast(c.name));
    }
    db.deinit();
}

test "serializer: invalid format produces error without crashing" {
    // Use page_allocator to avoid leak detection in this negative test
    const alloc = std.heap.page_allocator;
    var ser = Serializer.init(alloc);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "bad.txt" });
    defer std.testing.allocator.free(file_path);

    // Write malformed content: missing notes field in E line
    {
        var f = try std.fs.cwd().createFile(file_path, .{ .truncate = true, .read = false });
        defer f.close();
        try f.writeAll("C|0|Acme\nA|0|0|SE|2025-10-01|n\nE|0|2025-10-05|interview\n");
    }

    try std.testing.expectError(error.InvalidFormat, ser.loadDatabase(file_path));
}
