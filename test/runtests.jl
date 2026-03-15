using TestItemRunner

include("test_queryduckdb.jl")
include("test_query_examples.jl")

@run_package_tests
