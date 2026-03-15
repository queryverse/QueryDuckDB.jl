"""
Query plan inspection — @duckdbplan() and @queryplan() macros.
"""

"""
    DuckDBQueryPlan

Holds the generated SQL, parameters, and optional DuckDB EXPLAIN output.
"""
struct DuckDBQueryPlan
    sql::String
    params::Vector{Any}
    explain_output::Union{Nothing,String}
end

# --- describe_node for DuckDBQueryableSource ---

function QueryableBackend.describe_node(q::DuckDBQueryableSource)
    if q.source_type == :table
        return "Source: :table"
    else
        return "Source: :$(q.source_type) '$(q.source_path)'"
    end
end

# --- create_duckdb_plan ---

"""
    create_duckdb_plan(query_tree, explain::Bool=false) -> DuckDBQueryPlan

Generate the SQL for the query tree without executing it.
If `explain=true`, also runs DuckDB's EXPLAIN to show the physical execution plan.
"""
function create_duckdb_plan(query_tree::QueryableBackend.Queryable, explain::Bool=false)
    sql_query = generate_sql(query_tree)

    explain_output = nothing
    if explain
        source = QueryableBackend.get_source(query_tree)
        if !(source isa DuckDBQueryableSource)
            error("Expected DuckDBQueryableSource at root of query tree")
        end

        db = DuckDB.DB()
        con = DBInterface.connect(db)

        if source.source_type == :table
            register_source_data(con, source.original_source)
        end

        explain_result = DBInterface.execute(con, "EXPLAIN " * sql_query.sql, sql_query.params)
        rows = collect(Tables.rows(explain_result))
        explain_output = join([row[2] for row in rows], "\n")

        DBInterface.close!(con)
        DBInterface.close!(db)
    end

    return DuckDBQueryPlan(sql_query.sql, sql_query.params, explain_output)
end

# --- show methods ---

function Base.show(io::IO, ::MIME"text/plain", plan::DuckDBQueryPlan)
    println(io, "DuckDB Query Plan")
    println(io, "─────────────────")
    println(io, "SQL:")
    for line in split(plan.sql, "\n")
        println(io, "  ", line)
    end
    println(io)
    if isempty(plan.params)
        println(io, "Parameters: (none)")
    else
        println(io, "Parameters: ", plan.params)
    end
    if plan.explain_output !== nothing
        println(io)
        println(io, "Physical Plan:")
        for line in split(plan.explain_output, "\n")
            println(io, "  ", line)
        end
    end
end

function Base.show(io::IO, plan::DuckDBQueryPlan)
    print(io, "DuckDBQueryPlan(\"", plan.sql, "\")")
end

# --- macros ---

"""
    @queryplan()

Terminal macro for a query pipe chain. Returns a `QueryableBackend.QueryPlan`
showing the generic operation tree.

    df |> @duckdb() |> @filter(_.age > 30) |> @queryplan()
"""
macro queryplan()
    return :(i -> QueryableBackend.queryplan(i))
end

"""
    @duckdbplan()
    @duckdbplan(explain=true)

Terminal macro for a query pipe chain. Returns a `DuckDBQueryPlan`
showing the generated SQL query.

With `explain=true`, also creates an ephemeral DuckDB connection and
runs `EXPLAIN` to show the physical execution plan.

    df |> @duckdb() |> @filter(_.age > 30) |> @duckdbplan()
    df |> @duckdb() |> @filter(_.age > 30) |> @duckdbplan(explain=true)
"""
macro duckdbplan(args...)
    explain = false
    for arg in args
        if arg isa Expr && arg.head == :(=) && arg.args[1] == :explain
            explain = arg.args[2]
        end
    end
    return :(i -> QueryDuckDB.create_duckdb_plan(i, $explain))
end
