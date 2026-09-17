module QueryDuckDB

using Base.ScopedValues: ScopedValue, @with

import QueryableBackend
import IteratorInterfaceExtensions
import TableTraits
import DuckDB
import DBInterface
import Tables
import DataValues

export @duckdb, @duckdbplan, @queryplan

include("source.jl")
include("source_detection.jl")
include("expr_translation.jl")
include("unsupported.jl")
include("sql_generation.jl")
include("execution.jl")
include("result.jl")
include("scalar.jl")
include("plan.jl")

end # module QueryDuckDB
