const std = @import("std");
const datas = @import("datas.zig");
const serialization = @import("serialization.zig");
const qe = @import("query_engine.zig");

pub fn run() !void {
    const gpa = std.heap.page_allocator;
    var args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // args[0] is program name.
    if (args.len < 2) {
        try printUsage();
        return;
    }

    var serializer = serialization.Serializer.init(gpa);
    defer serializer.deinit();

    // Optional: --db <path>
    var i: usize = 1;
    var db_path: []const u8 = "applications.db";
    while (i + 1 < args.len and std.mem.eql(u8, std.mem.sliceTo(args[i], 0), "--db")) : (i += 2) {
        db_path = std.mem.sliceTo(args[i + 1], 0);
    }

    var db = try serializer.loadDatabase(db_path);
    defer db.deinit();

    var engine = qe.QueryEngine.init(gpa, &db);

    if (i >= args.len) {
        try printUsage();
        return;
    }
    const cmd = std.mem.sliceTo(args[i], 0);

    if (std.mem.eql(u8, cmd, "select")) {
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try engine.select(stdout);
        try stdout.flush();
        return;
    } else if (std.mem.eql(u8, cmd, "insert")) {
        try handleInsert(&engine, args[(i + 1)..]);
    } else if (std.mem.eql(u8, cmd, "update")) {
        try handleUpdate(&engine, args[(i + 1)..]);
    } else {
        try printUsage();
        return;
    }

    // Save after mutating commands.
    try serializer.saveDatabase(db_path, &db);
}

fn handleInsert(engine: *qe.QueryEngine, tail: []const [:0]u8) !void {
    if (tail.len == 0) return error.InvalidArguments;
    const kind = std.mem.sliceTo(tail[0], 0);
    if (std.mem.eql(u8, kind, "company")) {
        if (tail.len < 2) return error.InvalidArguments;
        const name = std.mem.sliceTo(tail[1], 0);
        const id = try engine.insertCompany(name);
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("company inserted id={d}\n", .{id});
        try stdout.flush();
        return;
    } else if (std.mem.eql(u8, kind, "application")) {
        var company_id_opt: ?usize = null;
        var position: ?[]const u8 = null;
        var date: ?[]const u8 = null;
        var notes: []const u8 = "";
        var j: usize = 1;
        while (j < tail.len) : (j += 1) {
            const arg = std.mem.sliceTo(tail[j], 0);
            if (std.mem.eql(u8, arg, "--company-id")) {
                if (j + 1 >= tail.len) return error.InvalidCompanyId;
                company_id_opt = try parseUsize(std.mem.sliceTo(tail[j + 1], 0));
                j += 1;
            } else if (std.mem.eql(u8, arg, "--position")) {
                if (j + 1 >= tail.len) return error.InvalidPosition;
                position = std.mem.sliceTo(tail[j + 1], 0);
                j += 1;
            } else if (std.mem.eql(u8, arg, "--date")) {
                if (j + 1 >= tail.len) return error.InvalidDate;
                date = std.mem.sliceTo(tail[j + 1], 0);
                j += 1;
            } else if (std.mem.eql(u8, arg, "--notes")) {
                if (j + 1 >= tail.len) return error.InvalidNotes;
                notes = std.mem.sliceTo(tail[j + 1], 0);
                j += 1;
            } else {
                return error.InvalidArgument;
            }
        }
        const company_id = company_id_opt orelse return error.InvalidArguments;
        const pos = position orelse return error.InvalidArguments;
        const d = date orelse return error.InvalidArguments;
        const id = try engine.insertApplication(company_id, pos, d, notes);
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("application inserted id={d}\n", .{id});
        try stdout.flush();
        return;
    }
    return error.InvalidArguments;
}

fn handleUpdate(engine: *qe.QueryEngine, tail: []const [:0]u8) !void {
    if (tail.len < 2) return error.InvalidArguments;
    const app_id = try parseUsize(std.mem.sliceTo(tail[0], 0));
    const kind = std.mem.sliceTo(tail[1], 0);
    if (std.mem.eql(u8, kind, "event")) {
        var date: ?[]const u8 = null;
        var notes: []const u8 = "";
        var etype: ?datas.EventType = null;
        var j: usize = 2;
        while (j < tail.len) : (j += 1) {
            const arg = std.mem.sliceTo(tail[j], 0);
            if (std.mem.eql(u8, arg, "--date")) {
                if (j + 1 >= tail.len) return error.InvalidArguments;
                date = std.mem.sliceTo(tail[j + 1], 0);
                j += 1;
            } else if (std.mem.eql(u8, arg, "--type")) {
                if (j + 1 >= tail.len) return error.InvalidArguments;
                etype = try parseEventType(std.mem.sliceTo(tail[j + 1], 0));
                j += 1;
            } else if (std.mem.eql(u8, arg, "--notes")) {
                if (j + 1 >= tail.len) return error.InvalidArguments;
                notes = std.mem.sliceTo(tail[j + 1], 0);
                j += 1;
            } else return error.InvalidArguments;
        }
        try engine.addEvent(app_id, date orelse return error.InvalidArguments, etype orelse return error.InvalidArguments, notes);
        return;
    } else if (std.mem.eql(u8, kind, "document")) {
        var path: ?[]const u8 = null;
        var date: ?[]const u8 = null;
        var notes: []const u8 = "";
        var dtype: ?datas.DocumentType = null;
        var submitted: bool = false;
        var j: usize = 2;
        while (j < tail.len) : (j += 1) {
            const arg = std.mem.sliceTo(tail[j], 0);
            if (std.mem.eql(u8, arg, "--path")) {
                if (j + 1 >= tail.len) return error.InvalidArguments;
                path = std.mem.sliceTo(tail[j + 1], 0);
                j += 1;
            } else if (std.mem.eql(u8, arg, "--type")) {
                if (j + 1 >= tail.len) return error.InvalidArguments;
                dtype = try parseDocumentType(std.mem.sliceTo(tail[j + 1], 0));
                j += 1;
            } else if (std.mem.eql(u8, arg, "--date")) {
                if (j + 1 >= tail.len) return error.InvalidArguments;
                date = std.mem.sliceTo(tail[j + 1], 0);
                j += 1;
            } else if (std.mem.eql(u8, arg, "--submitted")) {
                if (j + 1 >= tail.len) return error.InvalidArguments;
                submitted = try parseBool(std.mem.sliceTo(tail[j + 1], 0));
                j += 1;
            } else if (std.mem.eql(u8, arg, "--notes")) {
                if (j + 1 >= tail.len) return error.InvalidArguments;
                notes = std.mem.sliceTo(tail[j + 1], 0);
                j += 1;
            } else return error.InvalidArguments;
        }
        try engine.addDocument(
            app_id,
            path orelse return error.InvalidArguments,
            dtype orelse return error.InvalidArguments,
            date orelse return error.InvalidArguments,
            submitted,
            notes,
        );
        return;
    }
    return error.InvalidArguments;
}

fn parseUsize(s: []const u8) !usize {
    return try std.fmt.parseInt(usize, s, 10);
}

fn parseBool(s: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false")) return false;
    return error.InvalidArguments;
}

fn parseEventType(s: []const u8) !datas.EventType {
    inline for (std.meta.fields(datas.EventType)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(datas.EventType, f.name);
    }
    return error.InvalidArguments;
}

fn parseDocumentType(s: []const u8) !datas.DocumentType {
    // Accept common aliases and case-insensitive matches
    if (std.ascii.eqlIgnoreCase(s, "resume") or std.ascii.eqlIgnoreCase(s, "cv") or std.ascii.eqlIgnoreCase(s, "resume_doc") or std.ascii.eqlIgnoreCase(s, "resume-document"))
        return datas.DocumentType.resume_doc;

    if (std.ascii.eqlIgnoreCase(s, "cover_letter") or std.ascii.eqlIgnoreCase(s, "cover-letter") or std.ascii.eqlIgnoreCase(s, "coverletter") or std.ascii.eqlIgnoreCase(s, "cover"))
        return datas.DocumentType.cover_letter;

    if (std.ascii.eqlIgnoreCase(s, "other"))
        return datas.DocumentType.other;

    // Fallback to enum names (case-sensitive and case-insensitive)
    inline for (std.meta.fields(datas.DocumentType)) |f| {
        if (std.mem.eql(u8, s, f.name) or std.ascii.eqlIgnoreCase(s, f.name))
            return @field(datas.DocumentType, f.name);
    }

    return error.InvalidArguments;
}

fn printUsage() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const w = &stdout_writer.interface;
    try w.print(
        "Usage:\n  applications [--db <path>] select\n  applications [--db <path>] insert company <name>\n  applications [--db <path>] insert application --company-id <id> --position <text> --date <date> [--notes <text>]\n  applications [--db <path>] update <application-id> event --date <date> --type <EventType> [--notes <text>]\n  applications [--db <path>] update <application-id> document --path <path> --type <DocumentType> --date <date> --submitted <true|false> [--notes <text>]\n",
        .{},
    );
    try w.flush();
}
