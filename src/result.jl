"""
DuckDBQueryResult — wraps materialized columns from a DuckDB result.
Implements TableTraits and IteratorInterfaceExtensions interfaces.
"""

"""
    DuckDBQueryResult

Holds a NamedTuple of column vectors eagerly materialized from a DuckDB query.
Implements TableTraits column interfaces for efficient downstream consumption.
"""
struct DuckDBQueryResult
    columns::NamedTuple
end

# --- Iteration protocol (required by Tables.jl row iteration path) ---

function Base.iterate(r::DuckDBQueryResult)
    rows = Tables.rows(r.columns)
    return iterate(rows)
end

function Base.iterate(r::DuckDBQueryResult, state)
    rows = Tables.rows(r.columns)
    return iterate(rows, state)
end

Base.length(r::DuckDBQueryResult) = length(first(r.columns))
Base.eltype(r::DuckDBQueryResult) = eltype(Tables.rows(r.columns))

# --- IteratorInterfaceExtensions ---

IteratorInterfaceExtensions.isiterable(::DuckDBQueryResult) = true

function IteratorInterfaceExtensions.getiterator(r::DuckDBQueryResult)
    return Tables.rows(r.columns)
end

# --- TableTraits ---

TableTraits.isiterabletable(::DuckDBQueryResult) = true

TableTraits.supports_get_columns_copy_using_missing(::DuckDBQueryResult) = true

function TableTraits.get_columns_copy_using_missing(r::DuckDBQueryResult)
    return r.columns
end
