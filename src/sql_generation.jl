"""
SQL Generation — walks the Queryable tree and composes a complete SQL query.
"""

struct SQLQuery
    sql::String
    params::Vector{Any}
end

"""
    generate_sql(q::QueryableBackend.Queryable) -> SQLQuery

Walk the Queryable tree from outermost operation inward, and build a valid SQL query.
"""
function generate_sql(q::QueryableBackend.Queryable)
    nodes = QueryableBackend.walk_tree(q)
    params = Any[]
    return build_sql(nodes, params)
end

function build_sql(nodes::Vector{QueryableBackend.Queryable}, params::Vector{Any})
    # nodes[1] is the source, nodes[2:end] are operations
    source = nodes[1]
    if !(source isa DuckDBQueryableSource)
        throw(TranslationError("Expected DuckDBQueryableSource at root of query tree", :source))
    end

    from_clause = source_to_from(source, "source_tbl")

    # Accumulate SQL clauses
    select_clause = "*"
    where_clauses = String[]
    having_clauses = String[]
    orderby_clauses = String[]
    groupby_clauses = String[]
    limit_clause = nothing
    offset_clause = nothing
    distinct = false
    distinct_on = nothing
    has_groupby = false
    group_key_sql = nothing

    for i in 2:length(nodes)
        node = nodes[i]

        if node isa QueryableBackend.QueryableFilter
            filter_sql = @with GROUP_KEY_SQL => group_key_sql begin
                translate_filter_expr(node.filter_expr, params)
            end
            if has_groupby
                push!(having_clauses, filter_sql)
            else
                push!(where_clauses, filter_sql)
            end

        elseif node isa QueryableBackend.QueryableMap
            if select_clause != "*"
                # We already have a SELECT — need a subquery
                inner_sql = assemble_sql(select_clause, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct, distinct_on)
                from_clause = "($inner_sql) AS subq$(i)"
                select_clause = "*"
                where_clauses = String[]
                having_clauses = String[]
                orderby_clauses = String[]
                groupby_clauses = String[]
                limit_clause = nothing
                offset_clause = nothing
                distinct = false
                distinct_on = nothing
                has_groupby = false
                group_key_sql = nothing
            end
            select_clause = @with GROUP_KEY_SQL => group_key_sql begin
                translate_map_expr(node.f_expr, params; in_aggregation=has_groupby)
            end

        elseif node isa QueryableBackend.QueryableOrderBy
            direction = node.descending ? "DESC" : "ASC"
            if is_identity_lambda(node.keySelector_expr)
                # @order()/@order_descending() sort by whole rows, which DuckDB
                # spells ORDER BY ALL.
                push!(orderby_clauses, "ALL $direction")
            else
                col = translate_orderby_expr(node.keySelector_expr, params)
                push!(orderby_clauses, "$col $direction")
            end

        elseif node isa QueryableBackend.QueryableShuffle
            node.rng === nothing ||
                throw(TranslationError("`@shuffle` with an explicit rng cannot be pushed down to DuckDB, which has its own random number generator. Drop the `rng` argument, or materialize the query first.", :shuffle))
            push!(orderby_clauses, "random()")

        elseif node isa QueryableBackend.QueryableThenBy
            col = translate_orderby_expr(node.keySelector_expr, params)
            direction = node.descending ? "DESC" : "ASC"
            push!(orderby_clauses, "$col $direction")

        elseif node isa QueryableBackend.QueryableTake
            limit_clause = node.n

        elseif node isa QueryableBackend.QueryableDrop
            offset_clause = node.n

        elseif node isa QueryableBackend.QueryableUnique
            key_sql = translate_unique_expr(node.f_expr, params)
            if key_sql === nothing
                distinct = true
            else
                distinct_on = key_sql
            end

        elseif node isa QueryableBackend.QueryableGroupBy
            col = translate_groupby_expr(node.elementSelector_expr, params)
            push!(groupby_clauses, col)
            has_groupby = true
            group_key_sql = col

        elseif node isa QueryableBackend.QueryableGroupByFull
            if is_identity_lambda(node.resultSelector_expr)
                col = translate_groupby_expr(node.elementSelector_expr, params)
                push!(groupby_clauses, col)
                has_groupby = true
                group_key_sql = col
            else
                # Three-argument @groupby: the result selector projects each
                # element of a group. Apply the projection (plus the key
                # column) in a subquery, then GROUP BY the key on top of it.
                key_sym, key_body = extract_lambda_parts(node.elementSelector_expr)
                key_body = unwrap_block(key_body)
                if !is_property_access(key_body, key_sym)
                    throw(TranslationError("Three-argument @groupby with a computed key selector is not supported; apply the transformation with @map before @groupby", :groupby))
                end
                key_col = quote_identifier(extract_column_name(key_body))
                if select_clause != "*"
                    inner_sql = assemble_sql(select_clause, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct, distinct_on)
                    from_clause = "($inner_sql) AS subq$(i)"
                    select_clause = "*"
                    where_clauses = String[]
                    having_clauses = String[]
                    orderby_clauses = String[]
                    groupby_clauses = String[]
                    limit_clause = nothing
                    offset_clause = nothing
                    distinct = false
                    distinct_on = nothing
                end
                proj = translate_map_expr(node.resultSelector_expr, params)
                inner_select = startswith(proj, "*") || occursin(key_col, proj) ? proj : "$proj, $key_col"
                inner_sql = assemble_sql(inner_select, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct, distinct_on)
                from_clause = "($inner_sql) AS grpsubq$(i)"
                select_clause = "*"
                where_clauses = String[]
                having_clauses = String[]
                orderby_clauses = String[]
                groupby_clauses = String[]
                limit_clause = nothing
                offset_clause = nothing
                distinct = false
                distinct_on = nothing
                push!(groupby_clauses, key_col)
                has_groupby = true
                group_key_sql = key_col
            end

        elseif node isa QueryableBackend.QueryableJoin ||
               node isa QueryableBackend.QueryableLeftJoin ||
               node isa QueryableBackend.QueryableRightJoin ||
               node isa QueryableBackend.QueryableFullJoin
            inner_from = inner_source_to_from(node, i, join_kind(node))
            outer_alias = "t1"
            inner_alias = "t2"
            # Extract key selectors with table aliases
            outer_key_col = join_key_sql(node.outerKeySelector_expr, outer_alias, params)
            inner_key_col = join_key_sql(node.innerKeySelector_expr, inner_alias, params)
            from_clause = "$from_clause AS $(quote_identifier(outer_alias)) $(join_kind(node)) $inner_from AS $(quote_identifier(inner_alias)) ON $outer_key_col = $inner_key_col"
            # Translate result selector with join context
            if select_clause == "*"
                select_clause = translate_join_map_expr(node.resultSelector_expr, params, outer_alias, inner_alias)
            end

        elseif node isa QueryableBackend.QueryableConcat ||
               node isa QueryableBackend.QueryableUnion ||
               node isa QueryableBackend.QueryableExcept ||
               node isa QueryableBackend.QueryableIntersect
            # Set operations combine the query built so far with a second one,
            # so everything accumulated is sealed into the left-hand side and
            # the result becomes the new FROM.
            left_sql = assemble_sql(select_clause, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct, distinct_on)
            right_sql = inner_query_sql(node, i, params)

            from_clause = setop_from(node, left_sql, right_sql, i)

            select_clause = "*"
            where_clauses = String[]
            having_clauses = String[]
            orderby_clauses = String[]
            groupby_clauses = String[]
            limit_clause = nothing
            offset_clause = nothing
            distinct = false
            distinct_on = nothing
            has_groupby = false
            group_key_sql = nothing

        elseif node isa QueryableBackend.QueryableCountBy
            col = translate_groupby_expr(node.f_expr, params)
            if select_clause != "*" || !isempty(groupby_clauses)
                inner_sql = assemble_sql(select_clause, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct, distinct_on)
                from_clause = "($inner_sql) AS countby_subq$(i)"
                where_clauses = String[]
                having_clauses = String[]
                orderby_clauses = String[]
                limit_clause = nothing
                offset_clause = nothing
                distinct = false
                distinct_on = nothing
            end
            # The key column is named `key`, matching how the in-memory
            # count_by and summarize name a scalar grouping key.
            select_clause = "$col AS $(quote_identifier("key")), COUNT(*) AS $(quote_identifier("count"))"
            groupby_clauses = [col]
            has_groupby = false
            group_key_sql = col

        elseif node isa QueryableBackend.QueryableTakeLast ||
               node isa QueryableBackend.QueryableDropLast
            inner_sql = assemble_sql(select_clause, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct, distinct_on)
            n = node.n
            comparison = node isa QueryableBackend.QueryableTakeLast ? ">" : "<="
            # Everything accumulated is now inside inner_sql, so the clause
            # state has to start over on top of it.
            where_clauses = String[]
            if n <= 0
                # take_last(0) keeps nothing; drop_last(0) keeps everything.
                from_clause = "($inner_sql) AS lastsubq$(i)"
                node isa QueryableBackend.QueryableTakeLast && push!(where_clauses, "FALSE")
            else
                # Row position is not a SQL concept, so it is materialised with
                # ROW_NUMBER(). COUNT(*) OVER () supplies the total from the
                # same single scan, so the subquery is not repeated and its
                # positional parameters stay in order.
                from_clause = "(SELECT * FROM ($inner_sql) AS lastinner$(i) " *
                    "QUALIFY ROW_NUMBER() OVER () $comparison COUNT(*) OVER () - $n) AS lastsubq$(i)"
            end
            select_clause = "*"
            having_clauses = String[]
            orderby_clauses = String[]
            groupby_clauses = String[]
            limit_clause = nothing
            offset_clause = nothing
            distinct = false
            distinct_on = nothing
            has_groupby = false
            group_key_sql = nothing

        else
            throw_unsupported(node)
        end
    end

    if has_groupby && select_clause == "*"
        throw(TranslationError("@groupby must be followed by @map with aggregations when using the DuckDB backend", :groupby))
    end

    sql = assemble_sql(select_clause, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct, distinct_on)
    return SQLQuery(sql, params)
end

# --- Two-input operators ---

# Each two-input node registers its right-hand source under a name derived from
# its position in the walked tree, so that several of them in one query cannot
# collide. execution.jl walks the tree the same way to register them.
inner_table_name(i::Int) = "source_tbl_$(i)"

join_kind(::QueryableBackend.QueryableJoin) = "INNER JOIN"
join_kind(::QueryableBackend.QueryableLeftJoin) = "LEFT OUTER JOIN"
join_kind(::QueryableBackend.QueryableRightJoin) = "RIGHT OUTER JOIN"
join_kind(::QueryableBackend.QueryableFullJoin) = "FULL OUTER JOIN"

function inner_source_to_from(node, i::Int, label::AbstractString)
    inner_source = node.inner
    inner_source isa DuckDBQueryableSource ||
        throw(TranslationError("The second operand of $label must be a DuckDB source too — add `|> @duckdb()` to it.", :join))
    return source_to_from(inner_source, inner_table_name(i))
end

# A join key qualified by its table alias, so that a column present on both
# sides is unambiguous.
function join_key_sql(expr::Expr, alias::AbstractString, params::Vector{Any})
    sym, body = extract_lambda_parts(expr)
    body = unwrap_block(body)
    if is_property_access(body, sym)
        return quote_identifier(alias) * "." * quote_identifier(extract_column_name(body))
    end
    return translate_expr(body, params, sym)
end

function inner_query_sql(node, i::Int, params::Vector{Any})
    inner_from = inner_source_to_from(node, i, "a set operation")
    return "SELECT * FROM $inner_from"
end

# The key of a `_by` set operation has to be a plain column: the key SQL is
# placed before the left-hand query in the generated text, so a key that
# contributed positional parameters would put them out of order.
function setop_key_sql(node, i::Int)
    sym, body = extract_lambda_parts(node.f_expr)
    body = unwrap_block(body)
    is_property_access(body, sym) ||
        throw(TranslationError("A computed key in a `_by` set operation is not supported by the DuckDB backend; apply the transformation with `@map` first.", :setop))
    return quote_identifier(extract_column_name(body))
end

function setop_from(node::QueryableBackend.QueryableConcat, left_sql, right_sql, i::Int)
    return "(($left_sql) UNION ALL ($right_sql)) AS setop$(i)"
end

function setop_from(node::QueryableBackend.QueryableUnion, left_sql, right_sql, i::Int)
    node.f_expr === nothing && return "(($left_sql) UNION ($right_sql)) AS setop$(i)"
    key = setop_key_sql(node, i)
    return "(SELECT DISTINCT ON ($key) * FROM (($left_sql) UNION ALL ($right_sql)) AS setopinner$(i)) AS setop$(i)"
end

function setop_from(node::QueryableBackend.QueryableExcept, left_sql, right_sql, i::Int)
    node.f_expr === nothing && return "(($left_sql) EXCEPT ($right_sql)) AS setop$(i)"
    key = setop_key_sql(node, i)
    return "(SELECT DISTINCT ON ($key) * FROM ($left_sql) AS setopleft$(i) " *
        "WHERE $key NOT IN (SELECT $key FROM ($right_sql) AS setopright$(i))) AS setop$(i)"
end

function setop_from(node::QueryableBackend.QueryableIntersect, left_sql, right_sql, i::Int)
    node.f_expr === nothing && return "(($left_sql) INTERSECT ($right_sql)) AS setop$(i)"
    key = setop_key_sql(node, i)
    return "(SELECT DISTINCT ON ($key) * FROM ($left_sql) AS setopleft$(i) " *
        "WHERE $key IN (SELECT $key FROM ($right_sql) AS setopright$(i))) AS setop$(i)"
end

function format_sql_option(value)
    if value isa AbstractString
        return "'$(escape_sql_string(value))'"
    elseif value isa Bool
        return value ? "true" : "false"
    elseif value isa Integer
        return string(value)
    elseif value isa AbstractVector
        return "[" * join([format_sql_option(v) for v in value], ", ") * "]"
    else
        return string(value)
    end
end

function source_to_from(source::DuckDBQueryableSource, table_name::String="source_tbl")
    if source.source_type == :csv
        path = escape_sql_string(source.source_path)
        if isempty(source.source_options)
            return "read_csv_auto('$path')"
        end
        parts = ["'$path'"]
        for (k, v) in source.source_options
            push!(parts, "$k = $(format_sql_option(v))")
        end
        return "read_csv(" * join(parts, ", ") * ")"
    elseif source.source_type == :parquet
        path = escape_sql_string(source.source_path)
        return "read_parquet('$path')"
    elseif source.source_type == :feather
        path = escape_sql_string(source.source_path)
        return "read_arrow('$path')"
    elseif source.source_type == :excel
        path = escape_sql_string(source.source_path)
        parts = ["'$path'"]
        for (k, v) in source.source_options
            push!(parts, "$k = $(format_sql_option(v))")
        end
        return "read_xlsx(" * join(parts, ", ") * ")"
    elseif source.source_type == :table
        return quote_identifier(table_name)
    else
        throw(TranslationError("Unknown source type: $(source.source_type)", :source))
    end
end

function assemble_sql(select_clause, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct, distinct_on)
    parts = String[]

    select_kw = distinct_on !== nothing ? "SELECT DISTINCT ON ($distinct_on)" :
                distinct ? "SELECT DISTINCT" : "SELECT"
    push!(parts, "$select_kw $select_clause")
    push!(parts, "FROM $from_clause")

    if !isempty(where_clauses)
        push!(parts, "WHERE " * join(where_clauses, " AND "))
    end
    if !isempty(groupby_clauses)
        push!(parts, "GROUP BY " * join(groupby_clauses, ", "))
    end
    if !isempty(having_clauses)
        push!(parts, "HAVING " * join(having_clauses, " AND "))
    end
    if !isempty(orderby_clauses)
        push!(parts, "ORDER BY " * join(orderby_clauses, ", "))
    end
    if limit_clause !== nothing
        push!(parts, "LIMIT $limit_clause")
    end
    if offset_clause !== nothing
        push!(parts, "OFFSET $offset_clause")
    end

    return join(parts, " ")
end
