# QueryDuckDB

[![Project Status: WIP – Initial development is in progress, but there has not yet been a stable, usable release suitable for the public.](https://www.repostatus.org/badges/latest/wip.svg)](https://www.repostatus.org/#wip)
[![Build Status](https://github.com/queryverse/QueryDuckDB.jl/actions/workflows/juliaci.yml/badge.svg?branch=main)](https://github.com/queryverse/QueryDuckDB.jl/actions/workflows/juliaci.yml)
[![codecov](https://codecov.io/gh/queryverse/QueryDuckDB.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/queryverse/QueryDuckDB.jl)

## Overview

QueryDuckDB executes [Query.jl](https://github.com/queryverse/Query.jl)
pipelines with [DuckDB](https://duckdb.org/): inserting `@duckdb()` into a
query pipeline translates the downstream query operators to SQL and runs
them inside DuckDB.

## Getting started

```julia
using QueryDuckDB, Query, DataFrames

df = DataFrame(name=["John", "Sally", "Kirk"], age=[23., 42., 59.], children=[3, 5, 2])

result = df |>
    @duckdb() |>
    @filter(_.age > 30 && _.children > 2) |>
    @map({_.name, _.age}) |>
    DataFrame
```

The whole pipeline downstream of `@duckdb()` is compiled to a single
parameterized SQL statement and executed by an in-process DuckDB database.

## File sources

When a pipeline starts from a file loaded with
[FileIO](https://github.com/JuliaIO/FileIO.jl)-style `load`, QueryDuckDB
pushes the file reading itself into DuckDB where possible, so the data is
never materialized on the Julia side:

```julia
using QueryDuckDB, Query, CSVFiles, DataFrames

result = load("data.csv") |>
    @duckdb() |>
    @filter(_.age > 30) |>
    DataFrame
```

| Package | DuckDB reader |
|---|---|
| [CSVFiles.jl](https://github.com/queryverse/CSVFiles.jl) | `read_csv` |
| [ParquetFiles.jl](https://github.com/queryverse/ParquetFiles.jl) | `read_parquet` |
| [ExcelFiles.jl](https://github.com/queryverse/ExcelFiles.jl) | `read_xlsx` (not on Windows, see below) |
| [FeatherFiles.jl](https://github.com/queryverse/FeatherFiles.jl) | none — Julia-side fallback |

Any other iterable table (a `DataFrame`, a file type not listed above, or a
file with options DuckDB cannot express) is read on the Julia side and
registered with DuckDB as a table — queries always work, push-down is an
optimization.

## Inspecting query plans

`@duckdbplan()` terminates a pipeline and returns the generated SQL instead
of executing it:

```julia
julia> df |> @duckdb() |> @filter(_.age > 30 && _.children > 2) |> @map({_.name, _.age}) |> @duckdbplan()
DuckDB Query Plan
─────────────────
SQL:
  SELECT "name" AS "name", "age" AS "age" FROM "source_tbl" WHERE (("age" > $1) AND ("children" > $2))

Parameters: Any[30, 2]
```

With `explain=true` it also runs DuckDB's `EXPLAIN` to show the physical
execution plan:

```julia
julia> df |> @duckdb() |> @filter(_.age > 30) |> @duckdbplan(explain=true)
DuckDB Query Plan
─────────────────
SQL:
  SELECT * FROM "source_tbl" WHERE ("age" > $1)

Parameters: Any[30]

Physical Plan:
  ┌───────────────────────────┐
  │           FILTER          │
  │    ────────────────────   │
  │        (age > 30.0)       │
  │                           │
  │           ~1 row          │
  └─────────────┬─────────────┘
  ┌─────────────┴─────────────┐
  │       JULIA_TBL_SCAN      │
  │            ...            │
  └───────────────────────────┘
```

`@queryplan()` shows the backend-independent operation tree instead.

## Supported operators

| Query.jl | SQL |
|---|---|
| `@filter` | `WHERE` (or `HAVING` after `@groupby`) |
| `@map`, `@select`, `@rename`, `@mutate` | `SELECT` column list |
| `@orderby`, `@orderby_descending`, `@thenby`, `@thenby_descending` | `ORDER BY` |
| `@take`, `@drop` | `LIMIT`, `OFFSET` |
| `@unique()` | `SELECT DISTINCT` |
| `@unique(_.col)`, `@unique({_.a, _.b})` | `SELECT DISTINCT ON (...)` |
| `@groupby` | `GROUP BY`; use aggregations and `key(_)` in the following `@map` |
| `@join` | `INNER JOIN` |

Common Julia functions are translated to their SQL equivalents
(`uppercase`, `lowercase`, `strip`, `replace`, `startswith`, `occursin`,
`abs`, `round`, `floor`, `ceil`, `coalesce`, `ismissing`, `in`, …), as are
the aggregations `sum`, `mean`, `minimum`, `maximum`, `length` and
`count()`.

## Known limitations

- `@groupjoin` and `@mapmany` are not supported and throw a
  `TranslationError`.
- A `@groupby` must be followed by a `@map` with aggregations; the group
  elements cannot be materialized as arrays. Three-argument `@groupby`
  requires a plain column key.
- `@unique` with a key selector maps to DuckDB's `DISTINCT ON`, which keeps
  an arbitrary row per key unless the input is ordered — Query.jl's
  in-memory implementation keeps the first occurrence.
- Excel push-down is disabled on Windows: loading DuckDB's `excel`
  extension crashes with the mingw libduckdb build that DuckDB_jll ships
  there. Excel files fall back to Julia-side reading (see
  `QueryDuckDB.duckdb_excel_supported`).
- Feather files are always read on the Julia side: DuckDB's `read_arrow`
  lives in a non-bundled community extension, and FeatherFiles writes the
  legacy Feather v1 format.
