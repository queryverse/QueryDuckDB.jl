using TestItemRunner

include("test_queryduckdb.jl")
include("test_query_examples.jl")
include("test_csvfiles.jl")
include("test_excelfiles.jl")
include("test_featherfiles.jl")
include("test_parquetfiles.jl")

@run_package_tests
