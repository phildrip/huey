pub const WEAR_MODE: bool = true;
const android_main = @import("android_main.zig");
comptime {
    _ = android_main;
}
