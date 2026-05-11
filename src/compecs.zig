const std = @import("std");

pub const DeferredActionKind = enum { destroy };

pub const Entity = packed struct(u32) {
    id: u20,
    generation: u12,
};

pub const DeferredAction = struct {
    action: DeferredActionKind,
    entity: Entity,
};

pub fn World(comptime ComponentTypes: []const type, comptime ResourceTypes: []const type) type {
    const MaskIntBound = comptime blk: {
        var size: u16 = 64;
        while (size <= ComponentTypes.len) size *= 2;

        break :blk size;
    };

    const ResMaskIntBound = comptime blk: {
        var size: u16 = 64;
        while (size <= ResourceTypes.len) size *= 2;

        break :blk size;
    };

    const ComponentMask = @Int(.unsigned, MaskIntBound);
    const ResourceMask = @Int(.unsigned, ResMaskIntBound);

    const ShiftUInt = std.math.Log2Int(ComponentMask);
    const ShiftResUInt = std.math.Log2Int(ResourceMask);

    const ResourceTupleType = comptime blk: {
        if (ResourceTypes.len == 0) break :blk struct {};
        var tps: [ResourceTypes.len]type = undefined;
        for (ResourceTypes, 0..) |R, i| tps[i] = R;

        break :blk @Tuple(&tps);
    };

    const CmdAddTuplesType = comptime blk: {
        var arr: [ComponentTypes.len]type = undefined;
        for (ComponentTypes, 0..) |C, i| arr[i] = std.ArrayListUnmanaged(struct { ent: Entity, comp: C });

        break :blk @Tuple(&arr);
    };

    return struct {
        const Self = @This();

        const EntityRecord = struct {
            arch_idx: u32,
            row: usize, // index row in arch
            gen: u12,
        };

        const Archetype = struct {
            mask: ComponentMask,
            entities: std.ArrayListUnmanaged(Entity),
            components: [ComponentTypes.len]?*anyopaque, // it's row. Save it's without type and extract with typesafety conversion
        };

        alloc: std.mem.Allocator,
        archetypes: std.ArrayListUnmanaged(*Archetype) = .empty,
        entity_idx: std.ArrayListUnmanaged(EntityRecord) = .empty,
        free_entities: std.ArrayListUnmanaged(u20) = .empty,
        query_caches: std.AutoHashMapUnmanaged(ComponentMask, std.ArrayListUnmanaged(*Archetype)) = .empty,
        archetype_map: std.AutoHashMapUnmanaged(ComponentMask, u32) = .empty,
        cmd_common: std.ArrayListUnmanaged(DeferredAction) = .empty,
        cmd_adds: CmdAddTuplesType = undefined,
        resources: ResourceTupleType = undefined,

        fn isOptional(comptime T: type) bool {
            return @typeInfo(T) == .optional;
        }

        pub fn getCompIdx(comptime T: type) ShiftUInt {
            inline for (ComponentTypes, 0..) |C, i| {
                if (C == T) return @intCast(i);
            }

            @compileError("Component " ++ @typeName(T) ++ " not found in World registration types. Baka!");
        }

        fn isZST(comptime T: type) bool {
            return @sizeOf(T) == 0;
        }

        pub fn isAlive(self: *Self, ent: Entity) bool {
            if (ent.id >= self.entity_idx.items.len) return false;

            return self.entity_idx.items[ent.id].gen == ent.generation;
        }

        fn isResType(comptime T: type) bool {
            if (ResourceTypes.len == 0) return false;

            inline for (ResourceTypes) |R| {
                if (R == T) return true;
            }

            return false;
        }

        pub fn getResIdx(comptime T: type) ShiftResUInt {
            inline for (ResourceTypes, 0..) |C, i| {
                if (C == T) return @intCast(i);
            }

            @compileError("Singleton " ++ @typeName(T) ++ "not defined in World init. Baka!");
        }

        fn getInnerCompType(comptime ReqPtr: type) type {
            const T = if (isOptional(ReqPtr)) @typeInfo(ReqPtr).optional.child else ReqPtr;

            return @typeInfo(T).pointer.child;
        }

        pub fn init(alloc: std.mem.Allocator) Self {
            var w: Self = .{ .alloc = alloc, .resources = if (ResourceTypes.len == 0) .{} else std.mem.zeroes(ResourceTupleType) };

            inline for (0..ComponentTypes.len) |i| {
                w.cmd_adds[i] = .empty;
            }

            return w;
        }

        pub fn deinit(self: *Self) void {
            var iter = self.query_caches.valueIterator();
            while (iter.next()) |lst| lst.deinit(self.alloc);
            self.query_caches.deinit(self.alloc);

            for (self.archetypes.items) |arch| {
                arch.entities.deinit(self.alloc);

                inline for (ComponentTypes, 0..) |T, i| {
                    if (comptime !isZST(T)) {
                        if (arch.mask & (@as(ComponentMask, 1) << @intCast(i)) != 0) {
                            const typed_ptr: *std.ArrayListUnmanaged(T) = @ptrCast(@alignCast(arch.components[i].?));
                            typed_ptr.deinit(self.alloc);

                            self.alloc.destroy(typed_ptr);
                        }
                    }
                }

                self.alloc.destroy(arch);
            }

            self.archetypes.deinit(self.alloc);
            self.entity_idx.deinit(self.alloc);
            self.free_entities.deinit(self.alloc);
            self.archetype_map.deinit(self.alloc);
            self.cmd_common.deinit(self.alloc);

            inline for (0..ComponentTypes.len) |i| {
                self.cmd_adds[i].deinit(self.alloc);
            }
        }

        pub fn createEntity(self: *Self) !Entity {
            var ent_id: u20 = undefined;
            var next_gen: u12 = 0;

            if (self.free_entities.pop()) |free_id| {
                ent_id = free_id;
                next_gen = self.entity_idx.items[free_id].gen + 1;
            } else {
                ent_id = @intCast(self.entity_idx.items.len);
                next_gen = 0;

                try self.entity_idx.append(self.alloc, undefined);
            }

            const ent = Entity{ .id = ent_id, .generation = next_gen };

            const arch_idx = try self.getOrCreateArchetype(0);
            const arch = self.archetypes.items[arch_idx];

            const dest_row = arch.entities.items.len;

            try arch.entities.append(self.alloc, ent);

            self.entity_idx.items[ent_id] = .{ .arch_idx = arch_idx, .row = dest_row, .gen = next_gen };

            return ent;
        }

        fn getOrCreateArchetype(self: *Self, mask: ComponentMask) !u32 {
            if (self.archetype_map.get(mask)) |idx| return idx;
            const new_arch = try self.alloc.create(Archetype);
            new_arch.mask = mask;
            new_arch.entities = .empty;
            new_arch.components = undefined;

            for (&new_arch.components) |*comp| {
                comp.* = null;
            }

            inline for (ComponentTypes, 0..) |T, i| {
                // If ZST then skip reallocation bytes
                if (comptime !isZST(T)) {
                    if (mask & (@as(ComponentMask, 1) << @intCast(i)) != 0) {
                        const ptr = try self.alloc.create(std.ArrayListUnmanaged(T));
                        ptr.* = .empty;
                        new_arch.components[i] = ptr;
                    }
                }
            }

            const idx: u32 = @intCast(self.archetypes.items.len);

            try self.archetypes.append(self.alloc, new_arch);
            try self.archetype_map.put(self.alloc, mask, idx);

            // New arrays for query caching
            var iter = self.query_caches.iterator();

            while (iter.next()) |entry| {
                const query_req = entry.key_ptr.*;

                if ((mask & query_req) == query_req) {
                    try entry.value_ptr.*.append(self.alloc, new_arch);
                }
            }

            return idx;
        }

        pub fn setResource(self: *Self, val: anytype) void {
            self.resources[comptime getResIdx(@TypeOf(val))] = val;
        }

        pub fn getResource(self: *Self, comptime T: type) *T {
            return &self.resources[comptime getResIdx(T)];
        }

        pub fn addComponent(self: *Self, ent: Entity, component: anytype) !void {
            if (!self.isAlive(ent)) return;
            const T = @TypeOf(component);
            const comp_id = getCompIdx(T);

            const record = self.entity_idx.items[ent.id];

            const src_arch = self.archetypes.items[record.arch_idx];

            // If component alive: throw up and leave without method graph
            var dest_mask = src_arch.mask;

            if (dest_mask & (@as(ComponentMask, 1) << comp_id) != 0) {
                // Ignore
                if (comptime !isZST(T)) {
                    const list: *std.ArrayListUnmanaged(T) = @ptrCast(@alignCast(src_arch.components[comp_id].?));
                    list.items[record.row] = component;
                }

                return;
            }

            dest_mask |= (@as(ComponentMask, 1) << comp_id);

            const dest_idx = try self.getOrCreateArchetype(dest_mask);
            const dest_arch = self.archetypes.items[dest_idx];

            const src_row = record.row;
            const dest_row = dest_arch.entities.items.len;

            try dest_arch.entities.append(self.alloc, ent);

            inline for (ComponentTypes, 0..) |CType, i| {
                if (comptime !isZST(CType)) {
                    if (src_arch.mask & (@as(ComponentMask, 1) << @intCast(i)) != 0) {
                        const src_l: *std.ArrayListUnmanaged(CType) = @ptrCast(@alignCast(src_arch.components[i].?));
                        const dst_l: *std.ArrayListUnmanaged(CType) = @ptrCast(@alignCast(dest_arch.components[i].?));

                        try dst_l.append(self.alloc, src_l.items[src_row]);
                    }
                }
            }

            if (comptime !isZST(T)) {
                const dst_c: *std.ArrayListUnmanaged(T) = @ptrCast(@alignCast(dest_arch.components[comp_id].?));

                try dst_c.append(self.alloc, component);
            }

            self.performSwapAndPop(src_arch, src_row); // clean prev area without pity in mem

            self.entity_idx.items[ent.id] = .{
                .arch_idx = dest_idx,
                .row = dest_row,
                .gen = ent.generation,
            };
        }

        fn performSwapAndPop(self: *Self, arch: *Archetype, src_row: usize) void {
            const last_row = arch.entities.items.len - 1;

            if (src_row != last_row) {
                const swap_ent = arch.entities.items[last_row];

                arch.entities.items[src_row] = swap_ent;

                inline for (ComponentTypes, 0..) |CType, i| {
                    if (comptime !isZST(CType)) {
                        if (arch.mask & (@as(ComponentMask, 1) << @intCast(i)) != 0) {
                            const l: *std.ArrayListUnmanaged(CType) = @ptrCast(@alignCast(arch.components[i].?));
                            l.items[src_row] = l.items[last_row];
                        }
                    }
                }

                self.entity_idx.items[swap_ent.id].row = src_row; // fix references whose fly on up
            }

            _ = arch.entities.pop();

            inline for (ComponentTypes, 0..) |CType, i| {
                if (comptime !isZST(CType)) {
                    if (arch.mask & (@as(ComponentMask, 1) << @intCast(i)) != 0) {
                        const l: *std.ArrayListUnmanaged(CType) = @ptrCast(@alignCast(arch.components[i].?));

                        _ = l.pop();
                    }
                }
            }
        }

        pub fn cmdAdd(self: *Self, ent: Entity, component: anytype) !void {
            const CompType = @TypeOf(component);

            inline for (ComponentTypes, 0..) |C_Type, idx| {
                if (C_Type == CompType) {
                    try self.cmd_adds[idx].append(self.alloc, .{ .ent = ent, .comp = component });

                    return;
                }
            }
        }

        pub fn cmdDestroy(self: *Self, ent: Entity) !void {
            try self.cmd_common.append(self.alloc, .{ .action = .destroy, .entity = ent });
        }

        pub fn flushCommands(self: *Self) void {
            for (self.cmd_common.items) |c| {
                if (!self.isAlive(c.entity)) continue;

                if (c.action == .destroy) {
                    const record = self.entity_idx.items[c.entity.id];
                    const arch = self.archetypes.items[record.arch_idx];

                    self.performSwapAndPop(arch, record.row);
                    self.entity_idx.items[c.entity.id].gen +%= 1; // make entity unlive
                    self.free_entities.append(self.alloc, c.entity.id) catch {};
                }
            }

            self.cmd_common.clearRetainingCapacity();

            inline for (ComponentTypes, 0..) |_, tId| {
                for (self.cmd_adds[tId].items) |intent| {
                    if (self.isAlive(intent.ent)) {
                        self.addComponent(intent.ent, intent.comp) catch |err| {
                            std.debug.panic("[PANIC]: You fucked up in mem. I think, you don't have enough mem in cycle your game: {any}", .{err});
                        };
                    }
                }

                self.cmd_adds[tId].clearRetainingCapacity();
            }
        }

        pub fn Iterator(comptime TargetCompTypeArgsList: anytype) type {
            return struct {
                world_p: *Self, // save reference for World, now query inject self resources
                cached_arrays: std.ArrayListUnmanaged(*Archetype),
                arch_pos: usize = 0,
                row_pos: usize = 0,

                pub fn next(it: *@This()) ?@Tuple(&TargetCompTypeArgsList) {
                    while (it.arch_pos < it.cached_arrays.items.len) {
                        const arch = it.cached_arrays.items[it.arch_pos];

                        if (it.row_pos < arch.entities.items.len) {
                            var ret: @Tuple(&TargetCompTypeArgsList) = undefined;

                            inline for (TargetCompTypeArgsList, 0..) |ReqArgPtr, t_id| {
                                if (ReqArgPtr == Entity) {
                                    ret[t_id] = arch.entities.items[it.row_pos];
                                } else {
                                    const CleanInnerStruct = getInnerCompType(ReqArgPtr);

                                    if (comptime isResType(CleanInnerStruct)) {
                                        ret[t_id] = &it.world_p.resources[comptime getResIdx(CleanInnerStruct)];
                                    } else {
                                        const C_Idx = getCompIdx(CleanInnerStruct);
                                        const bitCheck = (@as(ComponentMask, 1) << C_Idx);

                                        if (comptime isOptional(ReqArgPtr)) {
                                            if ((arch.mask & bitCheck) == 0) {
                                                ret[t_id] = null; // leave component options as it alredy

                                            } else {
                                                if (comptime !isZST(CleanInnerStruct)) {
                                                    const ls: *std.ArrayListUnmanaged(CleanInnerStruct) = @ptrCast(@alignCast(arch.components[C_Idx].?));

                                                    ret[t_id] = &ls.items[it.row_pos];
                                                } else {
                                                    // SAFETY: Give abstracted 0 bytes ptr to ZST struct (0x01)
                                                    ret[t_id] = @ptrFromInt(@alignOf(CleanInnerStruct));
                                                }
                                            }
                                        } else {
                                            if (comptime !isZST(CleanInnerStruct)) {
                                                const ls: *std.ArrayListUnmanaged(CleanInnerStruct) = @ptrCast(@alignCast(arch.components[C_Idx].?));

                                                ret[t_id] = &ls.items[it.row_pos];
                                            } else {
                                                ret[t_id] = @ptrFromInt(@alignOf(CleanInnerStruct));
                                            }
                                        }
                                    }
                                }
                            }

                            it.row_pos += 1;

                            return ret;
                        } else {
                            it.arch_pos += 1;
                            it.row_pos = 0;
                        }
                    }

                    return null;
                }
            };
        }

        pub fn query(self: *Self, comptime TargetComponentsList: anytype) !Iterator(TargetComponentsList) {
            const req_mask = comptime blk: {
                var mk: ComponentMask = 0;

                for (TargetComponentsList) |ReqPtr| {
                    if (ReqPtr != Entity and !isOptional(ReqPtr)) {
                        const innerStructureType = getInnerCompType(ReqPtr);

                        if (!isResType(innerStructureType)) mk |= (@as(ComponentMask, 1) << getCompIdx(innerStructureType));
                    }
                }

                break :blk mk;
            };

            var out_archs: std.ArrayListUnmanaged(*Archetype) = undefined;

            if (self.query_caches.get(req_mask)) |hit| {
                out_archs = hit;
            } else {
                // On cache
                var list: std.ArrayListUnmanaged(*Archetype) = .empty;

                for (self.archetypes.items) |arch| {
                    if ((arch.mask & req_mask) == req_mask) try list.append(self.alloc, arch);
                }

                try self.query_caches.put(self.alloc, req_mask, list);

                out_archs = list;
            }

            return .{ .world_p = self, .cached_arrays = out_archs, .arch_pos = 0, .row_pos = 0 };
        }

        pub fn extractAccess(comptime sys: anytype) struct { read: u64, write: u64, rs_read: u64, rs_write: u64 } {
            const fn_info = @typeInfo(@TypeOf(sys)).@"fn";

            var cw: u64 = 0;
            var rw: u64 = 0;
            var cr: u64 = 0;
            var rr: u64 = 0;

            inline for (fn_info.params) |p| {
                if (p.type.? == Entity) continue;
                if (p.type.? == *Self) continue; // command buffer interface

                const ptr_info = @typeInfo(if (isOptional(p.type.?)) @typeInfo(p.type.?).optional.child else p.type.?).pointer;

                const CleanIn = getInnerCompType(p.type.?);

                if (isResType(CleanIn)) {
                    const m = @as(u64, 1) << getResIdx(CleanIn);

                    if (ptr_info.is_const) {
                        rr |= m;
                    } else {
                        rw |= m;
                    }
                } else {
                    const m = @as(u64, 1) << getCompIdx(CleanIn);

                    if (ptr_info.is_const) {
                        cr |= m;
                    } else {
                        cw |= m;
                    }
                }
            }

            return .{ .read = cr, .write = cw, .rs_read = rr, .rs_write = rw };
        }

        pub fn scheduleBatchExec(self: *Self, comptime TargetSysSet: anytype) !void {
            const exec_batches = comptime blk: {
                var batched_idxs: [TargetSysSet.len]usize = undefined;
                var current_b: usize = 0;
                var unassigned = TargetSysSet.len;
                var resolved: [TargetSysSet.len]bool = undefined;

                for (&resolved) |*b| {
                    b.* = false;
                }

                while (unassigned > 0) {
                    var B_Acc = Self.extractAccess(TargetSysSet[0]);
                    B_Acc.read = 0;
                    B_Acc.write = 0;
                    B_Acc.rs_read = 0;
                    B_Acc.rs_write = 0;

                    for (0..TargetSysSet.len) |s_idx| {
                        if (resolved[s_idx]) continue;

                        const iAccess = Self.extractAccess(TargetSysSet[s_idx]);

                        const crace = (B_Acc.write & iAccess.write) != 0 or (B_Acc.read & iAccess.write) != 0 or (B_Acc.write & iAccess.read) != 0;
                        const rrace = (B_Acc.rs_write & iAccess.rs_write) != 0 or (B_Acc.rs_read & iAccess.rs_write) != 0 or (B_Acc.rs_write & iAccess.rs_read) != 0;

                        if (!crace and !rrace) {
                            resolved[s_idx] = true;
                            unassigned -= 1;
                            batched_idxs[s_idx] = current_b;
                            B_Acc.write |= iAccess.write;
                            B_Acc.read |= iAccess.read;
                            B_Acc.rs_write |= iAccess.rs_write;
                            B_Acc.rs_read |= iAccess.rs_read;
                        }
                    }

                    current_b += 1;
                }

                break :blk .{ batched_idxs, current_b };
            };

            const SysOrders = exec_batches[0];
            const BatchCount = exec_batches[1];

            var running_threads: [TargetSysSet.len]std.Thread = undefined;

            inline for (0..BatchCount) |batch_cursor| {
                var active_threads_count: usize = 0;

                inline for (TargetSysSet, 0..) |SysToRun, origin_id| {
                    if (SysOrders[origin_id] == batch_cursor) {
                        const NativeClosureContext = struct {
                            pub fn rawThreadLaunchTarget(ptr: *Self) void {
                                ptr.internalSpawnThreadIterSys(SysToRun);
                            }
                        };

                        running_threads[active_threads_count] = try std.Thread.spawn(.{}, NativeClosureContext.rawThreadLaunchTarget, .{self});
                        active_threads_count += 1;
                    }
                }

                var wait_idx: usize = 0;

                while (wait_idx < active_threads_count) : (wait_idx += 1) {
                    running_threads[wait_idx].join();
                }
            }
        }

        fn internalSpawnThreadIterSys(self: *Self, comptime fnToLaunch: anytype) void {
            const fnInfo = @typeInfo(@TypeOf(fnToLaunch)).@"fn";

            const isPureGlobalOnly = comptime blk: {
                var yes = true;
                if (fnInfo.params.len == 0) yes = false;

                for (fnInfo.params) |p| {
                    if (p.type.? == Entity or p.type.? == *Self) {
                        yes = false;
                    } else if (!isResType(getInnerCompType(p.type.?))) {
                        yes = false;
                    }
                }

                break :blk yes;
            };

            if (comptime isPureGlobalOnly) {
                var exec_only_globals_tupledArgs: @Tuple(&blk: {
                    var t_arr: [fnInfo.params.len]type = undefined;
                    for (fnInfo.params, 0..) |p, idx| t_arr[idx] = p.type.?;

                    break :blk t_arr;
                }) = undefined;

                inline for (fnInfo.params, 0..) |p, i| {
                    exec_only_globals_tupledArgs[i] = &self.resources[comptime getResIdx(getInnerCompType(p.type.?))];
                }

                @call(.auto, fnToLaunch, exec_only_globals_tupledArgs);
            } else {
                const AutoTupleToFilter = comptime blk: {
                    var temp: [fnInfo.params.len]type = undefined;

                    for (fnInfo.params, 0..) |v, x| {
                        temp[x] = v.type.?;
                    }

                    break :blk temp;
                };

                var BlazingQueryWalker = self.query(AutoTupleToFilter) catch unreachable;

                while (BlazingQueryWalker.next()) |SysTuplesSlicesRef| {
                    @call(.auto, fnToLaunch, SysTuplesSlicesRef);
                }
            }
        }
    };
}
