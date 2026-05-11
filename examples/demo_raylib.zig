const std = @import("std");
const compecs = @import("compecs");
const rl = @import("raylib");

const TagPlayer = struct {};
const TagGravity = struct {};

const Pos = struct { x: f32, y: f32 };
const Vel = struct { dx: f32, dy: f32 };
const Appereance = struct { radius: f32, color: rl.Color };

const GameState = struct {
    dt: f32,
    screen_w: f32,
    screen_h: f32,
};

const InputState = struct {
    move_x: f32,
    move_y: f32,
    mouse_x: f32,
    mouse_y: f32,
    is_shooting: bool,
};

const WSetup = compecs.World(&.{ Pos, Vel, Appereance, TagPlayer, TagGravity }, &.{ GameState, InputState } // singletons
);

fn sysPlayerControl(v: *Vel, input: *const InputState, _: *const TagPlayer) void {
    const speed = 300.0;

    v.dx = input.move_x * speed;
    v.dy = input.move_y * speed;
}

fn sysGravity(v: *Vel, state: *const GameState, _: *const TagGravity) void {
    v.dy += 900.0 * state.dt;
}

fn sysMovAndBounds(pos: *Pos, v: *Vel, app_opt: ?*const Appereance, state: *const GameState) void {
    pos.x += v.dx * state.dt;
    pos.y += v.dy * state.dt;

    const radius = if (app_opt) |a| a.radius else 2.0;

    const bounce_loss = 0.9;

    // Left and right bounce
    if (pos.x - radius < 0.0) {
        pos.x = radius;
        v.dx *= -bounce_loss;
    } else if (pos.x + radius > state.screen_w) {
        pos.x = state.screen_w - radius;
        v.dx *= -bounce_loss;
    }

    // Floor and ceil bounce
    if (pos.y - radius < 0.0) {
        pos.y = radius;
        v.dy *= -bounce_loss;
    } else if (pos.y + radius > state.screen_h) {
        pos.y = state.screen_h - radius;
        v.dy *= -bounce_loss;

        // If ball rub via ceil then bounce_loss horizontal mov with rubbing
        v.dx *= 0.99;
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    rl.setConfigFlags(rl.ConfigFlags{ .window_resizable = true, .msaa_4x_hint = true });
    rl.initWindow(1024, 768, "Test compecs lib");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    var world = WSetup.init(alloc);

    // Free all except command-buffer
    defer world.deinit();

    world.setResource(GameState{ .dt = 0.0, .screen_w = 1024, .screen_h = 768 });
    world.setResource(InputState{ .move_x = 0, .move_y = 0, .mouse_x = 0, .mouse_y = 0, .is_shooting = false });

    const player = try world.createEntity();
    try world.addComponent(player, Pos{ .x = 513, .y = 385 });
    try world.addComponent(player, Vel{ .dx = 0, .dy = 0 });
    try world.addComponent(player, Appereance{ .radius = 30, .color = rl.Color.black });
    try world.addComponent(player, TagPlayer{});

    var prng = std.Random.DefaultPrng.init(12345);
    const rng = prng.random();

    while (!rl.windowShouldClose()) {
        // Receive physic button before working system
        var in_st = InputState{ .move_x = 0, .move_y = 0, .mouse_x = 0, .mouse_y = 0, .is_shooting = false };

        if (rl.isKeyDown(rl.KeyboardKey.a)) in_st.move_x -= 1.0;
        if (rl.isKeyDown(rl.KeyboardKey.d)) in_st.move_x += 1.0;
        if (rl.isKeyDown(rl.KeyboardKey.w)) in_st.move_y -= 1.0;
        if (rl.isKeyDown(rl.KeyboardKey.s)) in_st.move_y += 1.0;

        in_st.is_shooting = rl.isMouseButtonDown(rl.MouseButton.left);
        const mp = rl.getMousePosition();
        in_st.mouse_x = mp.x;
        in_st.mouse_y = mp.y;

        world.setResource(in_st);

        world.setResource(GameState{
            .dt = rl.getFrameTime(),
            .screen_w = @floatFromInt(rl.getScreenWidth()),
            .screen_h = @floatFromInt(rl.getScreenHeight()),
        });

        if (in_st.is_shooting) {
            // Spawn 20 physic entity each 1/60 sec while hold mouse - 1200+ entity in sec
            for (0..20) |_| {
                const bullet = try world.createEntity();

                // Spawn with drifting in hand player
                try world.addComponent(bullet, Pos{ .x = in_st.mouse_x + (rng.float(f32) * 8.0 - 3.0), .y = in_st.mouse_y });

                try world.addComponent(bullet, Vel{
                    .dx = rng.float(f32) * 800.0 - 300.0,
                    .dy = rng.float(f32) * -800.0,
                });

                try world.addComponent(bullet, TagGravity{});

                const c = rl.Color{ .r = rng.intRangeAtMost(u8, 130, 255), .g = rng.intRangeAtMost(u8, 30, 60), .b = 40, .a = 255 };

                try world.addComponent(bullet, Appereance{ .radius = rng.float(f32) * 3.0 + 4.0, .color = c });
            }
        }

        // When press 'R' - radiowave that burn all ball which located left from mouse
        if (rl.isKeyPressed(rl.KeyboardKey.r)) {
            var q_radar = try world.query(.{ compecs.Entity, *Pos, *const TagGravity });

            while (q_radar.next()) |item| {
                if (item[1].x < in_st.mouse_x) try world.cmdDestroy(item[0]);
            }
        }

        try world.scheduleBatchExec(.{ sysPlayerControl, sysGravity, sysMovAndBounds });

        // Delete old with button 'R' and create arr bullet linking with mouse
        world.flushCommands();

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color{ .r = 30, .g = 25, .b = 30, .a = 255 }); // dark

        // ECS save 'Appereance' in cache_friendly array
        var graphics_bus = try world.query(.{ *const Pos, *const Appereance });

        while (graphics_bus.next()) |entry| {
            // Entry - Tuple
            // Index '0' - '*const Pos', '1' - '*const Appereance'
            const cur_pos = entry[0];
            const render_cmp = entry[1];

            rl.drawCircle(@intFromFloat(cur_pos.x), @intFromFloat(cur_pos.y), render_cmp.radius, render_cmp.color);
        }

        const active_ents_count = world.entity_idx.items.len - world.free_entities.items.len;

        // Stack-buffer for formatting str in 'C'
        var text_buf: [100]u8 = undefined;

        if (std.fmt.bufPrint(&text_buf, "All active entities: {d}", .{active_ents_count})) |rendered_text| {
            // Null terminator
            text_buf[rendered_text.len] = 0;

            const final_slice = text_buf[0..rendered_text.len :0];

            rl.drawText(final_slice, 13, 83, 23, rl.Color.magenta);
        } else |_| {}

        rl.drawFPS(15, 15);
    }
}
