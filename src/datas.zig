/// This zig file defines the data types that go into the 'database'.
const std = @import("std");
pub const Company = struct {
    name: []const u8,
    id: usize,
};

pub const EventType = enum {
    applied,
    interview,
    technical_phone_call,
    offer,
    rejection,
    recruiter_contact,
    other,
};

pub const Event = struct {
    date: []const u8,
    kind: EventType,
    notes: []const u8,
};

pub const DocumentType = enum {
    resume_doc,
    cover_letter,
    other,
};

pub const Document = struct {
    path: []const u8,
    kind: DocumentType,
    date: []const u8,
    submitted: bool,
    notes: []const u8,
};

pub const Application = struct {
    id: usize,
    company: Company,
    position: []const u8,
    date: []const u8,
    notes: []const u8,
    events: []const Event,
    documents: []const Document,

    pub fn getFinalEventType(self: @This()) ?EventType {
        // return the final event type
        if (self.events.len > 0) {
            return self.events[self.events.len - 1].kind;
        }
        return null;
    }
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    companies: std.ArrayList(Company),
    applications: std.ArrayList(Application),

    pub fn init(allocator: std.mem.Allocator) Database {
        return .{
            .allocator = allocator,
            .companies = .empty,
            .applications = .empty,
        };
    }

    pub fn deinit(self: *Database) void {
        // Note: Application.events/documents slices, if allocated, are not freed here.
        // Free per-application event/document arrays to avoid leaks in tests.
        for (self.applications.items) |app| {
            if (app.events.len > 0) self.allocator.free(@constCast(app.events));
            if (app.documents.len > 0) self.allocator.free(@constCast(app.documents));
        }
        self.companies.deinit(self.allocator);
        self.applications.deinit(self.allocator);
    }

    pub fn nextCompanyId(self: *Database) usize {
        return self.companies.items.len;
    }

    pub fn nextApplicationId(self: *Database) usize {
        return self.applications.items.len;
    }

    pub fn findCompanyById(self: *Database, id: usize) ?*Company {
        for (self.companies.items) |*c| {
            if (c.id == id) return c;
        }
        return null;
    }

    pub fn findApplicationById(self: *Database, id: usize) ?*Application {
        for (self.applications.items) |*a| {
            if (a.id == id) return a;
        }
        return null;
    }
};
