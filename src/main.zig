const std = @import("std");
const cli = @import("cli.zig");

pub fn main() !void {
    try cli.run();
}

test "import submodule tests" {
    _ = @import("serialization.zig");
    _ = @import("query_engine.zig");
}
