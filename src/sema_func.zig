const std = @import("std");
const cy = @import("cyber.zig");
const bt = cy.types.BuiltinTypes;
const ast = cy.ast;
const sema = cy.sema;
const cte = cy.cte;
const log = cy.log.scoped(.sema_func);
const fmt = cy.fmt;
const v = fmt.v;

pub const FuncSymResult = struct {
    dyn_call: bool,
    func: *cy.Func,
    data: FuncResultUnion,
};

const FuncResultUnion = union {
    rt: struct {
        args_loc: u32,
        nargs: u32,
    },
    ct: cte.CtValue,
};

pub const FuncResult = struct {
    func: *cy.Func,
    data: FuncResultUnion,
};

const ArgType = enum {
    standard,
    pre_resolved,
    skip,
};

const ResolvedArgType = enum {
    null,
    rt,
    template,
    ct,
    incompat,
};

pub const Argument = struct {
    type: ArgType,

    /// This is wasteful since only pre_resolved uses `data`.
    /// The resolved arg result is stored together to avoid building two lists.
    data: union {
        pre_resolved: sema.ExprResult,
    },
    resolve_t: ResolvedArgType,
    res: union {
        rt: sema.ExprResult,
        ct: cte.CtValue,
        template: cte.CtValue,
        incompat: struct {
            target_t: cy.TypeId,
            res_t: cy.TypeId,
        },
    },
    node: *ast.Node,

    pub fn init(node: *ast.Node) Argument {
        return .{ .type = .standard, .data = undefined, .resolve_t = .null, .res = undefined, .node = node };
    }

    pub fn initSkip() Argument {
        return .{ .type = .skip, .data = undefined, .resolve_t = .null, .res = undefined, .node = undefined };
    }

    pub fn initPreResolved(node: *ast.Node, res: sema.ExprResult) Argument {
        return .{
            .type = .pre_resolved,
            .data = .{ .pre_resolved = res },
            .resolve_t = .null,
            .res = undefined,
            .node = node,
        };
    }
};

pub fn matchFuncTemplate(c: *cy.Chunk, template: *cy.sym.FuncTemplate,
    arg_start: usize, nargs: usize, cstr: CallCstr, node: *ast.Node) !FuncResult {

    if (template.func_params.len != nargs) {
        return c.reportErrorFmt("Expected {} arguments. Found {}.", &.{v(template.func_params.len), v(nargs)}, node);
    }

    // Prepare template context.
    const src_chunk = template.chunk();
    try sema.pushResolveContext(src_chunk);
    var template_ctx = sema.saveResolveContext(src_chunk);
    template_ctx.has_ct_params = true;
    defer template_ctx.deinit(src_chunk);

    const loc = try c.ir.pushEmptyArray(c.alloc, u32, nargs);

    // Record resolved func parameter types, for error
    const type_start = c.typeStack.items.len;
    defer c.typeStack.items.len = type_start;

    // ct/rt args share the same index counter.
    var rt_arg_idx: u32 = 0;

    const ct_arg_start = c.valueStack.items.len;
    if (cstr.ct_call) {
        // First reserve the ct args since the exact amount is known.
        try c.valueStack.resize(c.alloc, ct_arg_start + nargs);
    }
    defer {
        if (cstr.ct_call) {
            for (c.valueStack.items[ct_arg_start..ct_arg_start+rt_arg_idx]) |arg| {
                c.vm.release(arg);
            }
        }
        c.valueStack.items.len = ct_arg_start;
    }

    const config = MatchConfig{
        .template_arg_start = undefined,
        .single_func = true,
        .ct_call = cstr.ct_call,
    };
    for (0..nargs) |i| {
        const arg = c.arg_stack.items[arg_start + i];
        if (arg.type == .skip) {
            rt_arg_idx += 1;
            continue;
        }
        const final_arg = try matchTemplateArg(c, arg, template, src_chunk, &template_ctx, i, config);
        c.arg_stack.items[arg_start + i] = final_arg;

        if (final_arg.resolve_t == .rt) {
            c.ir.setArrayItem(loc, u32, rt_arg_idx, final_arg.res.rt.irIdx);
            rt_arg_idx += 1;
        } else if (final_arg.resolve_t == .ct) {
            c.valueStack.items[ct_arg_start + rt_arg_idx] = final_arg.res.ct.value;
            rt_arg_idx += 1;
        } else if (final_arg.resolve_t == .template) {
            const name = src_chunk.ast.nodeString(template.func_params[i].name_type);
            try template_ctx.setCtParam(c.alloc, name, final_arg.res.template.value);
        } else if (final_arg.resolve_t == .incompat) {
            return error.Unexpected;
        }
    }

    try sema.pushSavedResolveContext(src_chunk, template_ctx);
    const ret_t = try sema.resolveReturnTypeSpecNode(src_chunk, template.func_ret);
    template_ctx = sema.saveResolveContext(src_chunk);

    // Check return type.
    if (!cy.types.isValidReturnType(c.compiler, ret_t, cstr.ret)) {
        const ret_name = try c.sema.allocTypeName(ret_t);
        defer c.alloc.free(ret_name);
        return c.reportErrorFmt("Expected `void` return. Found `{}`.", &.{v(ret_name)}, node);
    }

    // Build template args from context.
    const targ_start = c.valueStack.items.len;
    defer {
        for (c.valueStack.items[targ_start..]) |arg| {
            c.vm.release(arg);
        }
        c.valueStack.items.len = targ_start;
    }
    for (template.params) |tparam| {
        const arg = template_ctx.ct_params.get(tparam.name).?;
        c.vm.retain(arg);
        try c.valueStack.append(c.alloc, arg);
    }
    const targs = c.valueStack.items[targ_start..];

    // Generate function.
    const func = try cte.expandFuncTemplate(c, template, targs);

    if (cstr.ct_call) {
        const ct_args = c.valueStack.items[ct_arg_start..];
        const res = try cte.callFunc(c, func, ct_args);
        return .{
            .func = func,
            .data = .{ .ct = res },
        };
    } else {
        return .{
            .func = func,
            .data = .{ .rt = .{
                .args_loc = loc,
                .nargs = rt_arg_idx,
            }}
        };
    }
}

pub fn matchFunc(c: *cy.Chunk, func: *cy.sym.Func, arg_start: usize, nargs: usize, cstr: CallCstr, node: *ast.Node) !FuncResult {
    const func_sig = c.sema.getFuncSig(func.funcSigId);
    const params = func_sig.params();
    if (params.len != nargs) {
        return reportIncompatCallFunc(c, func, arg_start, cstr.ret, node);
    }

    const loc = try c.ir.pushEmptyArray(c.alloc, u32, nargs);

    // ct/rt args share the same index counter.
    var rt_arg_idx: u32 = 0;

    var ct_arg_start: usize = undefined;
    if (cstr.ct_call) {
        // First reserve the ct args since the exact amount is known.
        ct_arg_start = c.valueStack.items.len;
        try c.valueStack.resize(c.alloc, ct_arg_start + nargs);
    }
    const template_arg_start = c.valueStack.items.len;
    defer {
        if (cstr.ct_call) {
            for (c.valueStack.items[ct_arg_start..ct_arg_start+rt_arg_idx]) |arg| {
                c.vm.release(arg);
            }
            for (c.valueStack.items[template_arg_start..]) |arg| {
                c.vm.release(arg);
            }
            c.valueStack.items.len = ct_arg_start;
        } else {
            for (c.valueStack.items[template_arg_start..]) |arg| {
                c.vm.release(arg);
            }
            c.valueStack.items.len = template_arg_start;
        }
    }

    const config = MatchConfig{
        .template_arg_start = template_arg_start,
        .single_func = true,
        .ct_call = cstr.ct_call,
    };
    for (0..nargs) |i| {
        const arg = c.arg_stack.items[arg_start + i];
        if (arg.type == .skip) {
            rt_arg_idx += 1;
            continue;
        }
        const final_arg = try matchArg(c, arg, params[i], config);
        c.arg_stack.items[arg_start + i] = final_arg;

        if (final_arg.resolve_t == .rt) {
            c.ir.setArrayItem(loc, u32, rt_arg_idx, final_arg.res.rt.irIdx);
            rt_arg_idx += 1;
        } else if (final_arg.resolve_t == .ct) {
            c.valueStack.items[ct_arg_start + rt_arg_idx] = final_arg.res.ct.value;
            rt_arg_idx += 1;
        } else if (final_arg.resolve_t == .incompat) {
            return reportIncompatCallFunc(c, func, arg_start, cstr.ret, arg.node);
        }
    }

    // Check return type.
    if (!cy.types.isValidReturnType(c.compiler, func.retType, cstr.ret)) {
        return reportIncompatCallFunc(c, func, arg_start, cstr.ret, node);
    }

    if (cstr.ct_call) {
        const ct_args = c.valueStack.items[ct_arg_start..];
        const res = try cte.callFunc(c, func, ct_args);
        return .{
            .func = func,
            .data = .{ .ct = res },
        };
    } else {
        return .{
            .func = func,
            .data = .{ .rt = .{
                .args_loc = loc,
                .nargs = rt_arg_idx,
            }}
        };
    }
}

pub const CallCstr = struct {
    ret: cy.types.ReturnCstr,
    ct_call: bool = false,
};

pub fn matchFuncSym(c: *cy.Chunk, func_sym: *cy.sym.FuncSym, arg_start: usize, nargs: usize,
    cstr: CallCstr, node: *ast.Node) !FuncSymResult {

    if (func_sym.numFuncs == 1) {
        const res = try matchFunc(c, func_sym.first, arg_start, nargs, cstr, node);
        return .{
            .dyn_call = false,
            .func = res.func,
            .data = res.data,
        };
    }

    const loc = try c.ir.pushEmptyArray(c.alloc, u32, nargs);

    const template_arg_start = c.valueStack.items.len;
    defer {
        for (c.valueStack.items[template_arg_start..]) |arg| {
            c.vm.release(arg);
        }
        c.valueStack.items.len = template_arg_start;
    }

    var next: ?*cy.Func = func_sym.first;
    while (next) |func| {
        if (try matchOverloadedFunc(c, func, arg_start, nargs, template_arg_start, cstr, loc)) |res| {
            return res;
        }
        next = func.next;
    }

    return reportIncompatCallFuncSym(c, func_sym, arg_start, cstr.ret, node);
}

fn matchOverloadedFunc(c: *cy.Chunk, func: *cy.Func, arg_start: usize, nargs: usize, template_arg_start: usize, cstr: CallCstr, args_loc: u32) !?FuncSymResult {
    const func_sig = c.sema.getFuncSig(func.funcSigId);
    const params = func_sig.params();

    if (params.len != nargs) {
        return null;
    }

    const config = MatchConfig{
        .template_arg_start = template_arg_start,
        .single_func = false,
        .ct_call = cstr.ct_call,
    };

    var has_dyn_arg = false;
    var rt_arg_idx: u32 = 0;
    for (0..nargs) |i| {
        const arg = c.arg_stack.items[arg_start + i];
        if (arg.type == .skip) {
            rt_arg_idx += 1;
            continue;
        }
        const final_arg = try matchArg(c, arg, params[i], config);
        c.arg_stack.items[arg_start + i] = final_arg;

        if (final_arg.resolve_t == .rt) {
            // Runtime arg.
            has_dyn_arg = has_dyn_arg or final_arg.res.rt.type.isDynAny();
            c.ir.setArrayItem(args_loc, u32, rt_arg_idx, final_arg.res.rt.irIdx);
            rt_arg_idx += 1;
        } else if (final_arg.resolve_t == .incompat) {
            return null;
        }
    }

    // Check return type.
    if (!cy.types.isValidReturnType(c.compiler, func.retType, cstr.ret)) {
        return null;
    }

    if (cstr.ct_call) {
        return error.TODO;
    } else {
        return .{
            // Becomes a dynamic call if this is an overloaded function with a dynamic arg.
            .dyn_call = has_dyn_arg,
            .func = func,
            .data = .{ .rt = .{
                .args_loc = args_loc,
                .nargs = rt_arg_idx,
            }},
        };
    }
}

fn resolveRtArg(c: *cy.Chunk, arg: Argument, node: *ast.Node, opt_target_t: ?cy.TypeId, single_func: bool) !sema.ExprResult {
    if (arg.resolve_t == .rt) {
        return arg.res.rt;
    }
    switch (arg.type) {
        .standard => {
            if (opt_target_t) |target_t| {
                if (single_func) {
                    return c.semaExprTarget(node, target_t);
                } else {
                    return c.semaExpr(node, .{
                        .target_t = target_t,
                        .req_target_t = false,
                        .fit_target = true,
                        .fit_target_unbox_dyn = false,
                    });
                }
            } else {
                return c.semaExpr(node, .{});
            }
        },
        .pre_resolved => {
            return arg.data.pre_resolved;
        },
        .skip => {
            return error.Unexpected;
        },
    }
}

const MatchConfig = struct {
    template_arg_start: usize,
    single_func: bool,

    /// Whether the function is intended to be invoked at compile-time.
    ct_call: bool,
};

fn getFuncTemplateParamType(c: *cy.Chunk, template: *cy.sym.FuncTemplate, ctx: *sema.ResolveContext, idx: usize) !cy.TypeId {
    if (idx == 0 and std.mem.eql(u8, c.ast.nodeString(template.func_params[idx].name_type), "self")) {
        return template.head.parent.?.getStaticType().?;
    } else {
        const spec_idx = sema.indexOfTypedParam(template.func_params, idx).?;
        try sema.pushSavedResolveContext(c, ctx.*);
        defer ctx.* = sema.saveResolveContext(c);
        return try sema.resolveTypeSpecNode(c, template.func_params[spec_idx].type);
    }
}

fn matchTemplateArg(c: *cy.Chunk, arg: Argument, template: *cy.sym.FuncTemplate, template_c: *cy.Chunk,
    template_ctx: *sema.ResolveContext, idx: usize, config: MatchConfig) !Argument {
    const param = template.func_params[idx];
    if (param.sema_tparam or config.ct_call) {
        const param_t = try getFuncTemplateParamType(template_c, template, template_ctx, idx);
        // Compile-time param.
        const ct_value = (try cte.resolveCtValueOpt(c, arg.node)) orelse {
            return c.reportError("Expected compile-time argument.", arg.node);
        };
        if (ct_value.type != param_t) {
            defer c.vm.release(ct_value.value);
            return sema.reportIncompatType(c, param_t, ct_value.type, arg.node);
        }
        var new_arg = arg;
        if (param.sema_tparam) {
            new_arg.resolve_t = .template;
            new_arg.res = .{ .template = ct_value };
        } else {
            new_arg.resolve_t = .ct;
            new_arg.res = .{ .ct = ct_value };
        }
        return new_arg;
    }

    var target_t: ?cy.TypeId = null;
    if (!param.sema_infer_tparam) {
        target_t = try getFuncTemplateParamType(template_c, template, template_ctx, idx);
    }
    var res = try resolveRtArg(c, arg, arg.node, target_t, true);

    if (param.sema_infer_tparam) {
        // Infer template params.
        try sema.pushSavedResolveContext(template_c, template_ctx.*);
        try inferCtArgs(c, res.type.id, template, template_c, param.type.?, arg.node);
        template_ctx.* = sema.saveResolveContext(template_c);
        target_t = res.type.id;
    }

    const ct_compat = cy.types.isTypeSymCompat(c.compiler, res.type.id, target_t.?);
    const rt_compat = res.type.isDynAny();
    if (!ct_compat and !rt_compat) {
        return sema.reportIncompatType(c, target_t.?, res.type.id, arg.node);
    }

    if (rt_compat and config.single_func) {
        // Insert rt arg type check. 
        const loc = try c.unboxOrCheck(target_t.?, res, arg.node);
        res.irIdx = loc;
        res.type = cy.types.CompactType.init(target_t.?);
    }

    var resolved_arg = arg;
    resolved_arg.res = .{ .rt = res };
    resolved_arg.resolve_t = .rt;
    return resolved_arg;
}

fn matchArg(c: *cy.Chunk, arg: Argument, param: sema.FuncParam, config: MatchConfig) !Argument {
    if (config.ct_call) {
        // Compile-time param.
        const ct_value = (try cte.resolveCtValueOpt(c, arg.node)) orelse {
            if (config.ct_call) {
                return c.reportError("Expected compile-time argument.", arg.node);
            }
            var new_arg = arg;
            new_arg.resolve_t = .incompat;
            new_arg.res = .{ .incompat = .{
                .res_t = cy.NullId,
                .target_t = param.type,
            }};
            return new_arg;
        };
        if (ct_value.type != param.type) {
            c.vm.release(ct_value.value);
            var new_arg = arg;
            new_arg.resolve_t = .incompat;
            new_arg.res = .{ .incompat = .{
                .res_t = ct_value.type,
                .target_t = param.type,
            }};
            return new_arg;
        }
        var new_arg = arg;
        new_arg.resolve_t = .ct;
        new_arg.res = .{ .ct = ct_value };
        return new_arg;
    }

    const target_t = param.type;
    var res = try resolveRtArg(c, arg, arg.node, target_t, config.single_func);

    const ct_compat = cy.types.isTypeSymCompat(c.compiler, res.type.id, target_t);
    const rt_compat = res.type.isDynAny();
    if (!ct_compat and !rt_compat) {
        var new_arg = arg;
        new_arg.resolve_t = .incompat;
        new_arg.res = .{ .incompat = .{
            .res_t = res.type.id,
            .target_t = param.type,
        }};
        return new_arg;
    }

    if (rt_compat and config.single_func) {
        // Insert rt arg type check. 
        const loc = try c.unboxOrCheck(target_t, res, arg.node);
        res.irIdx = loc;
        res.type = cy.types.CompactType.init(target_t);
    }

    var resolved_arg = arg;
    resolved_arg.res = .{ .rt = res };
    resolved_arg.resolve_t = .rt;
    return resolved_arg;
}

fn reportIncompatCallFuncSym(c: *cy.Chunk, sym: *cy.sym.FuncSym, arg_start: usize, ret_cstr: cy.types.ReturnCstr, node: *ast.Node) anyerror {
    const type_start = c.typeStack.items.len;
    defer c.typeStack.items.len = type_start;

    const args = c.arg_stack.items[arg_start..];
    for (args) |arg| {
        if (arg.resolve_t == .null) {
            try c.typeStack.append(c.alloc, cy.NullId);
        } else if (arg.resolve_t == .rt) {
            try c.typeStack.append(c.alloc, arg.res.rt.type.id);
        } else if (arg.resolve_t == .ct) {
            try c.typeStack.append(c.alloc, arg.res.ct.type);
        } else {
            try c.typeStack.append(c.alloc, arg.res.incompat.res_t);
        }
    }
    const types = c.typeStack.items[type_start..];
    return sema.reportIncompatCallFuncSym2(c, sym, types, ret_cstr, node);
}

fn reportIncompatCallFunc(c: *cy.Chunk, func: *cy.Func, arg_start: usize, ret_cstr: cy.types.ReturnCstr, node: *ast.Node) anyerror {
    const type_start = c.typeStack.items.len;
    defer c.typeStack.items.len = type_start;

    const args = c.arg_stack.items[arg_start..];
    for (args) |arg| {
        if (arg.resolve_t == .null) {
            try c.typeStack.append(c.alloc, cy.NullId);
        } else if (arg.resolve_t == .rt) {
            try c.typeStack.append(c.alloc, arg.res.rt.type.id);
        } else if (arg.resolve_t == .ct) {
            try c.typeStack.append(c.alloc, arg.res.ct.type);
        } else {
            try c.typeStack.append(c.alloc, arg.res.incompat.res_t);
        }
    }
    const types = c.typeStack.items[type_start..];
    return sema.reportIncompatCallFunc2(c, func, types, ret_cstr, node);
}

fn expectTypeFromTemplate(c: *cy.Chunk, type_id: cy.TypeId, exp: *cy.sym.Template, node: *ast.Node) !*cy.sym.Variant {
    const variant = c.sema.getTypeSym(type_id).getVariant() orelse {
        const name = try c.sema.allocTypeName(type_id);
        defer c.alloc.free(name);
        return c.reportErrorFmt("Expected `{}` to be an expanded type.", &.{v(name)}, node);
    };

    if (variant.type != .sym or variant.data.sym.template != exp) {
        return c.reportErrorFmt("Expected template `{}`. Found `{}`.", &.{v(exp.head.name()), v(variant.data.sym.template.head.name())}, node);
    }
    return variant;
}

/// CtInfer types are extracted from `arg_t`.
fn inferCtArgs(c: *cy.Chunk, arg_t: cy.TypeId, template: *cy.sym.FuncTemplate, template_c: *cy.Chunk, template_n: *ast.Node, node: *ast.Node) !void {
    switch (template_n.type()) {
        .ident => {
            const name = template_c.ast.nodeString(template_n);
            if (template.indexOfParam(name) != null) {
                const ctx = sema.getResolveContext(template_c);
                if (!ctx.ct_params.contains(name)) {
                    const targ = try c.vm.allocType(arg_t);
                    try ctx.setCtParam(c.alloc, name, targ);
                    return;
                }
            }
            const act_t = try cte.resolveCtType(template_c, template_n);
            if (arg_t != arg_t) {
                return sema.reportIncompatType(template_c, arg_t, act_t, template_n);
            }
        },
        .ptr => {
            const ptr = template_n.cast(.ptr);
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.pointer_tmpl, node);
            try inferCtArgValue(c, variant.args[0], template, template_c, ptr.elem);
        },
        .ptr_slice => {
            const ptr_slice = template_n.cast(.ptr_slice);
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.ptr_slice_tmpl, node);
            try inferCtArgValue(c, variant.args[0], template, template_c, ptr_slice.elem);
        },
        .ref_slice => {
            const ref_slice = template_n.cast(.ref_slice);
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.ref_slice_tmpl, node);
            try inferCtArgValue(c, variant.args[0], template, template_c, ref_slice.elem);
        },
        .array_expr => {
            // Infer nested. (e.g. `A[T]`)
            const array_expr = template_n.cast(.array_expr);
            const variant = c.sema.getTypeSym(arg_t).getVariant() orelse {
                const name = try c.sema.allocTypeName(arg_t);
                defer c.alloc.free(name);
                return c.reportErrorFmt("Expected `{}` to be an expanded type.", &.{v(name)}, node);
            };

            const template_t = try cte.resolveCtSym(template_c, array_expr.left);
            if (template_t.type != .template) {
                return template_c.reportErrorFmt("Expected template. Found `{}`.", &.{v(template_t.type)}, array_expr.left);
            }

            if (variant.type != .sym or variant.data.sym.template != template_t.cast(.template)) {
                return c.reportErrorFmt("Expected template `{}`. Found `{}`.", &.{v(template_t.name()), v(variant.data.sym.template.head.name())}, node);
            }

            if (variant.args.len != array_expr.args.len) {
                return template_c.reportErrorFmt("Expected `{}` args. Found `{}`.", &.{v(variant.args.len), v(array_expr.args.len)}, template_n);
            }
            for (variant.args, 0..) |targ, i| {
                try inferCtArgValue(c, targ, template, template_c, array_expr.args[i]);
            }
        },
        else => {
            return template_c.reportErrorFmt("Unsupported infer node `{}`.", &.{v(template_n.type())}, template_n);
        }
    }
}

fn inferCtArgValue(c: *cy.Chunk, arg: cy.Value, template: *cy.sym.FuncTemplate, template_c: *cy.Chunk, template_n: *ast.Node) !void {
    switch (template_n.type()) {
        .ident => {
            const name = template_c.ast.nodeString(template_n);
            if (template.indexOfParam(name) != null) {
                const ctx = sema.getResolveContext(template_c);
                if (!ctx.ct_params.contains(name)) {
                    c.vm.retain(arg);
                    try ctx.setCtParam(c.alloc, name, arg);
                    return;
                }
            }
            const act_v = try cte.resolveCtValue(template_c, template_n);
            defer c.vm.release(act_v.value);
            try assertValueEq(template_c, arg, act_v.value, template_n);
        },
        else => {
            return template_c.reportErrorFmt("Unsupported infer node `{}`.", &.{v(template_n.type())}, template_n);
        }
    }
}

fn assertValueEq(c: *cy.Chunk, exp: cy.Value, act: cy.Value, node: *ast.Node) !void {
    if (exp.getTypeId() != act.getTypeId()) {
        return sema.reportIncompatType(c, exp.getTypeId(), act.getTypeId(), node);
    }

    switch (exp.getTypeId()) {
        bt.Type => {
            if (exp.asHeapObject().type.type != act.asHeapObject().type.type) {
                return sema.reportIncompatType(c, exp.asHeapObject().type.type, act.asHeapObject().type.type, node);
            }
        },
        else => {
            const type_name = try c.sema.allocTypeName(exp.getTypeId());
            defer c.alloc.free(type_name);
            return c.reportErrorFmt("Unsupport value type: `{s}`", &.{v(type_name)}, node);
        }
    }
}
