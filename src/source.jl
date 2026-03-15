struct DuckDBQueryableSource <: QueryableBackend.Queryable
    original_source
    source_type::Symbol   # :csv, :parquet, :feather, :table
    source_path           # file path string or nothing
    source_options::Dict{String,Any}
    getiterator
end

# DuckDBQueryableSource is a leaf node in the query tree (like QueryableSource)
QueryableBackend.get_source(q::DuckDBQueryableSource) = q
QueryableBackend._collect_nodes!(nodes, q::DuckDBQueryableSource) = push!(nodes, q)

"""
    @duckdb()

Macro to mark the beginning of a DuckDB-backed query pipeline.
Place it after the data source in a pipe chain:

    df |> @duckdb() |> @filter(_.x > 5) |> @select(:a, :b) |> DataFrame
"""
macro duckdb()
    return :(i -> QueryDuckDB.create_duckdb_source(i))
end

function create_duckdb_source(source)
    source_type, source_path, source_options = detect_source(source)
    return DuckDBQueryableSource(source, source_type, source_path, source_options, duckdb_getiterator)
end
