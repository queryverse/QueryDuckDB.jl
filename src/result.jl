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

# --- Row iteration ---
#
# DuckDB hands back columns typed `Union{Missing,T}`, but Query's operators use
# DataValue for an absent value and never Missing. Rows are therefore converted
# on the way out, so that piping a DuckDB result back through query operators —
# or comparing it element-wise against the in-memory backend — sees the same
# thing either way.
#
# The *column* interfaces below still speak Missing, because that is what the
# TableTraits `_using_missing` protocol is defined in terms of and what table
# sinks such as DataFrame expect.

_datavalue_fieldtype(::Type{S}) where {S} =
    Missing <: S ? DataValues.DataValue{Base.nonmissingtype(S)} : S

function _datavalue_row_type(::Type{NamedTuple{names,types}}) where {names,types}
    field_types = Tuple{(_datavalue_fieldtype(eltype(t)) for t in types.parameters)...}
    return NamedTuple{names,field_types}
end

_as_field(::Type{DataValues.DataValue{S}}, v) where {S} =
    v === missing ? DataValues.DataValue{S}() : DataValues.DataValue{S}(v)

_as_field(::Type{S}, v) where {S} = v

struct DuckDBRowIterator{T,C<:NamedTuple}
    columns::C
    nrows::Int
end

function row_iterator(r::DuckDBQueryResult)
    C = typeof(r.columns)
    T = _datavalue_row_type(C)
    nrows = length(r.columns) == 0 ? 0 : length(first(r.columns))
    return DuckDBRowIterator{T,C}(r.columns, nrows)
end

Base.eltype(::Type{DuckDBRowIterator{T,C}}) where {T,C} = T

Base.IteratorSize(::Type{<:DuckDBRowIterator}) = Base.HasLength()

Base.length(it::DuckDBRowIterator) = it.nrows

@generated function _build_row(::Type{T}, columns::NamedTuple{names,types}, i::Int) where {T,names,types}
    fields = [:( _as_field($(fieldtype(T, n)), columns.$(names[n])[i]) ) for n in 1:length(names)]
    return :( T(($(fields...),)) )
end

function Base.iterate(it::DuckDBRowIterator{T,C}, i::Int=1) where {T,C}
    i > it.nrows && return nothing
    return _build_row(T, it.columns, i), i + 1
end

# --- Iteration protocol ---

Base.iterate(r::DuckDBQueryResult) = iterate(row_iterator(r))

Base.iterate(r::DuckDBQueryResult, state) = iterate(row_iterator(r), state)

Base.length(r::DuckDBQueryResult) = length(first(r.columns))

Base.eltype(r::DuckDBQueryResult) = eltype(row_iterator(r))

# --- IteratorInterfaceExtensions ---

IteratorInterfaceExtensions.isiterable(::DuckDBQueryResult) = true

function IteratorInterfaceExtensions.getiterator(r::DuckDBQueryResult)
    return row_iterator(r)
end

# --- TableTraits ---

TableTraits.isiterabletable(::DuckDBQueryResult) = true

TableTraits.supports_get_columns_copy_using_missing(::DuckDBQueryResult) = true

function TableTraits.get_columns_copy_using_missing(r::DuckDBQueryResult)
    return r.columns
end
