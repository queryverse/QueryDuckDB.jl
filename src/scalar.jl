"""
Push-down for terminal operators — the ones that return a value rather than
another query.

QueryableBackend hands every terminal operator to `execute_scalar`, which
dispatches on the root source type. Specialising it here lets a terminal
operator become part of the SQL instead of pulling every row into Julia first.
Anything not handled falls through to QueryableBackend's default, which
materializes and runs the in-memory implementation — so correctness never
depends on the list below being complete.
"""

function QueryableBackend._execute_scalar(::DuckDBQueryableSource, q::QueryableBackend.QueryableScalar)
    sql = _scalar_sql(q)
    sql === nothing && return QueryableBackend._execute_scalar_fallback(q)
    return _run_scalar(q, sql)
end

# Returns the SQL for a terminal operator, or `nothing` when it has no
# translation and should fall back to the in-memory path.
function _scalar_sql(q::QueryableBackend.QueryableScalar)
    params = Any[]
    inner = generate_sql(q.source)
    append!(params, inner.params)

    body = "($(inner.sql))"

    if q.op == :count
        if isempty(q.args)
            return SQLQuery("SELECT COUNT(*) FROM $body AS scalar_subq", params)
        end
        predicate = translate_filter_expr(q.args[2], params)
        return SQLQuery("SELECT COUNT(*) FROM $body AS scalar_subq WHERE $predicate", params)

    elseif q.op == :any
        if isempty(q.args)
            return SQLQuery("SELECT EXISTS (SELECT 1 FROM $body AS scalar_subq)", params)
        end
        predicate = translate_filter_expr(q.args[2], params)
        return SQLQuery("SELECT EXISTS (SELECT 1 FROM $body AS scalar_subq WHERE $predicate)", params)

    elseif q.op == :all
        predicate = translate_filter_expr(q.args[2], params)
        # True when no row violates the predicate. A NULL result from the
        # predicate is not a violation, matching the in-memory behaviour of
        # treating only an explicit `false` as a failure.
        return SQLQuery("SELECT NOT EXISTS (SELECT 1 FROM $body AS scalar_subq WHERE NOT COALESCE($predicate, TRUE))", params)

    elseif q.op == :first
        if isempty(q.args)
            return SQLQuery("SELECT * FROM $body AS scalar_subq LIMIT 1", params)
        end
        predicate = translate_filter_expr(q.args[2], params)
        return SQLQuery("SELECT * FROM $body AS scalar_subq WHERE $predicate LIMIT 1", params)

    elseif q.op == :element_at
        n = q.args[1]
        n < 1 && error("element_at was called with index $n; the index must be at least 1.")
        return SQLQuery("SELECT * FROM $body AS scalar_subq LIMIT 1 OFFSET $(n - 1)", params)

    elseif q.op == :min_by || q.op == :max_by
        key = translate_orderby_expr(q.args[2], params)
        direction = q.op == :min_by ? "ASC" : "DESC"
        return SQLQuery("SELECT * FROM $body AS scalar_subq ORDER BY $key $direction LIMIT 1", params)
    end

    return nothing
end

# Runs the scalar SQL and unwraps the result the way the corresponding
# in-memory operator would: a bare value for the aggregates, a row for the
# element-returning operators.
function _run_scalar(q::QueryableBackend.QueryableScalar, sql::SQLQuery)
    db = DuckDB.DB()
    con = DBInterface.connect(db)

    try
        register_query_sources(con, q.source)

        result = DBInterface.execute(con, sql.sql, sql.params)
        cols = Tables.columns(result)
        col_names = Tuple(Tables.columnnames(cols))
        columns_nt = NamedTuple{col_names}(Tuple(collect(Tables.getcolumn(cols, n)) for n in col_names))

        nrows = length(col_names) == 0 ? 0 : length(first(columns_nt))

        if q.op in (:count, :any, :all)
            return only(first(columns_nt))
        end

        # Element-returning operators: no row means the sequence was empty or
        # nothing matched, which is an error for every one of them.
        if nrows == 0
            if q.op == :element_at
                error("element_at was called with index $(q.args[1]) on a sequence with fewer elements.")
            elseif isempty(q.args)
                error("$(q.op) was called on a sequence with no elements.")
            else
                error("$(q.op) was called on a sequence with no element matching the predicate.")
            end
        end

        return first(row_iterator(DuckDBQueryResult(columns_nt)))
    finally
        DBInterface.close!(con)
        DBInterface.close!(db)
    end
end
