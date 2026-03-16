"""
Expression translation from Julia AST to SQL fragments.

Translates the expression ASTs captured by QueryableBackend into SQL.
Returns `(sql_fragment::String, params::Vector{Any})` tuples.
"""

struct TranslationError <: Exception
    msg::String
    expr
end

Base.showerror(io::IO, e::TranslationError) = print(io, "TranslationError: ", e.msg, "\n  Expression: ", e.expr)

# Map Julia operators to SQL operators
const BINARY_OPS = Dict{Symbol,String}(
    :(==) => "=",
    :(!=) => "<>",
    :(<)  => "<",
    :(>)  => ">",
    :(<=) => "<=",
    :(>=) => ">=",
    :(+)  => "+",
    :(-)  => "-",
    :(*)  => "*",
    :(/)  => "/",
    :(%)  => "%",
)

const JULIA_TO_SQL_FUNCTIONS = Dict{Symbol,String}(
    :uppercase  => "UPPER",
    :lowercase  => "LOWER",
    :abs        => "ABS",
    :round      => "ROUND",
    :floor      => "FLOOR",
    :ceil       => "CEIL",
    :coalesce   => "COALESCE",
    :sum        => "SUM",
    :minimum    => "MIN",
    :maximum    => "MAX",
    :strip      => "TRIM",
    :lstrip     => "LTRIM",
    :rstrip     => "RTRIM",
    :replace    => "REPLACE",
    :string     => "CONCAT",
)

"""
    translate_expr(expr, params::Vector{Any}, row_sym::Symbol) -> String

Translate a Julia expression AST into a SQL fragment.
`row_sym` is the lambda parameter name (e.g. the gensym used by Query macros).
`params` accumulates literal values for parameterized queries.
"""
function translate_expr(expr::Expr, params::Vector{Any}, row_sym::Symbol; in_aggregation::Bool=false, inner_row_sym::Symbol=Symbol(), outer_alias::String="", inner_alias::String="")
    if expr.head == :call
        return translate_call(expr, params, row_sym; in_aggregation=in_aggregation)
    elseif expr.head == :(.)
        return translate_property_access(expr, params, row_sym; inner_row_sym=inner_row_sym, outer_alias=outer_alias, inner_alias=inner_alias)
    elseif expr.head == :(&&)
        left = translate_expr(expr.args[1], params, row_sym; in_aggregation=in_aggregation)
        right = translate_expr(expr.args[2], params, row_sym; in_aggregation=in_aggregation)
        return "($left AND $right)"
    elseif expr.head == :(||)
        left = translate_expr(expr.args[1], params, row_sym; in_aggregation=in_aggregation)
        right = translate_expr(expr.args[2], params, row_sym; in_aggregation=in_aggregation)
        return "($left OR $right)"
    elseif expr.head == :comparison
        return translate_comparison_chain(expr, params, row_sym)
    elseif expr.head == :block
        # Single-expression blocks (from macro expansion)
        for arg in expr.args
            if !(arg isa LineNumberNode)
                return translate_expr(arg, params, row_sym; in_aggregation=in_aggregation)
            end
        end
    end
    throw(TranslationError("Unsupported expression type: $(expr.head)", expr))
end

function translate_expr(sym::Symbol, params::Vector{Any}, row_sym::Symbol; kwargs...)
    if sym == :missing
        return "NULL"
    elseif sym == :true
        return "TRUE"
    elseif sym == :false
        return "FALSE"
    end
    throw(TranslationError("Unsupported bare symbol: $sym", sym))
end

function translate_expr(val::Number, params::Vector{Any}, row_sym::Symbol; kwargs...)
    push!(params, val)
    return "\$$(length(params))"
end

function translate_expr(val::AbstractString, params::Vector{Any}, row_sym::Symbol; kwargs...)
    push!(params, val)
    return "\$$(length(params))"
end

function translate_expr(val::Bool, params::Vector{Any}, row_sym::Symbol; kwargs...)
    return val ? "TRUE" : "FALSE"
end

function translate_expr(qn::QuoteNode, params::Vector{Any}, row_sym::Symbol; kwargs...)
    if qn.value isa Symbol
        # A quoted symbol like :col_name — treat as column name
        return quote_identifier(string(qn.value))
    end
    throw(TranslationError("Unsupported QuoteNode value", qn))
end

# Handle compiled NamedTuple() literals that appear in macro-expanded expressions
function translate_expr(::NamedTuple, params::Vector{Any}, row_sym::Symbol; kwargs...)
    # Empty NamedTuple — should be handled by merge chain, but just in case
    return ""
end

function translate_property_access(expr::Expr, params::Vector{Any}, row_sym::Symbol; inner_row_sym::Symbol=Symbol(), outer_alias::String="", inner_alias::String="")
    # Pattern: row_sym.col_name
    if expr.head == :(.) && length(expr.args) == 2
        obj = expr.args[1]
        field = expr.args[2]
        if obj == row_sym || obj == :_
            if field isa QuoteNode
                col = quote_identifier(string(field.value))
                if !isempty(outer_alias)
                    return "$(quote_identifier(outer_alias)).$col"
                end
                return col
            end
        end
        # Inner row reference (__) for joins
        if inner_row_sym != Symbol() && (obj == inner_row_sym || obj == :__)
            if field isa QuoteNode
                col = quote_identifier(string(field.value))
                if !isempty(inner_alias)
                    return "$(quote_identifier(inner_alias)).$col"
                end
                return col
            end
        end
        # Nested property access like QueryOperators.NamedTupleUtilities
        if obj isa Expr && obj.head == :(.)
            return translate_expr(expr, params, row_sym)
        end
    end
    throw(TranslationError("Unsupported property access", expr))
end

function translate_call(expr::Expr, params::Vector{Any}, row_sym::Symbol; in_aggregation::Bool=false)
    func = expr.args[1]
    args = expr.args[2:end]

    # Unary NOT
    if func == :! && length(args) == 1
        inner = translate_expr(args[1], params, row_sym; in_aggregation=in_aggregation)
        return "(NOT $inner)"
    end

    # Unary minus
    if func == :(-) && length(args) == 1
        inner = translate_expr(args[1], params, row_sym; in_aggregation=in_aggregation)
        return "(-$inner)"
    end

    # Binary operators
    if func isa Symbol && haskey(BINARY_OPS, func) && length(args) == 2
        left = translate_expr(args[1], params, row_sym; in_aggregation=in_aggregation)
        right = translate_expr(args[2], params, row_sym; in_aggregation=in_aggregation)
        op = BINARY_OPS[func]
        return "($left $op $right)"
    end

    # ismissing → IS NULL
    if func == :ismissing && length(args) == 1
        inner = translate_expr(args[1], params, row_sym; in_aggregation=in_aggregation)
        return "($inner IS NULL)"
    end

    # in operator
    if func == :in && length(args) == 2
        val = translate_expr(args[1], params, row_sym; in_aggregation=in_aggregation)
        collection = args[2]
        if collection isa Expr && collection.head == :vect
            items = [translate_expr(item, params, row_sym; in_aggregation=in_aggregation) for item in collection.args]
            return "($val IN ($(join(items, ", "))))"
        elseif collection isa Expr && collection.head == :tuple
            items = [translate_expr(item, params, row_sym; in_aggregation=in_aggregation) for item in collection.args]
            return "($val IN ($(join(items, ", "))))"
        end
    end

    # startswith / endswith
    if func == :startswith && length(args) == 2
        str = translate_expr(args[1], params, row_sym; in_aggregation=in_aggregation)
        prefix = translate_expr(args[2], params, row_sym; in_aggregation=in_aggregation)
        return "starts_with($str, $prefix)"
    end
    if func == :endswith && length(args) == 2
        str = translate_expr(args[1], params, row_sym; in_aggregation=in_aggregation)
        suffix = translate_expr(args[2], params, row_sym; in_aggregation=in_aggregation)
        return "suffix($str, $suffix)"
    end

    # occursin(needle, haystack)
    if func == :occursin && length(args) == 2
        needle = translate_expr(args[1], params, row_sym; in_aggregation=in_aggregation)
        haystack = translate_expr(args[2], params, row_sym; in_aggregation=in_aggregation)
        return "contains($haystack, $needle)"
    end

    # mean → AVG
    if func == :mean && length(args) == 1
        inner = translate_expr(args[1], params, row_sym; in_aggregation=in_aggregation)
        return "AVG($inner)"
    end

    # count
    if func == :count && length(args) == 0
        return "COUNT(*)"
    end

    # length: context-dependent — COUNT in aggregation, LENGTH otherwise
    if func == :length && length(args) == 1
        inner = translate_expr(args[1], params, row_sym; in_aggregation=in_aggregation)
        if in_aggregation
            return "COUNT($inner)"
        else
            return "LENGTH($inner)"
        end
    end

    # Known Julia→SQL function mappings
    if func isa Symbol && haskey(JULIA_TO_SQL_FUNCTIONS, func)
        sql_func = JULIA_TO_SQL_FUNCTIONS[func]
        translated_args = [translate_expr(a, params, row_sym; in_aggregation=in_aggregation) for a in args]
        return "$sql_func($(join(translated_args, ", ")))"
    end

    throw(TranslationError("Unsupported function call: $func", expr))
end

function translate_comparison_chain(expr::Expr, params::Vector{Any}, row_sym::Symbol)
    # Julia comparison chains like: a < b < c → (a < b AND b < c)
    parts = String[]
    i = 1
    while i + 2 <= length(expr.args)
        left = translate_expr(expr.args[i], params, row_sym)
        op_sym = expr.args[i+1]
        right = translate_expr(expr.args[i+2], params, row_sym)
        op = get(BINARY_OPS, op_sym, nothing)
        if op === nothing
            throw(TranslationError("Unsupported comparison operator: $op_sym", expr))
        end
        push!(parts, "($left $op $right)")
        i += 2
    end
    return join(parts, " AND ")
end

"""
    extract_lambda_parts(expr::Expr) -> (row_sym::Symbol, body::Any)

Extract the parameter name and body from a lambda expression.
Handles: `x -> body` and `(x,) -> body`.
"""
function extract_lambda_parts(expr::Expr)
    if expr.head == :(->)
        param = expr.args[1]
        body = expr.args[2]
        if param isa Symbol
            return (param, body)
        elseif param isa Expr && param.head == :tuple && length(param.args) == 1
            return (param.args[1], body)
        end
    end
    throw(TranslationError("Cannot extract lambda parts", expr))
end

"""
    translate_filter_expr(filter_expr::Expr, params::Vector{Any}) -> String

Translate a filter expression (lambda) into a SQL WHERE clause fragment.
"""
function translate_filter_expr(filter_expr::Expr, params::Vector{Any})
    row_sym, body = extract_lambda_parts(filter_expr)
    return translate_expr(body, params, row_sym)
end

# --- SELECT clause translation ---

"""
Represents the columns selected in a SQL SELECT clause.
"""
struct SelectClause
    columns::Vector{String}  # Individual "col AS alias" or "col" entries
    star::Bool               # If true, SELECT * (with possible EXCLUDE)
    excludes::Vector{String} # Columns to EXCLUDE (DuckDB syntax)
end

SelectClause() = SelectClause(String[], false, String[])

function select_to_sql(sc::SelectClause)
    if sc.star
        base = "*"
        if !isempty(sc.excludes)
            base *= " EXCLUDE($(join(sc.excludes, ", ")))"
        end
        if !isempty(sc.columns)
            return "$base, $(join(sc.columns, ", "))"
        end
        return base
    end
    if isempty(sc.columns)
        return "*"
    end
    return join(sc.columns, ", ")
end

"""
    translate_map_expr(map_expr::Expr, params::Vector{Any}; in_aggregation::Bool=false) -> String

Translate a map expression (lambda) into a SQL SELECT column list.
Handles both simple NamedTuple construction and NamedTupleUtilities patterns from @select.
"""
function translate_map_expr(map_expr::Expr, params::Vector{Any}; in_aggregation::Bool=false)
    row_sym, body = extract_lambda_parts(map_expr)
    body = unwrap_block(body)
    sc = translate_select_body(body, params, row_sym; in_aggregation=in_aggregation)
    return select_to_sql(sc)
end

"""
    translate_join_map_expr(map_expr::Expr, params::Vector{Any}, outer_alias::String, inner_alias::String) -> String

Translate a join result selector expression into a SQL SELECT column list with table aliases.
The lambda has two parameters: outer row (_) and inner row (__).
"""
function translate_join_map_expr(map_expr::Expr, params::Vector{Any}, outer_alias::String, inner_alias::String)
    if map_expr.head == :(->)
        param = map_expr.args[1]
        body = map_expr.args[2]
        if param isa Expr && param.head == :tuple && length(param.args) == 2
            outer_sym = param.args[1]
            inner_sym = param.args[2]
            body = unwrap_block(body)
            sc = translate_join_select_body(body, params, outer_sym, inner_sym, outer_alias, inner_alias)
            return select_to_sql(sc)
        end
    end
    throw(TranslationError("Cannot extract join lambda parts", map_expr))
end

function translate_join_select_body(body, params::Vector{Any}, outer_sym::Symbol, inner_sym::Symbol, outer_alias::String, inner_alias::String)
    if body isa Expr && (body.head == :tuple || body.head == :block || body.head == :parameters)
        return translate_join_named_tuple(body, params, outer_sym, inner_sym, outer_alias, inner_alias)
    end
    throw(TranslationError("Unsupported join result selector body", body))
end

function translate_join_named_tuple(body::Expr, params::Vector{Any}, outer_sym::Symbol, inner_sym::Symbol, outer_alias::String, inner_alias::String)
    columns = String[]
    args_list = body.head == :parameters ? body.args : body.args
    for arg in args_list
        arg isa LineNumberNode && continue
        if arg isa Expr && arg.head == :parameters
            inner_sc = translate_join_named_tuple(arg, params, outer_sym, inner_sym, outer_alias, inner_alias)
            append!(columns, inner_sc.columns)
        elseif arg isa Expr && (arg.head == :kw || arg.head == :(=))
            name = string(arg.args[1])
            val = translate_expr(arg.args[2], params, outer_sym; inner_row_sym=inner_sym, outer_alias=outer_alias, inner_alias=inner_alias)
            push!(columns, "$val AS $(quote_identifier(name))")
        elseif is_join_property_access(arg, outer_sym, inner_sym)
            col_name, alias = resolve_join_column(arg, outer_sym, inner_sym, outer_alias, inner_alias)
            push!(columns, col_name)
        else
            sql = translate_expr(arg, params, outer_sym; inner_row_sym=inner_sym, outer_alias=outer_alias, inner_alias=inner_alias)
            push!(columns, sql)
        end
    end
    return SelectClause(columns, false, String[])
end

function is_join_property_access(expr, outer_sym::Symbol, inner_sym::Symbol)
    return expr isa Expr && expr.head == :(.) && length(expr.args) == 2 &&
           (expr.args[1] == outer_sym || expr.args[1] == :_ || expr.args[1] == inner_sym || expr.args[1] == :__) &&
           expr.args[2] isa QuoteNode
end

function resolve_join_column(expr, outer_sym::Symbol, inner_sym::Symbol, outer_alias::String, inner_alias::String)
    obj = expr.args[1]
    col = string(expr.args[2].value)
    if obj == outer_sym || obj == :_
        return ("$(quote_identifier(outer_alias)).$(quote_identifier(col))", col)
    else
        return ("$(quote_identifier(inner_alias)).$(quote_identifier(col))", col)
    end
end

function unwrap_block(expr)
    if expr isa Expr && expr.head == :block
        for arg in expr.args
            if !(arg isa LineNumberNode)
                return unwrap_block(arg)
            end
        end
    end
    return expr
end

"""
    translate_select_body(body, params, row_sym) -> SelectClause

Analyze the body of a map lambda and produce a SelectClause.
"""
function translate_select_body(body, params::Vector{Any}, row_sym::Symbol; in_aggregation::Bool=false)
    # Single column access: i -> i.col
    if is_property_access(body, row_sym)
        col = extract_column_name(body)
        return SelectClause([quote_identifier(col)], false, String[])
    end

    # NamedTuple construction: i -> (a=i.x, b=i.y) or @map({_.name, _.age})
    if body isa Expr && (body.head == :tuple || body.head == :block || body.head == :parameters)
        return translate_named_tuple(body, params, row_sym; in_aggregation=in_aggregation)
    end

    # merge(...) chains from @select and @mutate
    if is_merge_call(body)
        return translate_merge_chain(body, params, row_sym; in_aggregation=in_aggregation)
    end

    # NamedTupleUtilities call directly (e.g. remove without merge)
    if is_ntu_call(body)
        return translate_ntu_call(body, params, row_sym)
    end

    # General expression (computed column)
    sql = translate_expr(body, params, row_sym; in_aggregation=in_aggregation)
    return SelectClause([sql], false, String[])
end

function is_property_access(expr, row_sym::Symbol)
    return expr isa Expr && expr.head == :(.) &&
           length(expr.args) == 2 &&
           (expr.args[1] == row_sym || expr.args[1] == :_) &&
           expr.args[2] isa QuoteNode
end

function extract_column_name(expr)
    return string(expr.args[2].value)
end

function translate_named_tuple(body::Expr, params::Vector{Any}, row_sym::Symbol; in_aggregation::Bool=false)
    columns = String[]
    # Handle :parameters head from @map({_.name, _.age}) curly brace syntax
    if body.head == :parameters
        for arg in body.args
            arg isa LineNumberNode && continue
            if arg isa Expr && arg.head == :kw
                name = string(arg.args[1])
                val = translate_expr(arg.args[2], params, row_sym; in_aggregation=in_aggregation)
                push!(columns, "$val AS $(quote_identifier(name))")
            elseif arg isa Expr && arg.head == :(=)
                name = string(arg.args[1])
                val = translate_expr(arg.args[2], params, row_sym; in_aggregation=in_aggregation)
                push!(columns, "$val AS $(quote_identifier(name))")
            elseif is_property_access(arg, row_sym)
                col = extract_column_name(arg)
                push!(columns, quote_identifier(col))
            else
                sql = translate_expr(arg, params, row_sym; in_aggregation=in_aggregation)
                push!(columns, sql)
            end
        end
        return SelectClause(columns, false, String[])
    end
    for arg in body.args
        arg isa LineNumberNode && continue
        if arg isa Expr && arg.head == :parameters
            # Nested :parameters from @map({...}) curly brace syntax — recurse
            inner_sc = translate_named_tuple(arg, params, row_sym; in_aggregation=in_aggregation)
            append!(columns, inner_sc.columns)
        elseif arg isa Expr && arg.head == :kw
            # Named field: a = expr
            name = string(arg.args[1])
            val = translate_expr(arg.args[2], params, row_sym; in_aggregation=in_aggregation)
            push!(columns, "$val AS $(quote_identifier(name))")
        elseif arg isa Expr && arg.head == :(=)
            name = string(arg.args[1])
            val = translate_expr(arg.args[2], params, row_sym; in_aggregation=in_aggregation)
            push!(columns, "$val AS $(quote_identifier(name))")
        elseif is_property_access(arg, row_sym)
            col = extract_column_name(arg)
            push!(columns, quote_identifier(col))
        else
            sql = translate_expr(arg, params, row_sym; in_aggregation=in_aggregation)
            push!(columns, sql)
        end
    end
    return SelectClause(columns, false, String[])
end

# --- NamedTupleUtilities pattern recognition ---

function is_merge_call(expr)
    if !(expr isa Expr && expr.head == :call)
        return false
    end
    func = expr.args[1]
    # Bare :merge symbol
    if func == :merge
        return true
    end
    # Dotted Base.merge from @mutate expansion
    if func isa Expr && func.head == :(.)
        parts = flatten_dotted_name(func)
        return length(parts) >= 1 && parts[end] == :merge
    end
    return false
end

function is_ntu_call(expr)
    if !(expr isa Expr && expr.head == :call)
        return false
    end
    func = expr.args[1]
    return is_ntu_function(func)
end

function is_ntu_function(func)
    if func isa Expr && func.head == :(.)
        # Check for QueryOperators.NamedTupleUtilities.something
        parts = flatten_dotted_name(func)
        return length(parts) >= 2 && any(p -> p == :NamedTupleUtilities, parts)
    end
    return false
end

function flatten_dotted_name(expr)
    if expr isa Symbol
        return [expr]
    elseif expr isa Expr && expr.head == :(.)
        left = flatten_dotted_name(expr.args[1])
        if expr.args[2] isa QuoteNode
            return vcat(left, [expr.args[2].value])
        end
    end
    return Symbol[]
end

function get_ntu_function_name(func)
    parts = flatten_dotted_name(func)
    return parts[end]
end

function extract_val_symbol(expr)
    # Extract the symbol from Val(:name) or Val{:name}()
    if expr isa Expr && expr.head == :call
        func = expr.args[1]
        if func isa Expr && func.head == :curly && func.args[1] == :Val
            # Val{:name}()
            val_arg = func.args[2]
            if val_arg isa QuoteNode
                return val_arg.value
            end
        elseif func == :Val && length(expr.args) >= 2
            # Val(:name)
            val_arg = expr.args[2]
            if val_arg isa QuoteNode
                return val_arg.value
            end
        end
    end
    return nothing
end

function translate_merge_chain(expr, params::Vector{Any}, row_sym::Symbol; in_aggregation::Bool=false)
    # Recursively unpack merge(merge(..., sel1), sel2)
    sc = SelectClause()

    if !is_merge_call(expr)
        # Base case: not a merge, just a direct NTU call or expression
        if is_ntu_call(expr)
            return translate_ntu_call(expr, params, row_sym)
        else
            sql = translate_expr(expr, params, row_sym; in_aggregation=in_aggregation)
            return SelectClause([sql], false, String[])
        end
    end

    args = expr.args[2:end]  # skip :merge or Base.merge

    columns = String[]
    excludes = String[]
    star = false

    for arg in args
        arg = unwrap_block(arg)
        if arg isa NamedTuple
            # Compiled NamedTuple() literal — empty starting point, skip
            continue
        elseif arg isa Expr && arg.head == :call && arg.args[1] == :NamedTuple && length(arg.args) == 1
            # NamedTuple() — empty starting point, skip
            continue
        elseif arg isa Expr && arg.head == :call && arg.args[1] == :NamedTuple
            continue
        elseif is_merge_call(arg)
            inner_sc = translate_merge_chain(arg, params, row_sym; in_aggregation=in_aggregation)
            append!(columns, inner_sc.columns)
            append!(excludes, inner_sc.excludes)
            star = star || inner_sc.star
        elseif is_ntu_call(arg)
            inner_sc = translate_ntu_call(arg, params, row_sym)
            append!(columns, inner_sc.columns)
            append!(excludes, inner_sc.excludes)
            star = star || inner_sc.star
        elseif is_property_access(arg, row_sym)
            col = extract_column_name(arg)
            push!(columns, quote_identifier(col))
        elseif arg isa Symbol && (arg == row_sym || arg == :_)
            # Row symbol itself (from @mutate: merge(_, (computed=...))) — emit *
            star = true
        elseif arg isa Expr && arg.head == :tuple
            # NamedTuple literal from @mutate, e.g. (total = _.amount * _.price,)
            inner_sc = translate_named_tuple(arg, params, row_sym; in_aggregation=in_aggregation)
            append!(columns, inner_sc.columns)
            # For merge semantics: only EXCLUDE columns that already exist in the source.
            # We detect this by checking if the column name is referenced via _.colname in the value expr.
            for tuple_arg in arg.args
                if tuple_arg isa Expr && (tuple_arg.head == :kw || tuple_arg.head == :(=))
                    col_name = string(tuple_arg.args[1])
                    value_expr = tuple_arg.args[2]
                    if expr_references_column(value_expr, row_sym, col_name)
                        push!(excludes, quote_identifier(col_name))
                    end
                end
            end
        else
            sql = translate_expr(arg, params, row_sym; in_aggregation=in_aggregation)
            push!(columns, sql)
        end
    end

    return SelectClause(columns, star, excludes)
end

function translate_ntu_call(expr, params::Vector{Any}, row_sym::Symbol)
    func = expr.args[1]
    fname = get_ntu_function_name(func)
    args = expr.args[2:end]

    if fname == :select
        # NamedTupleUtilities.select(_, Val(:name))
        val_sym = extract_val_symbol(args[2])
        if val_sym !== nothing
            return SelectClause([quote_identifier(string(val_sym))], false, String[])
        end
    elseif fname == :remove
        # NamedTupleUtilities.remove(_, Val(:name))
        val_sym = extract_val_symbol(args[2])
        if val_sym !== nothing
            return SelectClause(String[], true, [quote_identifier(string(val_sym))])
        end
    elseif fname == :rename
        # NamedTupleUtilities.rename(source, Val(:old), Val(:new))
        # source may be _ or another nested NTU call (for multi-rename)
        old_sym = extract_val_symbol(args[2])
        new_sym = extract_val_symbol(args[3])
        if old_sym !== nothing && new_sym !== nothing
            old_name = quote_identifier(string(old_sym))
            new_name = quote_identifier(string(new_sym))
            # Check if the first arg is a nested NTU call (chained renames)
            inner_source = args[1]
            if is_ntu_call(inner_source)
                inner_sc = translate_ntu_call(inner_source, params, row_sym)
                # Merge: accumulate columns, excludes, and star from inner
                new_columns = vcat(inner_sc.columns, ["$old_name AS $new_name"])
                new_excludes = vcat(inner_sc.excludes, [old_name])
                return SelectClause(new_columns, inner_sc.star || true, new_excludes)
            end
            return SelectClause(["$old_name AS $new_name"], true, [old_name])
        end
    elseif fname == :startswith
        # NamedTupleUtilities.startswith(_, Val(:prefix))
        val_sym = extract_val_symbol(args[2])
        if val_sym !== nothing
            # Use DuckDB COLUMNS regex
            pattern = string(val_sym) * ".*"
            return SelectClause(["COLUMNS('$(escape_sql_string(pattern))')"], false, String[])
        end
    elseif fname == :endswith
        val_sym = extract_val_symbol(args[2])
        if val_sym !== nothing
            pattern = ".*" * string(val_sym)
            return SelectClause(["COLUMNS('$(escape_sql_string(pattern))')"], false, String[])
        end
    elseif fname == :occursin
        val_sym = extract_val_symbol(args[2])
        if val_sym !== nothing
            pattern = ".*" * string(val_sym) * ".*"
            return SelectClause(["COLUMNS('$(escape_sql_string(pattern))')"], false, String[])
        end
    end

    throw(TranslationError("Unsupported NamedTupleUtilities function: $fname", expr))
end

"""
    translate_orderby_expr(expr::Expr, params::Vector{Any}) -> String

Translate an orderby expression (lambda) into a SQL ORDER BY column fragment.
"""
function translate_orderby_expr(expr::Expr, params::Vector{Any})
    row_sym, body = extract_lambda_parts(expr)
    body = unwrap_block(body)
    if is_property_access(body, row_sym)
        return quote_identifier(extract_column_name(body))
    end
    return translate_expr(body, params, row_sym)
end

"""
    translate_groupby_expr(expr::Expr, params::Vector{Any}) -> String

Translate a groupby expression (lambda) into a SQL GROUP BY column fragment.
"""
function translate_groupby_expr(expr::Expr, params::Vector{Any})
    row_sym, body = extract_lambda_parts(expr)
    body = unwrap_block(body)
    if is_property_access(body, row_sym)
        return quote_identifier(extract_column_name(body))
    end
    return translate_expr(body, params, row_sym)
end

# --- Utilities ---

"""
    expr_references_column(expr, row_sym, col_name) -> Bool

Check if an expression contains a property access `row_sym.col_name` (i.e., _.col_name).
Used to determine if a @mutate column replaces an existing column.
"""
function expr_references_column(expr::Expr, row_sym::Symbol, col_name::String)
    if expr.head == :(.) && length(expr.args) == 2
        obj = expr.args[1]
        field = expr.args[2]
        if (obj == row_sym || obj == :_) && field isa QuoteNode && string(field.value) == col_name
            return true
        end
    end
    return any(arg -> expr_references_column(arg, row_sym, col_name), expr.args)
end

function expr_references_column(::Any, ::Symbol, ::String)
    return false
end

function quote_identifier(name::String)
    # DuckDB uses double quotes for identifiers
    escaped = replace(name, "\"" => "\"\"")
    return "\"$escaped\""
end

function escape_sql_string(s::String)
    return replace(s, "'" => "''")
end
