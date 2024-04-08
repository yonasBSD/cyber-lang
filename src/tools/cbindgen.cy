#!cyber
use os

-- usage: ./cbindgen.cy -o llvm.cy /path/to/LLVM.h -libpath 'libLLVM.dylib' -stripPrefix LLVM
-- `-I/opt/homebrew/Cellar/llvm/17.0.6/lib/clang/17/include` if missing libc headers.

use clang 'clang_bs.cy'

var POST_HEADER = '''
'''

var .args = os.parseArgs([
    -- Output cy path.
    { name: 'o', type: String, default: 'bindings.cy' },
    { name: 'libpath', type: String, default: 'lib.dll' },
    { name: 'stripPrefix', type: String, default: 'DONT_MATCH' },
])

var existingLibPath = false
var markerPos = 0
var existing = ''

-- Determine where in the output file to emit generated bindings.
-- Also collect existing symbols that should be skipped.
-- Build skip map.
existing = try os.readFile(args['o']) catch ''
if existing != '':
    markerPos = existing.find("\n-- CBINDGEN MARKER") ?else existing.len()

    -- Only parse section before the marker since the gen part could contain bad syntax.
    var res = parseCyber(existing[..markerPos])
    for res['decls'] -> decl:
        if decl['pos'] < markerPos:
            switch decl['type']
            case 'func':
                skipMap[decl['name']] = true
            case 'funcInit':
                skipMap[decl['name']] = true
            case 'object':
                skipMap[decl['name']] = true
            case 'variable':
                if decl['name'] == 'libPath':
                    existingLibPath = true

if args['rest'].len() <= 2:
    print 'Missing path to header file.'
    os.exit(1)

let headerPath = args['rest'][2]
print headerPath

var headerSrc = os.readFile(headerPath)
headerSrc = POST_HEADER + headerSrc

var unit = getTranslationUnit(headerPath)

for 0..clang.lib.clang_getNumDiagnostics(unit) -> i:
    var diag = clang.lib.clang_getDiagnostic(unit, i)
    let spelling = clang.lib.clang_getDiagnosticSpelling(diag)
    print spelling.fromCstr(0).decode()

let cursor = clang.lib.clang_getTranslationUnitCursor(unit)

skipMap['__gnuc_va_list'] = true
skipMap['va_list'] = true
skipMap['true'] = true
skipMap['false'] = true

var state = State{type: .root}
var cstate = clang.ffi.bindObjPtr(state)

out += "-- Code below is generated by cbindgen.cy\n"

-- enum CXChildVisitResult(*CXCursorVisitor) (CXCursor cursor, CXCursor parent, CXClientData client_data)
cvisitor = clang.ffi.bindCallback(visitor, [clang.CXCursor, clang.CXCursor, .voidPtr], .int)

clang.lib.clang_visitChildren(cursor, cvisitor, cstate)

-- Generate ffi init.
out += "\nuse os\n"
out += "let .ffi = false\n"
out += "let .lib = load()\n"
out += "func load():\n"
out += "    ffi = os.newFFI()\n"
for structs -> name:
    var fieldTypes = structMap[name].fieldTypes as List
    var finalFieldTypes = []
    for fieldTypes -> ftype:
        ftype = ensureBindType(ftype)
        if typeof(ftype) == String:
            finalFieldTypes.append(getApiName(ftype))
        else:
            finalFieldTypes.append(ftype)

    out += "    ffi.cbind($(getApiName(name)), [$(finalFieldTypes.join(', '))])\n"
for funcs -> fn:
    var finalParams = []
    for fn.params -> param:
        param = ensureBindType(param)
        if typeof(param) == String:
            finalParams.append(getApiName(param))
        else:
            finalParams.append(param as symbol)
    var finalRet = ensureBindType(fn.ret)
    out += "    ffi.cfunc('$(fn.name)', [$(finalParams.join(', '))], $(finalRet))\n"
var libPath = if (existingLibPath) 'libPath' else "'$(args['libpath'])'"
out += "    let lib = ffi.bindLib(?String{some: $(libPath)}, {genMap: false})\n"
out += "    return lib\n\n"

-- Generate macros.
genMacros(headerPath)

-- Final output.
out = existing[0..markerPos] + "\n-- CBINDGEN MARKER\n" + out

os.writeFile(args['o'], out)

-- Declarations.

var .skipMap = {}
var .macros = []
var .cvisitor = pointer(0)
-- Build output string.
var .out = ''
var .skipChildren = false
var .aliases = {}    -- aliasName -> structName or binding symbol (eg: .voidPtr)
let .struct = false
var .structMap = {}  -- structName -> list of fields (symOrName)
var .enumMap = {}
var .structs = []
var .funcs = []
-- var .arrays = {}     -- [n]typeName -> true
-- var vars = {}            -- varName -> bindingType

func getTranslationUnit(headerPath String):
    var rest List = args['rest'][3..]

    var cargs = os.malloc(8 * rest.len())
    for rest -> arg, i:
        print "clang arg: $(arg)"
        cargs.set(i * 8, .voidPtr, os.cstr(arg))

    var cpath = os.cstr(headerPath)
    var index = clang.lib.clang_createIndex(0, 0)
    return clang.lib.clang_parseTranslationUnit(index, cpath, cargs, rest.len(), pointer(0), 0,
        -- clang.CXTranslationUnit_DetailedPreprocessingRecord | clang.CXTranslationUnit_SkipFunctionBodies | clang.CXTranslationUnit_SingleFileParse)
        clang.CXTranslationUnit_DetailedPreprocessingRecord | clang.CXTranslationUnit_SkipFunctionBodies | clang.CXTranslationUnit_KeepGoing)

func getMacrosTranslationUnit(hppPath String):
    var rest List = args['rest'][3..]

    var cargs = os.malloc(8 * rest.len())
    for rest -> arg, i:
        cargs.set(i * 8, .voidPtr, os.cstr(arg))

    var cpath = os.cstr(hppPath)
    var index = clang.lib.clang_createIndex(0, 0)
    return clang.lib.clang_parseTranslationUnit(index, cpath, cargs, rest.len(), pointer(0), 0,
        clang.CXTranslationUnit_SkipFunctionBodies | clang.CXTranslationUnit_KeepGoing)

type Struct:
    fieldTypes   List
    fieldNames   List
    cxFieldTypes List

type StateType enum:
    case root
    case struct
    case enum
    case macrosRoot
    case initVar
    case initListExpr

type State:
    type StateType
    data dynamic

let visitor(cursor, parent, client_data):
    var state State = client_data.asObject()
    switch state.type
    case StateType.root:
        return rootVisitor(cursor, parent, state)
    case StateType.struct:
        return structVisitor(cursor, parent, state)
    case StateType.enum:
        return enumVisitor(cursor, parent, state)
    case StateType.macrosRoot:
        return macrosRootVisitor(cursor, parent, state)
    case StateType.initVar:
        return initVarVisitor(cursor, parent, state)
    case StateType.initListExpr:
        return initListExpr(cursor, parent, state)
    else:
        throw error.Unsupported

let rootVisitor(cursor, parent, state):
    var cxName = clang.lib.clang_getCursorDisplayName(cursor)
    var name = fromCXString(cxName)

    var loc = clang.lib.clang_getCursorLocation(cursor)
    if clang.lib.clang_Location_isInSystemHeader(loc) != 0:
        -- Skip system headers.
        return clang.CXChildVisit_Continue

    switch cursor.kind
    case clang.CXCursor_MacroDefinition:
        if clang.lib.clang_Cursor_isMacroBuiltin(cursor) != 0:
            return clang.CXChildVisit_Continue
        if clang.lib.clang_Cursor_isMacroFunctionLike(cursor) != 0:
            return clang.CXChildVisit_Continue

        -- Append to macros.
        macros.append(name)

    case clang.CXCursor_MacroExpansion,
        clang.CXCursor_InclusionDirective: pass

    case clang.CXCursor_TypedefDecl: 
        -- print "typedef $(name)"
        if skipMap.contains(name):
            out += "-- typedef $(name)\n\n"
        else:
            var atype = clang.lib.clang_getTypedefDeclUnderlyingType(cursor)
            var bindType = toBindType(atype)
            if typeof(bindType) == symbol or bindType != name:
                aliases[name] = bindType
                out += "type $(getApiName(name)) = $(toCyType(bindType, true))\n\n"

    case clang.CXCursor_StructDecl:
        -- print "struct $(name)"
        var effName = name + '_S'

        struct = Struct{fieldTypes: [], fieldNames: [], cxFieldTypes: []}
        structMap[effName] = struct

        var newState = State{type: .struct}
        var cnewState = clang.ffi.bindObjPtr(newState)
        clang.lib.clang_visitChildren(cursor, cvisitor, cnewState)
        clang.ffi.unbindObjPtr(newState)

        if struct.fieldTypes.len() == 0:
            -- Empty struct, skip.
            return clang.CXChildVisit_Continue

        structs.append(effName)
        if skipMap.contains(effName):
            out += "-- type $(getApiName(effName)):\n"
            skipChildren = true
        else:
            out += "type $(getApiName(effName)):\n"

        for struct.fieldNames -> name, i:
            if skipChildren:
                out += '-- '

            let fieldt = struct.fieldTypes[i]
            out += "    $(name) $(toCyType(fieldt, false))"
            if is(fieldt, .voidPtr) or
                (typeof(fieldt) == String and fieldt.startsWith('[os.CArray')):
                out += " -- $(struct.cxFieldTypes[i])"
            out += "\n"

        out += "\n"
        skipChildren = false

    case clang.CXCursor_EnumDecl:
        -- print "enum $(name)"

        -- Skip unnamed enum.
        if !name.startsWith('enum '):
            out += "type $(getApiName(name)) = int\n"
            aliases[name] = .int

        var newState = State{type: .enum}
        var cnewState = clang.ffi.bindObjPtr(newState)
        clang.lib.clang_visitChildren(cursor, cvisitor, cnewState)
        clang.ffi.unbindObjPtr(newState)
        out += "\n"

    case clang.CXCursor_FunctionDecl:
        -- print "func $(name)"

        var cxName = clang.lib.clang_getCursorSpelling(cursor)
        var funcName = fromCXString(cxName)
        var fn = Func{}
        fn.name = funcName

        var cxFunc = clang.lib.clang_getCursorType(cursor)
        var cxRet = clang.lib.clang_getResultType(cxFunc)

        var outFunc = "func $(getApiName(funcName))("

        -- Parse params.
        var fnParamTypes = []
        var numParams int = clang.lib.clang_getNumArgTypes(cxFunc)
        for 0..numParams -> i:
            var cxParam = clang.lib.clang_Cursor_getArgument(cursor, i)
            var cxParamName = clang.lib.clang_getCursorSpelling(cxParam)
            var paramName = fromCXString(cxParamName)
            if paramName == '' or reserved_keywords.contains(paramName):
                paramName = "param$(i)"
            var cxParamType = clang.lib.clang_getArgType(cxFunc, i)
            var paramT = toBindType(cxParamType)

            outFunc += "$(paramName) $(toCyType(paramT, false))"
            if i < numParams-1:
                outFunc += ', '

            fnParamTypes.append(paramT)

        outFunc += ') '

        var retT = toBindType(cxRet)
        outFunc += toCyType(retT, true)

        if skipMap.contains(funcName):
            outFunc = "--$(outFunc)\n"
        else:
            outFunc += ":\n"
            outFunc += "    return lib.$(funcName)("
            for 0..numParams -> i:
                var cxParam = clang.lib.clang_Cursor_getArgument(cursor, i)
                var cxParamName = clang.lib.clang_getCursorSpelling(cxParam)
                var paramName = fromCXString(cxParamName)
                if paramName == '' or reserved_keywords.contains(paramName):
                    paramName = "param$(i)"
                outFunc += paramName
                if i < numParams-1:
                    outFunc += ', '
            outFunc += ")\n"

        out += outFunc

        fn.params = fnParamTypes
        fn.ret = retT
        funcs.append(fn)

    case clang.CXCursor_VarDecl:
        print "TODO: var $(name)"

    else:
        print "visitor invoked $(cursor.kind) $(name)"
        throw error.Unsupported

    return clang.CXChildVisit_Continue

let structVisitor(cursor, parent, state):
    var cxName = clang.lib.clang_getCursorDisplayName(cursor)
    var name = fromCXString(cxName)

    switch cursor.kind
    case clang.CXCursor_FieldDecl:
        -- print "field $(cursor.kind) $(name)"
        let ftype = clang.lib.clang_getCursorType(cursor)
        var fsym = toBindType(ftype)

        struct.fieldTypes.append(fsym)
        struct.fieldNames.append(name)

        var cxTypeName = clang.lib.clang_getTypeSpelling(ftype)
        var typeName = fromCXString(cxTypeName)
        struct.cxFieldTypes.append(typeName)
    else: 
        print "unsupported $(cursor.kind) $(name)"
    return clang.CXChildVisit_Continue

let enumVisitor(cursor, parent, state):
    var cxName = clang.lib.clang_getCursorDisplayName(cursor)
    var name = fromCXString(cxName)
    var val = clang.lib.clang_getEnumConstantDeclValue(cursor)
        
    out += "var .$(getApiName(name)) int = $(val)\n"
    return clang.CXChildVisit_Continue

func genMacros(headerPath String):
    var absPath = os.realPath(headerPath)

    var hpp = ''
    hpp += """#include "$(absPath)"\n\n"""
    for macros -> macro:
        hpp += "auto var_$(macro) = $(macro);\n"
    os.writeFile('macros.hpp', hpp)

    var unit = getMacrosTranslationUnit('macros.hpp')
    let cursor = clang.lib.clang_getTranslationUnitCursor(unit)

    for 0..clang.lib.clang_getNumDiagnostics(unit) -> i:
        var diag = clang.lib.clang_getDiagnostic(unit, i)
        let spelling = clang.lib.clang_getDiagnosticSpelling(diag)
        print spelling.fromCstr(0).decode()

    out += "-- Macros\n"

    var state = State{type: .macrosRoot}
    var cstate = clang.ffi.bindObjPtr(state)
    clang.lib.clang_visitChildren(cursor, cvisitor, cstate)

let initListExpr(cursor, parent, state):
    switch cursor.kind
    case clang.CXCursor_IntegerLiteral:
        var eval = clang.lib.clang_Cursor_Evaluate(cursor)
        var val = clang.lib.clang_EvalResult_getAsLongLong(eval)
        state.data.append(val)
    else:
        print "visitor invoked $(cursor.kind)"
        throw error.Unsupported

    return clang.CXChildVisit_Continue

let initVarVisitor(cursor, parent, state):
    var cxName = clang.lib.clang_getCursorDisplayName(cursor)
    var name = fromCXString(cxName)

    switch cursor.kind
    case clang.CXCursor_TypeRef:
        state.data['type'] = name
    case clang.CXCursor_InitListExpr:
        var args = []
        var newState = State{type: .initListExpr, data: args}
        var cnewState = clang.ffi.bindObjPtr(newState)
        clang.lib.clang_visitChildren(cursor, cvisitor, cnewState)
        clang.ffi.unbindObjPtr(newState)
        state.data['args'] = args
    else:
        print "visitor invoked $(cursor.kind) $(name)"
        throw error.Unsupported

    return clang.CXChildVisit_Continue

let macrosRootVisitor(cursor, parent, state):
    var cxName = clang.lib.clang_getCursorDisplayName(cursor)
    var name = fromCXString(cxName)

    var loc = clang.lib.clang_getCursorLocation(cursor)
    if clang.lib.clang_Location_isInSystemHeader(loc) != 0:
        -- Skip system headers.
        return clang.CXChildVisit_Continue

    switch cursor.kind
    case clang.CXCursor_UnexposedDecl: pass
    case clang.CXCursor_MacroDefinition: pass
    case clang.CXCursor_MacroExpansion,
        clang.CXCursor_InclusionDirective: pass
    case clang.CXCursor_TypedefDecl: pass
    case clang.CXCursor_StructDecl: pass
    case clang.CXCursor_EnumDecl: pass
    case clang.CXCursor_FunctionDecl: pass
    case clang.CXCursor_VarDecl:
        if !name.startsWith('var_'):
            -- Skip non-macro vars.
            return clang.CXChildVisit_Continue

        if skipMap.contains(name[4..]):
            out += '-- '

        -- print "var $(name)"
        var eval = clang.lib.clang_Cursor_Evaluate(cursor)
        var kind = clang.lib.clang_EvalResult_getKind(eval)

        var finalName = getApiName(name[4..].trim(.left, '_'))
        switch kind
        case clang.CXEval_UnExposed:
            -- Can't eval to primitive. Check for struct intializer.
            let initCur = clang.lib.clang_Cursor_getVarDeclInitializer(cursor)

            var cxInitName = clang.lib.clang_getCursorDisplayName(initCur)
            var initName = fromCXString(cxInitName)
            switch initCur.kind
            case clang.CXCursor_InvalidFile: pass
            case clang.CXCursor_CXXFunctionalCastExpr:
                var state = State{type: .initVar, data: {}}
                var cstate = clang.ffi.bindObjPtr(state)
                clang.lib.clang_visitChildren(initCur, cvisitor, cstate)
                clang.ffi.unbindObjPtr(state)

                var initT = state.data['type']

                let struct = getStruct(initT)
                var kvs = []
                for struct.fieldNames -> fieldn, i:
                    kvs.append("$(fieldn): $(state.data['args'][i])")
                out += "var .$(finalName) $(initT) = [$(initT) $(kvs.join(', '))]\n"
            else:
                print "init $(initName) $(initCur.kind)"
                throw error.Unsupported
        case clang.CXEval_Int:
            var val = clang.lib.clang_EvalResult_getAsLongLong(eval)
            out += "var .$(finalName) int = $(val)\n"
        case clang.CXEval_Float:
            var val = clang.lib.clang_EvalResult_getAsDouble(eval)
            out += "var .$(finalName) float = $(val)\n"
        case clang.CXEval_StrLiteral:
            let strz = clang.lib.clang_EvalResult_getAsStr(eval)
            var str = strz.fromCstr(0).decode()
            out += """var .$(finalName) String = "$(str)"\n"""
        else:
            print "$(kind)"
            throw error.Unsupported

        clang.lib.clang_EvalResult_dispose(eval)
    else:
        print "visitor invoked $(cursor.kind) $(name)"
        throw error.Unsupported
    return clang.CXChildVisit_Continue

func fromCXString(cxStr any) String:
    let cname = clang.lib.clang_getCString(cxStr)
    return cname.fromCstr(0).decode()

let toCyType(nameOrSym, forRet):
    if typeof(nameOrSym) == symbol:
        switch nameOrSym
        case .voidPtr   : return if (forRet) 'pointer' else 'any' -- `any` until Optionals are done
        case .bool      : return 'bool'
        case .int       : return 'int'
        case .uint      : return 'int'
        case .char      : return 'int'
        case .uchar     : return 'int'
        case .long      : return 'int'
        case .ulong     : return 'int'
        case .float     : return 'float'
        case .double    : return 'float'
        case .voidPtr   : return 'pointer'
        case .void      : return 'void'
        else:
            print "Unsupported type $(nameOrSym)"
            throw error.Unsupported
    else:
        if nameOrSym.startsWith('[os.CArray'):
            return 'List'
        if !forRet and aliases.contains(nameOrSym):
            if aliases[nameOrSym] == .voidPtr:
                return 'any'
        return getApiName(nameOrSym)

func ensureBindType(nameOrSym any):
    if typeof(nameOrSym) == symbol:
        return nameOrSym
    else:
        if aliases.contains(nameOrSym):
            var og = aliases[nameOrSym]
            if typeof(og) == symbol:
                return og
        return nameOrSym

func getStruct(name any):
    if structMap.contains(name):
        return structMap[name]
    if aliases.contains(name):
        var alias = aliases[name]
        return structMap[alias]
    return false

let toBindType(cxType):
    switch cxType.kind
    case clang.CXType_Float             : return .float
    case clang.CXType_Double            : return .double
    case clang.CXType_Long              : return .long
    case clang.CXType_LongLong          : return .long
    case clang.CXType_ULongLong         : return .ulong
    case clang.CXType_Void              : return .void
    case clang.CXType_Bool              : return .bool
    case clang.CXType_Int               : return .int
    case clang.CXType_UInt              : return .uint
    case clang.CXType_Char_S            : return .char
    case clang.CXType_UChar             : return .uchar
    case clang.CXType_Pointer           : return .voidPtr
    case clang.CXType_FunctionProto     : return .voidPtr
    case clang.CXType_IncompleteArray   : return .voidPtr
    case clang.CXType_Typedef:
        var name = fromCXString(clang.lib.clang_getTypedefName(cxType))

        switch name
        case 'size_t'   : return .long
        case 'uint8_t'  : return .uchar
        case 'uint64_t' : return .ulong
        else:
            if structMap.contains(name):
                -- Valid type.
                return name
            else aliases.contains(name):
                -- Valid alias.
                return name
            else enumMap.contains(name):
                return name

        print name
        throw error.Unsupported
    case clang.CXType_Elaborated:
        var decl = clang.lib.clang_getTypeDeclaration(cxType)
        let declType = clang.lib.clang_getCursorType(decl)
        var name = fromCXString(clang.lib.clang_getCursorDisplayName(decl))

        if declType.kind == clang.CXType_Typedef:
            return toBindType(declType)
        else declType.kind == clang.CXType_Record:
            -- struct Foo
            return name + '_S'
        else declType.kind == clang.CXType_Enum:
            return name

        print "Unsupported elaborated type: $(name) $(declType.kind)"
        throw error.Unsupported
    case clang.CXType_ConstantArray:
        var n = clang.lib.clang_getNumElements(cxType)
        var cxElem = clang.lib.clang_getElementType(cxType)
        var elem = toBindType(cxElem)
        return "[os.CArray n: $(n), elem: $(elem)]"
    else:
        print "Unsupported type $(cxType.kind)"
        throw error.Unsupported

func getApiName(name String):
    if name.startsWith(args['stripPrefix']):
        name = name[args['stripPrefix'].len()..]
    if name.startsWith('_'):
        name = name[1..]
    return name

var .reserved_keywords = {'type': true}

type Func:
    name dynamic
    params dynamic
    ret dynamic