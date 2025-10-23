const std = @import("std");
const datas = @import("datas.zig");

pub const QueryEngine = struct {
    allocator: std.mem.Allocator,
    db: *datas.Database,

    pub fn init(allocator: std.mem.Allocator, db: *datas.Database) QueryEngine {
        return .{ .allocator = allocator, .db = db };
    }

    pub fn select(self: *QueryEngine, writer: anytype) !void {
        // Emit labeled fields for readability
        // Companies
        for (self.db.companies.items) |c| {
            try writer.print("C|id={d}|name={s}\n", .{ c.id, c.name });
        }
        // Applications
        for (self.db.applications.items) |a| {
            try writer.print(
                "A|id={d}|company_id={d}|position={s}|date={s}|notes={s}\n",
                .{ a.id, a.company.id, a.position, a.date, a.notes },
            );
        }
        // Events and Documents grouped by application
        for (self.db.applications.items) |a| {
            for (a.events) |ev| {
                try writer.print(
                    "E|application_id={d}|date={s}|kind={s}|notes={s}\n",
                    .{ a.id, ev.date, @tagName(ev.kind), ev.notes },
                );
            }
            for (a.documents) |doc| {
                try writer.print(
                    "D|application_id={d}|path={s}|kind={s}|date={s}|submitted={s}|notes={s}\n",
                    .{ a.id, doc.path, @tagName(doc.kind), doc.date, if (doc.submitted) "true" else "false", doc.notes },
                );
            }
        }
    }

    pub fn insertCompany(self: *QueryEngine, name: []const u8) !usize {
        const id = self.db.nextCompanyId();
        try self.db.companies.append(self.db.allocator, .{ .name = name, .id = id });
        return id;
    }

    pub fn insertApplication(
        self: *QueryEngine,
        company_id: usize,
        position: []const u8,
        date: []const u8,
        notes: []const u8,
    ) !usize {
        const company = self.db.findCompanyById(company_id) orelse return error.CompanyNotFound;
        const id = self.db.nextApplicationId();
        const empty_events: []const datas.Event = &[_]datas.Event{};
        const empty_docs: []const datas.Document = &[_]datas.Document{};
        try self.db.applications.append(self.db.allocator, .{
            .id = id,
            .company = company.*,
            .position = position,
            .date = date,
            .notes = notes,
            .events = empty_events,
            .documents = empty_docs,
        });
        return id;
    }

    pub fn addEvent(
        self: *QueryEngine,
        application_id: usize,
        date: []const u8,
        kind: datas.EventType,
        notes: []const u8,
    ) !void {
        const app = self.db.findApplicationById(application_id) orelse return error.ApplicationNotFound;
        const new_len = app.events.len + 1;
        var new_events = try self.allocator.alloc(datas.Event, new_len);
        std.mem.copyForwards(datas.Event, new_events[0..app.events.len], app.events);
        new_events[new_len - 1] = .{ .date = date, .kind = kind, .notes = notes };
        app.events = new_events;
    }

    pub fn addDocument(
        self: *QueryEngine,
        application_id: usize,
        path: []const u8,
        kind: datas.DocumentType,
        date: []const u8,
        submitted: bool,
        notes: []const u8,
    ) !void {
        const app = self.db.findApplicationById(application_id) orelse return error.ApplicationNotFound;
        const new_len = app.documents.len + 1;
        var new_docs = try self.allocator.alloc(datas.Document, new_len);
        std.mem.copyForwards(datas.Document, new_docs[0..app.documents.len], app.documents);
        new_docs[new_len - 1] = .{ .path = path, .kind = kind, .date = date, .submitted = submitted, .notes = notes };
        app.documents = new_docs;
    }
};

test "query engine: insert company and application, then add event and document" {
    const gpa = std.testing.allocator;
    var db = datas.Database.init(gpa);
    defer db.deinit();

    var engine = QueryEngine.init(gpa, &db);
    const comp_id = try engine.insertCompany("Acme");
    try std.testing.expectEqual(@as(usize, 0), comp_id);

    const app_id = try engine.insertApplication(comp_id, "SWE", "2025-10-21", "initial");
    try std.testing.expectEqual(@as(usize, 0), app_id);

    try engine.addEvent(app_id, "2025-10-22", datas.EventType.applied, "submitted");
    try engine.addDocument(app_id, "/tmp/resume.pdf", datas.DocumentType.resume_doc, "2025-10-21", true, "v1");

    const app = db.findApplicationById(app_id).?;
    try std.testing.expectEqual(@as(usize, 1), app.events.len);
    try std.testing.expectEqual(@as(usize, 1), app.documents.len);
}

test "query engine: insert application requires existing company" {
    const gpa = std.testing.allocator;
    var db = datas.Database.init(gpa);
    defer db.deinit();
    var engine = QueryEngine.init(gpa, &db);
    try std.testing.expectError(error.CompanyNotFound, engine.insertApplication(123, "SWE", "2025-10-21", "initial"));
}

test "query engine: update requires existing application" {
    const gpa = std.testing.allocator;
    var db = datas.Database.init(gpa);
    defer db.deinit();
    var engine = QueryEngine.init(gpa, &db);
    try std.testing.expectError(error.ApplicationNotFound, engine.addEvent(5, "2025-10-22", datas.EventType.applied, "x"));
    try std.testing.expectError(error.ApplicationNotFound, engine.addDocument(5, "/tmp/x", datas.DocumentType.cover_letter, "2025-10-21", false, "y"));
}

test "query engine: select prints full DB in line format" {
    const gpa = std.testing.allocator;
    var db = datas.Database.init(gpa);
    defer db.deinit();

    var engine = QueryEngine.init(gpa, &db);
    const cid = try engine.insertCompany("Acme");
    const app_id = try engine.insertApplication(cid, "SWE", "2025-10-21", "n");
    try engine.addEvent(app_id, "2025-10-22", datas.EventType.applied, "submitted");
    try engine.addDocument(app_id, "/tmp/resume.pdf", datas.DocumentType.resume_doc, "2025-10-21", true, "v1");

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    try engine.select(w);

    const out = stream.getWritten();
    const expected1 = "C|id=0|name=Acme\nA|id=0|company_id=0|position=SWE|date=2025-10-21|notes=n\n";
    try std.testing.expect(std.mem.startsWith(u8, out, expected1));
    // Expect some E and D lines present with labels
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "E|application_id=0|date=2025-10-22|kind=applied|notes=submitted\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "D|application_id=0|path=/tmp/resume.pdf|kind=resume_doc|date=2025-10-21|submitted=true|notes=v1\n"));
}
