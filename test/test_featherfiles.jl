@testmodule FeatherTestData begin
    using FeatherFiles, DataFrames

    const df = DataFrame(
        name=["Alice", "Bob", "Charlie", "Diana"],
        age=[30, 25, 35, 28],
        city=["NYC", "LA", "NYC", "LA"]
    )

    const feather_path = joinpath(mktempdir(), "testdata.feather")
    save(feather_path, df)
end

@testitem "feather detect_source falls back to table" setup=[FeatherTestData] begin
    using FeatherFiles

    # DuckDB cannot read Feather v1 files (read_arrow is a non-bundled
    # community extension), so feather sources use the Julia-side fallback.
    @test QueryDuckDB.detect_source(load(FeatherTestData.feather_path)) ==
          (:table, nothing, Dict{String,Any}())
end

@testitem "feather sql generation" begin
    source = QueryDuckDB.DuckDBQueryableSource(
        nothing, :feather, "data.feather", Dict{String,Any}(), nothing)
    @test QueryDuckDB.source_to_from(source) == "read_arrow('data.feather')"
end

@testitem "feather fallback query" setup=[FeatherTestData] begin
    using Query, DataFrames, FeatherFiles

    result = load(FeatherTestData.feather_path) |> @duckdb() |> @filter(_.age > 28) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["Alice", "Charlie"])
end
