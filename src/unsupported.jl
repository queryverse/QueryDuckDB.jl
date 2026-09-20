"""
Explanations for query operations the DuckDB backend cannot translate.

`build_sql` used to fail with a bare "Unsupported query operation: <type>",
which told the user nothing about why or what to do instead. Each node that
has no SQL equivalent gets a method here saying what the obstacle is and how
to get the operation done anyway — almost always by materializing the query
first, which moves the rest of the pipeline onto the in-memory backend.
"""

const _MATERIALIZE_HINT = "Materialize the query first, e.g. `… |> DataFrame |> "

"""
    unsupported_reason(node) -> String

A human-readable explanation of why `node` cannot be pushed down to DuckDB.
"""
function unsupported_reason(node::QueryableBackend.Queryable)
    return "the DuckDB backend cannot translate $(typeof(node)) into SQL."
end

unsupported_reason(::QueryableBackend.QueryableChunk) =
    "`@chunk` has no SQL equivalent — SQL has no batching construct. " *
    _MATERIALIZE_HINT * "@chunk(3)`."

unsupported_reason(::QueryableBackend.QueryableAggregateBy) =
    "`@aggregate_by` folds each group with an arbitrary Julia function, which SQL " *
    "cannot express. Use `@groupby` with `@map` and a SQL aggregate such as `sum` " *
    "to push the aggregation down, or " * lowercasefirst(_MATERIALIZE_HINT) * "@aggregate_by(…)`."

unsupported_reason(::QueryableBackend.QueryableTakeWhile) =
    "`@take_while` stops at the first row failing the predicate, which depends on " *
    "row order that SQL does not guarantee. Use `@filter` if you meant to keep every " *
    "matching row, or " * lowercasefirst(_MATERIALIZE_HINT) * "@take_while(…)`."

unsupported_reason(::QueryableBackend.QueryableDropWhile) =
    "`@drop_while` skips a leading run of rows, which depends on row order that SQL " *
    "does not guarantee. Use `@filter` if you meant to drop every matching row, or " *
    lowercasefirst(_MATERIALIZE_HINT) * "@drop_while(…)`."

unsupported_reason(::QueryableBackend.QueryableReverse) =
    "`@reverse` has no SQL equivalent, because a SQL result has no inherent row order " *
    "to reverse. Use `@orderby_descending` on the column you care about, or " *
    lowercasefirst(_MATERIALIZE_HINT) * "@reverse()`."

unsupported_reason(::QueryableBackend.QueryableIndex) =
    "`@index` yields `(index, item)` pairs whose `item` is a whole row, and SQL has no " *
    "nested row values. " * _MATERIALIZE_HINT * "@index()`."

unsupported_reason(::QueryableBackend.QueryableAppend) =
    "`@append` adds a single row at the end, which depends on row order that SQL does " *
    "not guarantee. " * _MATERIALIZE_HINT * "@append(row)`."

unsupported_reason(::QueryableBackend.QueryablePrepend) =
    "`@prepend` adds a single row at the front, which depends on row order that SQL does " *
    "not guarantee. " * _MATERIALIZE_HINT * "@prepend(row)`."

unsupported_reason(::QueryableBackend.QueryableZip) =
    "`@zip` pairs rows by position and yields tuples, which SQL has no value type for. " *
    _MATERIALIZE_HINT * "@zip(other)`."

unsupported_reason(::QueryableBackend.QueryableOfType) =
    "`@of_type` dispatches on Julia types, which a SQL result does not carry. " *
    _MATERIALIZE_HINT * "@of_type(T)`."

unsupported_reason(::QueryableBackend.QueryableCast) =
    "`@cast` converts to a Julia type, which SQL cannot express. Use `@map` with a " *
    "conversion on individual columns, or " * lowercasefirst(_MATERIALIZE_HINT) * "@cast(T)`."

unsupported_reason(::QueryableBackend.QueryableGroupJoin) =
    "`@groupjoin` produces a nested collection per outer row, and SQL has no nested " *
    "row values. Use `@join` with `@groupby`, or " *
    lowercasefirst(_MATERIALIZE_HINT) * "@groupjoin(…)`."

unsupported_reason(::QueryableBackend.QueryableMapMany) =
    "`@mapmany` flattens a collection computed per row, which SQL cannot express in " *
    "general. " * _MATERIALIZE_HINT * "@mapmany(…)`."

"""
    throw_unsupported(node)

Raise a `TranslationError` carrying `unsupported_reason(node)`.
"""
function throw_unsupported(node::QueryableBackend.Queryable)
    throw(TranslationError(unsupported_reason(node), :unsupported))
end
