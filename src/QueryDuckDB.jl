module QueryDuckDB

import QueryableBackend
import QueryOperators
import IteratorInterfaceExtensions
import TableTraits
import DuckDB
import DBInterface
import Tables

export @duckdb, @duckdbplan, @queryplan

include("source.jl")
include("source_detection.jl")
include("expr_translation.jl")
include("sql_generation.jl")
include("execution.jl")
include("result.jl")
include("plan.jl")

end # module QueryDuckDB
