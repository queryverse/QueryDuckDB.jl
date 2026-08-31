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
