const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const stdx = @import("stdx");
const t = stdx.testing;
const cy = @import("cyber.zig");
const C = @import("capi.zig");
const ir = cy.ir;
const vmc = @import("vm_c.zig");
const rt = cy.rt;
const bt = cy.types.BuiltinTypes;
const Nullable = cy.Nullable;
const sema = @This();
pub usingnamespace @import("sema_func.zig");
const cte = cy.cte;
const fmt = cy.fmt;
const v = fmt.v;
const module = cy.module;
const ast = cy.ast;

const ChunkId = cy.chunk.ChunkId;
const TypeId = cy.types.TypeId;
const CompactType = cy.types.CompactType;
const Sym = cy.Sym;
const ReturnCstr = cy.types.ReturnCstr;

const vm_ = @import("vm.zig");

const log = cy.log.scoped(.sema);

pub const LocalVarId = u32;

const LocalVarType = enum(u8) {
    /// Local var or param.
    local, 

    /// Whether this var references a static variable.
    staticAlias,

    parentLocalAlias,
};

const LocalVarS = struct {
    /// Id emitted in IR code. Starts from 0 after params in the current block.
    /// Aliases do not have an id.
    id: u8,

    /// If `isParam` is true, `id` refers to the param idx.
    isParam: bool,
    /// If a param is written to or turned into a Box, `copied` becomes true.
    isParamCopied: bool,

    /// If declaration has an initializer.
    hasInit: bool,

    /// Currently a captured var always needs to be lifted.
    /// In the future, the concept of a immutable variable could change this.
    lifted: bool,

    /// If var is hidden, user code can not reference it.
    hidden: bool,

    /// For locals this points to a ir.DeclareLocal.
    /// This is NullId for params.
    declIrStart: u32,
};

/// Represents a variable or alias in a block.
/// Local variables are given reserved registers on the stack frame.
/// Captured variables have box values at runtime.
/// TODO: This should be SemaVar since it includes all vars not just locals.
pub const LocalVar = struct {
    type: LocalVarType,

    declT: TypeId,

    /// This tracks the most recent type as the ast is traversed.
    /// This is updated when there is a variable assignment or a child block returns.
    vtype: CompactType,

    /// Last sub-block that mutated the dynamic var.
    dynamicLastMutBlockId: BlockId,

    /// Local register offset assigned to this var.
    /// Locals are relative to the stack frame's start position.
    local: u8 = undefined,

    inner: union {
        staticAlias: *Sym,
        local: LocalVarS,
        parentLocalAlias: struct {
            capturedIdx: u8,
        },
        unDefined: void,
    } = .{ .unDefined = {} },

    nameLen: u16,
    namePtr: [*]const u8,

    /// Whether the variable is dynamic or statically typed.
    /// This should provide the same result as `vtype.dynamic`.
    pub fn isDynamic(self: LocalVar) bool {
        return self.declT == bt.Dyn;
    }

    pub fn name(self: LocalVar) []const u8 {
        return self.namePtr[0..self.nameLen];
    }

    pub inline fn isParentLocalAlias(self: LocalVar) bool {
        return self.type == .parentLocalAlias;
    }

    pub inline fn isCapturable(self: LocalVar) bool {
        return self.type == .local;
    }
};

const VarBlock = extern struct {
    varId: LocalVarId,
    blockId: BlockId,
};

pub const VarShadow = extern struct {
    namePtr: [*]const u8,
    nameLen: u32,
    varId: LocalVarId,
    blockId: BlockId,
};

pub const NameVar = extern struct {
    namePtr: [*]const u8,
    nameLen: u32,
    varId: LocalVarId,
};

pub const CapVarDesc = extern union {
    /// The user of a captured var contains the SemaVarId back to the owner's var.
    user: LocalVarId,
};

pub const PreLoopVarSave = packed struct {
    vtype: CompactType,
    varId: LocalVarId,
};

pub const VarAndType = struct {
    id: LocalVarId,
    vtype: TypeId,
};

pub const BlockId = u32;

pub const Block = struct {
    /// Track which vars were assigned to in the current sub block.
    /// If the var was first assigned in a parent sub block, the type is saved in the map to
    /// be merged later with the ending var type.
    /// Can be freed after the end of block.
    prevVarTypes: std.AutoHashMapUnmanaged(LocalVarId, CompactType),

    /// Start of vars assigned in this block in `assignedVarStack`.
    /// When leaving this block, all assigned var types in this block are merged
    /// back to the parent scope.
    assignedVarStart: u32,

    /// Start of local vars in this sub-block in `varStack`.
    varStart: u32,

    /// Start of shadowed vars from the previous sub-block in `varShadowStack`.
    varShadowStart: u32,

    preLoopVarSaveStart: u32, 

    /// Node that began the sub-block.
    node: *ast.Node,

    /// Whether execution can reach the end.
    /// If a return statement was generated, this would be set to false.
    endReachable: bool = true,

    /// Tracks how many locals are owned by this sub-block.
    /// When the sub-block is popped, this is subtracted from the block's `curNumLocals`.
    numLocals: u8,

    pub fn init(node: *ast.Node, assignedVarStart: usize, varStart: usize, varShadowStart: usize) Block {
        return .{
            .node = node,
            .assignedVarStart = @intCast(assignedVarStart),
            .varStart = @intCast(varStart),
            .varShadowStart = @intCast(varShadowStart),
            .preLoopVarSaveStart = 0,
            .prevVarTypes = .{},
            .numLocals = 0,
        };
    }

    pub fn deinit(self: *Block, alloc: std.mem.Allocator) void {
        self.prevVarTypes.deinit(alloc);
    }
};

pub const ProcId = u32;

/// Container for main, fiber, function, and lambda blocks.
pub const Proc = struct {
    /// `varStack[varStart]` is the start of params.
    numParams: u8,

    /// Captured vars. 
    captures: std.ArrayListUnmanaged(LocalVarId),

    /// Maps a name to a var.
    /// This is updated as blocks declare their own locals and restored
    /// when blocks end.
    /// This can be deinited after ending the sema block.
    /// TODO: Move to chunk level.
    nameToVar: std.StringHashMapUnmanaged(VarBlock),

    /// First sub block id is recorded so the rest can be obtained by advancing
    /// the id in the same order it was traversed in the sema pass.
    firstBlockId: BlockId,

    /// Current sub block depth.
    blockDepth: u32,

    /// Main block if `NullId`.
    func: ?*cy.Func,

    /// Whether this block belongs to a static function.
    isStaticFuncBlock: bool,

    /// Whether this is a method block.
    isMethodBlock: bool = false,

    /// Track max locals so that codegen knows where stack registers begin.
    /// Includes function params.
    maxLocals: u8,

    /// Everytime a new local is encountered in a sub-block, this is incremented by one.
    /// At the end of the sub-block `maxLocals` is updated and this unwinds by subtracting its numLocals.
    /// Includes function params.
    curNumLocals: u8,

    /// All locals currently alive in this block.
    /// Every local above the current sub-block is included.
    varStart: u32,

    /// Where the IR starts for this block.
    irStart: u32,

    node: *ast.Node,

    pub fn init(node: *ast.Node, func: ?*cy.Func, firstBlockId: BlockId, isStaticFuncBlock: bool, varStart: u32) Proc {
        return .{
            .nameToVar = .{},
            .numParams = 0,
            .blockDepth = 0,
            .func = func,
            .firstBlockId = firstBlockId,
            .isStaticFuncBlock = isStaticFuncBlock,
            .node = node,
            .captures = .{},
            .maxLocals = 0,
            .curNumLocals = 0,
            .varStart = varStart,
            .irStart = cy.NullId,
        };
    }

    pub fn deinit(self: *Proc, alloc: std.mem.Allocator) void {
        self.nameToVar.deinit(alloc);
        self.captures.deinit(alloc);
    }

    fn getReturnType(self: *const Proc) !TypeId {
        if (self.func) |func| {
            return func.retType;
        } else {
            return bt.Any;
        }
    }
};

pub const ModFuncSigKey = cy.hash.KeyU96;
const ObjectMemberKey = cy.hash.KeyU64;

pub fn semaStmts(c: *cy.Chunk, stmts: []const *ast.Node) anyerror!void {
    for (stmts) |stmt| {
        try semaStmt(c, stmt);
    }
}

pub fn semaStmt(c: *cy.Chunk, node: *ast.Node) !void {
    c.curNode = node;
    if (cy.Trace) {
        var buf: [1024]u8 = undefined;
        var fbuf = std.io.fixedBufferStream(&buf);
        try c.encoder.write(fbuf.writer(), node);
        log.tracev("stmt.{s}: \"{s}\"", .{@tagName(node.type()), fbuf.getWritten()});
    }
    switch (node.type()) {
        .exprStmt => {
            const stmt = node.cast(.exprStmt);
            const returnMain = stmt.isLastRootStmt;
            var expr = try c.semaExpr(stmt.child, .{ .target_t = bt.Void });
            // Ensure returning dynamic value from main.
            if (returnMain and expr.type.id != bt.Void) {
                expr = try c.semaExpr(stmt.child, .{ .target_t = bt.Void });
                const loc = try c.ir.pushExpr(.box, c.alloc, bt.Any, stmt.child, .{
                    .expr = expr.irIdx,
                });
                expr.type = CompactType.init(bt.Dyn);
                expr.irIdx = loc;
            }
            _ = try c.ir.pushStmt(c.alloc, .exprStmt, node, .{
                .expr = expr.irIdx,
                .isBlockResult = returnMain,
            });
        },
        .breakStmt => {
            _ = try c.ir.pushStmt(c.alloc, .breakStmt, node, {});
        },
        .continueStmt => {
            _ = try c.ir.pushStmt(c.alloc, .contStmt, node, {});
        },
        .localDecl => {
            try localDecl(c, node.cast(.localDecl));
        },
        .opAssignStmt => {
            const stmt = node.cast(.opAssignStmt);
            switch (stmt.op) {
                .star,
                .slash,
                .percent,
                .caret,
                .plus,
                .minus => {},
                else => {
                    return c.reportErrorFmt("Unsupported op assign statement for {}.", &.{v(stmt.op)}, node);
                }
            }

            const irIdx = try c.ir.pushStmt(c.alloc, .opSet, node, .{ .op = stmt.op, .set_stmt = undefined });

            const set_stmt = try assignStmt(c, node, stmt.left, node, .{ .rhsOpAssignBinExpr = true });
            c.ir.getStmtDataPtr(irIdx, .opSet).set_stmt = set_stmt;

            // Reset `opSet`'s next since pushed statements are appended to the top StmtBlock.
            c.ir.setStmtNext(irIdx, cy.NullId);
            c.ir.stmtBlockStack.items[c.ir.stmtBlockStack.items.len-1].last = irIdx;
        },
        .assignStmt => {
            const stmt = node.cast(.assignStmt);
            _ = try assignStmt(c, node, stmt.left, stmt.right, .{});
        },
        .trait_decl,
        .objectDecl,
        .structDecl,
        .cstruct_decl,
        .passStmt,
        .staticDecl,
        .context_decl,
        .typeAliasDecl,
        .distinct_decl,
        .template,
        .enumDecl,
        .funcDecl => {
            // Nop.
        },
        .forIterStmt => {
            const stmt = node.cast(.forIterStmt);

            try preLoop(c, node);
            try pushBlock(c, node);
            {
                const iterable_n: *ast.Node = @ptrCast(stmt.iterable);
                const iterable_init = try c.semaExprCstr(stmt.iterable, bt.Dyn);
                const iterable_v = try declareHiddenLocal(c, "$iterable", bt.Dyn, iterable_init, iterable_n);
                const iterable = try semaLocal(c, iterable_v.id, node);

                const iterator_init = try c.semaCallObjSym0(iterable.irIdx, "iterator", iterable_n);
                const iterator_v = try declareHiddenLocal(c, "$iterator", bt.Dyn, iterator_init, iterable_n);
                const iterator = try semaLocal(c, iterator_v.id, node);

                const counter_init = try c.semaInt(-1, node);
                const counterv = try declareHiddenLocal(c, "$counter", bt.Integer, counter_init, node);

                const ClosureData = struct {
                    stmt: *ast.ForIterStmt,
                    counterv: LocalResult,
                };
                var closure_data = ClosureData{
                    .stmt = stmt,
                    .counterv = counterv,
                };

                // Loop block.
                const loop_stmt = try c.ir.pushEmptyStmt(c.alloc, .loopStmt, node);
                try pushBlock(c, node);
                {
                    // if $iterator.next() -> each, i
                    const S = struct {
                        fn body(c_: *cy.Chunk, data_: *anyopaque) !void {
                            const data: *ClosureData = @ptrCast(@alignCast(data_));
                            if (data.stmt.count) |count| {
                                // $counter += 1
                                const int_t = c_.sema.getTypeSym(bt.Integer);
                                const sym = try c_.mustFindSym(int_t, "$infix+", @ptrCast(data.stmt));
                                const func_sym = try requireFuncSym(c_, sym, @ptrCast(data.stmt));
                                const one = try c_.semaInt(1, @ptrCast(data.stmt));

                                const counter_ = try semaLocal(c_, data.counterv.id, @ptrCast(data.stmt));
                                const right = try c_.semaCallFuncSymRec2(func_sym, @ptrCast(data.stmt), counter_, 
                                    &.{one}, &.{ @ptrCast(data.stmt) }, .any, @ptrCast(data.stmt));
                                const irStart = try c_.ir.pushEmptyStmt(c_.alloc, .setLocal, @ptrCast(data.stmt));
                                const info = c_.varStack.items[data.counterv.id].inner.local;
                                c_.ir.setStmtData(irStart, .setLocal, .{ .local = .{
                                    .id = info.id,
                                    .right = right.irIdx,
                                }});

                                // $count = $counter
                                const count_name = c_.ast.nodeString(count);
                                _ = try declareLocalInit(c_, count_name, bt.Integer, counter_, @ptrCast(data.stmt));
                            }

                            try semaStmts(c_, data.stmt.stmts);
                            _ = try c_.ir.pushStmt(c_.alloc, .contStmt, @ptrCast(data.stmt), {});
                        }
                    }; 
                    const next = try c.semaCallObjSym0(iterator.irIdx, "next", node);
                    const opt = try c.semaOptionExpr2(next, node);

                    try semaIfUnwrapStmt2(c, opt, node, stmt.each, S.body, &closure_data, &.{}, @ptrCast(stmt));
                }
                const block = try popLoopBlock(c);
                c.ir.setStmtData(loop_stmt, .loopStmt, .{
                    .body_head = block.first,
                });
            }
            const block = try popBlock(c);
            _ = try c.ir.pushStmt(c.alloc, .block, @ptrCast(stmt), .{ .bodyHead = block.first });
        },
        .forRangeStmt => {
            const stmt = node.cast(.forRangeStmt);
            try preLoop(c, node);
            const irIdx = try c.ir.pushEmptyStmt(c.alloc, .forRangeStmt, node);

            const range_start = try c.semaExprCstr(stmt.start, bt.Integer);
            const range_end = try c.semaExprCstr(stmt.end, bt.Integer);

            try pushBlock(c, node);

            var eachLocal: ?u8 = null;
            if (stmt.each) |each| {
                if (each.type() == .ident) {
                    const varId = try declareLocal(c, each, bt.Integer, false);
                    eachLocal = c.varStack.items[varId].inner.local.id;
                } else {
                    return c.reportErrorFmt("Unsupported each clause: {}", &.{v(each.type())}, each);
                }
            }

            const declHead = c.ir.getAndClearStmtBlock();

            try semaStmts(c, stmt.stmts);
            const stmtBlock = try popLoopBlock(c);
            c.ir.setStmtData(irIdx, .forRangeStmt, .{
                .eachLocal = eachLocal,
                .start = range_start.irIdx,
                .end = range_end.irIdx,
                .bodyHead = stmtBlock.first,
                .increment = stmt.increment,
                .declHead = declHead,
            });
        },
        .whileInfStmt => {
            const stmt = node.cast(.whileInfStmt);
            try preLoop(c, node);
            const loc = try c.ir.pushEmptyStmt(c.alloc, .loopStmt, node);
            try pushBlock(c, node);
            {
                try semaStmts(c, stmt.stmts);
                _ = try c.ir.pushStmt(c.alloc, .contStmt, node, {});
            }
            const stmtBlock = try popLoopBlock(c);
            c.ir.setStmtData(loc, .loopStmt, .{
                .body_head = stmtBlock.first,
            });
        },
        .whileCondStmt => {
            const stmt = node.cast(.whileCondStmt);
            try preLoop(c, node);
            const loc = try c.ir.pushEmptyStmt(c.alloc, .loopStmt, node);

            try pushBlock(c, node);
            {
                const if_stmt = try c.ir.pushEmptyStmt(c.alloc, .ifStmt, stmt.cond);
                const cond = try c.semaExprCstr(stmt.cond, bt.Boolean);
                try pushBlock(c, stmt.cond);
                {
                    try semaStmts(c, stmt.stmts);
                    _ = try c.ir.pushStmt(c.alloc, .contStmt, node, {});
                }
                const if_block = try popBlock(c);
                c.ir.setStmtData(if_stmt, .ifStmt, .{
                    .cond = cond.irIdx,
                    .body_head = if_block.first,
                    .else_block = cy.NullId,
                });
            }
            const stmtBlock = try popLoopBlock(c);
            c.ir.setStmtData(loc, .loopStmt, .{
                .body_head = stmtBlock.first,
            });
        },
        .whileOptStmt => {
            const stmt = node.cast(.whileOptStmt);
            try preLoop(c, node);
            const loc = try c.ir.pushEmptyStmt(c.alloc, .loopStmt, node);

            try pushBlock(c, node);
            {
                const S = struct {
                    fn body(c_: *cy.Chunk, data: *anyopaque) !void {
                        const stmt_: *ast.WhileOptStmt = @ptrCast(@alignCast(data));
                        try semaStmts(c_, stmt_.stmts);
                        _ = try c_.ir.pushStmt(c_.alloc, .contStmt, @ptrCast(stmt_), {});
                    }
                }; 
                const opt = try c.semaOptionExpr(stmt.opt);
                try semaIfUnwrapStmt2(c, opt, stmt.opt, stmt.capture, S.body, stmt, &.{}, @ptrCast(stmt));
            }
            const stmtBlock = try popLoopBlock(c);
            c.ir.setStmtData(loc, .loopStmt, .{
                .body_head = stmtBlock.first,
            });
        },
        .switchStmt => {
            try semaSwitchStmt(c, node.cast(.switchStmt));
        },
        .if_stmt => {
            try semaIfStmt(c, node.cast(.if_stmt));
        },
        .if_unwrap_stmt => {
            try semaIfUnwrapStmt(c, node.cast(.if_unwrap_stmt));
        },
        .tryStmt => {
            const stmt = node.cast(.tryStmt);
            var data: ir.TryStmt = undefined;
            const irIdx = try c.ir.pushEmptyStmt(c.alloc, .tryStmt, node);
            try pushBlock(c, node);
            {
                try semaStmts(c, stmt.stmts);
            }
            var block = try popBlock(c);
            data.bodyHead = block.first;

            try pushBlock(c, node);
            {
                if (stmt.catchStmt.errorVar) |err_var| {
                    const id = try declareLocal(c, err_var, bt.Error, false);
                    data.hasErrLocal = true;
                    data.errLocal = c.varStack.items[id].inner.local.id;
                } else {
                    data.hasErrLocal = false;
                }
                try semaStmts(c, stmt.catchStmt.stmts);
            }
            block = try popBlock(c);
            data.catchBodyHead = block.first;

            c.ir.setStmtData(irIdx, .tryStmt, data);
        },
        .use_alias,
        .import_stmt => {},
        .returnStmt => {
            _ = try c.ir.pushStmt(c.alloc, .retStmt, node, {});
        },
        .returnExprStmt => {
            const proc = c.proc();
            const retType = try proc.getReturnType();

            const expr = try c.semaExprCstr(node.cast(.returnExprStmt).child, retType);
            _ = try c.ir.pushStmt(c.alloc, .retExprStmt, node, .{
                .expr = expr.irIdx,
            });
        },
        .comptimeStmt => {
            const expr = node.cast(.comptimeStmt).expr;
            if (expr.type() == .callExpr) {
                const call = expr.cast(.callExpr);
                const name = c.ast.nodeString(call.callee);

                if (std.mem.eql(u8, "genLabel", name)) {
                    if (call.args.len != 1) {
                        return c.reportErrorFmt("genLabel expected 1 arg", &.{}, node);
                    }

                    if (call.args[0].type() != .stringLit and call.args[0].type() != .raw_string_lit) {
                        return c.reportErrorFmt("genLabel expected string arg", &.{}, node);
                    }

                    const label = c.ast.nodeString(call.args[0]);
                    _ = try c.ir.pushStmt(c.alloc, .pushDebugLabel, node, .{ .name = label });
                } else if (std.mem.eql(u8, "dumpLocals", name)) {
                    const proc = c.proc();
                    try c.dumpLocals(proc);
                } else if (std.mem.eql(u8, "dumpBytecode", name)) {
                    _ = try c.ir.pushStmt(c.alloc, .dumpBytecode, node, {});
                } else if (std.mem.eql(u8, "verbose", name)) {
                    C.setVerbose(true);
                    _ = try c.ir.pushStmt(c.alloc, .verbose, node, .{ .verbose = true });
                } else if (std.mem.eql(u8, "verboseOff", name)) {
                    C.setVerbose(false);
                    _ = try c.ir.pushStmt(c.alloc, .verbose, node, .{ .verbose = false });
                } else {
                    return c.reportErrorFmt("Unsupported annotation: {}", &.{v(name)}, node);
                }
            } else {
                return c.reportErrorFmt("Unsupported expr: {}", &.{v(expr.type())}, node);
            }
        },
        else => return c.reportErrorFmt("Unsupported statement: {}", &.{v(node.type())}, node),
    }
}

fn semaElseStmt(c: *cy.Chunk, node: *ast.Node) !u32 {
    if (node.type() == .else_block) {
        const block = node.cast(.else_block);
        if (block.cond) |cond| {
            const irElseIdx = try c.ir.pushEmptyExpr(.else_block, c.alloc, undefined, node);
            const elseCond = try c.semaExprCstr(cond, bt.Boolean);

            try pushBlock(c, node);
            try semaStmts(c, block.stmts);
            const stmtBlock = try popBlock(c);

            c.ir.setExprData(irElseIdx, .else_block, .{
                .cond = elseCond.irIdx, .body_head = stmtBlock.first, .else_block = cy.NullId,
            });
            return irElseIdx;
        } else {
            // else.
            const irElseIdx = try c.ir.pushEmptyExpr(.else_block, c.alloc, undefined, node);
            try pushBlock(c, node);
            try semaStmts(c, block.stmts);
            const stmtBlock = try popBlock(c);

            c.ir.setExprData(irElseIdx, .else_block, .{
                .cond = cy.NullId, .body_head = stmtBlock.first, .else_block = cy.NullId,
            });

            return irElseIdx;
        }
    } else return error.TODO;
}

fn semaIfUnwrapStmt2(c: *cy.Chunk, opt: ExprResult, opt_n: *ast.Node, opt_unwrap: ?*ast.Node, body: *const fn (*cy.Chunk, *anyopaque) anyerror!void, body_data: *anyopaque, else_blocks: []*ast.ElseBlock, node: *ast.Node) !void {
    try pushBlock(c, @ptrCast(node));
    {
        // $opt = <opt>
        const opt_v = try declareHiddenLocal(c, "$opt", opt.type.toDeclType(), opt, opt_n);
        const get_opt = try semaLocal(c, opt_v.id, opt_n);

        // if !isNone($opt)
        var cond = try c.semaIsNone(get_opt, opt_n);
        const irIdx = try c.ir.pushExpr(.preUnOp, c.alloc, bt.Boolean, opt_n, .{ .unOp = .{
            .childT = bt.Boolean, .op = .not, .expr = cond.irIdx,
        }});
        cond.irIdx = irIdx;
        try pushBlock(c, @ptrCast(node));
        {
            // $unwrap = $opt.?
            const unwrap_t = if (opt.type.isDynAny()) bt.Dyn else b: {
                break :b c.sema.getTypeSym(opt.type.id).cast(.enum_t).getMemberByIdx(1).payloadType;
            };
            var unwrap_name: []const u8 = undefined;
            if (opt_unwrap) |unwrap| {
                if (unwrap.type() == .ident) {
                    unwrap_name = c.ast.nodeString(unwrap);
                } else if (unwrap.type() == .seqDestructure) {
                    unwrap_name = "$unwrap";
                } else {
                    return c.reportErrorFmt("Unsupported unwrap declaration: {}", &.{v(unwrap.type())}, unwrap);
                }
                const unwrap_init = try semaAccessEnumPayload(c, get_opt, "some", unwrap);
                const unwrap_v = try declareLocalInit(c, unwrap_name, unwrap_t, unwrap_init, unwrap);
                const unwrap_local = try semaLocal(c, unwrap_v.id, unwrap);

                if (unwrap.type() == .seqDestructure) {
                    const decls = unwrap.cast(.seqDestructure).args;
                    for (decls, 0..) |decl, i| {
                        const name = c.ast.nodeString(decl);
                        var index = try c.semaInt(@intCast(i), unwrap);
                        index.irIdx = try c.ir.pushExpr(.box, c.alloc, bt.Any, unwrap, .{
                            .expr = index.irIdx,
                        });
                        index.type.id = bt.Any;
                        const dvar_init = try semaIndexExpr2(c, unwrap_local, unwrap, index, unwrap, unwrap);
                        _ = try declareLocalInit(c, name, bt.Dyn, dvar_init, unwrap);
                    }
                }
            }

            try body(c, body_data);
        }
        const block = try popBlock(c);
        var first_else: u32 = cy.NullId;
        if (else_blocks.len > 0) {
            var else_loc = try semaElseStmt(c, @ptrCast(else_blocks[0]));
            first_else = else_loc;

            for (else_blocks[1..]) |else_block| {
                const next_else_loc = try semaElseStmt(c, @ptrCast(else_block));
                c.ir.getExprDataPtr(else_loc, .else_block).else_block = next_else_loc;
                else_loc = next_else_loc;
            }
        }
        try semaIfStmt2(c, cond, block.first, first_else, node);
    }
    const block = try popBlock(c);
    _ = try c.ir.pushStmt(c.alloc, .block, node, .{ .bodyHead = block.first });
}

fn semaIfUnwrapStmt(c: *cy.Chunk, stmt: *ast.IfUnwrapStmt) !void {
    const opt = try c.semaOptionExpr(stmt.opt);
    const S = struct {
        fn body(c_: *cy.Chunk, data: *anyopaque) !void {
            const stmt_: *ast.IfUnwrapStmt = @ptrCast(@alignCast(data));
            try semaStmts(c_, stmt_.stmts);
        }
    }; 
    try semaIfUnwrapStmt2(c, opt, stmt.opt, stmt.unwrap, S.body, stmt, stmt.else_blocks, @ptrCast(stmt));
}

fn semaIfStmt2(c: *cy.Chunk, cond: ExprResult, first_stmt: u32, else_block: u32, node: *ast.Node) !void {
    const irIdx = try c.ir.pushEmptyStmt(c.alloc, .ifStmt, node);
    c.ir.setStmtData(irIdx, .ifStmt, .{
        .cond = cond.irIdx,
        .body_head = first_stmt,
        .else_block = else_block,
    });
}

fn semaIfStmt(c: *cy.Chunk, block: *ast.IfStmt) !void {
    const irIdx = try c.ir.pushEmptyStmt(c.alloc, .ifStmt, @ptrCast(block));

    const cond = try c.semaExprCstr(block.cond, bt.Boolean);

    try pushBlock(c, @ptrCast(block));
    try semaStmts(c, block.stmts);
    const ifStmtBlock = try popBlock(c);

    if (block.else_blocks.len == 0) {
        c.ir.setStmtData(irIdx, .ifStmt, .{
            .cond = cond.irIdx,
            .body_head = ifStmtBlock.first,
            .else_block = cy.NullId,
        });
        return;
    }

    var else_loc = try semaElseStmt(c, @ptrCast(block.else_blocks[0]));
    c.ir.setStmtData(irIdx, .ifStmt, .{
        .cond = cond.irIdx,
        .body_head = ifStmtBlock.first,
        .else_block = else_loc,
    });

    for (block.else_blocks[1..]) |else_block| {
        const next_else_loc = try semaElseStmt(c, @ptrCast(else_block));
        c.ir.getExprDataPtr(else_loc, .else_block).else_block = next_else_loc;
        else_loc = next_else_loc;
    }
}

const AssignOptions = struct {
    rhsOpAssignBinExpr: bool = false,
};

/// Pass rightId explicitly to perform custom sema on op assign rhs.
fn assignStmt(c: *cy.Chunk, node: *ast.Node, left_n: *ast.Node, right: *ast.Node, opts: AssignOptions) !u32 {
    switch (left_n.type()) {
        .array_expr => {
            const left = left_n.cast(.array_expr);
            if (left.args.len != 1) {
                return c.reportErrorFmt("Unsupported array expr.", &.{}, left_n);
            }

            const rec = try c.semaExpr(left.left, .{});

            var final_right = right;
            if (opts.rhsOpAssignBinExpr) {
                // Push bin expr.
                const op_assign = right.cast(.opAssignStmt);
                final_right = try c.parser.ast.newNodeErase(.binExpr, .{
                    .left = left_n,
                    .right = op_assign.right,
                    .op = op_assign.op,
                    .op_pos = op_assign.assign_pos,
                });
            }

            if (rec.type.isDynAny()) {
                const index = try c.semaExprCstr(left.args[0], bt.Dyn);
                const right_res = try c.semaExprCstr(final_right, bt.Dyn);
                const res = try c.semaCallObjSym2(rec.irIdx, "$setIndex", &.{index, right_res}, node);
                return c.ir.pushStmt(c.alloc, .exprStmt, node, .{
                    .expr = res.irIdx,
                    .isBlockResult = false,
                });
            }

            const rec_type_sym = c.sema.getTypeSym(rec.type.id);
            const set_index_sym = try c.mustFindSym(rec_type_sym, "$setIndex", left_n);
            const func_sym = try requireFuncSym(c, set_index_sym, left_n);

            const res = try c.semaCallFuncSymRec(func_sym, left.left, rec,
                &.{ left.args[0], final_right }, .any, node);
            return c.ir.pushStmt(c.alloc, .exprStmt, node, .{
                .expr = res.irIdx,
                .isBlockResult = false,
            });
        },
        .accessExpr => {
            const left = left_n.cast(.accessExpr);
            const rec = try c.semaExpr(left.left, .{});
            const name = c.ast.nodeString(left.right);
            const type_sym = c.sema.getTypeSym(rec.type.id);
            const debug_node = left.right;
            if (rec.type.isDynAny()) {
                const expr = Expr.initRequire(right, bt.Dyn);
                const right_res = try c.semaExprOrOpAssignBinExpr(expr, opts.rhsOpAssignBinExpr);
                return try c.ir.pushStmt(c.alloc, .set_field_dyn, debug_node, .{ .set_field_dyn = .{
                    .name = name,
                    .rec = rec.irIdx,
                    .right = right_res.irIdx,
                }});
            }

            const sym = type_sym.getMod().?.getSym(name) orelse {
                // TODO: This depends on $get being known, make sure $get is a nested declaration.
                const type_e = c.sema.types.items[type_sym.getStaticType().?];
                if (type_e.has_set_method) {
                    const expr = Expr.initRequire(right, bt.Dyn);
                    const right_res = try c.semaExprOrOpAssignBinExpr(expr, opts.rhsOpAssignBinExpr);
                    return try c.ir.pushStmt(c.alloc, .set_field_dyn, debug_node, .{ .set_field_dyn = .{
                        .name = name,
                        .rec = rec.irIdx,
                        .right = right_res.irIdx,
                    }});
                }

                if (type_sym.getVariant()) |variant| {
                    if (variant.getSymTemplate() == c.sema.pointer_tmpl) {
                        const child_t = variant.args[0].castHeapObject(*cy.heap.Type).type;
                        const child_ts = c.sema.getTypeSym(child_t);
                        const sym = child_ts.getMod().?.getSym(name) orelse {
                            const type_name = child_ts.name();
                            return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, debug_node);
                        };
                        if (sym.type != .field) {
                            const type_name = child_ts.name();
                            return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(name)}, debug_node);
                        }
                        const field_s = sym.cast(.field);
                        const expr = Expr.initRequire(right, field_s.type);
                        const right_res = try c.semaExprOrOpAssignBinExpr(expr, opts.rhsOpAssignBinExpr);
                        // Take address of field, and perform deref assignment.
                        var loc = try c.ir.pushExpr(.field, c.alloc, field_s.type, debug_node, .{
                            .idx = @intCast(field_s.idx),
                            .rec = rec.irIdx,
                            .parent_t = child_t,
                        });
                        const ptr_t = try getPointerType(c, field_s.type);
                        loc = try c.ir.pushExpr(.address_of, c.alloc, ptr_t, debug_node, .{
                            .expr = loc,
                        });
                        return try c.ir.pushStmt(c.alloc, .set_deref, debug_node, .{
                            .ptr = loc,
                            .right = right_res.irIdx,
                        });
                    }
                }

                const type_name = type_sym.name();
                return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, debug_node);
            };
            if (sym.type != .field) {
                const type_name = type_sym.name();
                return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(name)}, debug_node);
            }
            const field_s = sym.cast(.field);

            if (c.sema.getTypeKind(rec.type.id) == .struct_t) {
                if (rec.resType == .field) {
                    const prev = c.ir.getExprDataPtr(rec.irIdx, .field);
                    prev.member_cont = true;
                }
            }
            const loc = try c.ir.pushExpr(.field, c.alloc, field_s.type, debug_node, .{
                .idx = @intCast(field_s.idx),
                .rec = rec.irIdx,
                .parent_t = rec.type.id,
            });

            const expr = Expr.initRequire(right, field_s.type);
            const right_res = try c.semaExprOrOpAssignBinExpr(expr, opts.rhsOpAssignBinExpr);
            return try c.ir.pushStmt(c.alloc, .set_field, debug_node, .{ .set_field = .{
                .field = loc,
                .right = right_res.irIdx,
            }});
        },
        .deref => {
            const ptr_n = left_n.cast(.deref).left;
            const ptr = try c.semaExpr(ptr_n, .{});
            const ptr_t = ptr.type.id;

            const child_t = c.sema.getTypeSym(ptr_t).getVariant().?.args[0].castHeapObject(*cy.heap.Type).type;
            const expr = Expr.initRequire(right, child_t);
            const right_res = try c.semaExprOrOpAssignBinExpr(expr, opts.rhsOpAssignBinExpr);
            return try c.ir.pushStmt(c.alloc, .set_deref, left_n, .{
                .ptr = ptr.irIdx,
                .right = right_res.irIdx,
            });
        },
        .ident => {
            var right_res: ExprResult = undefined;
            const leftRes = try c.semaExpr(left_n, .{});
            const leftT = leftRes.type;
            if (leftRes.resType == .local) {
                right_res = try assignToLocalVar(c, leftRes, right, opts);
            } else if (leftRes.resType == .field) {
                const expr = Expr.initRequire(right, leftT.id);
                right_res = try c.semaExprOrOpAssignBinExpr(expr, opts.rhsOpAssignBinExpr);
                return try c.ir.pushStmt(c.alloc, .set_field, left_n, .{ .set_field = .{
                    .field = leftRes.irIdx,
                    .right = right_res.irIdx,
                }});
            } else if (leftRes.resType == .global) {
                const rightExpr = Expr.initRequire(right, leftT.id);
                right_res = try c.semaExprOrOpAssignBinExpr(rightExpr, opts.rhsOpAssignBinExpr);

                const name = c.ast.nodeString(left_n);
                const key = try c.semaString(name, left_n);

                const map = try symbol(c, @ptrCast(c.compiler.global_sym.?), Expr.init(left_n), true);
                const map_sym = c.sema.getTypeSym(bt.Map);
                const set_index = map_sym.getMod().?.getSym("$setIndex").?;

                const arg_start = c.arg_stack.items.len;
                defer c.arg_stack.items.len = arg_start;
                try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(left_n, map));
                try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(left_n, key));
                try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(right, right_res));
                const cstr = sema.CallCstr{ .ret = .any };
                const func_res = try sema.matchFuncSym(c, set_index.cast(.func), arg_start, 3, cstr, node);
                const res = try c.semaCallFuncSymResult(set_index.cast(.func), func_res, cstr.ct_call, node);

                return c.ir.pushStmt(c.alloc, .exprStmt, node, .{
                    .expr = res.irIdx,
                    .isBlockResult = false,
                });
            } else {
                const rightExpr = Expr{
                    .node = right,
                    .reqTypeCstr = !leftT.dynamic,
                    .target_t = if (leftT.dynamic) bt.Dyn else leftT.id,
                    .fit_target = true,
                    .fit_target_unbox_dyn = !leftT.dynamic
                };
                right_res = try c.semaExprOrOpAssignBinExpr(rightExpr, opts.rhsOpAssignBinExpr);
            }

            switch (leftRes.resType) {
                .varSym         => {
                    const left_ir = c.ir.getExprData(leftRes.irIdx, .varSym);
                    return try c.ir.pushStmt(c.alloc, .set_var_sym, node, .{
                        .sym = left_ir.sym,
                        .expr = right_res.irIdx,
                    });
                },
                .func           => {
                    return c.reportErrorFmt("Can not reassign to a namespace function.", &.{}, node);
                },
                .local          => {
                    const irStart = try c.ir.pushEmptyStmt(c.alloc, .set, node);
                    c.ir.setStmtData(irStart, .set, .{ .generic = .{
                        .left_t = leftT,
                        .right_t = right_res.type,
                        .left = leftRes.irIdx,
                        .right = right_res.irIdx,
                    }});
                    c.ir.setStmtCode(irStart, .setLocal);
                    c.varStack.items[leftRes.data.local].vtype = right_res.type;
                    const info = c.varStack.items[leftRes.data.local].inner.local;
                    c.ir.setStmtData(irStart, .setLocal, .{ .local = .{
                        .id = info.id,
                        .right = right_res.irIdx,
                    }});
                    return irStart;
                },
                .capturedLocal  => {
                    const irStart = try c.ir.pushEmptyStmt(c.alloc, .set, node);
                    c.ir.setStmtData(irStart, .set, .{ .generic = .{
                        .left_t = leftT,
                        .right_t = right_res.type,
                        .left = leftRes.irIdx,
                        .right = right_res.irIdx,
                    }});
                    c.ir.setStmtCode(irStart, .setCaptured);
                    return irStart;
                },
                else => {
                    log.tracev("leftRes {s} {}", .{@tagName(leftRes.resType), leftRes.type});
                    return c.reportErrorFmt("Assignment to the left `{}` is unsupported.", &.{v(left_n.type())}, node);
                }
            }
        },
        else => {
            return c.reportErrorFmt("Assignment to the left `{}` is unsupported.", &.{v(left_n.type())}, node);
        }
    }
}

fn semaIndexExpr2(c: *cy.Chunk, left: ExprResult, left_n: *ast.Node, arg0: ExprResult, arg0_n: *ast.Node, node: *ast.Node) !ExprResult {
    const leftT = left.type.id;
    if (left.type.isDynAny()) {
        return c.semaCallObjSym2(left.irIdx, getBinOpName(.index), &.{arg0}, node);
    }

    const recTypeSym = c.sema.getTypeSym(leftT);
    const sym = try c.mustFindSym(recTypeSym, "$index", node);
    const func_sym = try requireFuncSym(c, sym, node);

    return c.semaCallFuncSymRec2(func_sym,
        left_n, left,
        &.{arg0}, &.{arg0_n}, .any, node);
}

fn semaSliceExpr(c: *cy.Chunk, left: *ast.Node, left_res: ExprResult, range: *ast.Range, node: *ast.Node) !ExprResult {
    var b: ObjectBuilder = .{ .c = c };
    try b.begin(bt.Range, 2, @ptrCast(range));
    if (range.start) |start| {
        const start_res = try c.semaExprCstr(start, bt.Integer);
        b.pushArg(start_res);
    } else {
        const start_res = try c.semaInt(0, @ptrCast(range));
        b.pushArg(start_res);
    }
    if (range.end) |end| {
        const end_res = try c.semaExprCstr(end, bt.Integer);
        b.pushArg(end_res);
    } else {
        if (left_res.type.isDynAny()) {
            const len_res = try c.semaCallObjSym0(left_res.irIdx, "len", @ptrCast(range));
            const loc = try c.ir.pushExpr(.unbox, c.alloc, bt.Integer, @ptrCast(range), .{
                .expr = len_res.irIdx,
            });
            b.pushArg(ExprResult.initStatic(loc, bt.Integer));
        } else {
            const recTypeSym = c.sema.getTypeSym(left_res.type.id);
            const sym = try c.mustFindSym(recTypeSym, "len", @ptrCast(range));
            const func_sym = try requireFuncSym(c, sym, @ptrCast(range));

            const end_res = try c.semaCallFuncSymRec(func_sym,
                left, left_res,
                &.{}, .any, @ptrCast(range));
            b.pushArg(end_res);
        }
    }
    const range_loc = b.end();
    const range_res = ExprResult.initStatic(range_loc, bt.Range);

    if (left_res.type.isDynAny()) {
        return c.semaCallObjSym2(left_res.irIdx, getBinOpName(.index), &.{range_res}, node);
    } else {
        const recTypeSym = c.sema.getTypeSym(left_res.type.id);
        const sym = try c.mustFindSym(recTypeSym, "$index", node);
        const func_sym = try requireFuncSym(c, sym, node);
        return c.semaCallFuncSymRec2(func_sym,
            left, left_res,
            &.{range_res}, &.{@ptrCast(range)}, .any, node);
    }
}

fn semaIndexExpr(c: *cy.Chunk, left: *ast.Node, left_res: ExprResult, expr: Expr) !ExprResult {
    const array = expr.node.cast(.array_expr);
    if (array.args.len != 1) {
        return c.reportErrorFmt("Unsupported array expr.", &.{}, expr.node);
    }

    if (array.args[0].type() == .range) {
        return semaSliceExpr(c, left, left_res, array.args[0].cast(.range), expr.node);
    }

    const leftT = left_res.type.id;
    if (left_res.type.isDynAny()) {
        const index = try c.semaExprCstr(array.args[0], bt.Dyn);
        return c.semaCallObjSym2(left_res.irIdx, getBinOpName(.index), &.{index}, expr.node);
    }

    const recTypeSym = c.sema.getTypeSym(leftT);
    const sym = try c.mustFindSym(recTypeSym, "$index", expr.node);
    const func_sym = try requireFuncSym(c, sym, expr.node);

    const res = try c.semaCallFuncSymRec(func_sym,
        left, left_res,
        array.args, expr.getRetCstr(), expr.node);

    const ptr_or_ref = c.sema.isPointerType(res.type.id) or c.sema.isRefType(res.type.id);
    if (!expr.use_addressable and ptr_or_ref and expr.target_t != res.type.id) {
        const child_t = c.sema.getPointerChildType(res.type.id);
        const loc = try c.ir.pushExpr(.deref, c.alloc, child_t, expr.node, .{
            .expr = res.irIdx,
        });
        return ExprResult.initStatic(loc, child_t);
    } else {
        return res;
    }
}

fn semaAccessField(c: *cy.Chunk, rec: ExprResult, field: *ast.Node) !ExprResult {
    if (field.type() != .ident) {
        return error.Unexpected;
    }
    const name = c.ast.nodeString(field);
    return semaAccessFieldName(c, rec, name, field);
}

fn semaAccessEnumPayload(c: *cy.Chunk, rec: ExprResult, name: []const u8, node: *ast.Node) !ExprResult {
    if (rec.type.isDynAny()) {
        const loc = try c.ir.pushExpr(.fieldDyn, c.alloc, bt.Any, node, .{
            .name = name,
            .rec = rec.irIdx,
        });
        return ExprResult.initCustom(loc, .fieldDyn, CompactType.initDynamic(bt.Any), undefined);
    }
    const type_sym = c.sema.getTypeSym(rec.type.id);
    const sym = type_sym.getMod().?.getSym(name) orelse {
        const type_name = type_sym.name();
        return c.reportErrorFmt("Enum member `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, node);
    };
    if (sym.type != .enumMember) {
        const type_name = type_sym.name();
        return c.reportErrorFmt("Enum `{}` does not have a member named `{}`.", &.{v(type_name), v(name)}, node);
    }
    const payload_t = sym.cast(.enumMember).payloadType;
    const loc = try c.ir.pushExpr(.field, c.alloc, payload_t, node, .{
        .idx = 1,
        .rec = rec.irIdx,
        .parent_t = rec.type.id,
    });
    return ExprResult.initCustom(loc, .field, CompactType.init(payload_t), undefined);
}

fn semaAccessFieldName(c: *cy.Chunk, rec: ExprResult, name: []const u8, field: *ast.Node) !ExprResult {
    if (rec.type.isDynAny()) {
        const loc = try c.ir.pushExpr(.fieldDyn, c.alloc, bt.Any, field, .{
            .name = name,
            .rec = rec.irIdx,
        });
        return ExprResult.initCustom(loc, .fieldDyn, CompactType.initDynamic(bt.Any), undefined);
    }

    const type_sym = c.sema.getTypeSym(rec.type.id);
    const sym = type_sym.getMod().?.getSym(name) orelse {
        // TODO: This depends on $get being known, make sure $get is a nested declaration.
        const type_e = c.sema.types.items[type_sym.getStaticType().?];
        if (type_e.has_get_method) {
            const loc = try c.ir.pushExpr(.fieldDyn, c.alloc, bt.Any, field, .{
                .name = name,
                .rec = rec.irIdx,
            });
            return ExprResult.initCustom(loc, .fieldDyn, CompactType.initDynamic(bt.Any), undefined);
        }

        if (type_sym.getVariant()) |variant| {
            if (variant.getSymTemplate() == c.sema.pointer_tmpl) {
                const child_t = variant.args[0].castHeapObject(*cy.heap.Type).type;
                const child_ts = c.sema.getTypeSym(child_t);
                const sym = child_ts.getMod().?.getSym(name) orelse {
                    const type_name = try c.sema.allocTypeName(child_t);
                    defer c.alloc.free(type_name);
                    return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, field);
                };
                if (sym.type != .field) {
                    const type_name = try c.sema.allocTypeName(child_t);
                    defer c.alloc.free(type_name);
                    return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(name)}, field);
                }
                const field_s = sym.cast(.field);
                // Access on typed pointer.
                const loc = try c.ir.pushExpr(.field, c.alloc, field_s.type, field, .{
                    .idx = @intCast(field_s.idx),
                    .rec = rec.irIdx,
                    .parent_t = child_t,
                });
                return ExprResult.initCustom(loc, .field, CompactType.init(field_s.type), undefined);
            }
        }

        const type_name = type_sym.name();
        return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, field);
    };
    if (sym.type != .field) {
        const type_name = type_sym.name();
        return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(name)}, field);
    }
    const field_sym = sym.cast(.field);
    return semaField(c, rec, field_sym.idx, field_sym.type, field);
}

fn semaField(c: *cy.Chunk, rec: ExprResult, idx: usize, type_id: cy.TypeId, node: *ast.Node) !ExprResult {
    var final_rec = rec;
    const rec_te = c.sema.getType(rec.type.id);
    if (rec_te.kind == .struct_t) {
        if (rec.resType != .local) {
            const tempv = try declareHiddenLocal(c, "$temp", rec.type.id, rec, node);
            const temp = try semaLocal(c, tempv.id, node);
            final_rec = temp;
        }
    }
    const loc = try c.ir.pushExpr(.field, c.alloc, type_id, node, .{
        .idx = @intCast(idx),
        .rec = final_rec.irIdx,
        .parent_t = final_rec.type.id,
    });
    return ExprResult.initCustom(loc, .field, CompactType.init(type_id), undefined);
}

fn checkSymInitField(c: *cy.Chunk, type_sym: *cy.Sym, name: []const u8, node: *ast.Node) !InitFieldResult {
    const sym = type_sym.getMod().?.getSym(name) orelse {
        // // TODO: This depends on $get being known, make sure $get is a nested declaration.
        // const type_e = c.sema.types.items[type_sym.getStaticType().?];
        // if (type_e.has_get_method) {
        //     return .{ .idx = undefined, .typeId = undefined, .use_get_method = true };
        // } else {
            const type_name = type_sym.name();
            return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, node);
        // }
    };
    if (sym.type != .field) {
        const type_name = type_sym.name();
        return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(name)}, node);
    }
    const field = sym.cast(.field);
    return .{
        .idx = @intCast(field.idx),
        .typeId = field.type,
    };
}

const SetFieldResult = struct {
    typeId: TypeId,
    idx: u8,
    use_set_method: bool,
};

const InitFieldResult = struct {
    typeId: TypeId,
    idx: u8,
};

pub fn reserveFuncTemplate(c: *cy.Chunk, decl: *ast.TemplateDecl) !*cy.sym.FuncTemplate {
    // Verify that template params do not have types.
    const tparams = try c.alloc.alloc(cy.sym.FuncTemplateParam, decl.params.len);
    for (decl.params, 0..) |param, i| {
        if (param.type != null) {
            return c.reportErrorFmt("Expected parameter type to be declared in function signature.", &.{}, @ptrCast(param.type));
        }
        tparams[i] = .{
            .name = c.ast.nodeString(param.name_type),
            .decl_idx = cy.NullId,
            .infer = false,
        };
    }
    const func_decl = decl.child_decl.cast(.funcDecl);
    const decl_path = try ensureDeclNamePath(c, @ptrCast(c.sym), func_decl.name);
    return c.reserveFuncTemplate(decl_path.parent, decl_path.name.base_name, tparams, decl);
}

pub fn reserveTemplate(c: *cy.Chunk, node: *ast.TemplateDecl) !*cy.sym.Template {
    var name_n: *ast.Node = undefined;
    var template_t: cy.sym.TemplateType = undefined;
    switch (node.child_decl.type()) {
        .objectDecl => {
            name_n = node.child_decl.cast(.objectDecl).name.?;
            template_t = .object_t;
        },
        .structDecl => {
            name_n = node.child_decl.cast(.structDecl).name.?;
            template_t = .struct_t;
        },
        .enumDecl => {
            name_n = node.child_decl.cast(.enumDecl).name;
            template_t = .enum_t;
        },
        .custom_decl => {
            name_n = node.child_decl.cast(.custom_decl).name;
            template_t = .custom_t;
        },
        .distinct_decl => {
            name_n = node.child_decl.cast(.distinct_decl).name;
            template_t = .distinct_t;
        },
        .funcDecl => {
            name_n = node.child_decl.cast(.funcDecl).name;
            template_t = .value;

            if (ast.findAttr(node.getAttrs(), .host) != null) {
                return c.reportError("A value template can not be binded to a `@host` function. Consider invoking a `@host` function in the template body instead.", @ptrCast(node));
            }
        },
        else => {
            return c.reportErrorFmt("Unsupported type template.", &.{}, @ptrCast(node));
        }
    }

    const decl_path = try ensureDeclNamePath(c, @ptrCast(c.sym), name_n);
    return c.reserveTemplate(decl_path.parent, decl_path.name.base_name, template_t, node);
}

pub fn resolveFuncTemplate(c: *cy.Chunk, template: *cy.sym.FuncTemplate) !void {
    try pushResolveContext(c);
    defer popResolveContext(c);

    // Determine where each template param is declared in the function signature and which are inferrable.
    for (template.func_params, 0..) |param, idx| {
        const name = c.ast.nodeString(param.name_type);
        if (std.mem.eql(u8, "self", name)) {
            continue;
        }
        if (template.indexOfParam(name)) |tidx| {
            if (template.params[tidx].decl_idx != cy.NullId) {
                return c.reportErrorFmt("Function template parameter `{}` is already declared.", &.{v(name)}, @ptrCast(param.name_type));
            }
            template.params[tidx] = .{
                .name = name,
                .decl_idx = @intCast(idx),
                .infer = false,
            };
            param.sema_tparam = true;
            continue;
        }
        try resolveFuncTemplateParamDeep(c, template, param.type.?, idx);
    }
    template.resolved = true;
}

/// TODO: Turn this into an AST walker like the IR walker.
fn resolveFuncTemplateParamDeep(c: *cy.Chunk, template: *cy.sym.FuncTemplate, node: *ast.Node, fidx: usize) !void {
    switch (node.type()) {
        .ident => {
            const name = c.ast.nodeString(node);
            if (template.indexOfParam(name)) |tidx| {
                if (template.params[tidx].decl_idx == cy.NullId) {
                    template.params[tidx].decl_idx = @intCast(fidx);
                    template.params[tidx].infer = true;
                    template.func_params[fidx].sema_infer_tparam = true;
                }
            }
        },
        .ref_slice => {
            const ref_slice = node.cast(.ref_slice);
            try resolveFuncTemplateParamDeep(c, template, ref_slice.elem, fidx);
        },
        .ptr_slice => {
            const ptr_slice = node.cast(.ptr_slice);
            try resolveFuncTemplateParamDeep(c, template, ptr_slice.elem, fidx);
        },
        .ptr => {
            const ptr = node.cast(.ptr);
            try resolveFuncTemplateParamDeep(c, template, ptr.elem, fidx);
        },
        .array_expr => {
            const array_expr = node.cast(.array_expr);
            for (array_expr.args) |arg| {
                try resolveFuncTemplateParamDeep(c, template, arg, fidx);
            }
        },
        else => {
            return c.reportErrorFmt("Unsupported node type `{}`.", &.{v(node.type())}, node);
        }
    }  
}

pub fn resolveTemplate(c: *cy.Chunk, sym: *cy.sym.Template) !void {
    try pushResolveContext(c);
    getResolveContext(c).has_ct_params = true;
    getResolveContext(c).prefer_ct_type = true;
    defer popResolveContext(c);

    var sigId: FuncSigId = undefined;
    var ret: ?*ast.Node = null;
    if (sym.kind == .value) {
        ret = sym.decl.child_decl.cast(.funcDecl).ret;
    }

    const params = try resolveTemplateSig(c, sym.decl.params, ret, &sigId);
    try c.resolveTemplate(sym, sigId, params);
}

/// Explicit `decl` for specialization declarations.
pub fn resolveCustomType(c: *cy.Chunk, decl: *ast.CustomDecl) !*cy.Sym {
    var name: ?[]const u8 = null;
    var has_host_attr = false;
    if (ast.findAttr(decl.attrs, .host)) |attr| {
        has_host_attr = true;
        name = try getHostAttrName(c, attr);
    }
    if (!has_host_attr) {
        return c.reportErrorFmt("Custom type requires a `@host` attribute.", &.{}, @ptrCast(decl));
    }

    const decl_path = try ensureDeclNamePath(c, @ptrCast(c.sym), decl.name);
    const bind_name = name orelse decl_path.name.name_path;
    log.tracev("bind name: {s}", .{bind_name});
    if (c.host_types.get(bind_name)) |host_t| {
        return resolveCustomTypeResult(c, decl_path, decl, host_t);
    }

    const loader = c.type_loader orelse {
        return c.reportErrorFmt("Failed to load custom type `{}`.", &.{v(bind_name)}, @ptrCast(decl));
    };
    const info = C.TypeInfo{
        .mod = c.sym.sym().toC(),
        .name = C.toStr(bind_name),
    };
    var host_t: C.HostType = .{
        .data = .{
            .hostobj = .{
                .out_type_id = null,
                .get_children = null,
                .finalizer = null,
                .pre = false,
            },
        },
        .type = C.BindTypeHostObj,
    };
    log.tracev("Invoke type loader for: {s}", .{bind_name});
    if (!loader(@ptrCast(c.compiler.vm), info, &host_t)) {
        return c.reportErrorFmt("Failed to load custom type `{}`.", &.{v(bind_name)}, @ptrCast(decl));
    }

    return resolveCustomTypeResult(c, decl_path, decl, host_t);
}

pub fn resolveHostObjectType(c: *cy.Chunk, hostobj_t: *cy.sym.HostObjectType,
    get_children: C.GetChildrenFn, finalizer: C.FinalizerFn, opt_type: ?cy.TypeId, pre: bool, load_all_methods: bool) !void {
    const typeid = opt_type orelse try c.sema.pushType();
    hostobj_t.type = typeid;
    c.compiler.sema.types.items[typeid] = .{
        .sym = @ptrCast(hostobj_t),
        .kind = .host_object,
        .info = .{
            .custom_pre = pre,
            .load_all_methods = load_all_methods,
        },
        .data = .{ .host_object = .{
            .getChildrenFn = get_children,
            .finalizerFn = finalizer,
        }},
    };
}

fn resolveCustomTypeResult(c: *cy.Chunk, name_path: DeclNamePathResult, decl: *ast.CustomDecl, host_t: C.HostType) !*cy.Sym {
    switch (host_t.type) {
        C.BindTypeCoreCustom => {
            const type_sym = try c.createHostObjectType(name_path.parent, name_path.name.base_name, decl);
            try resolveHostObjectType(c, type_sym,
                host_t.data.core_custom.get_children,
                host_t.data.core_custom.finalizer,
                host_t.data.core_custom.type_id,
                false,
                host_t.data.core_custom.load_all_methods,
            );
            return @ptrCast(type_sym);
        },
        C.BindTypeHostObj => {
            const type_sym = try c.createHostObjectType(name_path.parent, name_path.name.base_name, decl);
            try resolveHostObjectType(c, type_sym,
                host_t.data.hostobj.get_children,
                host_t.data.hostobj.finalizer,
                null,
                host_t.data.hostobj.pre,
                false,
            );
            if (host_t.data.hostobj.out_type_id) |out_type_id| {
                out_type_id.* = type_sym.type;
            }
            return @ptrCast(type_sym);
        },
        C.BindTypeCreate => {
            const sym = host_t.data.create.create_fn.?(@ptrCast(c.vm), name_path.parent.toC(), C.toNode(@ptrCast(decl)));
            return cy.Sym.fromC(sym);
        },
        else => return error.Unsupported,
    }
}

pub fn reserveDistinctType(c: *cy.Chunk, decl: *ast.DistinctDecl) !*cy.sym.DistinctType {
    const name = c.ast.nodeString(decl.name);

    const sym = try c.reserveDistinctType(@ptrCast(c.sym), name, decl);
    var opt_type: ?cy.TypeId = null;

    if (ast.findAttr(decl.attrs, .host)) |attr| {
        const host_name = try getHostAttrName(c, attr);
        opt_type = try getHostTypeId(c, @ptrCast(sym), host_name, @ptrCast(decl));
    }

    try resolveDistinctTypeId(c, sym, opt_type);
    return sym;
}

pub fn reserveTypeAlias(c: *cy.Chunk, node: *ast.TypeAliasDecl) !*cy.sym.TypeAlias {
    const name = c.ast.nodeString(node.name);
    return c.reserveTypeAlias(@ptrCast(c.sym), name, node);
}

pub fn resolveTypeAlias(c: *cy.Chunk, sym: *cy.sym.TypeAlias) !void {
    try sema.pushResolveContext(c);
    defer sema.popResolveContext(c);

    sym.type = try cy.sema.resolveTypeSpecNode(c, sym.decl.typeSpec);
    sym.sym = c.sema.types.items[sym.type].sym;
    // Merge modules.
    const mod = sym.getMod();
    const src_sym = sym.sym;
    const src_mod = src_sym.getMod().?;
    var iter = mod.symMap.iterator();
    while (iter.next()) |e| {
        const name = e.key_ptr.*;
        const child = e.value_ptr.*;
        if (src_mod.symMap.contains(name)) {
            try cy.module.reportDupSym(c, child, name, @ptrCast(sym.decl));
        }
        child.parent = src_sym;
        try src_mod.symMap.putNoClobber(c.alloc, name, child);
    }
    mod.retainedVars.clearAndFree(c.alloc);
    mod.symMap.clearAndFree(c.alloc);
    mod.overloadedFuncMap.clearAndFree(c.alloc);
    sym.resolved = true;
}

pub fn reserveUseAlias(c: *cy.Chunk, node: *ast.UseAlias) !*cy.sym.UseAlias {
    const name = c.ast.nodeString(node.name);
    return c.reserveUseAlias(@ptrCast(c.sym), name, @ptrCast(node));
}

pub fn resolveUseAlias(c: *cy.Chunk, sym: *cy.sym.UseAlias) anyerror!void {
    const r_sym = try cte.resolveCtSym(c, sym.decl.?.cast(.use_alias).target);
    sym.sym = r_sym;
    sym.resolved = true;
}

pub fn declareUseImport(c: *cy.Chunk, node: *ast.ImportStmt) !void {
    var specPath: []const u8 = undefined;
    if (node.spec) |spec| {
        if (spec.type() != .raw_string_lit) {
            // use alias.
            return error.TODO;
        }
        specPath = c.ast.nodeString(spec);
    } else {
        if (node.name.type() == .ident) {
            // Single ident import.
            specPath = c.ast.nodeString(node.name);
        } else {
            // use path.
            return error.TODO;
        }
    }

    if (std.mem.eql(u8, "$global", specPath)) {
        if (c.use_global) {
            return c.reportErrorFmt("`use $global` is already declared.", &.{}, @ptrCast(node));
        }
        c.use_global = true;
        if (c.compiler.global_sym == null) {
            const global = try c.reserveUserVar(@ptrCast(c.compiler.main_chunk.sym), "$global", null);
            c.resolveUserVarType(global, bt.Map);

            // Mark as resolved and emitted.
            global.ir = 0;
            global.emitted = true;

            c.compiler.global_sym = global;

            const func = try c.reserveHostFunc(@ptrCast(c.compiler.main_chunk.sym), "$getGlobal", null, false, false);
            const func_sig = try c.sema.ensureFuncSigRt(&.{ bt.Map, bt.Any }, bt.Dyn);
            try c.resolveHostFunc(func, func_sig, cy.bindings.getGlobal);
            c.compiler.get_global = func;
        }
        return;
    }

    var buf: [4096]u8 = undefined;
    const uri = try cy.compiler.resolveModuleUriFrom(c, &buf, specPath, node.spec);

    // resUri is duped. Moves to chunk afterwards.
    const dupedResUri = try c.alloc.dupe(u8, uri);

    // Queue import task.
    var task = cy.compiler.ImportTask{
        .type = .use_alias,
        .from = c,
        .node = node,
        .resolved_spec = dupedResUri,
        .data = undefined,
    };
    if (node.name.type() != .all) {
        const name = c.ast.nodeString(node.name);
        const sym = try c.reserveUseAlias(@ptrCast(c.sym), name, @ptrCast(node));
        task.data = .{ .use_alias = .{
            .sym = sym,
        }};
    }
    try c.compiler.import_tasks.append(c.alloc, task);
}

pub fn declareModuleAlias(c: *cy.Chunk, node: *ast.ImportStmt) !void {
    const name = c.ast.nodeString(node.name);

    var specPath: []const u8 = undefined;
    if (node.spec) |spec| {
        specPath = c.ast.nodeString(spec);
    } else {
        specPath = name;
    }

    var buf: [4096]u8 = undefined;
    const uri = try cy.compiler.resolveModuleUri(c, &buf, specPath, node.spec);

    const import = try c.declareModuleAlias(@ptrCast(c.sym), name, undefined, node);

    // resUri is duped. Moves to chunk afterwards.
    const dupedResUri = try c.alloc.dupe(u8, uri);

    // Queue import task.
    try c.compiler.import_tasks.append(c.alloc, .{
        .type = .module_alias,
        .from = c,
        .node = node,
        .absSpec = dupedResUri,
        .data = .{ .module_alias = .{
            .sym = import,
        }},
    });
}

pub fn reserveEnum(c: *cy.Chunk, node: *ast.EnumDecl) !*cy.sym.EnumType {
    const name = c.ast.nodeString(node.name);
    const sym = try c.reserveEnumType(@ptrCast(c.sym), name, node.isChoiceType, node);
    if (node.isChoiceType) {
        _ = try c.reserveEnumType(@ptrCast(sym), "Tag", false, node);
    }
    return sym;
}

pub fn resolveEnumType(c: *cy.Chunk, sym: *cy.sym.EnumType, decl: *ast.EnumDecl) !void {
    if (sym.variant != null) {
        try pushVariantResolveContext(c, sym.variant.?);
    } else {
        try pushResolveContext(c);
    }
    defer popResolveContext(c);

    try declareEnumMembers(c, sym, decl);

    if (sym.isChoiceType) {
        const tag_sym = sym.getMod().getSym("Tag").?.cast(.enum_t);
        try declareEnumMembers(c, tag_sym, decl);
    }
}

/// Explicit `decl` node for distinct type declarations. Must belong to `c`.
pub fn declareEnumMembers(c: *cy.Chunk, sym: *cy.sym.EnumType, decl: *ast.EnumDecl) !void {
    if (sym.isResolved()) {
        return;
    }
    const members = try c.alloc.alloc(*cy.sym.EnumMember, decl.members.len);
    for (decl.members, 0..) |member, i| {
        const mName = c.ast.nodeString(member.name);
        var payloadType: cy.TypeId = bt.Void;
        if (sym.isChoiceType and member.typeSpec != null) {
            payloadType = try resolveTypeSpecNode(c, member.typeSpec);
        }
        const modSymId = try c.declareEnumMember(@ptrCast(sym), mName, sym.type, sym.isChoiceType, @intCast(i), payloadType, member);
        members[i] = modSymId;
    }
    sym.member_ptr = members.ptr;
    sym.member_len = @intCast(members.len);
}

/// Only allows binding a predefined host type id (BIND_TYPE_DECL).
pub fn getHostTypeId(c: *cy.Chunk, type_sym: *cy.Sym, opt_name: ?[]const u8, node: ?*ast.Node) !cy.TypeId {
    const bind_name = opt_name orelse type_sym.name();
    if (c.host_types.get(bind_name)) |host_t| {
        switch (host_t.type) {
            C.BindTypeDecl => {
                if (host_t.data.decl.type_id != cy.NullId) {
                    return host_t.data.decl.type_id;
                }
                const type_id = try c.sema.pushType();
                if (host_t.data.decl.out_type_id) |out_type_id| {
                    out_type_id.* = type_id;
                }
                return type_id;
            },
            else => return error.Unsupported,
        }
    }

    const loader = c.type_loader orelse {
        return c.reportErrorFmt("Failed to load @host type `{}`.", &.{v(bind_name)}, node);
    };

    const info = C.TypeInfo{
        .mod = c.sym.sym().toC(),
        .name = C.toStr(bind_name),
    };
    var host_t: C.HostType = .{
        .data = .{
            .hostobj = .{
                .out_type_id = null,
                .get_children = null,
                .finalizer = null,
            },
        },
        .type = C.BindTypeHostObj,
    };
    log.tracev("Invoke type loader for: {s}", .{bind_name});
    if (!loader(@ptrCast(c.compiler.vm), info, &host_t)) {
        return c.reportErrorFmt("Failed to load @host type `{}`.", &.{v(bind_name)}, node);
    }

    if (host_t.type != C.BindTypeDecl) {
        return error.Unsupported;
    }
    if (host_t.data.decl.type_id != cy.NullId) {
        return host_t.data.decl.type_id;
    }
    const type_id = try c.sema.pushType();
    if (host_t.data.decl.out_type_id) |out_type_id| {
        out_type_id.* = type_id;
    }
    return type_id;
}

const ResolveContextType = enum(u8) {
    incomplete,
    sym,
    func,
};

pub const ResolveContext = struct {
    type: ResolveContextType,
    has_ct_params: bool,

    has_parent_ctx: bool = false,

    /// Prefer the comptime type when encountering a runtime type. (e.g. For template param types)
    prefer_ct_type: bool = false,

    /// Compile-time params in this context.
    /// TODO: Avoid hash map if 2 or fewer ct params.
    ct_params: std.StringHashMapUnmanaged(cy.Value),

    data: union {
        sym: *cy.Sym,
        func: *cy.Func,
    },

    pub fn deinit(self: *ResolveContext, c: *cy.Chunk) void {
        var iter = self.ct_params.iterator();
        while (iter.next()) |e| {
            c.vm.release(e.value_ptr.*);
        }
        self.ct_params.deinit(c.alloc);
    }

    pub fn setCtParam(self: *ResolveContext, alloc: std.mem.Allocator, name: []const u8, val: cy.Value) !void {
        const res = try self.ct_params.getOrPut(alloc, name);
        if (res.found_existing) {
            return error.DuplicateParam;
        }
        res.value_ptr.* = val;
    }
};

pub fn pushVariantResolveContext(c: *cy.Chunk, variant: *cy.sym.Variant) !void {
    switch (variant.type) {
        .sym => {
            var new = ResolveContext{
                .type = .sym,
                .has_ct_params = true,
                .ct_params = .{},
                .data = .{ .sym = variant.data.sym.sym },
            };
            try setContextTemplateParams(c, &new, variant.data.sym.template, variant.args);
            try c.resolve_stack.append(c.alloc, new);
        }, 
        .ct_val => {
            var new = ResolveContext{
                .type = .incomplete,
                .has_ct_params = true,
                .ct_params = .{},
                .data = undefined,
            };
            try setContextTemplateParams(c, &new, variant.data.ct_val.template, variant.args);
            try c.resolve_stack.append(c.alloc, new);
        },
        .func => {
            var new = ResolveContext{
                .type = .func,
                .has_ct_params = true,
                .ct_params = .{},
                .data = .{ .func = variant.data.func.func },
            };
            for (variant.data.func.template.params, 0..) |param, i| {
                const arg = variant.args[i];
                c.vm.retain(arg);
                try new.setCtParam(c.alloc, param.name, arg);
            }
            try c.resolve_stack.append(c.alloc, new);
        },
    }
}

pub fn setContextTemplateParams(c: *cy.Chunk, ctx: *ResolveContext, template: *cy.sym.Template, args: []const cy.Value) !void {
    for (template.params, 0..) |param, i| {
        const arg = args[i];
        c.vm.retain(arg);
        try ctx.setCtParam(c.alloc, param.name, arg);
    }
}

pub fn pushSymResolveContext(c: *cy.Chunk, sym: *cy.Sym) !void {
    const new = ResolveContext{
        .type = .sym,
        .has_ct_params = false,
        .ct_params = .{},
        .data = .{ .sym = sym },
    };
    try c.resolve_stack.append(c.alloc, new);
}

pub fn pushFuncResolveContext(c: *cy.Chunk, func: *cy.Func) !void {
    const new = ResolveContext{
        .type = .func,
        .has_ct_params = false,
        .ct_params = .{},
        .data = .{ .func = func },
    };
    try c.resolve_stack.append(c.alloc, new);
}

pub fn pushResolveContext(c: *cy.Chunk) !void {
    const new = ResolveContext{
        .type = .incomplete,
        .has_ct_params = false,
        .ct_params = .{},
        .data = undefined,
    };
    try c.resolve_stack.append(c.alloc, new);
}

pub fn pushSavedResolveContext(c: *cy.Chunk, ctx: ResolveContext) !void {
    try c.resolve_stack.append(c.alloc, ctx);
}

pub fn setResolveCtParam(c: *cy.Chunk, name: []const u8, param: cy.Value) !void {
    try c.resolve_stack.items[c.resolve_stack.items.len-1].setCtParam(c.alloc, name, param);
}

pub fn popResolveContext(c: *cy.Chunk) void {
    const last = &c.resolve_stack.items[c.resolve_stack.items.len-1];
    last.deinit(c);
    c.resolve_stack.items.len -= 1;
}

pub fn saveResolveContext(c: *cy.Chunk) ResolveContext {
    const last = c.resolve_stack.items[c.resolve_stack.items.len-1];
    c.resolve_stack.items.len -= 1;
    return last;
}

/// Allow an explicit `opt_header_decl` so that template specialization can use it to override @host attributes.
pub fn reserveFuncTemplateVariant(c: *cy.Chunk, template: *cy.sym.FuncTemplate, opt_header_decl: ?*ast.Node, variant: *cy.sym.Variant) !*cy.sym.Func {
    var func: *cy.Func = undefined;
    const decl = template.decl.child_decl.cast(.funcDecl);
    const is_method = c.ast.isMethodDecl(decl);
    if (decl.stmts.len == 0) {
        func = try c.createFunc(.hostFunc, @ptrCast(template), @ptrCast(opt_header_decl), is_method);
        func.data = .{ .hostFunc = .{
            .ptr = undefined,
        }};
    } else {
        func = try c.createFunc(.userFunc, @ptrCast(template), @ptrCast(opt_header_decl), is_method);
    }
    func.is_nested = false;
    func.variant = variant;
    return func;
}

/// Allow an explicit `opt_header_decl` so that template specialization can use it to override @host attributes.
pub fn reserveTemplateVariant(c: *cy.Chunk, template: *cy.sym.Template, opt_header_decl: ?*ast.Node, variant: *cy.sym.Variant) !*cy.sym.Sym {
    const tchunk = template.chunk();
    const name = template.head.name();

    switch (template.kind) {
        .object_t => {
            const decl = template.decl.child_decl.cast(.objectDecl);
            const object_t = try c.createObjectType(@ptrCast(c.sym), name, @ptrCast(decl));
            object_t.variant = variant;

            const header_decl = opt_header_decl orelse template.decl.child_decl;
            const type_id = try resolveTypeIdFromDecl(c, @ptrCast(object_t), header_decl.cast(.objectDecl).attrs, header_decl);
            try resolveObjectTypeId(c, object_t, decl.is_tuple, type_id);

            return @ptrCast(object_t);
        },
        .struct_t => {
            const decl = template.decl.child_decl.cast(.structDecl);
            const struct_t = try c.createStructType(@ptrCast(c.sym), name, false, @ptrCast(decl));
            struct_t.variant = variant;

            const header_decl = opt_header_decl orelse template.decl.child_decl;
            const type_id = try resolveTypeIdFromDecl(c, @ptrCast(struct_t), header_decl.cast(.structDecl).attrs, header_decl);
            try resolveStructTypeId(c, struct_t, decl.is_tuple, type_id);

            return @ptrCast(struct_t);
        },
        .custom_t => {
            const header_decl = opt_header_decl orelse template.decl.child_decl;

            try pushVariantResolveContext(tchunk, variant);
            defer popResolveContext(tchunk);

            const custom_t = try resolveCustomType(tchunk, header_decl.cast(.custom_decl));
            try custom_t.setVariant(variant);

            if (template == c.sema.future_tmpl) {
                c.sema.types.items[custom_t.getStaticType().?].info.is_future = true;
            }

            return custom_t;
        },
        .enum_t => {
            const decl = template.decl.child_decl.cast(.enumDecl);
            const sym = try c.createEnumType(@ptrCast(c.sym), name, decl.isChoiceType, decl);
            sym.variant = variant;
            if (template == c.sema.option_tmpl) {
                c.compiler.sema.types.items[sym.type].kind = .option;
            }
            if (decl.isChoiceType) {
                _ = try c.reserveEnumType(@ptrCast(sym), "Tag", false, decl);
            }
            return @ptrCast(sym);
        },
        .distinct_t => {
            const decl = template.decl.child_decl.cast(.distinct_decl);
            const sym = try c.createDistinctType(@ptrCast(c.sym), name, decl);
            sym.variant = variant;

            const header_decl = opt_header_decl orelse template.decl.child_decl;
            const type_id = try resolveTypeIdFromDecl(c, @ptrCast(sym), header_decl.cast(.distinct_decl).attrs, header_decl);
            try resolveDistinctTypeId(c, sym, type_id);

            return @ptrCast(sym);
        },
        .value => {
            return error.Unexpected;
        },
    }
}

/// TODO: Load methods on-demand for tree-shaking.
pub fn resolveTemplateVariant(c: *cy.Chunk, template: *cy.sym.Template, sym: *cy.Sym) anyerror!*cy.Sym {
    // Skip resolving if it's a compile-time infer type.
    const type_e = c.sema.types.items[sym.getStaticType().?];
    if (type_e.info.ct_ref) {
        return sym;
    }
    const tchunk = template.chunk();

    switch (sym.type) {
        .object_t => {
            const object_t = sym.cast(.object_t);
            try resolveObjectLikeType(tchunk, @ptrCast(sym), template.decl.child_decl.cast(.objectDecl));

            try pushVariantResolveContext(tchunk, object_t.variant.?);
            defer popResolveContext(tchunk);

            const object_decl = template.decl.child_decl.cast(.objectDecl);
            for (object_decl.funcs) |func_n| {
                const func = try reserveNestedFunc(tchunk, @ptrCast(object_t), func_n, true);
                // func.sym.?.variant = object_t.variant.?;
                try resolveFunc2(tchunk, func, true);
                try tchunk.deferred_funcs.append(c.alloc, func);
            }
            return sym;
        },
        .hostobj_t => {
            const hostobj_t = sym.cast(.hostobj_t);
            try pushVariantResolveContext(tchunk, hostobj_t.variant.?);
            defer popResolveContext(tchunk);

            const custom_decl = template.decl.child_decl.cast(.custom_decl);

            for (custom_decl.funcs) |func_n| {
                const func = try reserveNestedFunc(tchunk, @ptrCast(hostobj_t), func_n, true);
                // func.sym.?.variant = custom_t.variant.?;
                try resolveFunc2(tchunk, func, true);
                try tchunk.deferred_funcs.append(c.alloc, func);
            }
            // if (type_e.info.load_all_methods) {
            //     var iter = template.getMod().symMap.iterator();
            //     while (iter.next()) |e| {
            //         if (e.value_ptr.*.type != .func) continue;
            //         const func_sym = e.value_ptr.*.cast(.func);
            //         var opt_func: ?*cy.Func = func_sym.first;
            //         while (opt_func) |func| {
            //             if (func.isMethod() and func.type == .template) {
            //                 const ct_args = custom_t.variant.?.args;
            //                 _ = try cte.expandFuncTemplate(c, func, ct_args, custom_t.type);
            //             }
            //             opt_func = func.next;
            //         }
            //     }
            // }
            return sym;
        },
        .struct_t => {
            const struct_t = sym.cast(.struct_t);
            try resolveObjectLikeType(tchunk, @ptrCast(sym), template.decl.child_decl.cast(.structDecl));

            try pushVariantResolveContext(tchunk, struct_t.variant.?);
            defer popResolveContext(tchunk);

            const struct_decl = template.decl.child_decl.cast(.structDecl);
            for (struct_decl.funcs) |func_n| {
                const func = try reserveNestedFunc(tchunk, @ptrCast(struct_t), func_n, true);
                // func.sym.?.variant = object_t.variant.?;
                try resolveFunc2(tchunk, func, true);
                try tchunk.deferred_funcs.append(c.alloc, func);
            }
            return sym;
        },
        .enum_t => {
            const enum_t = sym.cast(.enum_t);
            try resolveEnumType(tchunk, enum_t, @ptrCast(template.decl.child_decl));
            return sym;
        },
        .distinct_t => {
            const distinct_t = sym.cast(.distinct_t);
            const new_sym = try sema.resolveDistinctType(tchunk, distinct_t);

            try pushVariantResolveContext(tchunk, distinct_t.variant.?);
            defer popResolveContext(tchunk);

            const distinct_decl = template.decl.child_decl.cast(.distinct_decl);
            for (distinct_decl.funcs) |func_n| {
                const func = try reserveNestedFunc(tchunk, new_sym, func_n, true);
                // func.sym.?.variant = object_t.variant.?;
                try resolveFunc2(tchunk, func, true);
                try tchunk.deferred_funcs.append(c.alloc, func);
            }
            return new_sym;
        },
        .type => {
            const type_sym = sym.cast(.type);
            try pushVariantResolveContext(tchunk, type_sym.variant.?);
            defer popResolveContext(tchunk);

            const custom_decl = template.decl.child_decl.cast(.custom_decl);

            for (custom_decl.funcs) |func_n| {
                const func = try reserveNestedFunc(tchunk, @ptrCast(type_sym), func_n, true);
                try resolveFunc2(tchunk, func, true);
                try tchunk.deferred_funcs.append(c.alloc, func);
            }

            return sym;
        },
        else => {
            return error.Unsupported;
        },
    }
}

pub fn reserveTraitType(c: *cy.Chunk, decl: *ast.TraitDecl) !*cy.sym.TraitType {
    const name = c.ast.nodeString(decl.name);
    const sym = try c.reserveTraitType(@ptrCast(c.sym), name, @ptrCast(decl));
    const type_id = try resolveTypeIdFromDecl(c, @ptrCast(sym), decl.attrs, @ptrCast(decl));
    try resolveTraitTypeId(c, sym, type_id);
    return sym;
}

pub fn reserveObjectType(c: *cy.Chunk, decl: *ast.ObjectDecl) !*cy.sym.ObjectType {
    if (decl.name == null) {
        // Unnamed object.
        var buf: [16]u8 = undefined;
        const name = c.getNextUniqUnnamedIdent(&buf);
        const nameDup = try c.alloc.dupe(u8, name);
        try c.parser.ast.strs.append(c.alloc, nameDup);
        return c.createObjectTypeUnnamed(@ptrCast(c.sym), nameDup, decl);
    }

    const name = c.ast.nodeString(decl.name.?);
    const sym = try c.reserveObjectType(@ptrCast(c.sym), name, @ptrCast(decl));
    const type_id = try resolveTypeIdFromDecl(c, @ptrCast(sym), decl.attrs, @ptrCast(decl));
    try resolveObjectTypeId(c, sym, decl.is_tuple, type_id);
    return sym;
}

fn resolveTypeIdFromDecl(c: *cy.Chunk, sym: *cy.Sym, attrs: []const *ast.Attribute, decl: ?*ast.Node) !cy.TypeId {
    var opt_type: ?cy.TypeId = null;

    if (ast.findAttr(attrs, .host)) |attr| {
        const name = try getHostAttrName(c, attr);
        opt_type = try getHostTypeId(c, sym, name, decl);
    }

    return opt_type orelse {
        return c.sema.pushType();
    };
}

pub fn resolveTraitTypeId(c: *cy.Chunk, trait_t: *cy.sym.TraitType, type_id: cy.TypeId) !void {
    trait_t.type = type_id;
    c.compiler.sema.types.items[type_id] = .{
        .sym = @ptrCast(trait_t),
        .kind = .trait,
        .data = undefined,
        .info = .{},
    };
}

pub fn resolveObjectTypeId(c: *cy.Chunk, object_t: *cy.sym.ObjectType, tuple: bool, type_id: cy.TypeId) !void {
    object_t.type = type_id;
    c.compiler.sema.types.items[type_id] = .{
        .sym = @ptrCast(object_t),
        .kind = .object,
        .data = .{ .object = .{
            .numFields = cy.NullU16,
            .has_boxed_fields = false,
            .tuple = tuple,
            .fields = undefined,
        }},
        .info = .{},
    };
}

pub fn reserveStruct(c: *cy.Chunk, node: *ast.ObjectDecl, cstruct: bool) !*cy.sym.ObjectType {
    if (node.name == null) {
        // Unnamed.
        var buf: [16]u8 = undefined;
        const name = c.getNextUniqUnnamedIdent(&buf);
        const nameDup = try c.alloc.dupe(u8, name);
        try c.parser.ast.strs.append(c.alloc, nameDup);
        return c.createStructTypeUnnamed(@ptrCast(c.sym), nameDup, cstruct, node.is_tuple, node);
    }

    const name = c.ast.nodeString(node.name.?);
    const sym = try c.reserveStructType(@ptrCast(c.sym), name, cstruct, node);

    // Check for @host modifier.
    var opt_type: ?cy.TypeId = null;
    if (ast.findAttr(node.attrs, .host)) |attr| {
        const host_name = try getHostAttrName(c, attr);
        opt_type = try getHostTypeId(c, @ptrCast(sym), host_name, @ptrCast(node));
    }

    try resolveStructTypeId(c, sym, node.is_tuple, opt_type);
    return @ptrCast(sym);
}

pub fn resolveDistinctType(c: *cy.Chunk, distinct_t: *cy.sym.DistinctType) !*cy.Sym {
    if (distinct_t.resolved) |resolved| {
        return resolved;
    }

    if (distinct_t.variant) |variant| {
        try sema.pushVariantResolveContext(c, variant);
    } else {
        try sema.pushResolveContext(c);
    }
    defer sema.popResolveContext(c);

    const decl = distinct_t.decl;

    const target_t = try resolveTypeSpecNode(c, decl.target);
    const target_sym = c.sema.getTypeSym(target_t);
    const name = distinct_t.head.name();
    var new_sym: *cy.Sym = undefined;
    switch (target_sym.type) {
        .object_t => {
            const object_t = target_sym.cast(.object_t);
            const new = try c.createObjectType(distinct_t.head.parent.?, name, object_t.decl);
            try resolveObjectTypeId(c, new, object_t.decl.?.cast(.objectDecl).is_tuple, distinct_t.type);
            new.getMod().* = distinct_t.getMod().*;
            new.getMod().updateParentRefs(@ptrCast(new));

            try sema.resolveObjectLikeType(c, @ptrCast(new), object_t.decl.?.cast(.objectDecl));

            new.variant = distinct_t.variant;
            new_sym = @ptrCast(new);
        },
        .type => {
            const new = try c.createTypeSymCopy(distinct_t.head.parent.?, name, distinct_t.type, target_t);
            new.getMod().* = distinct_t.getMod().*;
            new.getMod().updateParentRefs(@ptrCast(new));
            new.variant = distinct_t.variant;
            new_sym = @ptrCast(new);
        },
        .hostobj_t => {
            const hostobj_t = target_sym.cast(.hostobj_t);
            const new = try c.createHostObjectType(distinct_t.head.parent.?, name, hostobj_t.decl);
            const target_te = c.sema.getType(target_t);
            try resolveHostObjectType(c, new,
                target_te.data.host_object.getChildrenFn,
                target_te.data.host_object.finalizerFn,
                distinct_t.type,
                target_te.info.custom_pre,
                target_te.info.load_all_methods,
            );
            new.getMod().* = distinct_t.getMod().*;
            new.getMod().updateParentRefs(@ptrCast(new));

            new.variant = distinct_t.variant;
            new_sym = @ptrCast(new);
        },
        else => {
            return c.reportErrorFmt("Unsupported: {}", &.{v(target_sym.type)}, @ptrCast(decl));
        },
    }
    if (distinct_t.variant == null) {
        try distinct_t.head.parent.?.getMod().?.symMap.put(c.alloc, name, new_sym);
    }
    distinct_t.resolved = new_sym;
    return new_sym;
}

pub fn resolveDistinctTypeId(c: *cy.Chunk, distinct_t: *cy.sym.DistinctType, opt_type: ?cy.TypeId) !void {
    const typeid = opt_type orelse try c.sema.pushType();
    distinct_t.type = typeid;
    c.compiler.sema.types.items[typeid] = .{
        .sym = @ptrCast(distinct_t),
        .kind = .distinct,
        .data = undefined,
        .info = .{},
    };
}

pub fn resolveStructTypeId(c: *cy.Chunk, struct_t: *cy.sym.ObjectType, is_tuple: bool, opt_type: ?cy.TypeId) !void {
    const typeid = opt_type orelse try c.sema.pushType();
    struct_t.type = typeid;
    c.compiler.sema.types.items[typeid] = .{
        .sym = @ptrCast(struct_t),
        .kind = .struct_t,
        .data = .{ .struct_t = .{
            .nfields = cy.NullU16,
            .cstruct = struct_t.cstruct,
            .has_boxed_fields = false,
            .fields = undefined,
            .tuple = is_tuple,
        }},
        .info = .{},
    };
}

pub fn resolveObjectLikeType(c: *cy.Chunk, object_like: *cy.Sym, decl: *ast.ObjectDecl) !void {
    if (object_like.getVariant()) |variant| {
        try pushVariantResolveContext(c, variant);
    } else {
        try pushSymResolveContext(c, object_like);
    }
    defer popResolveContext(c);

    try resolveObjectFields(c, object_like, decl);
    if (object_like.type == .object_t) {
        const object_t = object_like.cast(.object_t);

        const impls = try c.alloc.alloc(cy.sym.Impl, decl.impl_withs.len);
        errdefer c.alloc.free(impls);

        for (decl.impl_withs, 0..) |with, i| {
            const trait_t = try resolveTypeSpecNode(c, with.trait);
            const trait_sym = c.sema.getTypeSym(trait_t);
            if (trait_sym.type != .trait_t) {
                return c.reportErrorFmt("Expected `{}` to be trait type. Found {}.", &.{v(trait_sym.name()), v(trait_sym.type)}, @ptrCast(with.trait));
            }
            impls[i] = .{
                .trait = trait_sym.cast(.trait_t),
                .funcs = &.{},
            };
        }
        object_t.impls_ptr = impls.ptr;
        object_t.impls_len = @intCast(impls.len);
    }
}

fn indexOfTypedField(fields: []const *ast.Field, start: usize) ?usize {
    for (fields[start..], start..) |field, i| {
        if (field.typeSpec != null) {
            return i;
        }
    }
    return null;
}

/// Explicit `decl` node for distinct type declarations. Must belong to `c`.
pub fn resolveObjectFields(c: *cy.Chunk, object_like: *cy.Sym, decl: *ast.ObjectDecl) !void {
    var obj: *cy.sym.ObjectType = undefined;
    switch (object_like.type) {
        .object_t => {
            obj = object_like.cast(.object_t);
        },
        .struct_t => {
            obj = object_like.cast(.struct_t);
            obj.resolving_struct = true;
        },
        else => {
            return error.Unsupported;
        },
    }
    if (obj.isResolved()) {
        return;
    }

    const rt_field_start = c.dataU8Stack.items.len;
    defer c.dataU8Stack.items.len = rt_field_start;

    // Load fields.
    var num_total_fields: u32 = 0;
    const fields = try c.alloc.alloc(cy.sym.FieldInfo, decl.fields.len);
    errdefer c.alloc.free(fields);

    var field_group_t: cy.TypeId = cy.NullId;
    var field_group_end: usize = undefined;
    var has_boxed_fields = false;
    for (decl.fields, 0..) |field, i| {
        const fieldName = c.ast.nodeString(field.name);
        var field_t: cy.TypeId = undefined;
        if (field.typeSpec == null) {
            if (field_group_t == cy.NullId or i > field_group_end) {
                // Attempt to find group type.
                field_group_end = indexOfTypedField(decl.fields, i + 1) orelse {
                    return c.reportError("Expected field type.", @ptrCast(field));
                };
                field_group_t = try resolveTypeSpecNode(c, decl.fields[field_group_end].typeSpec);
                try ensureCompleteType(c, field_group_t, @ptrCast(decl.fields[field_group_end].typeSpec));
            }
            field_t = field_group_t;
        } else {
            field_t = try resolveTypeSpecNode(c, field.typeSpec);
            try ensureCompleteType(c, field_t, @ptrCast(field.typeSpec));
        }

        const sym = try c.declareField(@ptrCast(obj), fieldName, i, field_t, @ptrCast(field));
        fields[i] = .{
            .sym = @ptrCast(sym),
            .type = field_t,
            .offset = num_total_fields,
        };

        if (object_like.type != .struct_t) {
            has_boxed_fields = has_boxed_fields or !c.sema.isUnboxedType(field_t);
        }

        const field_te = c.sema.types.items[field_t];
        if (field_te.kind == .struct_t) {
            num_total_fields += field_te.data.struct_t.nfields;

            if (object_like.type == .struct_t) {
                if (field_te.data.struct_t.has_boxed_fields) {
                    const child_fields = field_te.data.struct_t.fields[0..field_te.data.struct_t.nfields];
                    try c.dataU8Stack.appendSlice(c.alloc, @ptrCast(child_fields));
                    has_boxed_fields = has_boxed_fields or field_te.data.struct_t.has_boxed_fields;
                } else {
                    try c.dataU8Stack.appendNTimes(c.alloc, .{ .boxed=false }, field_te.data.struct_t.nfields);
                }
            }
        } else {
            num_total_fields += 1;
            if (object_like.type == .struct_t) {
                const boxed = !c.sema.isUnboxedType(field_t);
                try c.dataU8Stack.append(c.alloc, .{ .boxed=boxed });
                has_boxed_fields = has_boxed_fields or boxed;
            }
        }
    }
    obj.fields = fields.ptr;
    obj.numFields = @intCast(fields.len);
    switch (object_like.type) {
        .object_t => {
            var rt_fields: []bool = &.{};
            if (has_boxed_fields) {
                rt_fields = try c.alloc.alloc(bool, fields.len);
                for (fields, 0..) |field, i| {
                    rt_fields[i] = !c.sema.isUnboxedType(field.type);
                }
            }
            const data = &c.sema.types.items[obj.type].data.object;
            data.numFields = @intCast(obj.numFields);
            data.has_boxed_fields = has_boxed_fields;
            data.fields = rt_fields.ptr;
        },
        .struct_t => {
            var rt_fields: []bool = &.{};
            if (has_boxed_fields) {
                rt_fields = try c.alloc.dupe(bool, @ptrCast(c.dataU8Stack.items[rt_field_start..]));
            }
            const data = &c.sema.types.items[obj.type].data.struct_t;
            data.nfields = @intCast(num_total_fields);
            data.cstruct = obj.cstruct;
            data.has_boxed_fields = has_boxed_fields;
            data.fields = rt_fields.ptr;
            obj.resolving_struct = false;
        },
        else => return error.Unexpected,
    }
}

pub fn reserveHostFunc(c: *cy.Chunk, node: *ast.FuncDecl) !*cy.Func {
    if (node.stmts.len > 0) {
        return error.Unexpected;
    }
    // Check if @host func.
    const decl_path = try ensureDeclNamePath(c, @ptrCast(c.sym), node.name);
    if (ast.findAttr(node.attrs, .host) != null) {
        const is_method = c.ast.isMethodDecl(node);
        return c.reserveHostFunc(decl_path.parent, decl_path.name.base_name, node, is_method, false);
    }
    return c.reportErrorFmt("`{}` is not a host function.", &.{v(decl_path.name.name_path)}, @ptrCast(node));
}

pub fn reserveHostFunc2(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, node: *ast.FuncDecl, is_variant: bool) !*cy.Func {
    if (node.stmts.len > 0) {
        return error.Unexpected;
    }
    if (ast.findAttr(node.attrs, .host) != null) {
        const is_method = c.ast.isMethodDecl(node);
        return c.reserveHostFunc(parent, name, node, is_method, is_variant);
    }
    return c.reportErrorFmt("`{}` is not a host function.", &.{v(name)}, @ptrCast(node));
}

pub fn resolveFuncVariant(c: *cy.Chunk, func: *cy.Func) !void {
    if (func.isResolved()) {
        return;
    }
    switch (func.type) {
        .hostFunc => {
            try sema.resolveHostFuncVariant(c, func);
        },
        .userFunc => {
            try sema.resolveUserFuncVariant(c, func);
        },
        .trait => {
            return error.TODO;
            // try sema.resolveImplicitTraitMethod(c, func); 
        },
        .userLambda => {},
    }
}

pub fn resolveFunc2(c: *cy.Chunk, func: *cy.Func, has_parent_ctx: bool) !void {
    if (func.isResolved()) {
        return;
    }

    try pushFuncResolveContext(c, func);
    defer popResolveContext(c);
    getResolveContext(c).has_parent_ctx = has_parent_ctx;

    const sig_id = try resolveFuncSig(c, func);
    switch (func.type) {
        .hostFunc => {
            try resolveHostFunc(c, func, sig_id);
        },
        .userFunc => {
            try c.resolveUserFunc(func, sig_id);
        },
        .trait => {
            try c.resolveUserFunc(func, sig_id);
        },
        else => {
            return error.Unexpected;
        },
    }
}

pub fn resolveFunc(c: *cy.Chunk, func: *cy.Func) !void {
    switch (func.type) {
        .trait,
        .userFunc,
        .hostFunc => {
            try resolveFunc2(c, func, false);
        },
        .userLambda => {},
    }
}

pub fn getHostAttrName(c: *cy.Chunk, attr: *ast.Attribute) !?[]const u8 {
    const value = attr.value orelse {
        return null;
    };
    if (value.type() != .raw_string_lit) {
        return error.Unsupported;
    }
    return c.ast.nodeString(value);
}

pub fn resolveHostFuncVariant(c: *cy.Chunk, func: *cy.Func) !void {
    try pushVariantResolveContext(c, func.variant.?);
    defer popResolveContext(c);

    const sig_id = try resolveFuncSig(c, func);
    const decl = func.decl.?.cast(.funcDecl);
    const attr = ast.findAttr(decl.attrs, .host).?;
    const func_ptr = try resolveHostFuncPtr(c, func, sig_id, attr);
    func.data.hostFunc.ptr = @ptrCast(func_ptr);
    c.resolveFuncInfo(func, sig_id);
    try c.deferred_funcs.append(c.alloc, func);
}

pub fn resolveHostFuncPtr(c: *cy.Chunk, func: *cy.Func, func_sig: FuncSigId, host_attr: *ast.Attribute) !C.FuncFn {
    const host_name = try getHostAttrName(c, host_attr);
    var name_buf: [128]u8 = undefined;
    const bind_name = host_name orelse b: {
        var fbs = std.io.fixedBufferStream(&name_buf);
        try cy.sym.writeFuncName(c.sema, fbs.writer(), func, .{ .from = c, .emit_template_args = false });
        break :b fbs.getWritten();
    };
    if (c.host_funcs.get(bind_name)) |ptr| {
        return ptr;
    }

    const loader = c.func_loader orelse {
        return c.reportErrorFmt("Host func `{}` failed to load.", &.{v(bind_name)}, @ptrCast(func.decl));
    };
    const parent = func.parent.parent.?;
    const info = C.FuncInfo{
        .mod = parent.toC(),
        .name = C.toStr(bind_name),
        .funcSigId = func_sig,
    };

    log.tracev("Invoke func loader for: {s}", .{bind_name});
    var res: C.FuncFn = null;
    if (!loader(@ptrCast(c.compiler.vm), info, @ptrCast(&res))) {
        return c.reportErrorFmt("Host func `{}` failed to load.", &.{v(bind_name)}, @ptrCast(func.decl));
    }
    return res;
}

fn resolveHostFunc(c: *cy.Chunk, func: *cy.Func, func_sig: FuncSigId) !void {
    const decl = func.decl.?.cast(.funcDecl);
    const attr = ast.findAttr(decl.attrs, .host).?;
    const func_ptr = try resolveHostFuncPtr(c, func, func_sig, attr);
    try c.resolveHostFunc(func, func_sig, @ptrCast(@alignCast(func_ptr)));
}

/// Declares a bytecode function in a given module.
pub fn reserveUserFunc(c: *cy.Chunk, decl: *ast.FuncDecl) !*cy.Func {
    const decl_path = try ensureDeclNamePath(c, @ptrCast(c.sym), decl.name);
    return reserveUserFunc2(c, decl_path.parent, decl_path.name.base_name, decl, false);
}

pub fn reserveUserFunc2(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: *ast.FuncDecl, is_variant: bool) !*cy.Func {
    const is_method = c.ast.isMethodDecl(decl);
    return c.reserveUserFunc(parent, name, decl, is_method, is_variant);
}

pub fn resolveUserFuncVariant(c: *cy.Chunk, func: *cy.Func) !void {
    try pushVariantResolveContext(c, func.variant.?);
    defer popResolveContext(c);

    const sig_id = try resolveFuncSig(c, func);
    c.resolveFuncInfo(func, sig_id);
    try c.deferred_funcs.append(c.alloc, func);
}

pub fn reserveImplicitTraitMethod(c: *cy.Chunk, parent: *cy.Sym, decl: *ast.FuncDecl, vtable_idx: usize, is_variant: bool) !*cy.Func {
    const decl_path = try ensureDeclNamePath(c, parent, decl.name);
    if (decl.stmts.len > 0) {
        return c.reportErrorFmt("Trait methods should not have a body.", &.{}, @ptrCast(decl));
    }
    const func = try c.reserveTraitFunc(decl_path.parent, decl_path.name.base_name, decl, vtable_idx, is_variant);
    func.is_nested = true;
    return func;
}

pub fn reserveNestedFunc(c: *cy.Chunk, parent: *cy.Sym, decl: *ast.FuncDecl, deferred: bool) !*cy.Func {
    const name = c.ast.nodeString(decl.name);
    const is_method = c.ast.isMethodDecl(decl);
    if (decl.stmts.len > 0) {
        const func = try c.reserveUserFunc(parent, name, decl, is_method, deferred);
        func.is_nested = true;
        return func;
    }

    // No initializer.
    if (ast.findAttr(decl.attrs, .host) != null) {
        const func = try c.reserveHostFunc(parent, name, decl, is_method, deferred);
        func.is_nested = true;
        return func;
    }

    return c.reportErrorFmt("`{}` does not have an initializer.", &.{v(name)}, @ptrCast(decl));
}

pub fn methodDecl(c: *cy.Chunk, func: *cy.Func) !void {
    if (func.variant) |variant| {
        try pushVariantResolveContext(c, variant);
        defer popResolveContext(c);
        try methodDecl2(c, func);
        return;
    }

    if (func.parent.parent.?.getVariant()) |parent_variant| {
        try pushVariantResolveContext(c, parent_variant);
        defer popResolveContext(c);
        try methodDecl2(c, func);
    } else {
        try pushFuncResolveContext(c, func);
        defer popResolveContext(c);
        try methodDecl2(c, func);
    }
}

pub fn methodDecl2(c: *cy.Chunk, func: *cy.Func) !void {
    // Object method.
    const blockId = try pushFuncProc(c, func);
    c.semaProcs.items[blockId].isMethodBlock = true;

    const sig = c.sema.getFuncSig(func.funcSigId);
    const parent_t = sig.params()[0].type;
    try pushMethodParamVars(c, parent_t, func);
    try semaStmts(c, func.decl.?.cast(.funcDecl).stmts);
    try popFuncBlock(c);
    func.emitted = true;
}

pub fn funcDecl(c: *cy.Chunk, func: *cy.Func) !void {
    if (func.variant) |variant| {
        try pushVariantResolveContext(c, variant);
        defer popResolveContext(c);
        try funcDecl2(c, func);
        return;
    }

    if (func.parent.parent.?.getVariant()) |parent_variant| {
        try pushVariantResolveContext(c, parent_variant);
        defer popResolveContext(c);
        try funcDecl2(c, func);
    } else {
        try pushFuncResolveContext(c, func);
        defer popResolveContext(c);
        try funcDecl2(c, func);
    }
}

pub fn funcDecl2(c: *cy.Chunk, func: *cy.Func) !void {
    const node = func.decl.?.cast(.funcDecl);
    _ = try pushFuncProc(c, func);
    const sig = c.sema.getFuncSig(func.funcSigId);
    try appendFuncParamVars(c, node.params, @ptrCast(sig.params()));
    try semaStmts(c, node.stmts);

    try popFuncBlock(c);
    func.emitted = true;
}

pub fn reserveContextVar(c: *cy.Chunk, decl: *ast.ContextDecl) !*cy.sym.ContextVar {
    const name = c.ast.nodeString(decl.name);
    if (decl.right) |_| {
        return error.TODO;
    }

    // No initializer, redeclaration.
    return c.reserveContextVar(@ptrCast(c.sym), name, decl);
}

pub fn reserveVar(c: *cy.Chunk, decl: *ast.StaticVarDecl) !*Sym {
    const decl_path = try ensureDeclNamePath(c, @ptrCast(c.sym), decl.name);
    if (decl.right == null) {
        // No initializer.
        if (ast.findAttr(decl.attrs, .host) != null) {
            return @ptrCast(try c.reserveHostVar(decl_path.parent, decl_path.name.base_name, decl));
        }
        return c.reportErrorFmt("`{}` does not have an initializer.", &.{v(decl_path.name.name_path)}, @ptrCast(decl));
    } else {
        return @ptrCast(try c.reserveUserVar(decl_path.parent, decl_path.name.base_name, decl));
    }
}

pub fn resolveContextVar(c: *cy.Chunk, sym: *cy.sym.ContextVar) !void {
    if (sym.isResolved()) {
        return;
    }
    if (sym.decl.right != null) {
        return error.TODO;
    }

    try pushResolveContext(c);
    defer popResolveContext(c);

    const name = sym.head.name();
    const exp_var = c.compiler.context_vars.get(name) orelse {
        return c.reportErrorFmt("Context variable `{}` does not exist.", &.{v(sym.head.name())}, @ptrCast(sym.decl.name));
    };

    const type_id = try resolveTypeSpecNode(c, sym.decl.type);
    if (exp_var.type != type_id) {
        const exp_type_name = c.sema.getTypeBaseName(exp_var.type);
        const act_type_name = c.sema.getTypeBaseName(type_id);
        const node = if (sym.decl.right != null) sym.decl.right.? else sym.decl.type.?;
        return c.reportErrorFmt("Expected type `{}` for context variable `{}`, found `{}`.", &.{
            v(exp_type_name), v(name), v(act_type_name),
        }, node);
    }
    c.resolveContextVar(sym, exp_var.type, exp_var.idx);
}

pub fn ensureUserVarResolved(c: *cy.Chunk, sym: *cy.sym.UserVar) !void {
    if (sym.isResolved()) {
        return;
    }
    try resolveUserVar(c, sym);
}

/// Resolves the variable's type and initializer.
/// If type spec is not provided, the initializer is resolved to obtain the type.
pub fn resolveUserVar(c: *cy.Chunk, sym: *cy.sym.UserVar) !void {
    try pushResolveContext(c);
    defer popResolveContext(c);

    const node = sym.decl.?;

    try c.compiler.svar_init_stack.append(c.alloc, .{});
    sym.resolving_init = true;

    var type_id: cy.TypeId = undefined;
    var res: ExprResult = undefined;
    if (node.typed) {
        if (node.typeSpec) |type_spec| {
            type_id = try resolveTypeSpecNode(c, type_spec);
            res = try c.semaExprCstr(node.right.?, type_id);
        } else {
            // Infer type from initializer.
            res = try c.semaExpr(node.right.?, .{});
            type_id = res.type.toDeclType();
        }
    } else {
        type_id = bt.Dyn;
        res = try c.semaExprCstr(node.right.?, type_id);
    }
    c.resolveUserVarType(sym, type_id);
    sym.ir = res.irIdx;
    sym.resolving_init = false;

    var svar_init = c.compiler.svar_init_stack.pop().?;
    sym.deps = try svar_init.deps.toOwnedSlice(c.alloc);
}

pub fn semaUserVarInitDeep(c: *cy.Chunk, sym: *cy.sym.UserVar) !void {
    if (sym.emitted) {
        return;
    }

    // Ensure initializer IR.
    const src_chunk = sym.head.parent.?.getMod().?.chunk;
    try ensureUserVarResolved(src_chunk, sym);

    // Emit deps first.
    for (sym.deps) |dep| {
        try semaUserVarInitDeep(c, dep);
    }

    const node = sym.decl.?;

    _ = try c.ir.pushStmt(c.alloc, .init_var_sym, @ptrCast(node), .{
        .src_ir = &src_chunk.own_ir,
        .sym = @ptrCast(sym),
        .expr = sym.ir,
    });
    sym.emitted = true;
}

pub fn resolveHostVar(c: *cy.Chunk, sym: *cy.sym.HostVar) !void {
    try pushResolveContext(c);
    defer popResolveContext(c);

    const decl = sym.decl.?;
    const name = c.ast.getNamePathInfo(decl.name);

    const info = C.VarInfo{
        .mod = c.sym.sym().toC(),
        .name = C.toStr(name.name_path),
        .idx = c.curHostVarIdx,
    };
    c.curHostVarIdx += 1;
    const varLoader = c.varLoader orelse {
        return c.reportErrorFmt("No var loader set for `{}`.", &.{v(name.name_path)}, @ptrCast(decl));
    };
    log.tracev("Invoke var loader for: {s}", .{name.name_path});
    var out: cy.Value = cy.Value.initInt(0);
    if (!varLoader(@ptrCast(c.compiler.vm), info, @ptrCast(&out))) {
        return c.reportErrorFmt("Host var `{}` failed to load.", &.{v(name.name_path)}, @ptrCast(decl));
    }
    // var type.
    const typeId = try resolveTypeSpecNode(c, decl.typeSpec);
    // c.ast.node(node.data.staticDecl.varSpec).next = typeId;

    if (!c.sema.isUnboxedType(typeId)) {
        const outTypeId = out.getTypeId();
        if (!cy.types.isTypeSymCompat(c.compiler, outTypeId, typeId)) {
            const expTypeName = c.sema.getTypeBaseName(typeId);
            const actTypeName = c.sema.getTypeBaseName(outTypeId);
            return c.reportErrorFmt("Host var `{}` expects type {}, got: {}.", &.{v(name.name_path), v(expTypeName), v(actTypeName)}, @ptrCast(decl));
        }
    }

    try c.resolveHostVar(sym, typeId, out);
}

fn declareParam(c: *cy.Chunk, param: ?*ast.FuncParam, isSelf: bool, paramIdx: usize, declT: TypeId) !void {
    var name: []const u8 = undefined;
    if (isSelf) {
        name = "self";
    } else {
        name = c.ast.nodeString(param.?.name_type);
    }

    const proc = c.proc();
    if (!isSelf) {
        if (proc.nameToVar.get(name)) |varInfo| {
            if (varInfo.blockId == c.semaBlocks.items.len - 1) {
                return c.reportErrorFmt("Function param `{}` is already declared.", &.{v(name)}, @ptrCast(param));
            }
        }
    }

    const id = try pushLocalVar(c, .local, name, declT, false);
    var svar = &c.varStack.items[id];
    svar.inner = .{
        .local = .{
            .id = @intCast(paramIdx),
            .isParam = true,
            .isParamCopied = false,
            .hasInit = false,
            .lifted = false,
            .declIrStart = cy.NullId,
            .hidden = false,
        },
    };
    proc.numParams += 1;

    proc.curNumLocals += 1;
}

const LocalResult = struct {
    id: u32, 
    ir_id: u32,
};

fn declareLocalInit(c: *cy.Chunk, name: []const u8, decl_t: cy.TypeId, init: ExprResult, node: *ast.Node) !LocalResult {
    const var_id = try declareLocalName(c, name, decl_t, false, true, node);
    const info = c.varStack.items[var_id].inner.local;
    var data = c.ir.getStmtDataPtr(info.declIrStart, .declareLocalInit);
    data.init = init.irIdx;
    data.initType = CompactType.init(decl_t);
    return .{ .id = var_id, .ir_id = info.declIrStart };
}

fn declareHiddenLocal(c: *cy.Chunk, name: []const u8, decl_t: cy.TypeId, init: ExprResult, node: *ast.Node) !LocalResult {
    const var_id = try declareLocalName(c, name, decl_t, true, true, node);
    const info = c.varStack.items[var_id].inner.local;
    var data = c.ir.getStmtDataPtr(info.declIrStart, .declareLocalInit);
    data.init = init.irIdx;
    data.initType = CompactType.init(decl_t);
    return .{ .id = var_id, .ir_id = info.declIrStart };
}

fn reserveLocalName(c: *cy.Chunk, name: []const u8, declType: TypeId, hidden: bool, hasInit: bool, node: *ast.Node) !LocalVarId {
    if (!hidden) {
        const proc = c.proc();
        if (proc.nameToVar.get(name)) |varInfo| {
            if (varInfo.blockId == c.semaBlocks.items.len - 1) {
                const svar = &c.varStack.items[varInfo.varId];
                if (svar.type == .local) {
                    return c.reportErrorFmt("Variable `{}` is already declared in the block.", &.{v(name)}, node);
                }
            } else {
                // Create shadow entry for restoring the prev var.
                try c.varShadowStack.append(c.alloc, .{
                    .namePtr = name.ptr,
                    .nameLen = @intCast(name.len),
                    .varId = varInfo.varId,
                    .blockId = varInfo.blockId,
                });
            }
        }
    }

    const id = try pushLocalVar(c, .local, name, declType, hidden);
    var svar = &c.varStack.items[id];

    const proc = c.proc();
    const irId = proc.curNumLocals;

    svar.inner = .{ .local = .{
        .id = irId,
        .isParam = false,
        .isParamCopied = false,
        .hasInit = hasInit,
        .lifted = false,
        .hidden = hidden,
        .declIrStart = cy.NullId,
    }};

    const b = c.block();
    b.numLocals += 1;

    proc.curNumLocals += 1;
    return id;
}

fn declareLocalName(c: *cy.Chunk, name: []const u8, declType: TypeId, hidden: bool, hasInit: bool, node: *ast.Node) !LocalVarId {
    const id = try reserveLocalName(c, name, declType, hidden, hasInit, node);
    const local = &c.varStack.items[id];
    var irIdx: u32 = undefined;
    if (hasInit) {
        irIdx = try c.ir.pushStmt(c.alloc, .declareLocalInit, node, .{
            .namePtr = name.ptr,
            .nameLen = @as(u16, @intCast(name.len)),
            .declType = declType,
            .id = local.inner.local.id,
            .lifted = false,
            .init = cy.NullId,
            .initType = undefined,
            .zeroMem = false,
        });
    } else {
        irIdx = try c.ir.pushStmt(c.alloc, .declareLocal, node, .{
            .namePtr = name.ptr,
            .nameLen = @as(u16, @intCast(name.len)),
            .declType = declType,
            .id = local.inner.local.id,
            .lifted = false,
        });
    }
    local.inner.local.declIrStart = irIdx;
    return id;
}

fn declareLocal(c: *cy.Chunk, ident: *ast.Node, declType: TypeId, hasInit: bool) !LocalVarId {
    const name = c.ast.nodeString(ident);
    return declareLocalName(c, name, declType, false, hasInit, ident);
}

fn localDecl(c: *cy.Chunk, node: *ast.VarDecl) !void {
    var typeId: cy.TypeId = undefined;
    var deduce_type = false;
    if (node.typed) {
        if (node.typeSpec == null) {
            deduce_type = true;
            typeId = bt.Any;
        } else {
            typeId = try resolveTypeSpecNode(c, node.typeSpec);
        }
    } else {
        typeId = bt.Dyn;
    }

    // Reserve local first.
    const name = c.ast.nodeString(node.name);
    const varId = try reserveLocalName(c, name, typeId, false, true, node.name);

    // const maxLocalsBeforeInit = c.proc().curNumLocals;

    // Infer rhs type and enforce constraint.
    const right = try c.semaExpr(node.right, .{
        .target_t = if (deduce_type) cy.NullId else typeId,
        .req_target_t = !deduce_type,
        .fit_target = !deduce_type,
        .fit_target_unbox_dyn = !deduce_type,
    });

    // Insert declare statement after rhs sema so it can depend on temp locals.
    var svar = &c.varStack.items[varId];
    if (deduce_type) {
        const declType = right.type.toDeclType();
        svar.declT = declType;
        svar.vtype = right.type;
        typeId = declType;
    } else if (typeId == bt.Dyn) {
        // Update recent static type.
        svar.vtype.id = right.type.id;
    }
    const loc = try c.ir.pushStmt(c.alloc, .declareLocalInit, node.name, .{
        .namePtr = name.ptr,
        .nameLen = @as(u16, @intCast(name.len)),
        .declType = typeId,
        .id = svar.inner.local.id,
        .lifted = false,
        .init = right.irIdx,
        .initType = right.type,
        .zeroMem = false,
    });
    svar.inner.local.declIrStart = loc;
    // if (maxLocalsBeforeInit < c.proc().maxLocals) {
    //     // Initializer must have a declaration (in a block expr)
    //     // since the number of locals increased.
    //     // Local's memory must be zeroed.
    //     data.zeroMem = true;
    // }

    try c.assignedVarStack.append(c.alloc, varId);
}

const SemaExprOptions = struct {
    target_t: TypeId = cy.NullId,
    req_target_t: bool = false,
    fit_target: bool = false,
    fit_target_unbox_dyn: bool = false,
    prefer_addressable: bool = false,
};

const ExprResultType = enum(u8) {
    value,
    sym,
    varSym,
    func,
    local,
    fieldDyn,
    field,
    capturedLocal,
    global,
    ct_value,
};

const ExprResultData = union {
    sym: *Sym,
    varSym: *Sym,
    func: *cy.sym.Func,
    local: LocalVarId,
    ct_value: cte.CtValue,
};

pub const ExprResult = struct {
    resType: ExprResultType,
    type: CompactType,
    data: ExprResultData,
    addressable: bool = false,
    irIdx: u32,

    pub fn init(irIdx: u32, ctype: CompactType) ExprResult {
        return .{
            .resType = .value,
            .type = ctype,
            .data = undefined,
            .irIdx = irIdx,
        };
    }

    fn initInheritDyn(loc: u32, ctype: CompactType, type_id: TypeId) ExprResult {
        var new_ctype = ctype;
        new_ctype.id = @intCast(type_id);
        return .{
            .resType = .value,
            .type = new_ctype,
            .data = undefined,
            .irIdx = loc,
        };
    }

    fn initDynamic(irIdx: u32, typeId: TypeId) ExprResult {
        return .{
            .resType = .value,
            .type = CompactType.initDynamic(typeId),
            .data = undefined,
            .irIdx = irIdx,
        };
    }

    fn initStatic(irIdx: u32, typeId: TypeId) ExprResult {
        return .{
            .resType = .value,
            .type = CompactType.initStatic(typeId),
            .data = undefined,
            .irIdx = irIdx,
        };
    }

    fn initCtValue(value: cte.CtValue) ExprResult {
        return .{
            .resType = .ct_value,
            .type = CompactType.initStatic(value.type),
            .data = .{ .ct_value = value },
            .irIdx = cy.NullId,
        };
    }

    fn initCustom(irIdx: u32, resType: ExprResultType, ctype: CompactType, data: ExprResultData) ExprResult {
        return .{
            .resType = resType,
            .type = ctype,
            .data = data,
            .irIdx = irIdx,
        };
    }
};

pub const Expr = struct {
    /// Whether to fail if incompatible with type cstr.
    reqTypeCstr: bool,

    /// Whether to try a last attempt to fit the target type before type checking.
    fit_target: bool,

    /// Whether to unbox dyn.
    /// Normally this is true when `fit_target` is true,
    /// but false when matching an arg for overloaded functions.
    fit_target_unbox_dyn: bool,

    prefer_addressable: bool = false,

    /// By default some addressable expressions (eg. $index calls that return a pointer)
    /// will deref unless `use_addressable` is true.
    use_addressable: bool = false, 

    node: *ast.Node,
    target_t: TypeId,

    pub fn init(node: *ast.Node) Expr {
        return .{
            .node = node,
            .target_t = bt.Any,
            .reqTypeCstr = false,
            .fit_target = false,
            .fit_target_unbox_dyn = false,
        };
    }

    fn initRequire(node: *ast.Node, type_id: cy.TypeId) Expr {
        return .{
            .node = node,
            .target_t = type_id,
            .reqTypeCstr = true,
            .fit_target = true,
            .fit_target_unbox_dyn = true,
        };
    }

    fn hasTargetType(self: Expr) bool {
        return self.target_t != cy.NullId;
    }

    fn getRetCstr(self: Expr) ReturnCstr {
        if (self.target_t == bt.Void) {
            return .any;
        } else {
            return .not_void;
        }
    }

    fn getCallCstr(self: Expr, ct_call: bool) sema.CallCstr {
        return .{
            .ret = self.getRetCstr(),
            .ct_call = ct_call,
        };
    }
};

fn requireFuncSym(c: *cy.Chunk, sym: *Sym, node: *ast.Node) !*cy.sym.FuncSym {
    if (sym.type != .func) {
        return c.reportErrorFmt("Expected `{}` to be a function symbol.", &.{v(sym.name())}, node);
    }
    return sym.cast(.func);
}

// Invoke a type's sym as the callee.
fn callNamespaceSym(c: *cy.Chunk, sym: *Sym, sym_n: *ast.Node, args: []*ast.Node, ret_cstr: ReturnCstr, node: *ast.Node) !ExprResult {
    const call_sym = try c.mustFindSym(sym, "$call", sym_n);
    if (call_sym.type == .func) {
        const cstr = sema.CallCstr{ .ret = ret_cstr };
        return c.semaCallFuncSym(call_sym.cast(.func), args, cstr, node);
    } else if (call_sym.type == .func_template) {
        const cstr = sema.CallCstr{ .ret = ret_cstr };
        return c.semaCallFuncTemplate(call_sym.cast(.func_template), args, cstr, node);
    } else {
        return c.reportErrorFmt("Expected `{}` to be a function.", &.{v(sym.name())}, node);
    }
}

fn callSym(c: *cy.Chunk, sym: *Sym, symNode: *ast.Node, args: []*ast.Node, cstr: sema.CallCstr, node: *ast.Node) !ExprResult {
    try referenceSym(c, sym, symNode);
    switch (sym.type) {
        .func => {
            const funcSym = sym.cast(.func);
            return c.semaCallFuncSym(funcSym, args, cstr, symNode);
        },
        .func_template => {
            const template = sym.cast(.func_template);
            return c.semaCallFuncTemplate(template, args, cstr, symNode);
        },
        .trait_t,
        .enum_t,
        .type,
        .hostobj_t,
        .struct_t,
        .object_t,
        .template => {
            return callNamespaceSym(c, sym, symNode, args, cstr.ret, node);
        },
        .enumMember => {
            const member = sym.cast(.enumMember);
            if (member.payloadType == cy.NullId) {
                return c.reportErrorFmt("Can not initialize choice member without a payload type.", &.{}, symNode);
            }
            if (args.len != 1) {
                return c.reportErrorFmt("Expected only one payload argument for choice initializer. Found `{}`.", &.{v(args.len)}, symNode);
            }
            const payload = try c.semaExprCstr(args[0], member.payloadType);
            return semaInitChoice(c, member, payload, symNode);
        },
        .userVar,
        .hostVar => {
            // preCall.
            const callee = try sema.symbol(c, sym, Expr.init(symNode), true);
            const args_loc = try c.semaPushDynCallArgs(args);
            return c.semaCallValue(callee.irIdx, args.len, args_loc, node);
        },
        else => {
            // try pushCallArgs(c, node.data.callExpr.argHead, numArgs, true);
            return c.reportErrorFmt("Unsupported call from symbol: `{}`", &.{v(sym.type)}, symNode);
        },
    }
}

pub fn symbol(c: *cy.Chunk, sym: *Sym, expr: Expr, prefer_ct_sym: bool) !ExprResult {
    const node = expr.node;
    try referenceSym(c, sym, node);

    switch (sym.type) {
        .context_var => {
            const typeId = sym.cast(.context_var).type;
            const ctype = CompactType.init(typeId);
            const loc = try c.ir.pushExpr(.context, c.alloc, typeId, node, .{ .sym = @ptrCast(sym) });
            return ExprResult.init(loc, ctype);
        },
        .userVar => {
            const user_var = sym.cast(.userVar);
            const src_chunk = user_var.head.parent.?.getMod().?.chunk;
            try ensureUserVarResolved(src_chunk, user_var);
            const loc = try c.ir.pushExpr(.varSym, c.alloc, user_var.type, node, .{ .sym = sym });
            return ExprResult.initCustom(loc, .varSym, CompactType.init(user_var.type), .{ .varSym = sym });
        },
        .hostVar => {
            const host_var = sym.cast(.hostVar);
            const ctype = CompactType.init(host_var.type);
            const loc = try c.ir.pushExpr(.varSym, c.alloc, host_var.type, node, .{ .sym = sym });
            return ExprResult.initCustom(loc, .varSym, ctype, .{ .varSym = sym });
        },
        .func => {
            // `symbol` being invoked suggests the func sym is not ambiguous.
            const func = sym.cast(.func);
            if (func.numFuncs != 1) {
                return error.AmbiguousSymbol;
            }
            const typeId = try cy.sema.getFuncPtrType(c, func.first.funcSigId);
            const ctype = CompactType.init(typeId);
            if (prefer_ct_sym) {
                return ExprResult.initCustom(cy.NullId, .sym, ctype, .{ .sym = sym });
            }
            const loc = try c.ir.pushExpr(.func_ptr, c.alloc, typeId, node, .{ .func = func.first });
            return ExprResult.initCustom(loc, .func, ctype, .{ .func = func.first });
        },
        .type,
        .enum_t,
        .trait_t,
        .hostobj_t,
        .object_t,
        .struct_t => {
            if (prefer_ct_sym) {
                const typeId = CompactType.init(sym.getStaticType().?);
                return ExprResult.initCustom(cy.NullId, .sym, typeId, .{ .sym = sym });
            }
            const static_t = sym.getStaticType().?;
            const loc = try c.ir.pushExpr(.type, c.alloc, bt.Type, node, .{ .typeId = static_t });
            return ExprResult.initStatic(loc, bt.Type);
        },
        .enumMember => {
            const member = sym.cast(.enumMember);
            if (member.is_choice_type) {
                return semaInitChoiceNoPayload(c, member, node);
            } else {
                const ctype = CompactType.init(member.type);
                const irIdx = try c.ir.pushExpr(.enumMemberSym, c.alloc, member.type, node, .{
                    .type = member.type,
                    .val = @as(u8, @intCast(member.val)),
                });
                return ExprResult.init(irIdx, ctype);
            }
        },
        .chunk,
        .func_template,
        .template => {
            if (prefer_ct_sym) {
                const ctype = CompactType.init(bt.Void);
                return ExprResult.initCustom(cy.NullId, .sym, ctype, .{ .sym = sym });
            }
        },
        else => {
            std.debug.panic("TODO: {}", .{sym.type});
        }
    }

    return c.reportErrorFmt("Can't use symbol `{}` as a runtime value.", &.{v(sym.name())}, node);
}

fn semaLocalAddr(c: *cy.Chunk, id: LocalVarId, node: *ast.Node) !ExprResult {
    const svar = c.varStack.items[id];
    switch (svar.type) {
        .local => {
            if (svar.declT == bt.Dyn or svar.declT == bt.Any) {
                return c.reportErrorFmt("Expected addressable type.", &.{}, node);
            }
            const loc = try c.ir.pushExpr(.local, c.alloc, svar.declT, node, .{ .id = svar.inner.local.id });
            var res = ExprResult.initCustom(loc, .local, CompactType.init(svar.declT), .{ .local = id });
            res.addressable = true;
            return res;
        },
        else => {
            return c.reportErrorFmt("Unsupported: {}", &.{v(svar.type)}, null);
        },
    }
}

fn semaLocal(c: *cy.Chunk, id: LocalVarId, node: *ast.Node) !ExprResult {
    const svar = c.varStack.items[id];
    switch (svar.type) {
        .local => {
            if (svar.declT == bt.Dyn and svar.vtype.id != bt.Any) {
                // TODO: If target_t == bt.Any, then emit just the local.
                if (c.sema.isUnboxedType(svar.vtype.id)) {
                    const local = try c.ir.pushExpr(.local, c.alloc, svar.vtype.id, node, .{ .id = svar.inner.local.id });
                    const loc = try c.ir.pushExpr(.unbox, c.alloc, svar.vtype.id, node, .{
                        .expr = local,
                    });
                    return ExprResult.initCustom(loc, .local, svar.vtype, .{ .local = id });
                } else {
                    const loc = try c.ir.pushExpr(.local, c.alloc, svar.vtype.id, node, .{ .id = svar.inner.local.id });
                    return ExprResult.initCustom(loc, .local, svar.vtype, .{ .local = id });
                }
            } else {
                const loc = try c.ir.pushExpr(.local, c.alloc, svar.declT, node, .{ .id = svar.inner.local.id });
                return ExprResult.initCustom(loc, .local, CompactType.init(svar.declT), .{ .local = id });
            }
        },
        .parentLocalAlias => {
            const loc = try c.ir.pushExpr(.captured, c.alloc, svar.vtype.id, node, .{ .idx = svar.inner.parentLocalAlias.capturedIdx });
            return ExprResult.initCustom(loc, .capturedLocal, svar.vtype, undefined);
        },
        else => {
            return c.reportErrorFmt("Unsupported: {}", &.{v(svar.type)}, null);
        },
    }
}

pub fn semaCtValue(c: *cy.Chunk, ct_value: cte.CtValue, expr: Expr, prefer_ct_sym: bool) !ExprResult {
    const node = expr.node;
    switch (ct_value.type) {
        bt.Type => {
            const type_id = ct_value.value.castHeapObject(*cy.heap.Type).type;
            const sym = c.sema.getTypeSym(type_id);
            return symbol(c, sym, expr, prefer_ct_sym);
        },
        bt.Boolean => {
            if (ct_value.value.isTrue()) {
                return c.semaTrue(node);
            } else {
                return c.semaFalse(node);
            }
        },
        bt.Integer => {
            return c.semaInt(ct_value.value.asBoxInt(), node);
        },
        bt.String => {
            return c.semaString(ct_value.value.asString(), node);
        },
        else => {},
    }
    const type_n = try c.sema.allocTypeName(ct_value.type);
    defer c.alloc.free(type_n);
    return c.reportErrorFmt("Unsupported compile-time value: `{}`.", &.{v(type_n)}, node);
}

fn semaIdent(c: *cy.Chunk, expr: Expr, prefer_ct_sym: bool) !ExprResult {
    const node = expr.node;
    const name = c.ast.nodeString(node);
    const res = try lookupIdent(c, name, node);
    switch (res) {
        .global => |sym| {
            const map = try symbol(c, sym, expr, false);
            const key = try c.semaString(name, node);

            const get_global = c.compiler.get_global.?.parent.cast(.func);
            var expr_res = try c.semaCallFuncSym2(get_global, node, map, node, key, .any, node);
            expr_res.resType = .global;
            return expr_res;
        },
        .local => |id| {
            if (expr.prefer_addressable) {
                return semaLocalAddr(c, id, node);
            } else {
                return semaLocal(c, id, node);
            }
        },
        .static => |sym| {
            return sema.symbol(c, sym, expr, prefer_ct_sym);
        },
        .ct_value => |ct_value| {
            defer c.vm.release(ct_value.value);
            return semaCtValue(c, ct_value, expr, prefer_ct_sym);
        },
    }
}

pub fn getLocalDistinctSym(c: *cy.Chunk, name: []const u8, node: *ast.Node) !?*Sym {
    // if (c.sym_cache.get(name)) |sym| {
    //     if (!sym.isDistinct()) {
    //         return c.reportErrorFmt("`{}` is not a unique symbol.", &.{v(name)}, node);
    //     }
    //     return sym;
    // }

    if (try c.getDistinctSym(@ptrCast(c.sym), name, node, false)) |res| {
        // try c.sym_cache.putNoClobber(c.alloc, name, res);
        return res;
    }
    return null;
}

const NameResultType = enum {
    sym,
    ct_value,
};

const NameResult = struct {
    type: NameResultType,
    data: union {
        sym: *Sym,
        ct_value: cte.CtValue,
    },

    fn initSym(sym: *Sym) NameResult {
        return .{ .type = .sym, .data = .{ .sym = sym, }};
    }

    fn initCtValue(ct_value: cte.CtValue) NameResult {
        return .{ .type = .ct_value, .data = .{ .ct_value = ct_value, }};
    }
};

pub fn getResolvedSym(c: *cy.Chunk, name: []const u8, node: *ast.Node, distinct: bool) !?NameResult {
    if (c.sym_cache.get(name)) |sym| {
        if (distinct and !sym.isDistinct()) {
            return c.reportErrorFmt("`{}` is not a unique symbol.", &.{v(name)}, node);
        }
        return NameResult.initSym(sym);
    }

    // Look in the current chunk module.
    if (distinct) {
        if (try c.getResolvedDistinctSym(@ptrCast(c.sym), name, node, false)) |res| {
            try c.sym_cache.putNoClobber(c.alloc, name, res);
            return NameResult.initSym(res);
        }
    } else {
        if (try c.getOptResolvedSym(@ptrCast(c.sym), name)) |sym| {
            try c.sym_cache.putNoClobber(c.alloc, name, sym);
            return NameResult.initSym(sym);
        }
    }

    // Look in ct context.
    var resolve_ctx_idx = c.resolve_stack.items.len-1;
    while (true) {
        const ctx = c.resolve_stack.items[resolve_ctx_idx];
        if (ctx.ct_params.size > 0) {
            if (ctx.ct_params.get(name)) |param| {
                c.vm.retain(param);
                return NameResult.initCtValue(.{ .type = param.getTypeId(), .value = param });
            }
        }

        if (std.mem.eql(u8, "Self", name)) {
            if (ctx.type == .func) {
                if (ctx.data.func.parent.type == .func) {
                    return NameResult.initSym(ctx.data.func.parent.parent.?);
                }
            } else if (ctx.type == .sym) {
                return NameResult.initSym(ctx.data.sym);
            }
        }

        if (!ctx.has_parent_ctx) {
            break;
        }
        resolve_ctx_idx -= 1;
    }

    // Look in use alls.
    var i = c.use_alls.items.len;
    while (i > 0) {
        i -= 1;
        const mod_sym = c.use_alls.items[i];
        if (distinct) {
            if (try c.getResolvedDistinctSym(@ptrCast(mod_sym), name, node, false)) |res| {
                try c.sym_cache.putNoClobber(c.alloc, name, res);
                return NameResult.initSym(res);
            }
        } else {
            if (try c.getOptResolvedSym(@ptrCast(mod_sym), name)) |sym| {
                try c.sym_cache.putNoClobber(c.alloc, name, sym);
                return NameResult.initSym(sym);
            }
        }
    }
    return null;
}

pub fn ensureResolvedFuncTemplate(c: *cy.Chunk, template: *cy.sym.FuncTemplate) !void {
    if (template.isResolved()) {
        return;
    }
    try sema.resolveFuncTemplate(c, template);
}

pub fn ensureResolvedTemplate(c: *cy.Chunk, template: *cy.sym.Template) !void {
    if (template.isResolved()) {
        return;
    }
    try sema.resolveTemplate(c, template);
}

pub fn ensureCompleteType(c: *cy.Chunk, type_id: cy.TypeId, node: *ast.Node) anyerror!void {
    const sym = c.sema.getTypeSym(type_id);
    const type_e = c.sema.getType(type_id);
    switch (sym.type) {
        .type => {
            switch (type_e.kind) {
                .bool,
                .int,
                .float => return,
                else => {
                    log.tracev("{}", .{sym.type});
                    return error.TODO;
                }
            }
        },
        .trait_t,
        .enum_t,
        .hostobj_t => {
            return;
        },
        .struct_t => {
            const struct_t = sym.cast(.struct_t);
            if (struct_t.isResolved()) {
                return;
            }
            if (struct_t.resolving_struct) {
                return c.reportError("Structs can not contain a circular dependency.", node);
            }
            const src_chunk = struct_t.getMod().chunk;
            try sema.resolveObjectLikeType(src_chunk, sym, @ptrCast(struct_t.decl.?));
        },
        .distinct_t => {
            const distinct_t = sym.cast(.distinct_t);
            if (distinct_t.resolved != null) {
                return;
            }
            _ = try resolveDistinctType(c, distinct_t);
        },
        .object_t => {
            // Objects are always references.
            return;
        },
        else => {
            log.tracev("{}", .{sym.type});
            return error.TODO;
        }
    }
}

/// If no type spec, default to `dynamic` type.
/// Returns the final resolved type sym.
pub fn resolveTypeSpecNode(c: *cy.Chunk, node: ?*ast.Node) anyerror!cy.TypeId {
    const n = node orelse {
        return bt.Dyn;
    };
    const type_id = try cte.resolveCtType(c, n);
    // if (type_id == bt.Void) {
    //     return c.reportErrorFmt("`void` can not be used as common type specifier.", &.{}, n);
    // }
    return type_id;
}

pub fn resolveReturnTypeSpecNode(c: *cy.Chunk, node: ?*ast.Node) anyerror!cy.TypeId {
    const n = node orelse {
        return bt.Void;
    };
    return cte.resolveCtType(c, n);
}

/// Creates `Placeholder`s for missing parent symbols.
fn ensureLocalNamePathSym(c: *cy.Chunk, path: []*ast.Node) !*Sym {
    var name = c.ast.nodeString(path[0]);
    var sym = (try getLocalDistinctSym(c, name, path[0])) orelse b: {
        const placeholder = try c.addPlaceholder(@ptrCast(c.sym), name);
        break :b @as(*cy.Sym, @ptrCast(placeholder));
    };
    for (path[1..]) |n| {
        name = c.ast.nodeString(n);
        sym = try c.getDistinctSym(sym, name, n, true);
    }
    return sym;
}

pub fn getResolveContext(c: *cy.Chunk) *ResolveContext {
    return &c.resolve_stack.items[c.resolve_stack.items.len-1];
}

fn resolveTemplateSig(c: *cy.Chunk, params: []*ast.FuncParam, opt_ret: ?*ast.Node, outSigId: *FuncSigId) ![]cy.sym.TemplateParam {
    const typeStart = c.typeStack.items.len;
    defer c.typeStack.items.len = typeStart;

    const tparams = try c.alloc.alloc(cy.sym.TemplateParam, params.len);
    errdefer c.alloc.free(tparams);

    for (params, 0..) |param, i| {
        if (param.type == null) {
            return c.reportErrorFmt("Expected param type specifier.", &.{}, @ptrCast(param));
        }
        const typeId = try resolveTypeSpecNode(c, param.type);
        try c.typeStack.append(c.alloc, typeId);
        const param_name = c.ast.nodeString(param.name_type);
        tparams[i] = .{
            .name = param_name,
            .type = typeId,
        };

        const ct_param_idx = getResolveContext(c).ct_params.size;
        const ref_t = try c.sema.ensureCtRefType(ct_param_idx);
        const param_v = try c.vm.allocType(ref_t);
        try setResolveCtParam(c, param_name, param_v);
    }

    var ret_t = bt.Type;
    if (opt_ret) |ret| {
        ret_t = try resolveReturnTypeSpecNode(c, ret);
    }

    outSigId.* = try c.sema.ensureFuncSig(@ptrCast(c.typeStack.items[typeStart..]), ret_t);
    return tparams;
}

pub fn resolveFuncType(c: *cy.Chunk, func_type: *ast.FuncType) !FuncSigId {
    const start = c.typeStack.items.len;
    defer c.typeStack.items.len = start;

    for (func_type.params) |param| {
        var type_id: cy.TypeId = undefined;
        if (param.type) |type_spec| {
            type_id = try resolveTypeSpecNode(c, type_spec);
        } else {
            type_id = try resolveTypeSpecNode(c, param.name_type);
        }

        const param_t = FuncParam.init(type_id);
        try c.typeStack.append(c.alloc, @bitCast(param_t));
    }

    // Get return type.
    const ret_t = try resolveReturnTypeSpecNode(c, func_type.ret);
    return c.sema.ensureFuncSig(@ptrCast(c.typeStack.items[start..]), ret_t);
}

pub fn indexOfTypedParam(params: []const *ast.FuncParam, start: usize) ?usize {
    for (params[start..], start..) |param, i| {
        if (param.type != null) {
            return i;
        }
    }
    return null;
}

/// `skip_ct_params` is used when expanding a template.
fn resolveFuncSig(c: *cy.Chunk, func: *cy.Func) !FuncSigId {
    const func_n = func.decl.?.cast(.funcDecl);

    // Get params, build func signature.
    const start = c.typeStack.items.len;
    defer c.typeStack.items.len = start;

    const sig_t = func_n.sig_t;
    if (sig_t == .infer) {
        return error.Unexpected;
    }

    var param_group_t: cy.TypeId = cy.NullId;
    var param_group_end: usize = undefined;
    for (func_n.params, 0..) |param, i| {
        const paramName = c.ast.nodeString(param.name_type);
        if (std.mem.eql(u8, paramName, "self")) {
            const self_t = func.parent.parent.?.getStaticType().?;
            try c.typeStack.append(c.alloc, self_t);
        } else {
            if (param.sema_tparam) {
                continue;
            }
            var type_id: cy.TypeId = undefined;
            if (param.type == null) {
                if (param_group_t == cy.NullId or i > param_group_end) {
                    // Attempt to find group type.
                    param_group_end = indexOfTypedParam(func_n.params, i + 1) orelse {
                        return c.reportError("Expected parameter type.", @ptrCast(param));
                    };
                    param_group_t = try resolveTypeSpecNode(c, func_n.params[param_group_end].type);
                }
                type_id = param_group_t;
            } else {
                type_id = try resolveTypeSpecNode(c, param.type);
            }

            const param_t = FuncParam.init(type_id);
            try c.typeStack.append(c.alloc, @bitCast(param_t));
        }
    }

    // Get return type.
    const retType = try resolveReturnTypeSpecNode(c, func_n.ret);
    return c.sema.ensureFuncSig(@ptrCast(c.typeStack.items[start..]), retType);
}

fn pushLambdaFuncParams(c: *cy.Chunk, n: *ast.LambdaExpr) !void {
    var param_group_t: cy.TypeId = cy.NullId;
    var param_group_end: usize = undefined;
    if (n.sig_t == .infer) {
        return error.Unexpected;
    }
    for (n.params, 0..) |param, i| {
        const paramName = c.ast.nodeString(param.name_type);
        if (std.mem.eql(u8, paramName, "self")) {
            return c.reportError("`self` is a reserved parameter for methods.", @ptrCast(param));
        }
        var type_id: cy.TypeId = undefined;
        if (param.type == null) {
            if (param_group_t == cy.NullId or i > param_group_end) {
                // Attempt to find group type.
                param_group_end = indexOfTypedParam(n.params, i + 1) orelse {
                    return c.reportError("Expected parameter type.", @ptrCast(param));
                };
                param_group_t = try resolveTypeSpecNode(c, n.params[param_group_end].type);
            }
            type_id = param_group_t;
        } else {
            type_id = try resolveTypeSpecNode(c, param.type);
        }
        const typeId = try resolveTypeSpecNode(c, param.type);
        try c.typeStack.append(c.alloc, typeId);
    }
}

fn inferLambdaFuncSig(c: *cy.Chunk, n: *ast.LambdaExpr, expr: Expr) !?FuncSigId {
    if (n.sig_t != .infer) {
        return null;
    }
    if (!expr.hasTargetType()) {
        return c.reportError("Can not infer function type.", expr.node);
    }
    const type_e = c.sema.getType(expr.target_t);
    if (type_e.kind == .func_ptr) {
        return type_e.data.func_ptr.sig;
    } else if (type_e.kind == .func_union) {
        return type_e.data.func_union.sig;
    } else {
        return c.reportError("Can not infer function type.", expr.node);
    }
}

const DeclNamePathResult = struct {
    name: cy.ast.NamePathInfo,
    parent: *cy.Sym,
};

fn ensureDeclNamePath(c: *cy.Chunk, parent: *cy.Sym, name_n: *ast.Node) !DeclNamePathResult {
    const name = c.ast.getNamePathInfo(name_n);
    if (name_n.type() != .name_path) {
        return .{
            .name = name,
            .parent = parent,
        };
    } else {
        const name_path = name_n.cast(.name_path).path;
        const explicit_parent = try ensureLocalNamePathSym(c, name_path[0..name_path.len-1]);
        return .{
            .name = name,
            .parent = explicit_parent,
        };
    }
}

pub fn popProc(self: *cy.Chunk) !cy.ir.StmtBlock {
    const stmtBlock = try popBlock(self);
    const proc = self.proc();
    proc.deinit(self.alloc);
    self.semaProcs.items.len -= 1;
    self.varStack.items.len = proc.varStart;
    return stmtBlock;
}

pub fn pushLambdaProc(c: *cy.Chunk, func: *cy.Func) !ProcId {
    const loc = try c.ir.pushEmptyExpr(.lambda, c.alloc, undefined, @ptrCast(func.decl));
    // try c.ir.func_blocks.append(c.alloc, loc);
    const id = try pushProc(c, func);
    c.proc().irStart = loc;
    return id;
}

pub fn pushFuncProc(c: *cy.Chunk, func: *cy.Func) !ProcId {
    const loc = try c.ir.pushEmptyStmt2(c.alloc, .funcBlock, @ptrCast(func.decl), false);
    try c.ir.func_blocks.append(c.alloc, loc);
    const id = try pushProc(c, func);
    c.proc().irStart = loc;
    return id;
}

pub fn semaMainBlock(compiler: *cy.Compiler, mainc: *cy.Chunk) !u32 {
    const loc = try mainc.ir.pushEmptyStmt2(compiler.alloc, .mainBlock, @ptrCast(mainc.ast.root), false);
    try mainc.ir.func_blocks.append(mainc.alloc, loc);

    const id = try pushProc(mainc, null);
    mainc.mainSemaProcId = id;

    if (!compiler.cont) {
        if (compiler.global_sym) |global| {
            const map = try mainc.semaMap(mainc.ast.null_node);
            _ = try mainc.ir.pushStmt(compiler.alloc, .set_var_sym, mainc.ast.null_node, .{
                .sym = @as(*cy.Sym, @ptrCast(global)),
                .expr = map.irIdx,
            });
        }
    }

    // Emit IR to invoke each chunks `$init` which has already has the correct dependency ordering. 
    // TODO: Should operate per worker not chunk.
    for (compiler.newChunks()) |c| {
        if (c.hasStaticInit) {
            const func = c.sym.getMod().getSym("$init").?.cast(.func).first;
            const exprLoc = try compiler.main_chunk.ir.pushExpr(.call_sym, c.alloc, bt.Void, c.ast.null_node, .{ 
                .func = func, .numArgs = 0, .args = 0,
            });
            _ = try compiler.main_chunk.ir.pushStmt(c.alloc, .exprStmt, c.ast.null_node, .{
                .expr = exprLoc,
                .isBlockResult = false,
            });
        }
    }

    // Main.
    try semaStmts(mainc, mainc.ast.root.?.stmts);

    const proc = mainc.proc();

    // Pop block first to obtain the max locals.
    const stmtBlock = try popProc(mainc);
    log.tracev("pop main block: {}", .{proc.maxLocals});

    mainc.ir.setStmtData(loc, .mainBlock, .{
        .maxLocals = proc.maxLocals,
        .bodyHead = stmtBlock.first,
    });
    return loc;
}

pub fn pushProc(self: *cy.Chunk, func: ?*cy.Func) !ProcId {
    var isStaticFuncBlock = false;
    var node: *ast.Node = undefined;
    if (func != null) {
        isStaticFuncBlock = func.?.isStatic();
        node = @ptrCast(func.?.decl);
    } else {
        node = @ptrCast(self.ast.root);
    }

    const new = Proc.init(node, func, @intCast(self.semaBlocks.items.len), isStaticFuncBlock, @intCast(self.varStack.items.len));
    const idx = self.semaProcs.items.len;
    try self.semaProcs.append(self.alloc, new);

    try pushBlock(self, node);
    return @intCast(idx);
}

fn preLoop(c: *cy.Chunk, node: *ast.Node) !void {
    _ = node;
    const proc = c.proc();
    const b = c.block();

    // Scan for dynamic vars and prepare them for entering loop block.
    const start = c.preLoopVarSaveStack.items.len;
    const vars = c.varStack.items[proc.varStart..];
    for (vars, 0..) |*svar, i| {
        if (svar.type == .local) {
            if (svar.isDynamic()) {
                if (svar.vtype.id != bt.Any) {
                    // Dynamic vars enter the loop with a recent type of `any`
                    // since the rest of the loop hasn't been seen.
                    try c.preLoopVarSaveStack.append(c.alloc, .{
                        .vtype = svar.vtype,
                        .varId = @intCast(proc.varStart + i),
                    });
                    svar.vtype.id = bt.Any;
                }
            }
        }
    }
    b.preLoopVarSaveStart = @intCast(start);
}

fn popBlock(c: *cy.Chunk) !cy.ir.StmtBlock {
    const proc = c.proc();
    const b = c.block();

    // Update max locals and unwind.
    if (proc.curNumLocals > proc.maxLocals) {
        proc.maxLocals = proc.curNumLocals;
    }
    proc.curNumLocals -= b.numLocals;

    const curAssignedVars = c.assignedVarStack.items[b.assignedVarStart..];
    c.assignedVarStack.items.len = b.assignedVarStart;

    if (proc.blockDepth > 1) {
        const pblock = c.semaBlocks.items[c.semaBlocks.items.len-2];

        // Merge types to parent sub block.
        for (curAssignedVars) |varId| {
            const svar = &c.varStack.items[varId];
            // log.tracev("merging {s}", .{self.getVarName(varId)});
            if (b.prevVarTypes.get(varId)) |prevt| {
                // Merge recent static type.
                if (svar.vtype.id != prevt.id) {
                    svar.vtype.id = bt.Any;

                    // Previous sub block hasn't recorded the var assignment.
                    if (!pblock.prevVarTypes.contains(varId)) {
                        try c.assignedVarStack.append(c.alloc, varId);
                    }
                }
            }
        }
    }
    b.prevVarTypes.deinit(c.alloc);

    // Restore `nameToVar` to previous sub-block state.
    if (proc.blockDepth > 1) {
        // Remove dead vars.
        const varDecls = c.varStack.items[b.varStart..];
        for (varDecls) |decl| {
            if (decl.type == .local and decl.inner.local.hidden) {
                continue;
            }
            const name = decl.namePtr[0..decl.nameLen];
            _ = proc.nameToVar.remove(name);
        }
        c.varStack.items.len = b.varStart;

        // Restore shadowed vars.
        const varShadows = c.varShadowStack.items[b.varShadowStart..];
        for (varShadows) |shadow| {
            const name = shadow.namePtr[0..shadow.nameLen];
            try proc.nameToVar.putNoClobber(c.alloc, name, .{
                .varId = shadow.varId,
                .blockId = shadow.blockId,
            });
        }
        c.varShadowStack.items.len = b.varShadowStart;
    }

    proc.blockDepth -= 1;
    c.semaBlocks.items.len -= 1;

    return c.ir.popStmtBlock();
}

fn popLoopBlock(c: *cy.Chunk) !cy.ir.StmtBlock {
    const stmtBlock = try popBlock(c);

    const b = c.block();
    const varSaves = c.preLoopVarSaveStack.items[b.preLoopVarSaveStart..];
    for (varSaves) |save| {
        var svar = &c.varStack.items[save.varId];
        if (svar.dynamicLastMutBlockId <= c.semaBlocks.items.len - 1) {
            // Unused inside loop block. Restore type.
            svar.vtype = save.vtype;
        }
    }
    c.preLoopVarSaveStack.items.len = b.preLoopVarSaveStart;
    return stmtBlock;
}

fn pushBlock(c: *cy.Chunk, node: *ast.Node) !void {
    try c.ir.pushStmtBlock(c.alloc);
    c.proc().blockDepth += 1;
    const new = Block.init(
        node,
        c.assignedVarStack.items.len,
        c.varStack.items.len,
        c.varShadowStack.items.len,
    );
    try c.semaBlocks.append(c.alloc, new);
}

fn pushMethodParamVars(c: *cy.Chunk, objectT: TypeId, func: *const cy.Func) !void {
    const curNode = c.curNode;
    defer c.curNode = curNode;

    const rFuncSig = c.compiler.sema.funcSigs.items[func.funcSigId];
    const params = rFuncSig.params();

    const param_decls = func.decl.?.cast(.funcDecl).params;
    if (param_decls.len > 0) {
        const name = c.ast.nodeString(param_decls[0].name_type);
        var rest: []const *ast.FuncParam = undefined;
        if (std.mem.eql(u8, name, "self")) {
            try declareParam(c, param_decls[0], false, 0, objectT);
            rest = param_decls[1..];
        } else {
            // Implicit `self` param.
            try declareParam(c, null, true, 0, objectT);
            rest = param_decls[0..];
        }
        var rt_param_idx: usize = 1;
        for (rest) |param_decl| {
            if (param_decl.sema_tparam) {
                continue;
            }
            try declareParam(c, param_decl, false, rt_param_idx, params[rt_param_idx].type);
            rt_param_idx += 1;
        }
    } else {
        // Implicit `self` param.
        try declareParam(c, null, true, 0, objectT);
    }
}

fn appendFuncParamVars(c: *cy.Chunk, ast_params: []const *ast.FuncParam, params: []const FuncParam) !void {
    if (params.len > 0) {
        var rt_param_idx: usize = 0;
        for (ast_params) |param| {
            if (param.sema_tparam) {
                continue;
            }
            try declareParam(c, param, false, rt_param_idx, params[rt_param_idx].type);
            rt_param_idx += 1;
        }
    }
}

fn pushLocalVar(c: *cy.Chunk, _type: LocalVarType, name: []const u8, declType: TypeId, hidden: bool) !LocalVarId {
    const proc = c.proc();
    const id: u32 = @intCast(c.varStack.items.len);

    if (!hidden) {
        _ = try proc.nameToVar.put(c.alloc, name, .{
            .varId = id,
            .blockId = @intCast(c.semaBlocks.items.len-1),
        });
    }
    try c.varStack.append(c.alloc, .{
        .declT = declType,
        .type = _type,
        .dynamicLastMutBlockId = 0,
        .namePtr = name.ptr,
        .nameLen = @intCast(name.len),
        .vtype = CompactType.init(declType),
    });
    return id;
}

fn getVarPtr(self: *cy.Chunk, name: []const u8) ?*LocalVar {
    if (self.proc().nameToVar.get(name)) |varId| {
        return &self.vars.items[varId];
    } else return null;
}

fn pushStaticVarAlias(c: *cy.Chunk, name: []const u8, sym: *Sym) !LocalVarId {
    const id = try pushLocalVar(c, .staticAlias, name, bt.Any, false);
    c.varStack.items[id].inner = .{ .staticAlias = sym };
    return id;
}

fn ensureLiftedVar(c: *cy.Chunk, var_id: LocalVarId) !void {
    const info = &c.varStack.items[var_id];
    info.inner.local.lifted = true;

    // Patch local IR.
    if (!info.inner.local.isParam) {
        const loc = info.inner.local.declIrStart;

        if (info.inner.local.hasInit) {
            const data = c.ir.getStmtDataPtr(loc, .declareLocalInit);
            data.lifted = true;
        } else {
            const data = c.ir.getStmtDataPtr(loc, .declareLocal);
            data.lifted = true;
        }
    }
}

fn pushCapturedVar(c: *cy.Chunk, name: []const u8, parentVarId: LocalVarId, vtype: CompactType) !LocalVarId {
    const proc = c.proc();
    const id = try pushLocalVar(c, .parentLocalAlias, name, vtype.id, false);
    const capturedIdx: u8 = @intCast(proc.captures.items.len);
    c.varStack.items[id].inner = .{
        .parentLocalAlias = .{
            .capturedIdx = capturedIdx,
        },
    };
    c.varStack.items[id].vtype = vtype;

    try ensureLiftedVar(c, parentVarId);

    try c.capVarDescs.put(c.alloc, id, .{
        .user = parentVarId,
    });

    try proc.captures.append(c.alloc, id);
    return id;
}

fn referenceSym(c: *cy.Chunk, sym: *Sym, node: *ast.Node) !void {
    if (!c.isInStaticInitializer()) {
        return;
    }

    // Determine the chunk the symbol belongs to.
    // Skip host symbols.
    var chunk: *cy.Chunk = undefined;
    if (sym.type != .userVar) {
        return;
    }
    chunk = sym.parent.?.getMod().?.chunk;

    if (c.compiler.svar_init_stack.items.len > 0) {
        const user_var = sym.cast(.userVar);
        if (user_var.resolving_init) {
            return c.reportErrorFmt("Referencing `{}` creates a circular dependency.", &.{v(sym.name())}, node);
        }
        const cur_svar = &c.compiler.svar_init_stack.items[c.compiler.svar_init_stack.items.len-1];
        if (std.mem.indexOfScalar(*cy.sym.UserVar, cur_svar.deps.items, user_var) == null) {
            try cur_svar.deps.append(c.alloc, user_var);
        }
    }
}

const LookupIdentResult = union(enum) {
    global: *Sym,
    static: *Sym,
    ct_value: cte.CtValue,

    /// Local, parent local alias, or parent object member alias.
    local: LocalVarId,
};

/// Static var lookup is skipped for callExpr since there is a chance it can fail on a
/// symbol with overloaded signatures.
pub fn lookupIdent(self: *cy.Chunk, name: []const u8, node: *ast.Node) !LookupIdentResult {
    if (self.semaProcs.items.len == 0) {
        return (try lookupStaticIdent(self, name, node)) orelse {
            if (self.use_global) {
                return LookupIdentResult{ .global = @ptrCast(self.compiler.global_sym.?) };
            }
            return self.reportErrorFmt("Could not find the symbol `{}`.", &.{v(name)}, node);
        };
    }

    const proc = self.proc();
    if (proc.nameToVar.get(name)) |varInfo| {
        const svar = self.varStack.items[varInfo.varId];
        if (svar.type == .staticAlias) {
            return LookupIdentResult{
                .static = svar.inner.staticAlias,
            };
        } else if (svar.isParentLocalAlias()) {
            // Can not reference local var in a static var decl unless it's in a nested block.
            // eg. var a = 0
            //     var b: a
            if (self.isInStaticInitializer() and self.semaBlockDepth() == 0) {
                return self.reportErrorFmt("Can not reference local `{}` in a static initializer.", &.{v(name)}, node);
            }
            return LookupIdentResult{
                .local = varInfo.varId,
            };
        } else {
            if (self.isInStaticInitializer() and self.semaBlockDepth() == 0) {
                return self.reportErrorFmt("Can not reference local `{}` in a static initializer.", &.{v(name)}, node);
            }
            return LookupIdentResult{
                .local = varInfo.varId,
            };
        }
    }

    if (try lookupParentLocal(self, name)) |res| {
        if (self.isInStaticInitializer()) {
            // Nop. Since static initializers are analyzed separately from the main block, it can capture any parent block local.
        } else if (proc.isStaticFuncBlock) {
            // Can not capture local before static function block.
            const funcName = proc.func.?.name();
            return self.reportErrorFmt("Can not capture the local variable `{}` from static function `{}`.\nOnly lambdas (anonymous functions) can capture local variables.", &.{v(name), v(funcName)}, self.curNode);
        }

        // Create a local captured variable.
        const parentVar = self.varStack.items[res.varId];
        const resVar = &self.varStack.items[res.varId];
        if (!resVar.inner.local.isParamCopied) {
            resVar.inner.local.isParamCopied = true;
        }
        const id = try pushCapturedVar(self, name, res.varId, parentVar.vtype);
        return LookupIdentResult{
            .local = id,
        };
    } else {
        const res = (try lookupStaticIdent(self, name, node)) orelse {
            if (self.use_global) {
                return LookupIdentResult{ .global = @ptrCast(self.compiler.global_sym.?) };
            }
            return self.reportErrorFmt("Undeclared variable `{}`.", &.{v(name)}, node);
        };
        // Caller should be responsible for caching.
        // switch (res) {
        //     .static => |sym| {
        //         if (!prefer_ct_sym) {
        //             _ = try pushStaticVarAlias(self, name, sym);
        //         }
        //     },
        //     else => {}
        // }
        return res;
    }
}

fn lookupStaticIdent(c: *cy.Chunk, name: []const u8, node: *ast.Node) !?LookupIdentResult {
    const res = (try getResolvedSym(c, name, node, false)) orelse {
        return null;
    };
    switch (res.type) {
        .sym => {
            return LookupIdentResult{ .static = res.data.sym };
        },
        .ct_value => {
            return LookupIdentResult{ .ct_value = res.data.ct_value };
        },
    }
}

const LookupParentLocalResult = struct {
    varId: LocalVarId,
    blockIdx: u32,
};

fn lookupParentLocal(c: *cy.Chunk, name: []const u8) !?LookupParentLocalResult {
    // Only check one block above.
    if (c.semaBlockDepth() > 1) {
        const prev = c.semaProcs.items[c.semaProcs.items.len - 2];
        if (prev.nameToVar.get(name)) |varInfo| {
            const svar = c.varStack.items[varInfo.varId];
            if (svar.isCapturable()) {
                return .{
                    .varId = varInfo.varId,
                    .blockIdx = @intCast(c.semaProcs.items.len - 2),
                };
            }
        }
    }
    return null;
}

pub fn reportIncompatType(c: *cy.Chunk, exp_t: cy.TypeId, act_t: cy.TypeId, node: *ast.Node) anyerror {
    const exp_name = try c.sema.allocTypeName(exp_t);
    defer c.alloc.free(exp_name);
    const act_name = try c.sema.allocTypeName(act_t);
    defer c.alloc.free(act_name);
    return c.reportErrorFmt("Expected type `{}`. Found `{}`.", &.{v(exp_name), v(act_name)}, node);
}

pub fn reportIncompatCallFunc2(c: *cy.Chunk, func: *cy.Func, args: []const cy.TypeId, ret_cstr: ReturnCstr, node: *ast.Node) anyerror {
    const name = func.name();
    var msg: std.ArrayListUnmanaged(u8) = .{};
    const w = msg.writer(c.alloc);
    const callSigStr = try c.sema.allocTypesStr(args, c);
    defer c.alloc.free(callSigStr);

    try w.print("Can not find compatible function for call: `{s}({s})`.", .{name, callSigStr});
    if (ret_cstr == .not_void) {
        try w.writeAll(" Expects non-void return.");
    }
    try w.writeAll("\n");
    const parent_name = try cy.sym.allocSymName(c.sema, c.alloc, func.parent.parent.?, .{ .from = c });
    defer c.alloc.free(parent_name);
    try w.print("Functions named `{s}` in `{s}`:\n", .{name, parent_name });

    const funcStr = try c.sema.formatFuncSig(func.funcSigId, &cy.tempBuf, c);
    try w.print("    func {s}{s}", .{name, funcStr});
    try c.compiler.addReportConsume(.compile_err, try msg.toOwnedSlice(c.alloc), c.id, node.pos());
    return error.CompileError;
}

pub fn reportIncompatCallFuncSym2(c: *cy.Chunk, sym: *cy.sym.FuncSym, args: []const cy.TypeId, ret_cstr: ReturnCstr, node: *ast.Node) anyerror {
    const name = sym.head.name();
    var msg: std.ArrayListUnmanaged(u8) = .{};
    const w = msg.writer(c.alloc);
    const callSigStr = try c.sema.allocTypesStr(args, c);
    defer c.alloc.free(callSigStr);

    try w.print("Can not find compatible function for call: `{s}({s})`.", .{name, callSigStr});
    if (ret_cstr == .not_void) {
        try w.writeAll(" Expects non-void return.");
    }
    try w.writeAll("\n");
    const parent_name = try cy.sym.allocSymName(c.sema, c.alloc, sym.head.parent.?, .{ .from = c });
    defer c.alloc.free(parent_name);
    try w.print("Functions named `{s}` in `{s}`:\n", .{name, parent_name });

    var funcStr = try c.sema.formatFuncSig(sym.firstFuncSig, &cy.tempBuf, c);
    try w.print("    func {s}{s}", .{name, funcStr});
    if (sym.numFuncs > 1) {
        var cur: ?*cy.Func = sym.first.next;
        while (cur) |curFunc| {
            try w.writeByte('\n');
            funcStr = try c.sema.formatFuncSig(curFunc.funcSigId, &cy.tempBuf, c);
            try w.print("    func {s}{s}", .{name, funcStr});
            cur = curFunc.next;
        }
    }
    try c.compiler.addReportConsume(.compile_err, try msg.toOwnedSlice(c.alloc), c.id, node.pos());
    return error.CompileError;
}

fn checkTypeCstr(c: *cy.Chunk, ctype: CompactType, cstrTypeId: TypeId, node: *ast.Node) !void {
    return checkTypeCstr2(c, ctype, cstrTypeId, cstrTypeId, node);
}

fn checkTypeCstr2(c: *cy.Chunk, ctype: CompactType, cstrTypeId: TypeId, reportCstrTypeId: TypeId, node: *ast.Node) !void {
    // Dynamic is allowed.
    if (!ctype.dynamic) {
        if (!cy.types.isTypeSymCompat(c.compiler, ctype.id, cstrTypeId)) {
            const cstrName = try c.sema.allocTypeName(reportCstrTypeId);
            defer c.alloc.free(cstrName);
            const typeName = try c.sema.allocTypeName(ctype.id);
            defer c.alloc.free(typeName);
            return c.reportErrorFmt("Expected type `{}`, got `{}`.", &.{v(cstrName), v(typeName)}, node);
        }
    }
}

fn pushExprRes(c: *cy.Chunk, res: ExprResult) !void {
    try c.exprResStack.append(c.alloc, res);
}

const SwitchInfo = struct {
    exprType: CompactType,
    exprTypeSym: *cy.Sym,
    exprIsChoiceType: bool,
    target: SemaExprOptions,
    choiceIrVarId: u8,
    is_expr: bool,

    fn init(c: *cy.Chunk, expr: ExprResult, is_expr: bool, target: SemaExprOptions) SwitchInfo {
        var info = SwitchInfo{
            .exprType = expr.type,
            .exprTypeSym = c.sema.getTypeSym(expr.type.id),
            .exprIsChoiceType = false,
            .choiceIrVarId = undefined,
            .is_expr = is_expr,
            .target = target,
        };

        if (info.exprTypeSym.type == .enum_t) {
            if (info.exprTypeSym.cast(.enum_t).isChoiceType) {
                info.exprIsChoiceType = true;
            }
        }
        return info;
    }
};

fn semaSwitchStmt(c: *cy.Chunk, block: *ast.SwitchBlock) !void {
    // Perform sema on expr first so it knows how to construct the rest of the switch.
    const expr = try c.semaExpr(block.expr, .{});
    var info = SwitchInfo.init(c, expr, false, .{});

    var blockLoc: u32 = undefined;
    var exprLoc: u32 = undefined;
    if (info.exprIsChoiceType) {
        blockLoc = try c.ir.pushStmt(c.alloc, .block, @ptrCast(block), .{ .bodyHead = cy.NullId });
        try pushBlock(c, @ptrCast(block));
        exprLoc = try semaSwitchChoicePrologue(c, &info, expr, block.expr);
    } else {
        exprLoc = expr.irIdx;
    }

    _ = try c.ir.pushStmt(c.alloc, .switchStmt, @ptrCast(block), {});
    _ = try semaSwitchBody(c, info, block, exprLoc);

    if (info.exprIsChoiceType) {
        const stmtBlock = try popBlock(c);
        const block_ = c.ir.getStmtDataPtr(blockLoc, .block);
        block_.bodyHead = stmtBlock.first;
    }
}

fn semaSwitchExpr(c: *cy.Chunk, block: *ast.SwitchBlock, target: SemaExprOptions) !ExprResult {
    // Perform sema on expr first so it knows how to construct the rest of the switch.
    const expr = block.expr;
    const expr_res = try c.semaExpr(expr, .{});
    var info = SwitchInfo.init(c, expr_res, true, target);

    var exprLoc: u32 = undefined;
    if (info.exprIsChoiceType) {
        try pushBlock(c, @ptrCast(block));

        exprLoc = try semaSwitchChoicePrologue(c, &info, expr_res, expr);
    } else {
        exprLoc = expr_res.irIdx;
    }

    if (info.exprIsChoiceType) {
    }
    const irIdx = try semaSwitchBody(c, info, block, exprLoc);

    if (info.exprIsChoiceType) {
        _ = try c.ir.pushStmt(c.alloc, .exprStmt, @ptrCast(block), .{
            .expr = irIdx,
            .isBlockResult = true,
        });

        const stmtBlock = try popBlock(c);
        const blockExprLoc = try c.ir.pushExpr(.blockExpr, c.alloc, bt.Any, @ptrCast(block), .{ .bodyHead = stmtBlock.first });
        return ExprResult.initStatic(blockExprLoc, bt.Any);
    } else {
        const type_id = c.ir.getExprType(irIdx).id;
        return ExprResult.initStatic(irIdx, type_id);
    }
}

/// Choice expr is assigned to a hidden local.
/// The choice tag is then used for the switch expr.
/// Choice payload is copied to case blocks that have a capture param.
fn semaSwitchChoicePrologue(c: *cy.Chunk, info: *SwitchInfo, expr: ExprResult, exprId: *ast.Node) !u32 {
    const choiceVarId = try declareLocalName(c, "choice", expr.type.id, true, true, exprId);
    const choiceVar = &c.varStack.items[choiceVarId];
    info.choiceIrVarId = choiceVar.inner.local.id;
    const declareLoc = choiceVar.inner.local.declIrStart;
    const declare = c.ir.getStmtDataPtr(declareLoc, .declareLocalInit);
    declare.init = expr.irIdx;
    declare.initType = expr.type;

    // Get choice tag for switch expr.
    const recLoc = try c.ir.pushExpr(.local, c.alloc, expr.type.id, exprId, .{ .id = choiceVar.inner.local.id });
    const exprLoc = try c.ir.pushExpr(.field, c.alloc, bt.Integer, exprId, .{
        .idx = 0,
        .rec = recLoc,
        .parent_t = expr.type.id,
    });
    return exprLoc;
}

fn semaSwitchBody(c: *cy.Chunk, info_: SwitchInfo, block: *ast.SwitchBlock, exprLoc: u32) !u32 {
    var info = info_;
    const irIdx = try c.ir.pushExpr(.switchExpr, c.alloc, undefined, @ptrCast(block), .{
        .numCases = @intCast(block.cases.len),
        .expr = exprLoc,
        .is_expr = info.is_expr,
    });
    const irCasesIdx = try c.ir.pushEmptyArray(c.alloc, u32, block.cases.len);

    // TODO: Check for exhaustive by looking at all case conds.
    const exhaustive = false;
    var has_else = false;
    for (block.cases, 0..) |case, i| {
        const irCaseIdx = try semaSwitchCase(c, info, @ptrCast(case));
        if (i == 0) {
            if (info.target.target_t != bt.Dyn and info.target.target_t != bt.Any) {
                const case_t = c.ir.getExprType(irCaseIdx).id;
                info.target.target_t = case_t;
            }
        }
        c.ir.setArrayItem(irCasesIdx, u32, i, irCaseIdx);
        if (case.conds.len == 0) {
            has_else = true;
        }
    }

    c.ir.setExprType(irIdx, info.target.target_t);

    if (!exhaustive and !has_else and info.is_expr) {
        return c.reportErrorFmt("Expected `else` case since switch is not exhaustive.", &.{}, @ptrCast(block));
    }

    return irIdx;
}

fn semaSwitchElseCase(c: *cy.Chunk, info: SwitchInfo, case: *ast.CaseBlock) !u32 {
    const irIdx = try c.ir.pushEmptyExpr(.switchCase, c.alloc, undefined, @ptrCast(case));

    var bodyHead: u32 = undefined;
    if (case.bodyIsExpr) {
        // Wrap in block expr.
        const body: *ast.Node = @ptrCast(@alignCast(case.stmts.ptr));
        bodyHead = try c.ir.pushExpr(.blockExpr, c.alloc, bt.Any, body, .{ .bodyHead = cy.NullId });
        try pushBlock(c, @ptrCast(case));

        const expr = try c.semaExpr(body, info.target);
        _ = try c.ir.pushStmt(c.alloc, .exprStmt, body, .{
            .expr = expr.irIdx,
            .isBlockResult = true,
        });
        const stmtBlock = try popBlock(c);
        const blockExpr = c.ir.getExprDataPtr(bodyHead, .blockExpr);
        blockExpr.bodyHead = stmtBlock.first;
        c.ir.setExprType(irIdx, expr.type.id);
    } else {
        try pushBlock(c, @ptrCast(case));

        if (info.is_expr) {
            return c.reportErrorFmt("Assign switch statement requires a return case: `else => {expr}`", &.{}, @ptrCast(case));
        }

        try semaStmts(c, case.stmts);
        const stmtBlock = try popBlock(c);
        bodyHead = stmtBlock.first;
        c.ir.setExprType(irIdx, bt.Void);
    }

    c.ir.setExprData(irIdx, .switchCase, .{
        .numConds = 0,
        .bodyIsExpr = case.bodyIsExpr,
        .bodyHead = bodyHead,
    });
    return irIdx;
}

fn semaSwitchCase(c: *cy.Chunk, info: SwitchInfo, case: *ast.CaseBlock) !u32 {
    if (case.conds.len == 0) {
        return semaSwitchElseCase(c, info, case);
    }

    const irIdx = try c.ir.pushEmptyExpr(.switchCase, c.alloc, undefined, @ptrCast(case));

    const hasCapture = case.capture != null;

    var case_capture_type: cy.TypeId = cy.NullId;
    if (case.conds.len > 0) {
        const conds_loc = try c.ir.pushEmptyArray(c.alloc, u32, case.conds.len);
        for (case.conds, 0..) |cond, i| {
            if (try semaCaseCond(c, info, conds_loc, cond, i)) |capture_type| {
                if (case_capture_type == cy.NullId) {
                    case_capture_type = capture_type;
                } else {
                    // TODO: Handle multiple cond capture types.
                }
            }
        }
    }

    var bodyHead: u32 = undefined;
    if (case.bodyIsExpr) {
        // Wrap in block expr.
        bodyHead = try c.ir.pushExpr(.blockExpr, c.alloc, bt.Any, @ptrCast(@alignCast(case.stmts.ptr)), .{ .bodyHead = cy.NullId });
        try pushBlock(c, @ptrCast(case));
    } else {
        try pushBlock(c, @ptrCast(case));
    }

    if (hasCapture) {
        const declT = if (info.exprType.dynamic) bt.Dyn else case_capture_type;
        const capVarId = try declareLocal(c, case.capture.?, declT, true);
        const declareLoc = c.varStack.items[capVarId].inner.local.declIrStart;

        // Copy payload to captured var.
        const recLoc = try c.ir.pushExpr(.local, c.alloc, info.exprType.id, case.capture.?, .{ .id = info.choiceIrVarId });
        const fieldLoc = try c.ir.pushExpr(.field, c.alloc, declT, case.capture.?, .{
            .idx = 1,
            .rec = recLoc,
            .parent_t = info.exprType.id,
        });

        const declare = c.ir.getStmtDataPtr(declareLoc, .declareLocalInit);
        declare.init = fieldLoc;
        declare.initType = CompactType.init(declT);
    }

    if (case.bodyIsExpr) {
        const body: *ast.Node = @ptrCast(@alignCast(case.stmts.ptr));
        const expr = try c.semaExpr(body, info.target);
        _ = try c.ir.pushStmt(c.alloc, .exprStmt, body, .{
            .expr = expr.irIdx,
            .isBlockResult = true,
        });
        const stmtBlock = try popBlock(c);
        const blockExpr = c.ir.getExprDataPtr(bodyHead, .blockExpr);
        blockExpr.bodyHead = stmtBlock.first;
        c.ir.setExprType(irIdx, expr.type.id);
    } else {
        if (info.is_expr) {
            return c.reportErrorFmt("Assign switch statement requires a return case: `case {cond} => {expr}`", &.{}, @ptrCast(case));
        }

        try semaStmts(c, case.stmts);
        const stmtBlock = try popBlock(c);
        bodyHead = stmtBlock.first;
        c.ir.setExprType(irIdx, bt.Void);
    }

    c.ir.setExprData(irIdx, .switchCase, .{
        .numConds = @intCast(case.conds.len),
        .bodyIsExpr = case.bodyIsExpr,
        .bodyHead = bodyHead,
    });
    return irIdx;
}

fn semaCaseCond(c: *cy.Chunk, info: SwitchInfo, conds_loc: u32, cond: *ast.Node, cond_idx: usize) !?cy.TypeId {
    if (info.exprIsChoiceType) {
        if (cond.type() == .dot_lit) {
            if (info.exprTypeSym.type != .enum_t) {
                const type_name = info.exprTypeSym.name();
                return c.reportErrorFmt("Can only match symbol literal for an enum type. Found `{}`.", &.{v(type_name)}, cond);
            }
            const name = c.ast.nodeString(cond);
            if (info.exprTypeSym.cast(.enum_t).getMember(name)) |member| {
                const condRes = try c.semaInt(member.val, cond);
                c.ir.setArrayItem(conds_loc, u32, cond_idx, condRes.irIdx);
                return member.payloadType;
            } else {
                const targetTypeName = info.exprTypeSym.name();
                return c.reportErrorFmt("`{}` is not a member of `{}`", &.{v(name), v(targetTypeName)}, cond);
            }
        } else {
            const targetTypeName = info.exprTypeSym.name();
            return c.reportErrorFmt("Expected to match a member of `{}`", &.{v(targetTypeName)}, cond);
        }
    }

    // General case.
    const condRes = try c.semaExprTarget(cond, info.exprType.id);
    c.ir.setArrayItem(conds_loc, u32, cond_idx, condRes.irIdx);
    return null;
}

pub const ChunkExt = struct {

    pub fn semaZeroInit(c: *cy.Chunk, typeId: cy.TypeId, node: *ast.Node) !ExprResult {
        switch (typeId) {
            bt.Any,
            bt.Dyn  => return c.semaInt(0, node),
            bt.Boolean  => return c.semaFalse(node),
            bt.Integer  => return c.semaInt(0, node),
            bt.Float    => return c.semaFloat(0, node),
            bt.ListDyn  => return c.semaEmptyList(node),
            bt.Map      => return c.semaMap(node),
            bt.String   => return c.semaString("", node),
            else => {
                const sym = c.sema.getTypeSym(typeId);
                if (sym.type != .object_t) {
                    return error.Unsupported;
                }

                const obj = sym.cast(.object_t);
                const irArgsIdx = try c.ir.pushEmptyArray(c.alloc, u32, obj.numFields);
                const irIdx = try c.ir.pushExpr(.object_init, c.alloc, typeId, node, .{
                    .typeId = obj.type, .numArgs = @as(u8, @intCast(obj.numFields)), .args = irArgsIdx,
                });
                for (obj.fields[0..obj.numFields], 0..) |field, i| {
                    const arg = try semaZeroInit(c, field.type, node);
                    c.ir.setArrayItem(irArgsIdx, u32, i, arg.irIdx);
                }
                return ExprResult.initStatic(irIdx, typeId);
            },
        }
    }

    pub fn semaTupleInit(c: *cy.Chunk, type_id: cy.TypeId, fields: []const cy.sym.FieldInfo, init: *ast.InitLit) !ExprResult {
        if (init.args.len != fields.len) {
            return c.reportErrorFmt("Expected {} args, found {}.", &.{v(fields.len), v(init.args.len)}, @ptrCast(init));
        }

        const args_loc = try c.ir.pushEmptyArray(c.alloc, u32, fields.len);
        for (fields, 0..) |field, i| {
            const arg = try c.semaExprCstr(init.args[i], field.type);
            c.ir.setArrayItem(args_loc, u32, i, arg.irIdx);
        }

        const loc = try c.ir.pushEmptyExpr(.object_init, c.alloc, ir.ExprType.init(type_id), @ptrCast(init));
        c.ir.setExprData(loc, .object_init, .{
            .typeId = type_id, .numArgs = @as(u8, @intCast(fields.len)), .args = args_loc,
        });

        return ExprResult.initStatic(loc, type_id);
    }

    /// `initializerId` is a record literal node.
    pub fn semaObjectInit2(c: *cy.Chunk, obj: *cy.sym.ObjectType, initializer: *ast.InitLit) !ExprResult {
        const node: *ast.Node = @ptrCast(initializer);
        const type_e = c.sema.types.items[obj.type];
        if (type_e.has_init_pair_method) {
            if (obj.numFields == 0) {
                const init = try c.ir.pushExpr(.object_init, c.alloc, obj.type, node, .{
                    .typeId = obj.type, .numArgs = 0, .args = 0,
                });
                return semaWithInitPairs(c, @ptrCast(obj), obj.type, initializer, init);
            } else {
                // Attempt to initialize fields with zero values.
                const fields = obj.getFields();
                const args_loc = try c.ir.pushEmptyArray(c.alloc, u32, fields.len);
                for (fields, 0..) |field, i| {
                    try c.checkForZeroInit(field.type, node);
                    // const type_name = try c.sema.allocTypeName(obj.type);
                    // defer c.alloc.free(type_name);
                    // return c.reportErrorFmt("Type `{}` can not initialize with `$initPair` since it does not have a default record initializer.", &.{v(type_name)}, initializerId);
                    const arg = try c.semaZeroInit(field.type, node);
                    c.ir.setArrayItem(args_loc, u32, i, arg.irIdx);
                }
                const init = try c.ir.pushExpr(.object_init, c.alloc, obj.type, node, .{
                    .typeId = obj.type, .numArgs = @as(u8, @intCast(fields.len)), .args = args_loc,
                });
                return semaWithInitPairs(c, @ptrCast(obj), obj.type, initializer, init);
            }
        }

        // Set up a temp buffer to map initializer entries to type fields.
        const fieldsDataStart = c.listDataStack.items.len;
        try c.listDataStack.resize(c.alloc, c.listDataStack.items.len + obj.numFields);
        defer c.listDataStack.items.len = fieldsDataStart;

        const undecl_start = c.listDataStack.items.len;
        _ = undecl_start;

        // Initially set to NullId so missed mappings are known from a linear scan.
        const fieldNodes = c.listDataStack.items[fieldsDataStart..];
        @memset(fieldNodes, .{ .node = null });

        for (initializer.args) |arg| {
            const pair = arg.cast(.keyValue);
            const fieldName = c.ast.nodeString(@ptrCast(pair.key));
            const info = try checkSymInitField(c, @ptrCast(obj), fieldName, pair.key);
            // if (info.use_get_method) {
            //     try c.listDataStack.append(c.alloc, .{ .node = entryId });
            //     entryId = entry.next();
            //     continue;
            // }

            fieldNodes[info.idx] = .{ .node = pair.value };
        }

        const irIdx = try c.ir.pushEmptyExpr(.object_init, c.alloc, ir.ExprType.init(obj.type), node);
        const irArgsIdx = try c.ir.pushEmptyArray(c.alloc, u32, obj.numFields);

        for (0..fieldNodes.len) |i| {
            const item = c.listDataStack.items[fieldsDataStart+i];
            const fieldT = obj.fields[i].type;
            if (item.node == null) {
                // Check that unset fields can be zero initialized.
                try c.checkForZeroInit(fieldT, node);

                const arg = try c.semaZeroInit(fieldT, node);
                c.ir.setArrayItem(irArgsIdx, u32, i, arg.irIdx);
            } else {
                const arg = try c.semaExprCstr(item.node.?, fieldT);
                c.ir.setArrayItem(irArgsIdx, u32, i, arg.irIdx);
            }
        }

        c.ir.setExprData(irIdx, .object_init, .{
            .typeId = obj.type, .numArgs = @as(u8, @intCast(obj.numFields)), .args = irArgsIdx,
        });

        // TODO: Implement with $initPairMissing.
        // const undecls = c.listDataStack.items[undecl_start..];
        // if (undecls.len > 0) {
        //     // Initialize object, then invoke $set on the undeclared fields.
        //     const expr = try c.ir.pushExpr(.blockExpr, c.alloc, obj.type, initializerId, .{ .bodyHead = cy.NullId });
        //     try pushBlock(c, initializerId);
        //     {
        //         // create temp with object.
        //         const var_id = try declareLocalName(c, "$temp", obj.type, true, initializerId);
        //         const temp_ir_id = c.varStack.items[var_id].inner.local.id;
        //         const temp_ir = c.varStack.items[var_id].inner.local.declIrStart;
        //         const decl_stmt = c.ir.getStmtDataPtr(temp_ir, .declareLocalInit);
        //         decl_stmt.init = irIdx;
        //         decl_stmt.initType = CompactType.initStatic(obj.type);

        //         // setFieldDyn.
        //         const temp_expr = try c.ir.pushExpr(.local, c.alloc, obj.type, initializerId, .{ .id = temp_ir_id });
        //         for (undecls) |undecl| {
        //             const entry = c.ast.node(undecl.node);
        //             const field_name = c.ast.nodeString(entry.data.keyValue.key);
        //             const field_value = try c.semaExpr(entry.data.keyValue.value, .{});
        //             _ = try c.ir.pushStmt(c.alloc, .set_field_dyn, initializerId, .{ .set_field_dyn = .{
        //                 .name = field_name,
        //                 .rec = temp_expr,
        //                 .right = field_value.irIdx,
        //             }});
        //         }

        //         // return temp.
        //         _ = try c.ir.pushStmt(c.alloc, .exprStmt, initializerId, .{
        //             .expr = temp_expr,
        //             .isBlockResult = true,
        //         });
        //     }
        //     const stmtBlock = try popBlock(c);
        //     c.ir.getExprDataPtr(expr, .blockExpr).bodyHead = stmtBlock.first;
        //     return ExprResult.initStatic(expr, obj.type);
        // } else {
            return ExprResult.initStatic(irIdx, obj.type);
        // }
    }

    pub fn semaObjectInit(c: *cy.Chunk, expr: Expr) !ExprResult {
        const node = expr.node.cast(.init_expr);

        const left = try c.semaExprSkipSym(Expr.init(node.left), false);
        if (left.resType != .sym) {
            const desc = try c.encoder.allocFmt(c.alloc, node.left);
            defer c.alloc.free(desc);
            return c.reportErrorFmt("Type `{}` does not exist.", &.{v(desc)}, node.left);
        }

        const sym = left.data.sym.resolved();
        if (sym.getStaticType()) |type_id| {
            if (left.data.sym.getVariant()) |variant| {
                if (variant.getSymTemplate() == c.sema.list_tmpl) {
                    const nargs = node.init.args.len;
                    const loc = try c.ir.pushEmptyExpr(.list, c.alloc, ir.ExprType.init(type_id), expr.node);
                    const args_loc = try c.ir.pushEmptyArray(c.alloc, u32, nargs);

                    const elem_t = variant.args[0].asHeapObject().type.type;

                    for (node.init.args, 0..) |arg, i| {
                        const res = try c.semaExprTarget(arg, elem_t);
                        c.ir.setArrayItem(args_loc, u32, i, res.irIdx);
                    }

                    c.ir.setExprData(loc, .list, .{ .nargs = @intCast(nargs), .args = args_loc });
                    return ExprResult.initStatic(loc, type_id);
                }
            }
        }

        switch (sym.type) {
            .struct_t => {
                const obj = sym.cast(.struct_t);
                if (node.init.array_like) {
                    const type_e = c.sema.getType(obj.type);
                    if (type_e.data.struct_t.tuple) {
                        return c.semaTupleInit(obj.type, obj.getFields(), node.init);
                    } else {
                        return c.reportError("Expected record initializer.", @ptrCast(node.init));
                    }
                }
                return c.semaObjectInit2(obj, node.init);
            },
            .object_t => {
                const obj = sym.cast(.object_t);
                if (node.init.array_like) {
                    const type_e = c.sema.getType(obj.type);
                    if (type_e.data.object.tuple) {
                        return c.semaTupleInit(obj.type, obj.getFields(), node.init);
                    } else {
                        return c.reportError("Expected record initializer.", @ptrCast(node.init));
                    }
                }
                return c.semaObjectInit2(obj, node.init);
            },
            .type => {
                const type_sym = sym.cast(.type);
                const type_e = c.sema.types.items[type_sym.type];
                if (type_e.kind == .array) {
                    const nargs = node.init.args.len;
                    const args_loc = try c.ir.pushEmptyArray(c.alloc, u32, nargs);
                    for (node.init.args, 0..) |arg, i| {
                        const res = try c.semaExprTarget(arg, type_e.data.array.elem_t);
                        c.ir.setArrayItem(args_loc, u32, i, res.irIdx);
                    }

                    const loc = try c.ir.pushExpr(.array, c.alloc, type_sym.type, expr.node, .{
                        .nargs = @intCast(nargs), .args = args_loc,
                    });
                    return ExprResult.initStatic(loc, type_sym.type);
                } else {
                    return error.TODO;
                }
            },
            .enum_t => {
                return c.reportErrorFmt("Only enum members can be used as initializers.", &.{}, node.left);
            },
            .enumMember => {
                const member = sym.cast(.enumMember);
                const enumSym = member.head.parent.?.cast(.enum_t);
                // Check if enum is choice type.
                if (!enumSym.isChoiceType) {
                    const desc = try c.encoder.allocFmt(c.alloc, node.left);
                    defer c.alloc.free(desc);
                    return c.reportErrorFmt("Can not initialize `{}`. It is not a choice type.", &.{v(desc)}, node.left);
                }

                if (member.payloadType == cy.NullId) {
                    return c.reportErrorFmt("Expected enum member with a payload type.", &.{}, node.left);
                } else {
                    if (c.sema.isUserObjectType(member.payloadType)) {
                        const obj = c.sema.getTypeSym(member.payloadType).cast(.object_t);
                        const payload = try c.semaObjectInit2(obj, node.init);
                        return semaInitChoice(c, member, payload, expr.node);
                    } else if (c.sema.isStructType(member.payloadType)) {
                        const struct_t = c.sema.getTypeSym(member.payloadType).cast(.struct_t);
                        const payload = try c.semaObjectInit2(struct_t, node.init);
                        return semaInitChoice(c, member, payload, expr.node);
                    } else {
                        const payloadTypeName = c.sema.getTypeBaseName(member.payloadType);
                        return c.reportErrorFmt("The payload type `{}` can not be initialized with key value pairs.", &.{v(payloadTypeName)}, node.left);
                    }
                }
            },
            .template => {
                const desc = try c.encoder.allocFmt(c.alloc, node.left);
                defer c.alloc.free(desc);
                return c.reportErrorFmt("Expected a type symbol. `{}` is a type template and must be expanded to a type first.", &.{v(desc)}, node.left);
            },
            .hostobj_t => {
                // TODO: Implement `$initRecord` instead of hardcoding which custom types are allowed.
                const object_t = sym.cast(.hostobj_t);
                switch (object_t.type) {
                    bt.Map => {
                        const init = try c.ir.pushExpr(.map, c.alloc, object_t.type, @ptrCast(node.init), .{ .placeholder = undefined });
                        const type_e = c.sema.types.items[object_t.type];
                        if (!type_e.has_init_pair_method) {
                            return error.Unexpected;
                        }
                        return semaWithInitPairs(c, sym, object_t.type, node.init, init);
                    },
                    else => {
                        const desc = try c.encoder.allocFmt(c.alloc, node.left);
                        defer c.alloc.free(desc);
                        return c.reportErrorFmt("Can not initialize `{}`.", &.{v(desc)}, node.left);
                    },
                }
            },
            else => {
                const desc = try c.encoder.allocFmt(c.alloc, node.left);
                defer c.alloc.free(desc);
                return c.reportErrorFmt("Can not initialize `{}`.", &.{v(desc)}, node.left);
            }
        }
    }

    pub fn semaCallFuncSymRec2(c: *cy.Chunk, sym: *cy.sym.FuncSym, rec: *ast.Node, rec_res: ExprResult,
        args: []const ExprResult, arg_nodes: []const *ast.Node, ret_cstr: ReturnCstr, node: *ast.Node) !ExprResult {

        if (sym.first.type == .trait) {
            const arg_start = c.arg_stack.items.len;
            defer c.arg_stack.items.len = arg_start;

            // Trait function will always match first argument.
            try c.arg_stack.append(c.alloc, sema.Argument.initSkip());
            for (0..args.len) |i| {
                try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(arg_nodes[i], args[i]));
            }

            const cstr = sema.CallCstr{ .ret = ret_cstr };
            const res = try sema.matchFuncSym(c, sym, arg_start, args.len+1, cstr, node);
            const loc = try c.ir.pushExpr(.call_trait, c.alloc, undefined, node, .{
                .trait = rec_res.irIdx,
                .vtable_idx = @intCast(res.func.data.trait.vtable_idx),
                .nargs = @intCast(res.data.rt.nargs),
                .args = res.data.rt.args_loc,
            });
            c.ir.setExprType2(loc, .{ .id = @intCast(res.func.retType), .throws = res.func.throws });
            return ExprResult.init(loc, CompactType.init(res.func.retType));
        } else {
            const arg_start = c.arg_stack.items.len;
            defer c.arg_stack.items.len = arg_start;

            try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(rec, rec_res));
            for (0..args.len) |i| {
                try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(arg_nodes[i], args[i]));
            }
            const cstr = sema.CallCstr{ .ret = ret_cstr };
            const res = try sema.matchFuncSym(c, sym, arg_start, args.len+1, cstr, node);
            return c.semaCallFuncSymResult(sym, res, cstr.ct_call, node);
        }
    }

    pub fn semaCallFuncSymRec(c: *cy.Chunk, sym: *cy.sym.FuncSym, rec: *ast.Node, rec_res: ExprResult,
        args: []const *ast.Node, ret_cstr: ReturnCstr, node: *ast.Node) !ExprResult {

        if (sym.first.type == .trait) {
            const arg_start = c.arg_stack.items.len;
            defer c.arg_stack.items.len = arg_start;

            // Trait function will always match first argument.
            try c.arg_stack.append(c.alloc, sema.Argument.initSkip());
            for (0..args.len) |i| {
                try c.arg_stack.append(c.alloc, sema.Argument.init(args[i]));
            }

            const cstr = sema.CallCstr{ .ret = ret_cstr };
            const res = try sema.matchFuncSym(c, sym, arg_start, args.len+1, cstr, node);
            const loc = try c.ir.pushExpr(.call_trait, c.alloc, undefined, node, .{
                .trait = rec_res.irIdx,
                .vtable_idx = @intCast(res.func.data.trait.vtable_idx),
                .nargs = @intCast(res.data.rt.nargs),
                .args = res.data.rt.args_loc,
            });
            c.ir.setExprType2(loc, .{ .id = @intCast(res.func.retType), .throws = res.func.throws });
            return ExprResult.init(loc, CompactType.init(res.func.retType));
        } else {
            const arg_start = c.arg_stack.items.len;
            defer c.arg_stack.items.len = arg_start;

            try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(rec, rec_res));
            for (args) |arg| {
                try c.arg_stack.append(c.alloc, sema.Argument.init(arg));
            }
            const cstr = sema.CallCstr{ .ret = ret_cstr };
            const res = try sema.matchFuncSym(c, sym, arg_start, args.len+1, cstr, node);
            return c.semaCallFuncSymResult(sym, res, cstr.ct_call, node);
        }
    }

    pub fn semaCallFuncResult(c: *cy.Chunk, res: sema.FuncResult, node: *ast.Node) !ExprResult {
        // try referenceSym(c, @ptrCast(matcher.sym), node);
        const loc = try c.ir.pushExpr(.call_sym, c.alloc, undefined, node, .{
            .func = res.func,
            .numArgs = @as(u8, @intCast(res.data.rt.nargs)),
            .args = res.data.rt.args_loc,
        });
        c.ir.setExprType2(loc, .{ .id = @intCast(res.func.retType), .throws = res.func.throws });
        return ExprResult.init(loc, CompactType.init(res.func.retType));
    }

    pub fn semaCallFuncSymResult(c: *cy.Chunk, func_sym: *cy.sym.FuncSym, func_res: sema.FuncSymResult, ct_call: bool, node: *ast.Node) !ExprResult {
        try referenceSym(c, @ptrCast(func_sym), node);

        if (ct_call) {
            if (func_res.dyn_call) {
                return error.TODO;
            }
            return ExprResult.initCtValue(func_res.data.ct);
        }
        if (func_res.dyn_call) {
            // Dynamic call.
            const loc = try c.ir.pushExpr(.call_sym_dyn, c.alloc, bt.Dyn, node, .{
                .sym = func_sym,
                .nargs = @as(u8, @intCast(func_res.data.rt.nargs)),
                .args = func_res.data.rt.args_loc,
            });
            return ExprResult.initDynamic(loc, bt.Any);
        } else {
            const loc = try c.ir.pushExpr(.call_sym, c.alloc, undefined, node, .{ 
                .func = func_res.func,
                .numArgs = @as(u8, @intCast(func_res.data.rt.nargs)),
                .args = func_res.data.rt.args_loc,
            });
            c.ir.setExprType2(loc, .{ .id = @intCast(func_res.func.retType), .throws = func_res.func.throws });
            return ExprResult.init(loc, CompactType.init(func_res.func.retType));
        }
    }

    pub fn semaCallFuncSym1(c: *cy.Chunk, sym: *cy.sym.FuncSym, arg1_n: *ast.Node, arg1: ExprResult,
        ret_cstr: ReturnCstr, node: *ast.Node) !ExprResult {

        const arg_start = c.arg_stack.items.len;
        defer c.arg_stack.items.len = arg_start;
        try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(arg1_n, arg1));

        const cstr = sema.CallCstr{ .ret = ret_cstr };
        const res = try sema.matchFuncSym(c, sym, arg_start, 1, cstr, node);
        return c.semaCallFuncSymResult(sym, res, cstr.ct_call, node);
    }

    pub fn semaCallFuncSym2(c: *cy.Chunk, sym: *cy.sym.FuncSym, arg1_n: *ast.Node, arg1: ExprResult,
        arg2_n: *ast.Node, arg2: ExprResult, ret_cstr: ReturnCstr, node: *ast.Node) !ExprResult {

        const arg_start = c.arg_stack.items.len;
        defer c.arg_stack.items.len = arg_start;
        try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(arg1_n, arg1));
        try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(arg2_n, arg2));

        const cstr = sema.CallCstr{ .ret = ret_cstr };
        const res = try sema.matchFuncSym(c, sym, arg_start, 2, cstr, node);
        return c.semaCallFuncSymResult(sym, res, cstr.ct_call, node);
    }

    pub fn semaCallFunc(c: *cy.Chunk, func: *cy.Func, args: []*ast.Node, ret_cstr: ReturnCstr, node: *ast.Node) !ExprResult {
        const arg_start = c.arg_stack.items.len;
        defer c.arg_stack.items.len = arg_start;
        for (args) |arg| {
            try c.arg_stack.append(c.alloc, sema.Argument.init(arg));
        }
        const cstr = sema.CallCstr{ .ret = ret_cstr };
        const res = try sema.matchFunc(c, func, arg_start, args.len, cstr, node);
        return c.semaCallFuncResult(res, node);
    }

    /// Match first overloaded function.
    pub fn semaCallFuncSym(c: *cy.Chunk, sym: *cy.sym.FuncSym, args: []*ast.Node, cstr: sema.CallCstr, node: *ast.Node) !ExprResult {
        const arg_start = c.arg_stack.items.len;
        defer c.arg_stack.items.len = arg_start;
        for (args) |arg| {
            try c.arg_stack.append(c.alloc, sema.Argument.init(arg));
        }
        const res = try sema.matchFuncSym(c, sym, arg_start, args.len, cstr, node);
        return c.semaCallFuncSymResult(sym, res, cstr.ct_call, node);
    }

    pub fn semaCallFuncTemplateRec(c: *cy.Chunk, template: *cy.sym.FuncTemplate, rec: *ast.Node, rec_res: ExprResult,
        args: []const *ast.Node, ret_cstr: ReturnCstr, node: *ast.Node) !ExprResult {

        const arg_start = c.arg_stack.items.len;
        defer c.arg_stack.items.len = arg_start;

        try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(rec, rec_res));
        for (args) |arg| {
            try c.arg_stack.append(c.alloc, sema.Argument.init(arg));
        }
        const cstr = sema.CallCstr{ .ret = ret_cstr };
        const res = try sema.matchFuncTemplate(c, template, arg_start, args.len+1, cstr, node);
        return c.semaCallFuncResult(res, node);
    }

    pub fn semaCallFuncTemplate(c: *cy.Chunk, template: *cy.sym.FuncTemplate, args: []*ast.Node, cstr: sema.CallCstr, node: *ast.Node) !ExprResult {
        const arg_start = c.arg_stack.items.len;
        defer c.arg_stack.items.len = arg_start;
        for (args) |arg| {
            try c.arg_stack.append(c.alloc, sema.Argument.init(arg));
        }
        const res = try sema.matchFuncTemplate(c, template, arg_start, args.len, cstr, node);
        return c.semaCallFuncResult(res, node);
    }

    pub fn semaPushDynCallArgs(c: *cy.Chunk, args: []*ast.Node) !u32 {
        const loc = try c.ir.pushEmptyArray(c.alloc, u32, args.len);
        for (args, 0..) |arg, i| {
            const argRes = try c.semaExprTarget(arg, bt.Dyn);
            c.ir.setArrayItem(loc, u32, i, argRes.irIdx);
        }
        return loc;
    }

    /// Skips emitting IR for a sym.
    pub fn semaExprSkipSym(c: *cy.Chunk, expr: Expr, use_addressable: bool) !ExprResult {
        const node = expr.node;
        switch (node.type()) {
            .ident => {
                var expr_ = expr;
                expr_.prefer_addressable = false;
                return semaIdent(c, expr_, true);
            },
            .array_expr => {
                const array_expr = node.cast(.array_expr);
                var left = try semaExprSkipSym(c, Expr.init(array_expr.left), true);
                if (left.resType == .sym) {
                    if (left.data.sym.type == .template) {
                        const template = left.data.sym.cast(.template);
                        if (template.kind == .value) {
                            const ct_val = try cte.expandValueTemplateForArgs(c, template, array_expr.args, node);
                            defer c.vm.release(ct_val.value);
                            if (ct_val.value.getTypeId() == bt.Type) {
                                const final_sym = c.sema.getTypeSym(ct_val.value.castHeapObject(*cy.heap.Type).type);
                                return sema.symbol(c, final_sym, expr, true);
                            } else {
                                return c.reportErrorFmt("Expected symbol.", &.{}, node);
                            }
                        } else {
                            const final_sym = try cte.expandTemplateForArgs(c, template, array_expr.args, node);
                            return sema.symbol(c, final_sym, expr, true);
                        }
                    } else if (left.data.sym.type == .func_template) {
                        const template = left.data.sym.cast(.func_template);
                        const func_res = try cte.expandFuncTemplateForArgs(c, template, array_expr.args, node);
                        return ExprResult.initCustom(cy.NullId, .func, CompactType.init(bt.Void), .{ .func = func_res });
                    }
                    left = try sema.symbol(c, left.data.sym, expr, false);
                }
                var expr_ = expr;
                expr_.use_addressable = use_addressable;
                return semaIndexExpr(c, array_expr.left, left, expr_);
            },
            .accessExpr => {
                const access = node.cast(.accessExpr);
                if (access.left.type() == .ident or access.left.type() == .accessExpr) {
                    if (access.right.type() != .ident) return error.Unexpected;

                    // TODO: Check if ident is sym to reduce work.
                    const cstr = Expr.init(node);
                    return c.semaAccessExpr(cstr, true);
                } else {
                    return c.semaExpr(node, .{});
                }
            },
            .array_type => {
                const array_type = node.cast(.array_type);
                const sym = try cte.expandTemplateForArgs(c, c.sema.array_tmpl, &.{ array_type.size, array_type.elem }, node);
                const ctype = CompactType.init(sym.getStaticType().?);
                return ExprResult.initCustom(cy.NullId, .sym, ctype, .{ .sym = sym });
            },
            .expandOpt => {
                const expand_opt = node.cast(.expandOpt);
                const sym = try cte.expandTemplateForArgs(c, c.sema.option_tmpl, &.{ expand_opt.param }, node);
                const ctype = CompactType.init(sym.getStaticType().?);
                return ExprResult.initCustom(cy.NullId, .sym, ctype, .{ .sym = sym });
            },
            .ptr => {
                const ptr = node.cast(.ptr);
                const sym = try cte.expandTemplateForArgs(c, c.sema.pointer_tmpl, &.{ ptr.elem }, node);
                const ctype = CompactType.init(sym.getStaticType().?);
                return ExprResult.initCustom(cy.NullId, .sym, ctype, .{ .sym = sym });
            },
            else => {
                // No chance it's a symbol path.
                return c.semaExpr2(expr);
            },
        }
    }

    pub fn semaExprHint(c: *cy.Chunk, node: *ast.Node, target_t: TypeId) !ExprResult {
        return try semaExpr(c, node, .{
            .target_t = target_t,
            .req_target_t = false,
            .fit_target = false,
            .fit_target_unbox_dyn = false,
        });
    }

    pub fn semaExprTarget(c: *cy.Chunk, node: *ast.Node, target_t: TypeId) !ExprResult {
        return try semaExpr(c, node, .{
            .target_t = target_t,
            .req_target_t = false,
            .fit_target = true,
            .fit_target_unbox_dyn = true,
        });
    }

    pub fn semaExprCstr(c: *cy.Chunk, node: *ast.Node, typeId: TypeId) !ExprResult {
        return try semaExpr(c, node, .{
            .target_t = typeId,
            .req_target_t = true,
            .fit_target = true,
            .fit_target_unbox_dyn = true,
        });
    }

    pub fn semaOptionExpr2(c: *cy.Chunk, res: ExprResult, node: *ast.Node) !ExprResult {
        if (res.type.dynamic and res.type.id == bt.Any) {
            // Runtime check.
            var new_res = res;
            new_res.irIdx = try c.ir.pushExpr(.typeCheckOption, c.alloc, bt.Any, node, .{
                .expr = res.irIdx,
            });
            return new_res;
        } else {
            const type_e = c.sema.types.items[res.type.id];
            if (type_e.kind != .option) {
                const name = try c.sema.allocTypeName(res.type.id);
                defer c.alloc.free(name);
                return c.reportErrorFmt("Expected `Option` type, found `{}`.", &.{v(name)}, node);
            }
            return res;
        }
    }

    pub fn semaOptionExpr(c: *cy.Chunk, node: *ast.Node) !ExprResult {
        const res = try semaExpr(c, node, .{});
        return semaOptionExpr2(c, res, node);
    }

    pub fn semaExpr(c: *cy.Chunk, node: *ast.Node, opts: SemaExprOptions) !ExprResult {
        // Set current node for unexpected errors.
        c.curNode = node;

        const expr = Expr{
            .target_t = opts.target_t,
            .reqTypeCstr = opts.req_target_t,
            .fit_target = opts.fit_target,
            .fit_target_unbox_dyn = opts.fit_target_unbox_dyn,
            .prefer_addressable = opts.prefer_addressable,
            .node = node,
        };
        return c.semaExpr2(expr);
    }

    pub fn semaExpr2(c: *cy.Chunk, expr: Expr) !ExprResult {
        const res = try c.semaExprNoCheck(expr);
        if (cy.Trace) {
            const node = expr.node;
            const type_name = c.sema.getTypeBaseName(res.type.id);
            log.tracev("expr.{s}: end {s}", .{@tagName(node.type()), type_name});
        }

        if (expr.hasTargetType()) {
            // TODO: Check for exact match first since it's the common case.
            const type_e = c.sema.types.items[expr.target_t];
            if (type_e.kind == .option) {
                // Already the same optional type.
                if (res.type.id == expr.target_t) {
                    return res;
                }
                // Check if type is compatible with Optional's some payload.
                const someMember = type_e.sym.cast(.enum_t).getMemberByIdx(1);
                if (cy.types.isTypeSymCompat(c.compiler, res.type.id, someMember.payloadType)) {
                    // Generate IR to wrap value into optional.
                    var b: ObjectBuilder = .{ .c = c };
                    try b.begin(expr.target_t, 2, expr.node);
                    const tag = try c.semaInt(1, expr.node);
                    b.pushArg(tag);
                    b.pushArg(res);
                    const irIdx = b.end();

                    return ExprResult.initStatic(irIdx, expr.target_t);
                }
            } else {
                if (type_e.kind == .trait) {
                    const res_type_e = c.sema.getType(res.type.id);
                    if (res_type_e.kind == .object) {
                        const object_t = res_type_e.sym.cast(.object_t);
                        if (object_t.implements(type_e.sym.cast(.trait_t))) {
                            const loc = try c.ir.pushExpr(.trait, c.alloc, expr.target_t, expr.node, .{
                                .expr = res.irIdx,
                                .expr_t = res.type.id,
                                .trait_t = expr.target_t,
                            });
                            return ExprResult.initStatic(loc, expr.target_t);
                        }
                    }
                } else if (type_e.kind == .func_union) {
                    const res_type_e = c.sema.getType(res.type.id);
                    if (res_type_e.kind == .func_ptr and res_type_e.data.func_ptr.sig == type_e.data.func_union.sig) {
                        const loc = try c.ir.pushExpr(.func_union, c.alloc, expr.target_t, expr.node, .{
                            .expr = res.irIdx,
                        });
                        return ExprResult.initStatic(loc, expr.target_t);
                    }
                }
            }

            if (expr.fit_target) {
                const target_is_boxed = expr.target_t == bt.Any or expr.target_t == bt.Dyn;
                if (target_is_boxed and res.type.id != bt.Any) {
                    // Box value.
                    var newRes = res;
                    newRes.irIdx = try c.ir.pushExpr(.box, c.alloc, bt.Any, expr.node, .{
                        .expr = res.irIdx,
                    });
                    // Returns IR expr as bt.Any since gen relies on it to determine whether an expression is boxed.
                    // But returns the child result type to sema so that vtype can be updated.
                    if (expr.target_t == bt.Any) {
                        newRes.type.id = bt.Any;
                    }
                    return newRes;
                }
                
                if (expr.target_t == bt.ExprType) {
                    // Infer expression type.
                    const loc = try c.ir.pushExpr(.type, c.alloc, bt.ExprType, expr.node, .{ .typeId = res.type.id, .expr_type = true });
                    return ExprResult.init(loc, CompactType.init(bt.ExprType));
                }

                if (!target_is_boxed and expr.fit_target_unbox_dyn and res.type.isDynAny()) {
                    const loc = try c.unboxOrCheck(expr.target_t, res, expr.node);
                    var newRes = res;
                    newRes.irIdx = loc;
                    newRes.type.id = @intCast(expr.target_t);
                    return newRes;
                }
            }

            if (expr.reqTypeCstr) {
                if (!cy.types.isTypeSymCompat(c.compiler, res.type.id, expr.target_t)) {
                    const cstrName = try c.sema.allocTypeName(expr.target_t);
                    defer c.alloc.free(cstrName);
                    const typeName = try c.sema.allocTypeName(res.type.id);
                    defer c.alloc.free(typeName);
                    return c.reportErrorFmt("Expected type `{}`, got `{}`.", &.{v(cstrName), v(typeName)}, expr.node);
                }
            }
        }
        return res;
    }

    pub fn unboxOrCheck(c: *cy.Chunk, target_t: cy.TypeId, res: ExprResult, node: *ast.Node) !u32 {
        if (c.sema.isUnboxedType(target_t)) {
            return c.ir.pushExpr(.unbox, c.alloc, target_t, node, .{
                .expr = res.irIdx,
            });
        } else {
            return c.ir.pushExpr(.type_check, c.alloc, target_t, node, .{
                .expr = res.irIdx,
                .exp_type = target_t,
            });
        }
    }

    pub fn semaExprNoCheck(c: *cy.Chunk, expr: Expr) anyerror!ExprResult {
        if (cy.Trace) {
            const node = expr.node;
            const nodeStr = try c.encoder.format(node, &cy.tempBuf);
            log.tracev("expr.{s}: \"{s}\"", .{@tagName(node.type()), nodeStr});
        }

        const node = expr.node;
        c.curNode = node;
        switch (node.type()) {
            .noneLit => {
                if (expr.hasTargetType()) {
                    return c.semaNone(expr.target_t, node);
                } else {
                    return c.reportErrorFmt("Could not determine optional type for `none`.", &.{}, node);
                }
            },
            .error_lit => {
                const name = c.ast.nodeString(node);
                const loc = try c.ir.pushExpr(.errorv, c.alloc, bt.Error, node, .{ .name = name });
                return ExprResult.initStatic(loc, bt.Error);
            },
            .symbol_lit => {
                const name = c.ast.nodeString(node);
                const irIdx = try c.ir.pushExpr(.symbol, c.alloc, bt.Symbol, node, .{ .name = name });
                return ExprResult.initStatic(irIdx, bt.Symbol);
            },
            .dot_lit => {
                if (!expr.hasTargetType()) {
                    return c.reportErrorFmt("Can not infer dot literal.", &.{}, node);
                }
                const name = c.ast.nodeString(node);
                switch (expr.target_t) {
                    bt.Dyn => {
                        const irIdx = try c.ir.pushExpr(.tag_lit, c.alloc, bt.TagLit, node, .{ .name = name });
                        return ExprResult.initStatic(irIdx, bt.TagLit);
                    },
                    bt.Symbol => {
                        const irIdx = try c.ir.pushExpr(.symbol, c.alloc, bt.Symbol, node, .{ .name = name });
                        return ExprResult.initStatic(irIdx, bt.Symbol);
                    },
                    else => {
                        if (c.sema.isEnumType(expr.target_t)) {
                            const sym = c.sema.getTypeSym(expr.target_t).cast(.enum_t);
                            if (sym.getMemberTag(name)) |tag| {
                                const irIdx = try c.ir.pushExpr(.enumMemberSym, c.alloc, expr.target_t, node, .{
                                    .type = expr.target_t,
                                    .val = @as(u8, @intCast(tag)),
                                });
                                return ExprResult.initStatic(irIdx, expr.target_t);
                            }
                        }
                    }
                }
                return c.reportErrorFmt("Can not infer dot literal.", &.{}, node);
            },
            .void_lit => {
                return c.semaVoid(node);
            },
            .trueLit => {
                return c.semaTrue(node);
            },
            .falseLit => return c.semaFalse(node),
            .floatLit => {
                const literal = c.ast.nodeString(node);
                const val = try std.fmt.parseFloat(f64, literal);
                const irIdx = try c.ir.pushExpr(.float, c.alloc, bt.Float, node, .{ .val = val });
                return ExprResult.initStatic(irIdx, bt.Float);
            },
            .decLit => {
                const literal = c.ast.nodeString(node);
                if (expr.target_t == bt.Float) {
                    const val = try std.fmt.parseFloat(f64, literal);
                    return c.semaFloat(val, node);
                } else if (expr.target_t == bt.Byte) {
                    const val = try std.fmt.parseInt(u8, literal, 10);
                    return c.semaByte(val, node);
                } else {
                    const val = try std.fmt.parseInt(u64, literal, 10);
                    return c.semaInt(@bitCast(val), node);
                }
            },
            .binLit => {
                const literal = c.ast.nodeString(node);
                if (expr.target_t == bt.Byte) {
                    const val = try std.fmt.parseInt(u8, literal[2..], 2);
                    const loc = try c.ir.pushExpr(.int, c.alloc, bt.Byte, node, .{ .val = val });
                    return ExprResult.initStatic(loc, bt.Byte);
                } else {
                    const val = try std.fmt.parseInt(i64, literal[2..], 2);
                    const loc = try c.ir.pushExpr(.int, c.alloc, bt.Integer, node, .{ .val = val });
                    return ExprResult.initStatic(loc, bt.Integer);
                }
            },
            .octLit => {
                const literal = c.ast.nodeString(node);
                if (expr.target_t == bt.Byte) {
                    const val = try std.fmt.parseInt(u8, literal[2..], 8);
                    const loc = try c.ir.pushExpr(.byte, c.alloc, bt.Byte, node, .{ .val = val });
                    return ExprResult.initStatic(loc, bt.Byte);
                } else {
                    const val = try std.fmt.parseInt(i64, literal[2..], 8);
                    const loc = try c.ir.pushExpr(.int, c.alloc, bt.Integer, node, .{ .val = val });
                    return ExprResult.initStatic(loc, bt.Integer);
                }
            },
            .hexLit => {
                const literal = c.ast.nodeString(node);
                if (expr.target_t == bt.Byte) {
                    const val = try std.fmt.parseInt(u8, literal[2..], 16);
                    const loc = try c.ir.pushExpr(.byte, c.alloc, bt.Byte, node, .{ .val = val });
                    return ExprResult.initStatic(loc, bt.Byte);
                } else {
                    const val = try std.fmt.parseInt(i64, literal[2..], 16);
                    const loc = try c.ir.pushExpr(.int, c.alloc, bt.Integer, node, .{ .val = val });
                    return ExprResult.initStatic(loc, bt.Integer);
                }
            },
            .ident => {
                return try semaIdent(c, expr, false);
            },
            .stringLit => return c.semaString(c.ast.nodeString(node), node),
            .raw_string_lit => return c.semaRawString(c.ast.nodeString(node), node),
            .runeLit => {
                const literal = c.ast.nodeString(node);
                if (literal.len == 0) {
                    return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
                }
                var val: i64 = undefined;
                if (literal[0] == '\\') {
                    const res = try unescapeSeq(literal[1..]);
                    val = res.char;
                    if (literal.len > res.advance + 1) {
                        return c.reportErrorFmt("Invalid escape sequence.", &.{}, node);
                    }
                } else {
                    const len = std.unicode.utf8ByteSequenceLength(literal[0]) catch {
                        return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
                    };
                    if (literal.len != len) {
                        return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
                    }
                    val = std.unicode.utf8Decode(literal[0..0+len]) catch {
                        return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
                    };
                }
                const loc = try c.ir.pushExpr(.int, c.alloc, bt.Integer, node, .{ .val = val });
                return ExprResult.initStatic(loc, bt.Integer);
            },
            .if_expr => {
                const if_expr = node.cast(.if_expr);

                const cond = try c.semaExprCstr(if_expr.cond, bt.Boolean);
                var body: ExprResult = undefined;
                var else_body: ExprResult = undefined;
                if (expr.hasTargetType()) {
                    body = try c.semaExprCstr(if_expr.body, expr.target_t);
                    else_body = try c.semaExprCstr(if_expr.else_expr, expr.target_t);
                } else {
                    body = try c.semaExpr(if_expr.body, .{});
                    else_body = try c.semaExprCstr(if_expr.else_expr, body.type.id);
                }

                const loc = try c.ir.pushExpr(.if_expr, c.alloc, body.type.id, node, .{
                    .cond = cond.irIdx,
                    .body = body.irIdx,
                    .elseBody = else_body.irIdx,
                });
                return ExprResult.init(loc, body.type);
            },
            .castExpr => {
                const cast_expr = node.cast(.castExpr);
                const typeId = try resolveTypeSpecNode(c, cast_expr.typeSpec);
                const child = try c.semaExpr(cast_expr.expr, .{});
                if (!child.type.isDynAny()) {
                    // Compile-time cast.
                    if (cy.types.isTypeSymCompat(c.compiler, child.type.id, typeId)) {
                        return child;
                    } else {
                        // Check if it's a narrowing cast (deferred to runtime).
                        if (!cy.types.isTypeSymCompat(c.compiler, typeId, child.type.id)) {
                            const actTypeName = c.sema.getTypeBaseName(child.type.id);
                            const expTypeName = c.sema.getTypeBaseName(typeId);
                            return c.reportErrorFmt("Cast expects `{}`, got `{}`.", &.{v(expTypeName), v(actTypeName)}, cast_expr.typeSpec);
                        }
                    }
                }
                var cast_loc: u32 = undefined;
                if (c.sema.isUnboxedType(typeId)) {
                    cast_loc = try c.ir.pushExpr(.unbox, c.alloc, typeId, node, .{
                        .expr = child.irIdx,
                    });
                } else {
                    cast_loc = try c.ir.pushExpr(.cast, c.alloc, typeId, node, .{
                        .typeId = typeId, .isRtCast = true, .expr = child.irIdx,
                    });
                }
                return ExprResult.init(cast_loc, CompactType.init(typeId));
            },
            .callExpr => {
                const call = node.cast(.callExpr);
                const res = try c.semaCallExpr(expr, call.ct);
                if (call.ct) {
                    if (res.resType != .ct_value) {
                        return error.Unexpected;
                    }
                    const ct_value = res.data.ct_value;
                    defer c.vm.release(ct_value.value);
                    return semaCtValue(c, ct_value, expr, false);
                }
                return res;
            },
            .ptr_slice => {
                const sym = try cte.expandTemplateForArgs(c, c.sema.ptr_slice_tmpl, &.{node.cast(.ptr_slice).elem}, node);
                const type_id = sym.getStaticType().?;
                const irIdx = try c.ir.pushExpr(.type, c.alloc, bt.Type, node, .{ .typeId = type_id });
                return ExprResult.init(irIdx, CompactType.init(bt.Type));
            },
            .ref_slice => {
                const sym = try cte.expandTemplateForArgs(c, c.sema.ref_slice_tmpl, &.{node.cast(.ref_slice).elem}, node);
                const type_id = sym.getStaticType().?;
                const irIdx = try c.ir.pushExpr(.type, c.alloc, bt.Type, node, .{ .typeId = type_id });
                return ExprResult.init(irIdx, CompactType.init(bt.Type));
            },
            .expandOpt => { 
                const sym = try cte.expandTemplateForArgs(c, c.sema.option_tmpl, &.{node.cast(.expandOpt).param}, node);
                const type_id = sym.getStaticType().?;
                const irIdx = try c.ir.pushExpr(.type, c.alloc, bt.Type, node, .{ .typeId = type_id });
                return ExprResult.init(irIdx, CompactType.init(bt.Type));
            },
            .array_type => { 
                const array_type = node.cast(.array_type);
                const sym = try cte.expandTemplateForArgs(c, c.sema.array_tmpl, &.{array_type.size, array_type.elem}, node);
                const type_id = sym.getStaticType().?;
                const irIdx = try c.ir.pushExpr(.type, c.alloc, bt.Type, node, .{ .typeId = type_id });
                return ExprResult.init(irIdx, CompactType.init(bt.Type));
            },
            .func_type => {
                const func_type = node.cast(.func_type);
                const sig = try resolveFuncType(c, func_type);
                if (func_type.is_union) {
                    const type_id = try getFuncUnionType(c, sig);
                    const irIdx = try c.ir.pushExpr(.type, c.alloc, bt.Type, node, .{ .typeId = type_id });
                    return ExprResult.init(irIdx, CompactType.init(bt.Type));
                } else {
                    const type_id = try getFuncPtrType(c, sig);
                    const irIdx = try c.ir.pushExpr(.type, c.alloc, bt.Type, node, .{ .typeId = type_id });
                    return ExprResult.init(irIdx, CompactType.init(bt.Type));
                }
            },
            .accessExpr => {
                return try c.semaAccessExpr(expr, false);
            },
            .unwrap_choice => {
                const unwrap = node.cast(.unwrap_choice);
                const choice = try c.semaExpr(unwrap.left, .{});
                const type_e = c.sema.getType(choice.type.id);
                if (type_e.kind != .choice) {
                    return c.reportError("Expected choice type.", unwrap.left);
                }

                const enum_t = type_e.sym.cast(.enum_t);
                const name = c.ast.nodeString(unwrap.right);
                const member = enum_t.getMember(name) orelse {
                    return c.reportErrorFmt("Choice case `{}` does not exist.", &.{v(name)}, unwrap.right);
                };
                const loc = try c.ir.pushExpr(.unwrapChoice, c.alloc, member.payloadType, node, .{
                    .choice = choice.irIdx,
                    .tag = @intCast(member.val),
                    .fieldIdx = 1,
                });
                return ExprResult.initStatic(loc, member.payloadType);
            },
            .unwrap => {
                const opt = try c.semaOptionExpr(node.cast(.unwrap).opt);
                const payload_t = if (opt.type.id == bt.Any) bt.Any else b: {
                    const type_sym = c.sema.getTypeSym(opt.type.id).cast(.enum_t);
                    const some = type_sym.getMemberByIdx(1);
                    break :b some.payloadType;
                };

                const loc = try c.ir.pushExpr(.unwrapChoice, c.alloc, payload_t, node, .{
                    .choice = opt.irIdx,
                    .tag = 1,
                    .fieldIdx = 1,
                });
                return ExprResult.initInheritDyn(loc, opt.type, payload_t);
            },
            .unwrap_or => {
                const unwrap = node.cast(.unwrap_or);
                const opt = try c.semaOptionExpr(unwrap.opt);
                const payload_t = if (opt.type.id == bt.Any) bt.Any else b: {
                    const type_sym = c.sema.getTypeSym(opt.type.id).cast(.enum_t);
                    const some = type_sym.getMemberByIdx(1);
                    break :b some.payloadType;
                };

                const default = try c.semaExprCstr(unwrap.default, payload_t);
                const loc = try c.ir.pushExpr(.unwrap_or, c.alloc, payload_t, node, .{
                    .opt = opt.irIdx,
                    .default = default.irIdx,
                });
                return ExprResult.initInheritDyn(loc, opt.type, payload_t);
            },
            .array_expr => {
                const array_expr = node.cast(.array_expr);
                var left = try c.semaExprSkipSym(Expr.init(array_expr.left), true);
                if (left.resType == .sym) {
                    if (left.data.sym.type == .template) {
                        const template = left.data.sym.cast(.template);
                        if (template.kind == .value) {
                            const ct_val = try cte.expandValueTemplateForArgs(c, template, array_expr.args, node);
                            defer c.vm.release(ct_val.value);
                            return semaCtValue(c, ct_val, expr, false);
                        } else {
                            const final_sym = try cte.expandTemplateForArgs(c, left.data.sym.cast(.template), array_expr.args, node);
                            return sema.symbol(c, final_sym, expr, false);
                        }
                    } else if (left.data.sym.type == .func_template) {
                        const template = left.data.sym.cast(.func_template);
                        const func_res = try cte.expandFuncTemplateForArgs(c, template, array_expr.args, node);
                        const typeId = try cy.sema.getFuncPtrType(c, func_res.funcSigId);
                        const ctype = CompactType.init(typeId);
                        const loc = try c.ir.pushExpr(.func_ptr, c.alloc, typeId, node, .{ .func = func_res });
                        return ExprResult.initCustom(loc, .func, ctype, .{ .func = func_res });
                    } else {
                        left = try sema.symbol(c, left.data.sym, expr, false);
                    }
                }
                return semaIndexExpr(c, array_expr.left, left, expr);
            },
            .range => {
                const range = node.cast(.range);
                const start = range.start orelse {
                    return error.Unexpected;
                };
                const end = range.end orelse {
                    return error.Unexpected;
                };

                var b: ObjectBuilder = .{ .c = c };
                try b.begin(bt.Range, 2, node);

                const start_res = try c.semaExprCstr(start, bt.Integer);
                b.pushArg(start_res);

                const end_res = try c.semaExprCstr(end, bt.Integer);
                b.pushArg(end_res);

                const loc = b.end();
                return ExprResult.initStatic(loc, bt.Range);
            },
            .binExpr => {
                const bin_expr = node.cast(.binExpr);
                return try c.semaBinExpr(expr, bin_expr.left, bin_expr.op, bin_expr.right);
            },
            .unary_expr => {
                return try c.semaUnExpr(expr);
            },
            .ref => {
                return try c.semaRefOf(expr);
            },
            .ptr => {
                return try c.semaPtrOf(expr);
            },
            .deref => {
                const deref = node.cast(.deref);

                const left = try c.semaExpr(deref.left, .{});
                const type_e = c.sema.types.items[left.type.id];
                const variant = type_e.sym.getVariant() orelse {
                    return c.reportError("Expected pointer type.", expr.node);
                };
                if (variant.getSymTemplate() != c.sema.pointer_tmpl) {
                    return c.reportError("Expected pointer type.", expr.node);
                }

                const child_t = variant.args[0].castHeapObject(*cy.heap.Type).type;
                const irIdx = try c.ir.pushExpr(.deref, c.alloc, child_t, expr.node, .{
                    .expr = left.irIdx,
                });
                return ExprResult.initStatic(irIdx, child_t);
            },
            .dot_init_lit => {
                if (expr.target_t == cy.NullId) {
                    return c.reportError("Can not infer initializer type.", expr.node);
                }

                const init_lit = node.cast(.dot_init_lit).init;

                const target_sym = c.sema.getTypeSym(expr.target_t);
                if (target_sym.getVariant()) |variant| {
                    if (variant.getSymTemplate() == c.sema.list_tmpl) {
                        const nargs = init_lit.args.len;
                        const loc = try c.ir.pushEmptyExpr(.list, c.alloc, ir.ExprType.init(expr.target_t), node);
                        const args_loc = try c.ir.pushEmptyArray(c.alloc, u32, nargs);

                        const elem_t = variant.args[0].asHeapObject().type.type;

                        for (init_lit.args, 0..) |arg, i| {
                            const res = try c.semaExprTarget(arg, elem_t);
                            c.ir.setArrayItem(args_loc, u32, i, res.irIdx);
                        }

                        c.ir.setExprData(loc, .list, .{ .nargs = @intCast(nargs), .args = args_loc });
                        return ExprResult.initStatic(loc, expr.target_t);
                    } else if (variant.getSymTemplate() == c.sema.array_tmpl) {
                        const elem_t = variant.args[1].asHeapObject().type.type;

                        const args_loc = try c.ir.pushEmptyArray(c.alloc, u32, init_lit.args.len);
                        for (init_lit.args, 0..) |arg, i| {
                            const res = try c.semaExprTarget(arg, elem_t);
                            c.ir.setArrayItem(args_loc, u32, i, res.irIdx);
                        }

                        const final_arr_t = try getArrayType(c, init_lit.args.len, elem_t);
                        const loc = try c.ir.pushEmptyExpr(.array, c.alloc, ir.ExprType.init(final_arr_t), node);
                        c.ir.setExprData(loc, .array, .{ .nargs = @intCast(init_lit.args.len), .args = args_loc });
                        return ExprResult.initStatic(loc, final_arr_t);
                    }
                }

                if (c.sema.isUserObjectType(expr.target_t)) {
                    // Infer user object type.
                    const type_e = c.sema.getType(expr.target_t);
                    if (init_lit.array_like) {
                        const sym = type_e.sym.cast(.object_t);
                        if (type_e.data.object.tuple) {
                            return c.semaTupleInit(sym.type, sym.getFields(), init_lit);
                        } else {
                            return c.reportError("Expected record initializer.", @ptrCast(init_lit));
                        }
                    }
                    return c.semaObjectInit2(type_e.sym.cast(.object_t), init_lit);
                } else if (c.sema.isStructType(expr.target_t)) {
                    const type_e = c.sema.getType(expr.target_t);
                    if (init_lit.array_like) {
                        const sym = type_e.sym.cast(.struct_t);
                        if (type_e.data.struct_t.tuple) {
                            return c.semaTupleInit(sym.type, sym.getFields(), init_lit);
                        } else {
                            return c.reportError("Expected record initializer.", @ptrCast(init_lit));
                        }
                    }
                    return c.semaObjectInit2(type_e.sym.cast(.struct_t), init_lit);
                } else {
                    return c.reportError("Can not infer initializer type.", expr.node);
                }
            },
            .init_lit => {
                const init_lit = node.cast(.init_lit);
                if (init_lit.array_like) {
                    const irIdx = try c.ir.pushEmptyExpr(.list, c.alloc, ir.ExprType.init(bt.ListDyn), node);
                    const irArgsIdx = try c.ir.pushEmptyArray(c.alloc, u32, init_lit.args.len);

                    for (init_lit.args, 0..) |arg, i| {
                        const argRes = try c.semaExprCstr(arg, bt.Dyn);
                        c.ir.setArrayItem(irArgsIdx, u32, i, argRes.irIdx);
                    }

                    c.ir.setExprData(irIdx, .list, .{ .nargs = @intCast(init_lit.args.len), .args = irArgsIdx });
                    return ExprResult.initStatic(irIdx, bt.ListDyn);
                } else {
                    const obj_t = c.sema.getTypeSym(bt.Table).cast(.object_t);
                    return c.semaObjectInit2(obj_t, init_lit);
                }
            },
            .stringTemplate => {
                const template = node.cast(.stringTemplate);
                const numExprs = template.parts.len / 2;
                const irIdx = try c.ir.pushEmptyExpr(.stringTemplate, c.alloc, ir.ExprType.init(bt.String), node);
                const irStrsIdx = try c.ir.pushEmptyArray(c.alloc, []const u8, numExprs+1);
                const irArgsIdx = try c.ir.pushEmptyArray(c.alloc, u32, numExprs);

                for (0..numExprs+1) |i| {
                    const str = template.parts[i*2];
                    c.ir.setArrayItem(irStrsIdx, []const u8, i, c.ast.nodeString(str));
                }

                for (0..numExprs) |i| {
                    const expr_ = template.parts[1 + i*2];
                    const argRes = try c.semaExprCstr(expr_, bt.Dyn);
                    c.ir.setArrayItem(irArgsIdx, u32, i, argRes.irIdx);
                }

                c.ir.setExprData(irIdx, .stringTemplate, .{ .numExprs = @intCast(numExprs), .args = irArgsIdx });
                return ExprResult.initStatic(irIdx, bt.String);
            },
            .group => {
                return c.semaExpr(node.cast(.group).child, .{});
            },
            .lambda_expr => {
                const lambda = node.cast(.lambda_expr);

                var ct = false;
                if (expr.hasTargetType()) {
                    const target_te = c.sema.getType(expr.target_t);
                    if (target_te.kind == .func_sym) {
                        ct = true;
                    }
                }

                if (try inferLambdaFuncSig(c, lambda, expr)) |sig| {
                    const func = try c.addUserLambda(@ptrCast(c.sym), lambda);
                    _ = try pushLambdaProc(c, func);
                    const irIdx = c.proc().irStart;

                    // Generate function body.
                    const func_sig = c.sema.getFuncSig(sig);
                    try c.resolveUserLambda(func, sig);
                    try appendFuncParamVars(c, lambda.params, func_sig.params());

                    const exprRes = try c.semaExprCstr(@ptrCast(@constCast(@alignCast(lambda.stmts.ptr))), func.retType);
                    _ = try c.ir.pushStmt(c.alloc, .retExprStmt, node, .{
                        .expr = exprRes.irIdx,
                    });

                    const ret_t = try popLambdaProc(c, ct);
                    return ExprResult.initStatic(irIdx, ret_t);
                } else {
                    const start = c.typeStack.items.len;
                    defer c.typeStack.items.len = start;
                    try pushLambdaFuncParams(c, lambda);

                    const func = try c.addUserLambda(@ptrCast(c.sym), lambda);
                    _ = try pushLambdaProc(c, func);
                    const irIdx = c.proc().irStart;

                    // Generate function body.
                    const params = c.typeStack.items[start..];
                    try appendFuncParamVars(c, lambda.params, @ptrCast(params));

                    var func_ret_t: cy.TypeId = undefined;
                    if (lambda.ret == null) {
                        // Infer return type.
                        const expr_res = try c.semaExpr(@ptrCast(@constCast(@alignCast(lambda.stmts.ptr))), .{});
                        func_ret_t = expr_res.type.id;
                        _ = try c.ir.pushStmt(c.alloc, .retExprStmt, node, .{
                            .expr = expr_res.irIdx,
                        });
                    } else {
                        func_ret_t = try resolveReturnTypeSpecNode(c, lambda.ret);

                        const expr_res = try c.semaExprCstr(@ptrCast(@constCast(@alignCast(lambda.stmts.ptr))), func_ret_t);
                        _ = try c.ir.pushStmt(c.alloc, .retExprStmt, node, .{
                            .expr = expr_res.irIdx,
                        });
                    }

                    const sig = try c.sema.ensureFuncSig(@ptrCast(params), func_ret_t);
                    try c.resolveUserLambda(func, sig);

                    const ret_t = try popLambdaProc(c, ct);
                    return ExprResult.initStatic(irIdx, ret_t);
                }
            },
            .lambda_multi => {
                const lambda = node.cast(.lambda_multi);

                var ct = false;
                if (expr.hasTargetType()) {
                    const target_te = c.sema.getType(expr.target_t);
                    if (target_te.kind == .func_sym) {
                        ct = true;
                    }
                }

                try pushResolveContext(c);
                defer popResolveContext(c);

                if (try inferLambdaFuncSig(c, lambda, expr)) |sig| {
                    const func = try c.addUserLambda(@ptrCast(c.sym), lambda);
                    _ = try pushLambdaProc(c, func);
                    const irIdx = c.proc().irStart;

                    const func_sig = c.sema.getFuncSig(sig);
                    try c.resolveUserLambda(func, sig);
                    try appendFuncParamVars(c, lambda.params, @ptrCast(func_sig.params()));

                    // Generate function body.
                    try semaStmts(c, lambda.stmts);

                    const ret_t = try popLambdaProc(c, ct);
                    return ExprResult.initStatic(irIdx, ret_t);
                } else {
                    const start = c.typeStack.items.len;
                    defer c.typeStack.items.len = start;
                    try pushLambdaFuncParams(c, lambda);

                    const func = try c.addUserLambda(@ptrCast(c.sym), lambda);
                    _ = try pushLambdaProc(c, func);
                    const irIdx = c.proc().irStart;

                    const func_ret_t = try resolveReturnTypeSpecNode(c, lambda.ret);
                    const params = c.typeStack.items[start..];
                    const sig = try c.sema.ensureFuncSig(@ptrCast(params), func_ret_t);
                    try c.resolveUserLambda(func, sig);

                    try appendFuncParamVars(c, lambda.params, @ptrCast(params));

                    // Generate function body.
                    try semaStmts(c, lambda.stmts);

                    const ret_t = try popLambdaProc(c, ct);
                    return ExprResult.initStatic(irIdx, ret_t);
                }
            },
            .init_expr => {
                return c.semaObjectInit(expr);
            },
            .throwExpr => {
                const child = try c.semaExpr(node.cast(.throwExpr).child, .{});
                const irIdx = try c.ir.pushExpr(.throw, c.alloc, bt.Any, node, .{ .expr = child.irIdx });
                return ExprResult.initDynamic(irIdx, bt.Any);
            },
            .tryExpr => {
                const try_expr = node.cast(.tryExpr);
                var catchError = false;
                if (try_expr.catchExpr) |catch_expr| {
                    if (catch_expr.type() == .ident) {
                        const name = c.ast.nodeString(catch_expr);
                        if (std.mem.eql(u8, "error", name)) {
                            catchError = true;
                        }
                    }
                } else {
                    catchError = true;
                }
                const irIdx = try c.ir.pushEmptyExpr(.tryExpr, c.alloc, ir.ExprType.init(bt.Any), node);

                if (catchError) {
                    // Ensure boxed since it will be merged with error type.
                    const child = try c.semaExprCstr(try_expr.expr, bt.Any);
                    c.ir.setExprData(irIdx, .tryExpr, .{ .expr = child.irIdx, .catchBody = cy.NullId });
                    const unionT = cy.types.unionOf(c.compiler, child.type.id, bt.Error);
                    return ExprResult.init(irIdx, CompactType.init2(unionT, child.type.dynamic));
                } else {
                    const child = try c.semaExpr(try_expr.expr, .{});
                    const catchExpr = try c.semaExprCstr(try_expr.catchExpr.?, child.type.id);
                    c.ir.setExprData(irIdx, .tryExpr, .{ .expr = child.irIdx, .catchBody = catchExpr.irIdx });
                    const dynamic = catchExpr.type.dynamic or child.type.dynamic;
                    const unionT = cy.types.unionOf(c.compiler, child.type.id, catchExpr.type.id);
                    return ExprResult.init(irIdx, CompactType.init2(unionT, dynamic));
                }
            },
            .comptimeExpr => {
                const child = node.cast(.comptimeExpr).child;
                if (child.type() == .ident) {
                    const name = c.ast.nodeString(child);
                    if (std.mem.eql(u8, name, "modUri")) {
                        return c.semaRawString(c.srcUri, node);
                    } else if (std.mem.eql(u8, name, "build_full_version")) {
                        return c.semaRawString(build_options.full_version, node);
                    } else {
                        return c.reportErrorFmt("Compile-time symbol does not exist: {}", &.{v(name)}, child);
                    }
                } else {
                    return c.reportErrorFmt("Unsupported compile-time expr: {}", &.{v(child.type())}, child);
                }
            },
            .coinit => {
                const coinit = node.cast(.coinit);
                const callExpr = coinit.child;

                const callee = try c.semaExprSkipSym(Expr.init(callExpr.callee), false);

                // Callee is already pushed as a value or is a symbol.
                var call_res: ExprResult = undefined;
                if (callee.resType == .sym) {
                    const sym = callee.data.sym;
                    call_res = try callSym(c, sym, callExpr.callee, callExpr.args, expr.getCallCstr(false), node);
                } else {
                    // preCall.
                    const args = try c.semaPushDynCallArgs(callExpr.args);
                    call_res = try c.semaCallValue(callee.irIdx, callExpr.args.len, args, node);
                }

                const irIdx = try c.ir.pushExpr(.coinitCall, c.alloc, bt.Fiber, node, .{
                    .call = call_res.irIdx,
                });
                return ExprResult.initStatic(irIdx, bt.Fiber);
            },
            .coyield => {
                const irIdx = try c.ir.pushExpr(.coyield, c.alloc, bt.Any, node, {});
                return ExprResult.initStatic(irIdx, bt.Any);
            },
            .coresume => {
                const child = try c.semaExpr(node.cast(.coresume).child, .{});
                const irIdx = try c.ir.pushExpr(.coresume, c.alloc, bt.Any, node, .{
                    .expr = child.irIdx,
                });
                return ExprResult.initStatic(irIdx, bt.Any);
            },
            .switchExpr => { 
                return semaSwitchExpr(c, node.cast(.switchExpr), .{
                    .target_t = expr.target_t,
                    .req_target_t = expr.reqTypeCstr,
                    .fit_target = expr.fit_target,
                    .fit_target_unbox_dyn = expr.fit_target_unbox_dyn,
                });
            },
            .await_expr => {
                const child = try c.semaExpr(node.cast(.await_expr).child, .{});

                const type_s = c.sema.getTypeSym(child.type.id);
                if (type_s.getVariant()) |variant| {
                    if (variant.getSymTemplate() == c.sema.future_tmpl) {
                        const ret = variant.args[0].asHeapObject().type.type;
                        const irIdx = try c.ir.pushExpr(.await_expr, c.alloc, ret, node, .{
                            .expr = child.irIdx,
                        });
                        return ExprResult.initInheritDyn(irIdx, child.type, ret);
                    }
                }

                if (child.type.isDynAny()) {
                    const irIdx = try c.ir.pushExpr(.await_expr, c.alloc, bt.Any, node, .{
                        .expr = child.irIdx,
                    });
                    return ExprResult.initDynamic(irIdx, bt.Any);
                } else {
                    // Can simply evaluate the expression.
                    return child;
                }
            },
            else => {
                return c.reportErrorFmt("Unsupported node: {}", &.{v(node.type())}, node);
            },
        }
    }

    pub fn semaCallExpr(c: *cy.Chunk, expr: Expr, ct_call: bool) !ExprResult {
        const node = expr.node.cast(.callExpr);

        if (node.hasNamedArg) {
            return c.reportErrorFmt("Unsupported named args.", &.{}, expr.node);
        }

        if (node.callee.type() == .accessExpr) {
            const callee = node.callee.cast(.accessExpr);
            const leftRes = try c.semaExprSkipSym(Expr.init(callee.left), true);
            if (callee.right.type() != .ident) {
                return error.Unexpected;
            }

            if (leftRes.resType == .sym) {
                const leftSym = leftRes.data.sym;

                if (leftSym.type == .func) {
                    return c.reportErrorFmt("Can not access function symbol `{}`.", &.{
                        v(c.ast.nodeString(callee.left))}, callee.right);
                }
                const rightName = c.ast.nodeString(callee.right);

                if (leftRes.type.isDynAny()) {
                    // Runtime method call.
                    const recv = try sema.symbol(c, leftSym, Expr.init(callee.left), true);
                    const args = try c.semaPushDynCallArgs(node.args);
                    const name = c.ast.nodeString(callee.right);
                    return c.semaCallObjSym(recv.irIdx, name, node.args.len, args, expr.node);
                }

                if (leftSym.isVariable()) {
                    // Look for sym under left type's module.
                    const leftTypeSym = c.sema.getTypeSym(leftRes.type.id);
                    const rightSym = try c.mustFindSym(leftTypeSym, rightName, callee.right);
                    const func_sym = try requireFuncSym(c, rightSym, callee.right);
                    const recv = try sema.symbol(c, leftSym, Expr.init(callee.left), true);
                    return c.semaCallFuncSymRec(func_sym, callee.left, recv,
                        node.args, expr.getRetCstr(), expr.node);
                } else {
                    // Look for sym under left module.
                    const rightSym = try c.mustFindSym(leftSym, rightName, callee.right);
                    return try callSym(c, rightSym, callee.right, node.args, expr.getCallCstr(ct_call), expr.node);
                }
            } else {
                if (leftRes.type.isDynAny()) {
                    // preCallObjSym.
                    const args = try c.semaPushDynCallArgs(node.args);
                    const name = c.ast.nodeString(callee.right);
                    return c.semaCallObjSym(leftRes.irIdx, name, node.args.len, args, expr.node);
                } else {
                    // Look for sym under left type's module.
                    const rightName = c.ast.nodeString(callee.right);
                    const leftTypeSym = c.sema.getTypeSym(leftRes.type.id);
                    const rightSym = try c.mustFindSym(leftTypeSym, rightName, callee.right);

                    if (rightSym.type == .func) {
                        return c.semaCallFuncSymRec(rightSym.cast(.func), callee.left, leftRes,
                            node.args, expr.getRetCstr(), expr.node);
                    } else if (rightSym.type == .func_template) {
                        return c.semaCallFuncTemplateRec(rightSym.cast(.func_template), callee.left, leftRes,
                            node.args, expr.getRetCstr(), expr.node);
                    } else {
                        const callee_v = try c.semaExpr(node.callee, .{});
                        if (callee_v.type.isDynAny()) {
                            const args = try c.semaPushDynCallArgs(node.args);
                            return c.semaCallValue(callee_v.irIdx, node.args.len, args, expr.node);
                        } else {
                            const type_e = c.sema.getType(callee_v.type.id);
                            if (type_e.kind == .func_ptr or type_e.kind == .func_union) {
                                const args = try c.semaPushDynCallArgs(node.args);
                                return c.semaCallValue(callee_v.irIdx, node.args.len, args, expr.node);
                            } else {
                                return c.reportErrorFmt("Expected `{}` to be a function.", &.{v(rightName)}, callee.right);
                            }
                        }
                    }
                }
            }
        } else if (node.callee.type() == .ident) {
            const name = c.ast.nodeString(node.callee);

            const varRes = try lookupIdent(c, name, node.callee);
            switch (varRes) {
                .global,
                .local => {
                    // preCall.
                    const calleeRes = try c.semaExpr(node.callee, .{});
                    const args = try c.semaPushDynCallArgs(node.args);
                    return c.semaCallValue(calleeRes.irIdx, node.args.len, args, expr.node);
                },
                .static => |sym| {
                    return callSym(c, sym, node.callee, node.args, expr.getCallCstr(ct_call), expr.node);
                },
                .ct_value => |ct_value| {
                    defer c.vm.release(ct_value.value);
                    if (ct_value.type == bt.Type) {
                        const type_id = ct_value.value.castHeapObject(*cy.heap.Type).type;
                        const sym = c.sema.getTypeSym(type_id);
                        return callSym(c, sym, node.callee, node.args, expr.getCallCstr(ct_call), expr.node);
                    } else {
                        const type_e = c.sema.getType(ct_value.type);
                        if (type_e.kind == .func_sym) {
                            const func = ct_value.value.asHeapObject().func_sym.func;
                            return c.semaCallFunc(func, node.args, expr.getRetCstr(), expr.node);
                        } else {
                            return error.TODO;
                        }
                    }
                },
            }
        } else {
            // preCall.
            const calleeRes = try c.semaExprSkipSym(Expr.init(node.callee), false);
            if (calleeRes.resType == .sym) {
                return callSym(c, calleeRes.data.sym, node.callee, node.args, expr.getCallCstr(ct_call), expr.node);
            } else if (calleeRes.resType == .func) {
                return c.semaCallFunc(calleeRes.data.func, node.args, expr.getRetCstr(), @ptrCast(node));
            } else {
                const args = try c.semaPushDynCallArgs(node.args);
                return c.semaCallValue(calleeRes.irIdx, node.args.len, args, expr.node);
            }
        }
    }

    /// Expr or construct binExpr from opAssignStmt.
    pub fn semaExprOrOpAssignBinExpr(c: *cy.Chunk, expr: Expr, opAssignBinExpr: bool) !ExprResult {
        if (!opAssignBinExpr) {
            return try c.semaExpr2(expr);
        } else {
            const stmt = expr.node.cast(.opAssignStmt);
            return try c.semaBinExpr(expr, stmt.left, stmt.op, stmt.right);
        }
    }

    pub fn semaString(c: *cy.Chunk, lit: []const u8, node: *ast.Node) !ExprResult {
        const raw = try c.unescapeString(lit);
        if (raw.ptr != lit.ptr) {
            // Dupe and track in ast.strs.
            const dupe = try c.alloc.dupe(u8, raw);
            try c.parser.ast.strs.append(c.alloc, dupe);
            return c.semaRawString(dupe, node);
        } else {
            return c.semaRawString(raw, node);
        }
    }

    pub fn semaRawString(c: *cy.Chunk, raw: []const u8, node: *ast.Node) !ExprResult {
        const irIdx = try c.ir.pushExpr(.string, c.alloc, bt.String, node, .{ .raw = raw });
        return ExprResult.initStatic(irIdx, bt.String);
    }

    pub fn semaFloat(c: *cy.Chunk, val: f64, node: *ast.Node) !ExprResult {
        const irIdx = try c.ir.pushExpr(.float, c.alloc, bt.Float, node, .{ .val = val });
        return ExprResult.initStatic(irIdx, bt.Float);
    }

    pub fn semaInt(c: *cy.Chunk, val: i64, node: *ast.Node) !ExprResult {
        const irIdx = try c.ir.pushExpr(.int, c.alloc, bt.Integer, node, .{ .val = val });
        return ExprResult.initStatic(irIdx, bt.Integer);
    }

    pub fn semaByte(c: *cy.Chunk, val: u8, node: *ast.Node) !ExprResult {
        const irIdx = try c.ir.pushExpr(.byte, c.alloc, bt.Byte, node, .{ .val = val });
        return ExprResult.initStatic(irIdx, bt.Byte);
    }

    pub fn semaVoid(c: *cy.Chunk, node: *ast.Node) !ExprResult {
        const loc = try c.ir.pushExpr(.voidv, c.alloc, bt.Void, node, {});
        return ExprResult.initStatic(loc, bt.Void);
    }

    pub fn semaTrue(c: *cy.Chunk, node: *ast.Node) !ExprResult {
        const loc = try c.ir.pushExpr(.truev, c.alloc, bt.Boolean, node, {});
        return ExprResult.initStatic(loc, bt.Boolean);
    }

    pub fn semaFalse(c: *cy.Chunk, node: *ast.Node) !ExprResult {
        const irIdx = try c.ir.pushExpr(.falsev, c.alloc, bt.Boolean, node, {});
        return ExprResult.initStatic(irIdx, bt.Boolean);
    }

    pub fn semaIsNone(c: *cy.Chunk, child: ExprResult, node: *ast.Node) !ExprResult {
        const irIdx = try c.ir.pushExpr(.none, c.alloc, bt.Boolean, node, .{ .child = child.irIdx });
        return ExprResult.initStatic(irIdx, bt.Boolean);
    }

    pub fn semaNone(c: *cy.Chunk, preferType: cy.TypeId, node: *ast.Node) !ExprResult {
        const type_e = c.sema.types.items[preferType];
        if (type_e.kind == .option) {
            // Generate IR to wrap value into optional.
            var b: ObjectBuilder = .{ .c = c };
            try b.begin(preferType, 2, node);
            const tag = try c.semaInt(0, node);
            b.pushArg(tag);
            const payload = try c.semaInt(0, node);
            b.pushArg(payload);
            const loc = b.end();

            return ExprResult.initStatic(loc, preferType);
        } else {
            const name = type_e.sym.name();
            return c.reportErrorFmt("Expected `Option(T)` to infer `none` value, found `{}`.", &.{v(name)}, node);
        }
    }

    pub fn semaEmptyList(c: *cy.Chunk, node: *ast.Node) !ExprResult {
        const irIdx = try c.ir.pushExpr(.list, c.alloc, bt.ListDyn, node, .{ .nargs = 0, .args = 0 });
        return ExprResult.initStatic(irIdx, bt.ListDyn);
    }

    pub fn semaMap(c: *cy.Chunk, node: *ast.Node) !ExprResult {
        const irIdx = try c.ir.pushExpr(.map, c.alloc, bt.Map, node, .{ .placeholder = undefined });
        return ExprResult.initStatic(irIdx, bt.Map);
    }

    pub fn semaCallValue(c: *cy.Chunk, calleeLoc: u32, numArgs: usize, argsLoc: u32, node: *ast.Node) !ExprResult {
        // Dynamic call.
        const loc = try c.ir.pushExpr(.call_dyn, c.alloc, bt.Dyn, node, .{ 
            .callee = calleeLoc,
            .numArgs = @as(u8, @intCast(numArgs)),
            .args = argsLoc,
        });
        return ExprResult.initDynamic(loc, bt.Any);
    }

    pub fn semaCallObjSym(c: *cy.Chunk, rec_loc: u32, name: []const u8, num_args: usize, irArgsIdx: u32, node: *ast.Node) !ExprResult {
        // Dynamic method call.
        const loc = try c.ir.pushExpr(.call_obj_sym, c.alloc, bt.Dyn, node, .{ 
            .name = name,
            .numArgs = @intCast(num_args),
            .rec = rec_loc,
            .args = irArgsIdx,
        });
        return ExprResult.initDynamic(loc, bt.Any);
    }

    pub fn semaCallObjSym0(c: *cy.Chunk, rec: u32, name: []const u8, node: *ast.Node) !ExprResult {
        const args_loc = try c.ir.pushEmptyArray(c.alloc, u32, 0);
        const loc = try c.ir.pushExpr(.call_obj_sym, c.alloc, bt.Dyn, node, .{ 
            .name = name,
            .numArgs = 0,
            .rec = rec,
            .args = args_loc,
        });
        return ExprResult.initDynamic(loc, bt.Any);
    }

    pub fn semaCallObjSym2(c: *cy.Chunk, recLoc: u32, name: []const u8, arg_exprs: []const ExprResult, node: *ast.Node) !ExprResult {
        const args_loc = try c.ir.pushEmptyArray(c.alloc, u32, arg_exprs.len);
        for (arg_exprs, 0..) |expr, i| {
            c.ir.setArrayItem(args_loc, u32, i, expr.irIdx);
        }

        const loc = try c.ir.pushExpr(.call_obj_sym, c.alloc, bt.Dyn, node, .{ 
            .name = name,
            .numArgs = @as(u8, @intCast(arg_exprs.len)),
            .rec = recLoc,
            .args = args_loc,
        });
        return ExprResult.initDynamic(loc, bt.Any);
    }

    pub fn semaRefOf(c: *cy.Chunk, expr: Expr) !ExprResult {
        const node = expr.node.cast(.ref);
        const child = try c.semaExpr(node.elem, .{ .prefer_addressable = true });
        const child_e = c.sema.getType(child.type.id);
        if (child_e.kind == .array) {
            if (child.resType == .local) {
                try ensureLiftedVar(c, child.data.local);
            }

            // Declare array in same block to extend lifetime.
            const tempv = try declareHiddenLocal(c, "$temp", child.type.id, child, node.elem);
            const temp = try semaLocal(c, tempv.id, node.elem);
            return semaArrayRefSlice(c, temp, expr.node);
        }

        if (!child.addressable) {
            return c.reportError("Expected an addressable expression.", expr.node);
        }
        if (child.resType == .local) {
            try ensureLiftedVar(c, child.data.local);
        }

        const ref_t = try getRefType(c, child.type.id);
        const irIdx = try c.ir.pushExpr(.address_of, c.alloc, ref_t, expr.node, .{
            .expr = child.irIdx,
        });
        return ExprResult.initStatic(irIdx, ref_t);
    }

    pub fn semaArrayPtrSlice(c: *cy.Chunk, arr: ExprResult, node: *ast.Node) !ExprResult {
        const array_t = c.sema.getType(arr.type.id);
        const elem_t = array_t.data.array.elem_t;
        const slice_t = try getPtrSliceType(c, elem_t);
        const ptr_t = try getPointerType(c, elem_t);

        var b: ObjectBuilder = .{ .c = c };
        try b.begin(slice_t, 2, node);
        var loc = try c.ir.pushExpr(.address_of, c.alloc, ptr_t, node, .{
            .expr = arr.irIdx,
        });
        b.pushArg(ExprResult.initStatic(loc, ptr_t));

        const len = try semaInt(c, @intCast(array_t.data.array.n), node);
        b.pushArg(len);
        loc = b.end();

        return ExprResult.initStatic(loc, slice_t);
    }

    pub fn semaArrayRefSlice(c: *cy.Chunk, arr: ExprResult, node: *ast.Node) !ExprResult {
        const array_t = c.sema.getType(arr.type.id);
        const elem_t = array_t.data.array.elem_t;
        const slice_t = try getRefSliceType(c, elem_t);
        const ptr_t = try getPointerType(c, elem_t);

        var b: ObjectBuilder = .{ .c = c };
        try b.begin(slice_t, 2, node);
        var loc = try c.ir.pushExpr(.address_of, c.alloc, ptr_t, node, .{
            .expr = arr.irIdx,
        });
        b.pushArg(ExprResult.initStatic(loc, ptr_t));

        const len = try semaInt(c, @intCast(array_t.data.array.n), node);
        b.pushArg(len);
        loc = b.end();

        return ExprResult.initStatic(loc, slice_t);
    }

    pub fn semaPtrOf(c: *cy.Chunk, expr: Expr) !ExprResult {
        const node = expr.node.cast(.ptr);
        var child_cstr = Expr.init(node.elem);
        child_cstr.prefer_addressable = true;
        if (expr.hasTargetType()) {
            const target_te = c.sema.getType(expr.target_t);
            if (target_te.sym.getVariant()) |variant| {
                if (variant.getSymTemplate() == c.sema.pointer_tmpl) {
                    const child_t = variant.args[0].castHeapObject(*cy.heap.Type).type;
                    child_cstr.target_t = child_t;
                } else if (variant.getSymTemplate() == c.sema.ptr_slice_tmpl) {
                    const child_t = variant.args[0].castHeapObject(*cy.heap.Type).type;
                    // Pick an arbitrary array size for inferred type.
                    const array_t = try getArrayType(c, 1, child_t);
                    child_cstr.target_t = array_t;
                }
            }
        }
        var child = try c.semaExprSkipSym(child_cstr, false);
        if (child.resType == .sym) {
            const arg = try c.vm.allocType(child.data.sym.getStaticType().?);
            defer c.vm.release(arg);
            const sym = try cte.expandTemplate(c, c.sema.pointer_tmpl, &.{ arg });
            const ptr_t = sym.getStaticType().?;
            const loc = try c.ir.pushExpr(.type, c.alloc, bt.Type, expr.node, .{ .typeId = ptr_t });
            return ExprResult.initStatic(loc, bt.Type);
        }
        if (child.resType != .local) {
            const tempv = try declareHiddenLocal(c, "$temp", child.type.id, child, expr.node);
            child = try semaLocal(c, tempv.id, expr.node);
        }

        if (child.resType == .local) {
            // Ensure lifted var so pointer doesn't get invalidated from stack resizing.
            try ensureLiftedVar(c, child.data.local);
        }

        const child_te = c.sema.getType(child.type.id);
        if (child_te.kind == .array) {
            return semaArrayPtrSlice(c, child, expr.node);
        }

        const ptr_t = try getPointerType(c, child.type.id);
        const loc = try c.ir.pushExpr(.address_of, c.alloc, ptr_t, expr.node, .{
            .expr = child.irIdx,
        });
        return ExprResult.initStatic(loc, ptr_t);
    }

    pub fn semaUnExpr(c: *cy.Chunk, expr: Expr) !ExprResult {
        const node = expr.node.cast(.unary_expr);

        switch (node.op) {
            .minus => {
                var child: ExprResult = undefined;
                if (node.child.type() == .decLit) {
                    const literal = c.ast.nodeString(node.child);
                    if (expr.target_t == bt.Float) {
                        const val = try std.fmt.parseFloat(f64, literal);
                        return c.semaFloat(-val, expr.node);
                    } else if (expr.target_t == bt.Byte) {
                        const val: i8 = @intCast(-(try std.fmt.parseInt(i9, literal, 10)));
                        return c.semaByte(@bitCast(val), expr.node);
                    } else {
                        const val: i64 = @intCast(-(try std.fmt.parseInt(i65, literal, 10)));
                        return c.semaInt(val, expr.node);
                    }
                } else {
                    child = try c.semaExprHint(node.child, expr.target_t);
                }
                if (child.type.isDynAny()) {
                    return c.semaCallObjSym2(child.irIdx, getUnOpName(.minus), &.{}, expr.node);
                }

                if (child.type.id == bt.Integer or child.type.id == bt.Float) {
                    // Specialized.
                    const irIdx = try c.ir.pushExpr(.preUnOp, c.alloc, child.type.id, expr.node, .{ .unOp = .{
                        .childT = child.type.id, .op = node.op, .expr = child.irIdx,
                    }});
                    return ExprResult.initStatic(irIdx, child.type.id);
                } else {
                    // Look for sym under child type's module.
                    const childTypeSym = c.sema.getTypeSym(child.type.id);
                    const sym = try c.mustFindSym(childTypeSym, node.op.name(), expr.node);
                    const func_sym = try requireFuncSym(c, sym, expr.node);
                    return c.semaCallFuncSym1(func_sym, node.child, child, expr.getRetCstr(), expr.node);
                }
            },
            .not => {
                const child = try c.semaExprCstr(node.child, bt.Boolean);
                const loc = try c.ir.pushExpr(.preUnOp, c.alloc, bt.Boolean, expr.node, .{ .unOp = .{
                    .childT = child.type.id,
                    .op = node.op,
                    .expr = child.irIdx,
                }});
                return ExprResult.initStatic(loc, bt.Boolean);
            },
            .bitwiseNot => {
                const child = try c.semaExprTarget(node.child, expr.target_t);
                if (child.type.isDynAny()) {
                    return c.semaCallObjSym2(child.irIdx, getUnOpName(.bitwiseNot), &.{}, expr.node);
                }

                if (child.type.id == bt.Integer) {
                    const loc = try c.ir.pushExpr(.preUnOp, c.alloc, bt.Integer, expr.node, .{ .unOp = .{
                        .childT = child.type.id,
                        .op = node.op,
                        .expr = child.irIdx,
                    }});
                    return ExprResult.initStatic(loc, bt.Integer);
                } else {
                    // Look for sym under child type's module.
                    const childTypeSym = c.sema.getTypeSym(child.type.id);
                    const sym = try c.mustFindSym(childTypeSym, node.op.name(), expr.node);
                    const func_sym = try requireFuncSym(c, sym, expr.node);
                    return c.semaCallFuncSym1(func_sym, node.child, child, expr.getRetCstr(), expr.node);
                }
            },
            else => return c.reportErrorFmt("Unsupported unary op: {}", &.{v(node.op)}, expr.node),
        }
    }

    pub fn semaBinExpr(c: *cy.Chunk, expr: Expr, leftId: *ast.Node, op: cy.BinaryExprOp, rightId: *ast.Node) !ExprResult {
        const node = expr.node;

        switch (op) {
            .and_op,
            .or_op => {
                const loc = try c.ir.pushEmptyExpr(.preBinOp, c.alloc, ir.ExprType.init(bt.Boolean), node);
                const left = try c.semaExprCstr(leftId, bt.Boolean);
                const right = try c.semaExprCstr(rightId, bt.Boolean);
                c.ir.setExprData(loc, .preBinOp, .{ .binOp = .{
                    .leftT = left.type.id,
                    .rightT = right.type.id,
                    .op = op,
                    .left = left.irIdx,
                    .right = right.irIdx,
                }});

                const dynamic = right.type.dynamic or left.type.dynamic;
                return ExprResult.init(loc, CompactType.init2(bt.Boolean, dynamic));
            },
            .bitwiseAnd,
            .bitwiseOr,
            .bitwiseXor,
            .bitwiseLeftShift,
            .bitwiseRightShift => {
                const left = try c.semaExprHint(leftId, expr.target_t);

                if (left.type.isDynAny()) {
                    const right = try c.semaExprTarget(rightId, bt.Dyn);
                    return c.semaCallObjSym2(left.irIdx, getBinOpName(op), &.{right}, node);
                }

                // Look for sym under left type's module.
                const leftTypeSym = c.sema.getTypeSym(left.type.id);
                const sym = try c.mustFindSym(leftTypeSym, op.name(), node);
                const funcSym = try requireFuncSym(c, sym, node);
                return c.semaCallFuncSymRec(funcSym, leftId, left, &.{ rightId }, expr.getRetCstr(), node);
            },
            .greater,
            .greater_equal,
            .less,
            .less_equal => {
                const left = try c.semaExprHint(leftId, expr.target_t);

                if (left.type.isDynAny()) {
                    const right = try c.semaExprTarget(rightId, bt.Dyn);
                    return c.semaCallObjSym2(left.irIdx, getBinOpName(op), &.{right}, node);
                }

                const leftTypeSym = c.sema.getTypeSym(left.type.id);
                const sym = try c.mustFindSym(leftTypeSym, op.name(), node);
                const func_sym = try requireFuncSym(c, sym, node);
                return c.semaCallFuncSymRec(func_sym, leftId, left, 
                    &.{ rightId }, expr.getRetCstr(), node);
            },
            .star,
            .slash,
            .percent,
            .caret,
            .plus,
            .minus => {
                const left = try c.semaExprHint(leftId, expr.target_t);

                if (left.type.isDynAny()) {
                    const right = try c.semaExprTarget(rightId, bt.Dyn);
                    return c.semaCallObjSym2(left.irIdx, getBinOpName(op), &.{right}, node);
                }

                // Look for sym under left type's module.
                const leftTypeSym = c.sema.getTypeSym(left.type.id);
                const sym = try c.mustFindSym(leftTypeSym, op.name(), node);
                const func_sym = try requireFuncSym(c, sym, node);
                return c.semaCallFuncSymRec(func_sym, leftId, left, 
                    &.{ rightId }, expr.getRetCstr(), node);
            },
            .bang_equal,
            .equal_equal => {
                const loc = try c.ir.pushEmptyExpr(.pre, c.alloc, undefined, node);

                const left = try c.semaExpr(leftId, .{});
                const right = try c.semaExprTarget(rightId, left.type.id);

                if (left.type.id == right.type.id) {
                    const left_te = c.sema.types.items[left.type.id];
                    switch (left_te.kind) {
                        .option,
                        .choice,
                        .struct_t => {
                            return semaStructCompare(c, left, leftId, op, right, rightId, left.type.id, node);
                        },
                        else => {},
                    }
                }

                c.ir.setExprCode(loc, .preBinOp);
                c.ir.setExprType(loc, bt.Boolean);
                c.ir.setExprData(loc, .preBinOp, .{ .binOp = .{
                    .leftT = left.type.id,
                    .rightT = right.type.id,
                    .op = op,
                    .left = left.irIdx,
                    .right = right.irIdx,
                }});
                return ExprResult.initStatic(loc, bt.Boolean);
            },
            else => return c.reportErrorFmt("Unsupported binary op: {}", &.{v(op)}, node),
        }
    }

    pub fn semaAccessExpr(c: *cy.Chunk, expr: Expr, prefer_ct_sym: bool) !ExprResult {
        const node = expr.node.cast(.accessExpr);

        if (node.right.type() != .ident) {
            return error.Unexpected;
        }

        const rec = try c.semaExprSkipSym(Expr.init(node.left), true);
        if (rec.resType == .sym) {
            const sym = rec.data.sym;
            const rightName = c.ast.nodeString(node.right);
            const rightSym = try c.getResolvedDistinctSym(sym, rightName, node.right, true);
            try referenceSym(c, rightSym, node.right);

            if (prefer_ct_sym) {
                var typeId: CompactType = undefined;
                if (rightSym.isType()) {
                    typeId = CompactType.init(rightSym.getStaticType().?);
                } else {
                    typeId = CompactType.init((try c.getSymValueType(rightSym)) orelse bt.Void);
                }
                return ExprResult.initCustom(cy.NullId, .sym, typeId, .{ .sym = rightSym });
            } else {
                return try sema.symbol(c, rightSym, Expr.init(node.right), false);
            }
        } else {
            return semaAccessField(c, rec, node.right);
        }
    }
};

fn semaWithInitPairs(c: *cy.Chunk, type_sym: *cy.Sym, type_id: cy.TypeId, init_n: *ast.InitLit, init: u32) !ExprResult {
    const node: *ast.Node = @ptrCast(init_n);
    if (init_n.args.len == 0) {
        // Just return default initializer for no record pairs.
        return ExprResult.init(init, CompactType.initStatic(type_id));
    }
    const init_pair = type_sym.getMod().?.getSym("$initPair").?;

    const expr = try c.ir.pushExpr(.blockExpr, c.alloc, type_id, node, .{ .bodyHead = cy.NullId });
    try pushBlock(c, node);
    {
        // create temp with object.
        const var_id = try declareLocalName(c, "$temp", type_id, true, true, node);
        const temp_ir_id = c.varStack.items[var_id].inner.local.id;
        const temp_ir = c.varStack.items[var_id].inner.local.declIrStart;
        const decl_stmt = c.ir.getStmtDataPtr(temp_ir, .declareLocalInit);
        decl_stmt.init = init;
        decl_stmt.initType = CompactType.initStatic(type_id);

        // call $initPair for each record pair.
        const temp_loc = try c.ir.pushExpr(.local, c.alloc, type_id, node, .{ .id = temp_ir_id });
        const temp_expr = ExprResult.init(temp_loc, CompactType.initStatic(type_id));

        for (init_n.args) |arg| {
            if (arg.type() != .keyValue) {
                return c.reportError("Expected key value pair.", arg);
            }
            const pair = arg.cast(.keyValue);
            const key_name = c.ast.nodeString(pair.key);
            const key_expr = try c.semaString(key_name, pair.key);

            const arg_start = c.arg_stack.items.len;
            defer c.arg_stack.items.len = arg_start;
            try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(node, temp_expr));
            try c.arg_stack.append(c.alloc, sema.Argument.initPreResolved(pair.key, key_expr));
            try c.arg_stack.append(c.alloc, sema.Argument.init(pair.value));
            const cstr = sema.CallCstr{ .ret = .any };
            const func_res = try sema.matchFuncSym(c, init_pair.cast(.func), arg_start, 3, cstr, arg);
            const res = try c.semaCallFuncSymResult(init_pair.cast(.func), func_res, cstr.ct_call, node);

            _ = try c.ir.pushStmt(c.alloc, .exprStmt, arg, .{
                .expr = res.irIdx,
                .isBlockResult = false,
            });
        }

        // return temp.
        _ = try c.ir.pushStmt(c.alloc, .exprStmt, node, .{
            .expr = temp_loc,
            .isBlockResult = true,
        });
    }
    const stmtBlock = try popBlock(c);
    c.ir.getExprDataPtr(expr, .blockExpr).bodyHead = stmtBlock.first;
    return ExprResult.initStatic(expr, type_id);
}

fn semaInitChoice(c: *cy.Chunk, member: *cy.sym.EnumMember, payload: ExprResult, node: *ast.Node) !ExprResult {
    var b: ObjectBuilder = .{ .c = c };
    try b.begin(member.type, 2, node);
    const tag = try c.semaInt(member.val, node);
    b.pushArg(tag);
    b.pushArg(payload);
    const irIdx = b.end();
    return ExprResult.initStatic(irIdx, member.type);
}

fn semaInitChoiceNoPayload(c: *cy.Chunk, member: *cy.sym.EnumMember, node: *ast.Node) !ExprResult {
    // No payload type.
    var b: ObjectBuilder = .{ .c = c };
    try b.begin(member.type, 2, node);
    const tag = try c.semaInt(member.val, node);
    b.pushArg(tag);
    const payload = try c.semaZeroInit(bt.Any, node);
    b.pushArg(payload);
    const irIdx = b.end();
    return ExprResult.initStatic(irIdx, member.type);
}

fn semaStructCompare(c: *cy.Chunk, left: ExprResult, left_id: *ast.Node, op: cy.BinaryExprOp,
    right: ExprResult, right_id: *ast.Node, left_t: cy.TypeId, node_id: *ast.Node) !ExprResult {

    // Struct memberwise comparison.
    const left_te = c.sema.types.items[left_t];
    const fields = left_te.sym.getFields().?;

    var field_t = c.sema.getTypeSym(fields[0].type);
    var field_te = c.sema.getType(fields[0].type);
    var it: u32 = undefined;
    if (field_te.kind == .struct_t) {
        return error.Unsupported;
    } else {
        const left_f = try semaField(c, left, 0, fields[0].type, left_id);
        const right_f = try semaField(c, right, 0, fields[0].type, right_id);
        it = try c.ir.pushExpr(.preBinOp, c.alloc, bt.Boolean, node_id, .{ .binOp = .{
            .leftT = fields[0].type,
            .rightT = fields[0].type,
            .op = op,
            .left = left_f.irIdx,
            .right = right_f.irIdx,
        }});
    }
    if (fields.len > 1) {
        for (fields[1..], 1..) |field, fidx| {
            field_t = c.sema.getTypeSym(fields[0].type);
            field_te = c.sema.getType(fields[0].type);
            if (field_te.kind == .struct_t) {
                return error.Unsupported;
            }
            const left_f = try semaField(c, left, fidx, field.type, left_id);
            const right_f = try semaField(c, right, fidx, field.type, right_id);
            const compare = try c.ir.pushExpr(.preBinOp, c.alloc, bt.Boolean, node_id, .{ .binOp = .{
                .leftT = field.type,
                .rightT = field.type,
                .op = op,
                .left = left_f.irIdx,
                .right = right_f.irIdx,
            }});
            const logic_op: cy.BinaryExprOp = if (op == .equal_equal) .and_op else .or_op;
            it = try c.ir.pushExpr(.preBinOp, c.alloc, bt.Boolean, node_id, .{ .binOp = .{
                .leftT = bt.Boolean,
                .rightT = bt.Boolean,
                .op = logic_op,
                .left = it,
                .right = compare,
            }});
        }
    }
    const dynamic = right.type.dynamic or left.type.dynamic;
    return ExprResult.init(it, CompactType.init2(bt.Boolean, dynamic));
}

const VarResult = struct {
    id: LocalVarId,
    fromParentBlock: bool,
};

fn assignToLocalVar(c: *cy.Chunk, localRes: ExprResult, rhs: *ast.Node, opts: AssignOptions) !ExprResult {
    const id = localRes.data.local;
    var svar = &c.varStack.items[id];

    var rightExpr: Expr = undefined;
    if (svar.declT == bt.Dyn) {
        rightExpr = Expr{
            .target_t = svar.vtype.id,
            .node = rhs,
            .reqTypeCstr = false,
            .fit_target = true,
            .fit_target_unbox_dyn = false,
        };
    } else {
        rightExpr = Expr.initRequire(rhs, svar.declT);
    }
    var right = try c.semaExprOrOpAssignBinExpr(rightExpr, opts.rhsOpAssignBinExpr);
    if (svar.declT == bt.Dyn and c.sema.isUnboxedType(right.type.id)) {
        // Ensure boxed even when using a non boxed target.
        const loc = try c.ir.pushExpr(.box, c.alloc, bt.Any, rhs, .{
            .expr = right.irIdx,
        });
        right.irIdx = loc;
    }

    // Refresh pointer after rhs.
    svar = &c.varStack.items[id];

    if (svar.inner.local.isParam) {
        if (!svar.inner.local.isParamCopied) {
            svar.inner.local.isParamCopied = true;
        }
    }

    const b = c.block();
    if (!b.prevVarTypes.contains(id)) {
        // Same variable but branched to sub block.
        try b.prevVarTypes.put(c.alloc, id, svar.vtype);
    }

    if (svar.isDynamic()) {
        svar.dynamicLastMutBlockId = @intCast(c.semaBlocks.items.len-1);

        // Update recent static type after checking for branched assignment.
        if (svar.vtype.id != right.type.id) {
            svar.vtype.id = right.type.id;
        }
    }

    try c.assignedVarStack.append(c.alloc, id);
    return right;
}

fn popLambdaProc(c: *cy.Chunk, ct: bool) !cy.TypeId {
    const proc = c.proc();
    const params = c.getProcParams(proc);

    const captures = try proc.captures.toOwnedSlice(c.alloc);
    const stmtBlock = try popProc(c);

    var numParamCopies: u8 = 0;

    const params_loc = try c.ir.pushEmptyArray(c.alloc, ir.FuncParam, params.len);
    const paramData = c.ir.getArray(params_loc, ir.FuncParam, params.len);
    for (params, 0..) |param, i| {
        paramData[i] = .{
            .namePtr = param.namePtr,
            .nameLen = param.nameLen,
            .declType = param.declT,
            .isCopy = param.inner.local.isParamCopied,
            .lifted = param.inner.local.lifted,
        };
        if (param.inner.local.isParamCopied) {
            numParamCopies += 1;
        }
    }

    var irCapturesIdx: u32 = cy.NullId;
    var type_id: cy.TypeId = undefined;
    if (captures.len > 0) {
        irCapturesIdx = try c.ir.pushEmptyArray(c.alloc, u8, captures.len);
        for (captures, 0..) |varId, i| {
            const pId = c.capVarDescs.get(varId).?.user;
            const pvar = c.varStack.items[pId];
            c.ir.setArrayItem(irCapturesIdx, u8, i, pvar.inner.local.id);
        }
        c.alloc.free(captures);
        if (ct) {
            return c.reportError("A closure can not be a function symbol.", proc.node);
        } else {
            type_id = try getFuncUnionType(c, proc.func.?.funcSigId);
        }
    } else {
        if (ct) {
            type_id = try getFuncSymType(c, proc.func.?.funcSigId);
        } else {
            type_id = try getFuncPtrType(c, proc.func.?.funcSigId);
        }
    }
    c.ir.setExprType(proc.irStart, type_id);

    // Patch `pushFuncBlock` with maxLocals and param copies.
    c.ir.setExprData(proc.irStart, .lambda, .{
        .func = proc.func.?,
        .numCaptures = @as(u8, @intCast(captures.len)),
        .maxLocals = proc.maxLocals,
        .numParamCopies = numParamCopies,
        .bodyHead = stmtBlock.first,
        .captures = irCapturesIdx,
        .params = params_loc,
        .ct = ct,
    });
    return type_id;
}

pub fn popFuncBlock(c: *cy.Chunk) !void {
    const proc = c.proc();
    const params = c.getProcParams(proc);

    const stmtBlock = try popProc(c);

    var numParamCopies: u8 = 0;
    const params_loc = try c.ir.pushEmptyArray(c.alloc, ir.FuncParam, params.len);
    const paramData = c.ir.getArray(params_loc, ir.FuncParam, params.len);
    for (params, 0..) |param, i| {
        paramData[i] = .{
            .namePtr = param.namePtr,
            .nameLen = param.nameLen,
            .declType = param.declT,
            .isCopy = param.inner.local.isParamCopied,
            .lifted = param.inner.local.lifted,
        };
        if (param.inner.local.isParamCopied) {
            numParamCopies += 1;
        }
    }

    const func = proc.func.?;
    const parentType = if (func.isMethod()) params[0].declT else cy.NullId;

    // Patch `pushFuncBlock` with maxLocals and param copies.
    c.ir.setStmtData(proc.irStart, .funcBlock, .{
        .maxLocals = proc.maxLocals,
        .numParamCopies = numParamCopies,
        .func = proc.func.?,
        .bodyHead = stmtBlock.first,
        .parentType = parentType,
        .params = params_loc,
    });
}

pub const FuncParam = packed struct {
    type: u32,

    pub fn init(type_id: cy.TypeId) FuncParam {
        return .{ .type = @intCast(type_id) };
    }
};

pub const FuncSigId = u32;

/// Turning this into to packed struct fails web-lib ReleaseFast strip=true,
/// however, it seems an inner packed struct `info` works.
pub const FuncSig = struct {
    /// Last elem is the return type sym.
    params_ptr: [*]const FuncParam,
    ret: cy.TypeId,
    params_len: u16,

    /// If a param or the return type is not the any type.
    // isTyped: bool,

    /// If a param is not the any type.
    // isParamsTyped: bool,

    info: packed struct {
        /// Requires type checking if any param is not `dynamic` or `any`.
        reqCallTypeCheck: bool,

        /// Contains a param or return type that is dependent on a compile-time param.
        ct_dep: bool,
    },

    pub inline fn params(self: FuncSig) []const FuncParam {
        return self.params_ptr[0..self.params_len];
    }

    pub inline fn numParams(self: FuncSig) u8 {
        return @intCast(self.params_len);
    }

    pub inline fn getRetType(self: FuncSig) cy.TypeId {
        return self.ret;
    }

    pub fn deinit(self: *FuncSig, alloc: std.mem.Allocator) void {
        alloc.free(self.params());
    }
};

const FuncSigKey = struct {
    params_ptr: [*]const FuncParam,
    params_len: u32,
    ret: TypeId,
};

const BuiltinSymType = enum(u8) {
    bool_t,
    int_t,
    float_t,
};

pub const Sema = struct {
    alloc: std.mem.Allocator,
    compiler: *cy.Compiler,

    types: std.ArrayListUnmanaged(cy.types.Type),

    /// Maps index to the ct_ref type.
    ct_ref_types: std.AutoHashMapUnmanaged(u32, cy.TypeId),

    /// Resolved signatures for functions.
    funcSigs: std.ArrayListUnmanaged(FuncSig),
    funcSigMap: std.HashMapUnmanaged(FuncSigKey, FuncSigId, FuncSigKeyContext, 80),

    // Not all functions need a pointer type so this is lazily generated.
    // Retrieved with `getFuncPtrType`.
    func_ptr_types: std.AutoHashMapUnmanaged(FuncSigId, cy.TypeId),

    future_tmpl: *cy.sym.Template,
    ref_slice_tmpl: *cy.sym.Template,
    ptr_slice_tmpl: *cy.sym.Template,
    option_tmpl: *cy.sym.Template,
    pointer_tmpl: *cy.sym.Template,
    ref_tmpl: *cy.sym.Template,
    list_tmpl: *cy.sym.Template,
    table_type: *cy.sym.ObjectType,
    array_tmpl: *cy.sym.Template,
    func_ptr_tmpl: *cy.sym.Template,
    func_union_tmpl: *cy.sym.Template,
    func_sym_tmpl: *cy.sym.Template,

    pub fn init(alloc: std.mem.Allocator, compiler: *cy.Compiler) !Sema {
        var new = Sema{
            .alloc = alloc,
            .compiler = compiler,
            .future_tmpl = undefined,
            .ref_slice_tmpl = undefined,
            .ptr_slice_tmpl = undefined,
            .option_tmpl = undefined,
            .pointer_tmpl = undefined,
            .ref_tmpl = undefined,
            .list_tmpl = undefined,
            .table_type = undefined,
            .array_tmpl = undefined,
            .func_ptr_tmpl = undefined,
            .func_union_tmpl = undefined,
            .func_sym_tmpl = undefined,
            .funcSigs = .{},
            .funcSigMap = .{},
            .func_ptr_types = .{},
            .types = .{},
            .ct_ref_types = .{},
        };
        // Reserve the null type.
        _ = try new.pushType();
        return new;
    }

    pub fn deinit(self: *Sema, alloc: std.mem.Allocator, comptime reset: bool) void {
        for (self.funcSigs.items) |*it| {
            it.deinit(alloc);
        }
        var iter = self.ct_ref_types.iterator();
        while (iter.next()) |e| {
            const sym = self.types.items[e.value_ptr.*].sym.cast(.dummy_t);
            alloc.destroy(sym);
        }

        for (self.types.items) |type_e| {
            if (type_e.kind == .object) {
                if (type_e.data.object.has_boxed_fields) {
                    alloc.free(type_e.data.object.fields[0..type_e.data.object.numFields]);
                }
            } else if (type_e.kind == .struct_t) {
                if (type_e.data.struct_t.has_boxed_fields) {
                    alloc.free(type_e.data.struct_t.fields[0..type_e.data.struct_t.nfields]);
                }
            }
        }
        if (reset) {
            self.ct_ref_types.clearRetainingCapacity();
            self.types.items.len = 1;
            self.funcSigs.clearRetainingCapacity();
            self.funcSigMap.clearRetainingCapacity();
            self.func_ptr_types.clearRetainingCapacity();
        } else {
            self.ct_ref_types.deinit(alloc);
            self.types.deinit(alloc);
            self.funcSigs.deinit(alloc);
            self.funcSigMap.deinit(alloc);
            self.func_ptr_types.deinit(alloc);
        }
    }

    pub fn ensureCtRefType(s: *Sema, ct_param_idx: u32) !cy.TypeId {
        const res = try s.ct_ref_types.getOrPut(s.alloc, ct_param_idx);
        if (!res.found_existing) {
            const new_t = try s.pushType();
            s.types.items[new_t].kind = .ct_ref;
            const sym = try s.alloc.create(cy.sym.DummyType);
            sym.* = .{
                .head = cy.Sym.init(.dummy_t, null, "ct-ref"),
                .type = new_t,
            };
            s.types.items[new_t].sym = @ptrCast(sym);
            s.types.items[new_t].info.ct_ref = true;
            s.types.items[new_t].data = .{ .ct_ref = .{ .ct_param_idx = ct_param_idx }};

            res.value_ptr.* = new_t;
        }
        return res.value_ptr.*;
    } 

    pub fn ensureUntypedFuncSig(s: *Sema, numParams: u32) !FuncSigId {
        const buf = std.mem.bytesAsSlice(FuncParam, &cy.tempBuf);
        if (buf.len < numParams) return error.TooBig;
        @memset(buf[0..numParams], FuncParam.init(bt.Dyn));
        return try s.ensureFuncSig(buf[0..numParams], bt.Dyn);
    }

    pub fn ensureFuncSigRt(s: *Sema, params: []const cy.TypeId, ret: TypeId) !FuncSigId {
        return ensureFuncSig(s, @ptrCast(params), ret);
    }

    pub fn ensureFuncSig(s: *Sema, params: []const FuncParam, ret: TypeId) !FuncSigId {
        const res = try s.funcSigMap.getOrPut(s.alloc, .{
            .params_ptr = params.ptr,
            .params_len = @intCast(params.len),
            .ret = ret,
        });
        if (res.found_existing) {
            return res.value_ptr.*;
        } else {
            const id: u32 = @intCast(s.funcSigs.items.len);
            const new = try s.alloc.dupe(FuncParam, params);
            var reqCallTypeCheck = false;
            var ct_dep = false;
            for (params) |param| {
                const param_te = s.getType(param.type);
                ct_dep = ct_dep or param_te.info.ct_ref;
                if (!reqCallTypeCheck and param.type != bt.Dyn and param.type != bt.Any) {
                    reqCallTypeCheck = true;
                }
            }
            try s.funcSigs.append(s.alloc, .{
                .params_ptr = new.ptr,
                .params_len = @intCast(new.len),
                .ret = ret,
                .info = .{
                    .reqCallTypeCheck = reqCallTypeCheck,
                    .ct_dep = ct_dep,
                },
            });
            res.value_ptr.* = id;
            res.key_ptr.* = .{
                .params_ptr = new.ptr,
                .params_len = @intCast(new.len),
                .ret = ret,
            };
            return id;
        }
    }

    pub fn formatFuncSig(s: *Sema, funcSigId: FuncSigId, buf: []u8, from: ?*cy.Chunk) ![]const u8 {
        var fbuf = std.io.fixedBufferStream(buf);
        try s.writeFuncSigStr(fbuf.writer(), funcSigId, from);
        return fbuf.getWritten();
    }

    pub fn allocArgsStr(s: *Sema, args: []const CompactType, comptime showRecentType: bool) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(s.alloc);

        const w = buf.writer(s.alloc);
        try w.writeAll("(");

        if (args.len > 0) {
            try s.writeCompactType(w, args[0], showRecentType);

            if (args.len > 1) {
                for (args[1..]) |arg| {
                    try w.writeAll(", ");
                    try s.writeCompactType(w, arg, showRecentType);
                }
            }
        }
        try w.writeAll(")");
        return buf.toOwnedSlice(s.alloc);
    }

    /// Format: (Type, ...) RetType
    pub fn getFuncSigTempStr(s: *Sema, buf: *std.ArrayListUnmanaged(u8), funcSigId: FuncSigId) ![]const u8 {
        buf.clearRetainingCapacity();
        const w = buf.writer(s.alloc);
        try writeFuncSigStr(s, w, funcSigId);
        return buf.items;
    }

    pub fn allocTypesStr(s: *Sema, types: []const cy.TypeId, from: ?*cy.Chunk) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(s.alloc);

        const w = buf.writer(s.alloc);
        if (types.len > 0) {
            try s.writeTypeName(w, types[0], from);

            if (types.len > 1) {
                for (types[1..]) |type_id| {
                    try w.writeAll(", ");
                    try s.writeTypeName(w, type_id, from);
                }
            }
        }
        return buf.toOwnedSlice(s.alloc);
    }

    pub fn allocFuncSigTypesStr(s: *Sema, params: []const FuncParam, ret: TypeId, from: ?*cy.Chunk) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(s.alloc);

        const w = buf.writer(s.alloc);
        try writeFuncSigTypesStr(s, w, params, ret, from);
        return buf.toOwnedSlice(s.alloc);
    }

    pub fn allocFuncParamsStr(s: *Sema, params: []const FuncParam, from: ?*cy.Chunk) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(s.alloc);

        const w = buf.writer(s.alloc);
        try writeFuncParams(s, w, params, from);
        return buf.toOwnedSlice(s.alloc);
    }

    pub fn allocFuncSigStr(s: *Sema, funcSigId: FuncSigId, show_ret: bool, from: ?*cy.Chunk) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(s.alloc);

        const w = buf.writer(s.alloc);
        const funcSig = s.funcSigs.items[funcSigId];
        try w.writeAll("(");
        try writeFuncParams(s, w, funcSig.params(), from);
        try w.writeAll(")");
        if (show_ret) {
            try w.writeAll(" ");
            try s.writeTypeName(w, funcSig.ret, from);
        }
        return buf.toOwnedSlice(s.alloc);
    }

    pub fn writeFuncSigStr(s: *Sema, w: anytype, funcSigId: FuncSigId, from: ?*cy.Chunk) !void {
        const funcSig = s.funcSigs.items[funcSigId];
        try writeFuncSigTypesStr(s, w, funcSig.params(), funcSig.ret, from);
    }

    pub fn writeFuncSigTypesStr(s: *Sema, w: anytype, params: []const FuncParam, ret: TypeId, from: ?*cy.Chunk) !void {
        try w.writeAll("(");
        try writeFuncParams(s, w, params, from);
        try w.writeAll(") ");
        try s.writeTypeName(w, ret, from);
    }

    pub fn writeFuncParams(s: *Sema, w: anytype, params: []const FuncParam, from: ?*cy.Chunk) !void {
        if (params.len > 0) {
            try s.writeTypeName(w, params[0].type, from);

            if (params.len > 1) {
                for (params[1..]) |paramT| {
                    try w.writeAll(", ");
                    try s.writeTypeName(w, paramT.type, from);
                }
            }
        }
    }

    pub inline fn getFuncSig(self: *Sema, id: FuncSigId) FuncSig {
        return self.funcSigs.items[id];
    }

    pub usingnamespace cy.types.SemaExt;
};

pub const FuncSigKeyContext = struct {
    pub fn hash(_: @This(), key: FuncSigKey) u64 {
        var c = std.hash.Wyhash.init(0);
        const bytes: [*]const u8 = @ptrCast(key.params_ptr);
        c.update(bytes[0..key.params_len*4]);
        c.update(std.mem.asBytes(&key.ret));
        return c.final();
    }
    pub fn eql(_: @This(), a: FuncSigKey, b: FuncSigKey) bool {
        return std.mem.eql(u32, @ptrCast(a.params_ptr[0..a.params_len]), @ptrCast(b.params_ptr[0..b.params_len])) and a.ret == b.ret;
    }
};

pub const U32SliceContext = struct {
    pub fn hash(_: @This(), key: []const u32) u64 {
        var c = std.hash.Wyhash.init(0);
        const bytes: [*]const u8 = @ptrCast(key.ptr);
        c.update(bytes[0..key.len*4]);
        return c.final();
    }
    pub fn eql(_: @This(), a: []const u32, b: []const u32) bool {
        return std.mem.eql(u32, a, b);
    }
};

/// `buf` is assumed to be big enough.
pub fn unescapeString(buf: []u8, literal: []const u8, always_copy: bool) ![]const u8 {
    var i = std.mem.indexOfScalar(u8, literal, '\\') orelse {
        if (always_copy) {
            @memcpy(buf[0..literal.len], literal);
            return buf[0..literal.len];
        } else {
            return literal;
        }
    };
    @memcpy(buf[0..i], literal[0..i]);
    var len = i;
    var res = try unescapeSeq(literal[i+1..]);
    buf[len] = res.char;
    len += 1;
    var rest = literal[i+1+res.advance..];

    while (true) {
        i = std.mem.indexOfScalar(u8, rest, '\\') orelse break;
        @memcpy(buf[len..len+i], rest[0..i]);
        len += i;
        res = try unescapeSeq(rest[i+1..]);
        buf[len] = res.char;
        len += 1;
        rest = rest[i+1+res.advance..];
    }

    @memcpy(buf[len..len+rest.len], rest);
    return buf[0..len+rest.len];
}

const CharAdvance = struct {
    char: u8,
    advance: u8,

    fn init(char: u8, advance: u8) CharAdvance {
        return CharAdvance{ .char = char, .advance = advance };
    }
};

pub fn unescapeSeq(seq: []const u8) !CharAdvance {
    if (seq.len == 0) {
        return error.MissingEscapeSeq;
    }
    switch (seq[0]) {
        'a' => {
            return CharAdvance.init(0x07, 1);
        },
        'b' => {
            return CharAdvance.init(0x08, 1);
        },
        'e' => {
            return CharAdvance.init(0x1b, 1);
        },
        'n' => {
            return CharAdvance.init('\n', 1);
        },
        'r' => {
            return CharAdvance.init('\r', 1);
        },
        't' => {
            return CharAdvance.init('\t', 1);
        },
        '\\' => {
            return CharAdvance.init('\\', 1);
        },
        '"' => {
            return CharAdvance.init('"', 1);
        },
        '0' => {
            return CharAdvance.init('"', 1);
        },
        'x' => {
            if (seq.len < 3) {
                return error.InvalidEscapeSeq;
            }
            const ch = try std.fmt.parseInt(u8, seq[1..3], 16);
            return CharAdvance.init(ch, 3);
        },
        else => {
            return error.InvalidEscapeSeq;
        }
    }
}

test "sema internals." {
    if (builtin.mode == .ReleaseFast) {
        if (cy.is32Bit) {
            try t.eq(@sizeOf(LocalVar), 32);
        } else {
            try t.eq(@sizeOf(LocalVar), 40);
        }
    } else {
        if (cy.is32Bit) {
            try t.eq(@sizeOf(LocalVar), 36);
        } else {
            try t.eq(@sizeOf(LocalVar), 40);
        }
    }

    if (cy.is32Bit) {
        try t.eq(@sizeOf(FuncSig), 12);
    } else {
        try t.eq(@sizeOf(FuncSig), 16);
    }

    try t.eq(@sizeOf(CapVarDesc), 4);
}

pub const ObjectBuilder = struct {
    irIdx: u32 = undefined,
    irArgsIdx: u32 = undefined,

    /// Generic typeId so choice types can also be instantiated.
    typeId: cy.TypeId = undefined,

    c: *cy.Chunk,
    argIdx: u32 = undefined,

    pub fn begin(b: *ObjectBuilder, typeId: cy.TypeId, numFields: u8, node: *ast.Node) !void {
        b.typeId = typeId;
        b.irArgsIdx = try b.c.ir.pushEmptyArray(b.c.alloc, u32, numFields);
        b.irIdx = try b.c.ir.pushExpr(.object_init, b.c.alloc, typeId, node, .{
            .typeId = typeId, .numArgs = @as(u8, @intCast(numFields)), .args = b.irArgsIdx,
        });
        b.argIdx = 0;
    }

    pub fn pushArg(b: *ObjectBuilder, expr: ExprResult) void {
        b.c.ir.setArrayItem(b.irArgsIdx, u32, b.argIdx, expr.irIdx);
        b.argIdx += 1;
    }

    pub fn end(b: *ObjectBuilder) u32 {
        return b.irIdx;
    }
};

fn getUnOpName(op: cy.UnaryOp) []const u8 {
    return switch (op) {
        .minus => "$prefix-",
        .bitwiseNot => "$prefix~",
        else => @panic("unsupported"),
    };
}

fn getBinOpName(op: cy.BinaryExprOp) []const u8 {
    return switch (op) {
        .index => "$index",
        .less => "$infix<",
        .greater => "$infix>",
        .less_equal => "$infix<=",
        .greater_equal => "$infix>=",
        .minus => "$infix-",
        .plus => "$infix+",
        .star => "$infix*",
        .slash => "$infix/",
        .percent => "$infix%",
        .caret => "$infix^",
        .bitwiseAnd => "$infix&",
        .bitwiseOr => "$infix|",
        .bitwiseXor => "$infix||",
        .bitwiseLeftShift => "$infix<<",
        .bitwiseRightShift => "$infix>>",
        else => @panic("unsupported"),
    };
}

/// TODO: Cache this by `elem_t`.
pub fn getPointerType(c: *cy.Chunk, elem_t: cy.TypeId) !cy.TypeId {
    const arg = try c.vm.allocType(elem_t);
    defer c.vm.release(arg);
    const sym = try cte.expandTemplate(c, c.sema.pointer_tmpl, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getPtrSliceType(c: *cy.Chunk, elem_t: cy.TypeId) !cy.TypeId {
    const arg = try c.vm.allocType(elem_t);
    defer c.vm.release(arg);
    const sym = try cte.expandTemplate(c, c.sema.ptr_slice_tmpl, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getRefType(c: *cy.Chunk, elem_t: cy.TypeId) !cy.TypeId {
    const arg = try c.vm.allocType(elem_t);
    defer c.vm.release(arg);
    const sym = try cte.expandTemplate(c, c.sema.ref_tmpl, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getRefSliceType(c: *cy.Chunk, elem_t: cy.TypeId) !cy.TypeId {
    const arg = try c.vm.allocType(elem_t);
    defer c.vm.release(arg);
    const sym = try cte.expandTemplate(c, c.sema.ref_slice_tmpl, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getFuncPtrType(c: *cy.Chunk, sig: FuncSigId) !cy.TypeId {
    const res = try c.sema.func_ptr_types.getOrPut(c.alloc, sig);
    if (res.found_existing) {
        return res.value_ptr.*;
    }

    const arg = try c.vm.allocFuncSig(@intCast(sig));
    defer c.vm.release(arg);
    const sym = try cy.cte.expandTemplate(c, c.sema.func_ptr_tmpl, &.{ arg });
    const type_id = sym.getStaticType().?;
    res.value_ptr.* = type_id;
    return type_id;
}

pub fn getFuncUnionType(c: *cy.Chunk, sig: FuncSigId) !cy.TypeId {
    const arg = try c.vm.allocFuncSig(sig);
    defer c.vm.release(arg);
    const sym = try cte.expandTemplate(c, c.sema.func_union_tmpl, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getFuncSymType(c: *cy.Chunk, sig: FuncSigId) !cy.TypeId {
    const arg = try c.vm.allocFuncSig(sig);
    defer c.vm.release(arg);
    const sym = try cte.expandTemplate(c, c.sema.func_sym_tmpl, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getArrayType(c: *cy.Chunk, n: u64, elem_t: cy.TypeId) !cy.TypeId {
    const n_arg = try c.vm.allocInt(@bitCast(n));
    defer c.vm.release(n_arg);
    const elem_arg = try c.vm.allocType(elem_t);
    defer c.vm.release(elem_arg);
    const sym = try cte.expandTemplate(c, c.sema.array_tmpl, &.{ n_arg, elem_arg });
    return sym.getStaticType().?;
}
