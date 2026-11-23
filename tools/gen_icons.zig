const std = @import("std");
const huey = @import("huey");
const core = huey.core;
const headless = huey.headless;
const anim = huey.animation;

const DensitySpec = struct {
    dir: []const u8,
    size: u32,
};

const DENSITIES = [_]DensitySpec{
    .{ .dir = "mipmap-hdpi", .size = 72 },
    .{ .dir = "mipmap-xhdpi", .size = 96 },
    .{ .dir = "mipmap-xxhdpi", .size = 144 },
    .{ .dir = "mipmap-xxxhdpi", .size = 192 },
};

fn renderHueyIcon(allocator: std.mem.Allocator, size: u32, round_wear: bool) ![]u8 {
    const w_f: f32 = @floatFromInt(size);
    const clip = [4]f32{ 0.0, 0.0, w_f, w_f };

    var quads: [32]core.QuadInstance = undefined;
    var qn: usize = 0;

    // 1. Background canvas (squircle for tablet/phone, circular OLED bezel for Wear OS)
    if (round_wear) {
        // Pure OLED circle with Frost-tinted luminous rim
        const pad = w_f * 0.03;
        const d = w_f - pad * 2.0;
        quads[qn] = .{
            .pos_size = .{ pad, pad, d, d },
            .color = .{ 0.14, 0.17, 0.22, 1.0 },
            .border_color = core.Nord.frost_1,
            .params = .{ d * 0.5, @max(2.0, w_f * 0.025), 0.0, 0.0 },
            .clip_rect = clip,
        };
        qn += 1;

        // Subtle inner dark Polar Night depth ring
        const pad2 = w_f * 0.10;
        const d2 = w_f - pad2 * 2.0;
        quads[qn] = .{
            .pos_size = .{ pad2, pad2, d2, d2 },
            .color = core.Nord.polar_night_0,
            .border_color = .{ 0.29, 0.34, 0.42, 0.45 },
            .params = .{ d2 * 0.5, @max(1.0, w_f * 0.01), 0.0, 0.0 },
            .clip_rect = clip,
        };
        qn += 1;
    } else {
        // Deep Polar Night rounded squircle
        const pad = w_f * 0.05;
        const d = w_f - pad * 2.0;
        quads[qn] = .{
            .pos_size = .{ pad, pad, d, d },
            .color = core.Nord.polar_night_0,
            .border_color = .{ 0.53, 0.75, 0.82, 0.45 },
            .params = .{ d * 0.24, @max(1.5, w_f * 0.018), w_f * 0.03, 0.0 },
            .clip_rect = clip,
        };
        qn += 1;

        // Subtle inner elevated glass card
        const pad2 = w_f * 0.11;
        const d2 = w_f - pad2 * 2.0;
        quads[qn] = .{
            .pos_size = .{ pad2, pad2, d2, d2 },
            .color = .{ 0.19, 0.22, 0.28, 0.92 },
            .border_color = .{ 0.30, 0.34, 0.42, 0.35 },
            .params = .{ d2 * 0.20, @max(1.0, w_f * 0.008), 0.0, 0.0 },
            .clip_rect = clip,
        };
        qn += 1;
    }

    // 2. Stylized geometric "H" made of overlapping translucent Oklab glass panes
    // Safe zone centered inside [0.22..0.78] so circular & squircle masks never clip it!
    const pillar_w = w_f * 0.155;
    const pillar_h = w_f * 0.52;
    const pillar_y = (w_f - pillar_h) * 0.5;
    const left_x = w_f * 0.245;
    const right_x = w_f - left_x - pillar_w;
    const p_rad = pillar_w * 0.42;
    const bw = @max(1.2, w_f * 0.014);
    const blur = w_f * 0.035;

    // Left vertical pillar — Nord Frost Cyan
    quads[qn] = .{
        .pos_size = .{ left_x, pillar_y, pillar_w, pillar_h },
        .color = .{ core.Nord.frost_1[0], core.Nord.frost_1[1], core.Nord.frost_1[2], 0.94 },
        .border_color = .{ 0.92, 0.96, 0.99, 0.65 },
        .params = .{ p_rad, bw, blur, 0.0 },
        .clip_rect = clip,
    };
    qn += 1;

    // Right vertical pillar — Aurora Coral-Orange
    quads[qn] = .{
        .pos_size = .{ right_x, pillar_y, pillar_w, pillar_h },
        .color = .{ core.Nord.aurora_orange[0], core.Nord.aurora_orange[1], core.Nord.aurora_orange[2], 0.94 },
        .border_color = .{ 0.99, 0.90, 0.85, 0.65 },
        .params = .{ p_rad, bw, blur, 0.0 },
        .clip_rect = clip,
    };
    qn += 1;

    // Center horizontal glass bridge — Oklab Aurora Purple overlapping both pillars
    const bridge_x = left_x + pillar_w * 0.35;
    const bridge_w = (right_x + pillar_w * 0.65) - bridge_x;
    const bridge_h = w_f * 0.145;
    const bridge_y = (w_f - bridge_h) * 0.5;
    const bridge_col = anim.lerpColorOklab(core.Nord.frost_1, core.Nord.aurora_purple, 0.62);
    quads[qn] = .{
        .pos_size = .{ bridge_x, bridge_y, bridge_w, bridge_h },
        .color = .{ bridge_col[0], bridge_col[1], bridge_col[2], 0.92 },
        .border_color = .{ 0.95, 0.92, 0.99, 0.72 },
        .params = .{ bridge_h * 0.45, bw, blur * 0.85, 0.0 },
        .clip_rect = clip,
    };
    qn += 1;

    // Tiny luminous Aurora Green / Yellow accent dot in center of bridge (Huey's Oklab spark!)
    const dot_d = w_f * 0.058;
    const dot_x = (w_f - dot_d) * 0.5;
    const dot_y = (w_f - dot_d) * 0.5;
    quads[qn] = .{
        .pos_size = .{ dot_x, dot_y, dot_d, dot_d },
        .color = core.Nord.aurora_yellow,
        .border_color = .{ 1.0, 1.0, 1.0, 0.85 },
        .params = .{ dot_d * 0.5, @max(1.0, w_f * 0.008), w_f * 0.015, 0.0 },
        .clip_rect = clip,
    };
    qn += 1;

    // Rasterize with Huey's own exact linear-space CPU UberQuad rasterizer!
    const rgba = try allocator.alloc(u8, @as(usize, size) * @as(usize, size) * 4);
    defer allocator.free(rgba);
    @memset(rgba, 0);

    for (quads[0..qn]) |q| {
        headless.rasterizeQuad(rgba, size, size, q);
    }

    var out_w: std.Io.Writer.Allocating = .init(allocator);
    errdefer out_w.deinit();
    try headless.encodePng(&out_w.writer, size, size, rgba);
    return try out_w.toOwnedSlice();
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var io_threaded = std.Io.Threaded.init_single_threaded;
    const io = io_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var path_buf: [256]u8 = undefined;

    for (DENSITIES) |d| {
        // Tablet / Phone showcase icon
        const tab_png = try renderHueyIcon(alloc, d.size, false);
        defer alloc.free(tab_png);
        const tab_path = try std.fmt.bufPrint(&path_buf, "demos/android-showcase/res/{s}/ic_launcher.png", .{d.dir});
        try writeFile(tab_path, tab_png);

        // Wear OS circular watch icon
        const wear_png = try renderHueyIcon(alloc, d.size, true);
        defer alloc.free(wear_png);
        const wear_path = try std.fmt.bufPrint(&path_buf, "demos/wear-showcase/res/{s}/ic_launcher.png", .{d.dir});
        try writeFile(wear_path, wear_png);
    }

    // High-res repo logo for README / GitHub
    const logo_png = try renderHueyIcon(alloc, 512, false);
    defer alloc.free(logo_png);
    try writeFile("assets/huey-logo.png", logo_png);
}
