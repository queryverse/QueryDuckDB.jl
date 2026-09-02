@testmodule CSVTestData begin
    using CSVFiles, DataFrames

    const df = DataFrame(
        name=["Alice", "Bob", "Charlie", "Diana"],
        age=[30, 25, 35, 28],
        city=["NYC", "LA", "NYC", "LA"]
    )

    const csv_path = joinpath(mktempdir(), "testdata.csv")
    save(csv_path, df)

    const semicolon_path = joinpath(mktempdir(), "testdata_semi.csv")
    save(semicolon_path, df; delim=';')
end

@testitem "csv detect_source" setup=[CSVTestData] begin
    using CSVFiles

    source_type, path, opts = QueryDuckDB.detect_source(load(CSVTestData.csv_path))
    @test source_type == :csv
    @test path == CSVTestData.csv_path
    @test opts["delim"] == ","
    @test opts["header"] == true
end

@testitem "csv detect_source with delimiter" setup=[CSVTestData] begin
    using CSVFiles

    source_type, path, opts = QueryDuckDB.detect_source(load(CSVTestData.semicolon_path, delim=';'))
    @test source_type == :csv
    @test opts["delim"] == ";"
end

@testitem "csv sql generation" begin
    source = QueryDuckDB.DuckDBQueryableSource(
        nothing, :csv, "C:\\data\\test file.csv",
        Dict{String,Any}("delim" => ",", "header" => true),
        nothing)
    from_clause = QueryDuckDB.source_to_from(source)
    @test startswith(from_clause, "read_csv('C:\\data\\test file.csv'")
    @test occursin("delim = ','", from_clause)
    @test occursin("header = true", from_clause)

    # An options-free source falls back to DuckDB's sniffer
    bare = QueryDuckDB.DuckDBQueryableSource(
        nothing, :csv, "data.csv", Dict{String,Any}(), nothing)
    @test QueryDuckDB.source_to_from(bare) == "read_csv_auto('data.csv')"
end

@testitem "csv native filter" setup=[CSVTestData] begin
    using Query, DataFrames, CSVFiles

    result = load(CSVTestData.csv_path) |> @duckdb() |> @filter(_.age > 28) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["Alice", "Charlie"])
end

@testitem "csv native filter with delimiter" setup=[CSVTestData] begin
    using Query, DataFrames, CSVFiles

    result = load(CSVTestData.semicolon_path, delim=';') |> @duckdb() |> @filter(_.city == "LA") |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["Bob", "Diana"])
end
