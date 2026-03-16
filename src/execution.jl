"""
Execution engine — creates a DuckDB connection, registers data, runs SQL, returns result.
"""

"""
    duckdb_getiterator(query_tree::QueryableBackend.Queryable)

The getiterator callback for DuckDBQueryableSource.
Walks the query tree, generates SQL, executes via DuckDB, and returns a DuckDBQueryResult.
"""
function duckdb_getiterator(query_tree::QueryableBackend.Queryable)
    source = QueryableBackend.get_source(query_tree)
    if !(source isa DuckDBQueryableSource)
        error("Expected DuckDBQueryableSource at root of query tree")
    end

    # Generate SQL
    sql_query = generate_sql(query_tree)

    # Create ephemeral DuckDB connection
    db = DuckDB.DB()
    con = DBInterface.connect(db)

    # Register table data if source is :table
    if source.source_type == :table
        register_source_data(con, source.original_source, "source_tbl")
    end

    # Register inner join table if needed
    nodes = QueryableBackend.walk_tree(query_tree)
    for node in nodes
        if node isa QueryableBackend.QueryableJoin
            inner_source = node.inner
            if inner_source isa DuckDBQueryableSource && inner_source.source_type == :table
                register_source_data(con, inner_source.original_source, "source_tbl_2")
            end
        end
    end

    # Execute query
    result = DBInterface.execute(con, sql_query.sql, sql_query.params)

    # Materialize columns eagerly so DuckDB connection can be released
    cols = Tables.columns(result)
    col_names = Tables.columnnames(cols)
    columns_nt = NamedTuple{Tuple(col_names)}(Tuple(collect(Tables.getcolumn(cols, n)) for n in col_names))

    # Close DuckDB connection
    DBInterface.close!(con)
    DBInterface.close!(db)

    return DuckDBQueryResult(columns_nt)
end

"""
    register_source_data(con, source)

Register the source data with DuckDB using the best available method.
Prefers columnar TableTraits interfaces, falls back to row iteration.
"""
function register_source_data(con, source, table_name::String="source_tbl")
    if TableTraits.supports_get_columns_copy_using_missing(source)
        # Fast columnar path
        columns = TableTraits.get_columns_copy_using_missing(source)
        DuckDB.register_table(con, columns, table_name)
    elseif TableTraits.supports_get_columns_copy(source)
        columns = TableTraits.get_columns_copy(source)
        DuckDB.register_table(con, columns, table_name)
    else
        # Fallback: use Tables.jl columntable (DuckDB.register_table calls this internally)
        DuckDB.register_table(con, source, table_name)
    end
end
