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
    has_groupby = false

    for i in 2:length(nodes)
        node = nodes[i]

        if node isa QueryableBackend.QueryableFilter
            filter_sql = translate_filter_expr(node.filter_expr, params)
            if has_groupby
                push!(having_clauses, filter_sql)
            else
                push!(where_clauses, filter_sql)
            end

        elseif node isa QueryableBackend.QueryableMap
            if select_clause != "*"
                # We already have a SELECT — need a subquery
                inner_sql = assemble_sql(select_clause, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct)
                from_clause = "($inner_sql) AS subq$(i)"
                select_clause = "*"
                where_clauses = String[]
                having_clauses = String[]
                orderby_clauses = String[]
                groupby_clauses = String[]
                limit_clause = nothing
                offset_clause = nothing
                distinct = false
            end
            select_clause = translate_map_expr(node.f_expr, params; in_aggregation=has_groupby)

        elseif node isa QueryableBackend.QueryableOrderBy
            col = translate_orderby_expr(node.keySelector_expr, params)
            direction = node.descending ? "DESC" : "ASC"
            push!(orderby_clauses, "$col $direction")

        elseif node isa QueryableBackend.QueryableThenBy
            col = translate_orderby_expr(node.keySelector_expr, params)
            direction = node.descending ? "DESC" : "ASC"
            push!(orderby_clauses, "$col $direction")

        elseif node isa QueryableBackend.QueryableTake
            limit_clause = node.n

        elseif node isa QueryableBackend.QueryableDrop
            offset_clause = node.n

        elseif node isa QueryableBackend.QueryableUnique
            distinct = true

        elseif node isa QueryableBackend.QueryableGroupBy
            col = translate_groupby_expr(node.elementSelector_expr, params)
            push!(groupby_clauses, col)
            has_groupby = true

        elseif node isa QueryableBackend.QueryableGroupByFull
            col = translate_groupby_expr(node.elementSelector_expr, params)
            push!(groupby_clauses, col)
            has_groupby = true

        elseif node isa QueryableBackend.QueryableJoin
            # Build JOIN clause
            inner_source = node.inner
            inner_from = if inner_source isa DuckDBQueryableSource
                source_to_from(inner_source, "source_tbl_2")
            else
                throw(TranslationError("JOIN inner source must be a DuckDBQueryableSource", :join))
            end
            outer_alias = "t1"
            inner_alias = "t2"
            # Extract key selectors with table aliases
            outer_key_sym, outer_key_body = extract_lambda_parts(node.outerKeySelector_expr)
            outer_key_body = unwrap_block(outer_key_body)
            outer_key_col = if is_property_access(outer_key_body, outer_key_sym)
                quote_identifier(outer_alias) * "." * quote_identifier(extract_column_name(outer_key_body))
            else
                translate_expr(outer_key_body, params, outer_key_sym)
            end
            inner_key_sym, inner_key_body = extract_lambda_parts(node.innerKeySelector_expr)
            inner_key_body = unwrap_block(inner_key_body)
            inner_key_col = if is_property_access(inner_key_body, inner_key_sym)
                quote_identifier(inner_alias) * "." * quote_identifier(extract_column_name(inner_key_body))
            else
                translate_expr(inner_key_body, params, inner_key_sym)
            end
            from_clause = "$from_clause AS $(quote_identifier(outer_alias)) INNER JOIN $inner_from AS $(quote_identifier(inner_alias)) ON $outer_key_col = $inner_key_col"
            # Translate result selector with join context
            if select_clause == "*" && hasproperty(node, :resultSelector_expr)
                select_clause = translate_join_map_expr(node.resultSelector_expr, params, outer_alias, inner_alias)
            end

        else
            throw(TranslationError("Unsupported query operation: $(typeof(node))", :unsupported))
        end
    end

    sql = assemble_sql(select_clause, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct)
    return SQLQuery(sql, params)
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

function assemble_sql(select_clause, from_clause, where_clauses, groupby_clauses, having_clauses, orderby_clauses, limit_clause, offset_clause, distinct)
    parts = String[]

    select_kw = distinct ? "SELECT DISTINCT" : "SELECT"
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
