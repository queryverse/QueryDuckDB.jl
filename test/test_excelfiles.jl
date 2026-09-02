@testmodule ExcelTestData begin
    using ExcelFiles, DataFrames

    const df = DataFrame(
        name=["Alice", "Bob", "Charlie", "Diana"],
        age=[30.0, 25.0, 35.0, 28.0],
        city=["NYC", "LA", "NYC", "LA"]
    )

    const xlsx_path = joinpath(mktempdir(), "testdata.xlsx")
    save(xlsx_path, df; sheetname="Sheet1")
end

@testitem "excel detect_source sheet" setup=[ExcelTestData] begin
    using ExcelFiles

    source_type, path, opts = QueryDuckDB.detect_source(load(ExcelTestData.xlsx_path, "Sheet1"))
    if QueryDuckDB.duckdb_excel_supported()
        @test source_type == :excel
        @test path == ExcelTestData.xlsx_path
        @test opts == Dict{String,Any}("sheet" => "Sheet1", "header" => true)
    else
        @test source_type == :table
    end
end

@testitem "excel detect_source sheet and range" setup=[ExcelTestData] begin
    using ExcelFiles

    source_type, path, opts = QueryDuckDB.detect_source(load(ExcelTestData.xlsx_path, "Sheet1!A1:C3"))
    if QueryDuckDB.duckdb_excel_supported()
        @test source_type == :excel
        @test path == ExcelTestData.xlsx_path
        @test opts == Dict{String,Any}("sheet" => "Sheet1", "range" => "A1:C3", "header" => true)
    else
        @test source_type == :table
    end
end

@testitem "excel sql generation" begin
    source = QueryDuckDB.DuckDBQueryableSource(
        nothing, :excel, "C:\\data\\test file.xlsx",
        Dict{String,Any}("sheet" => "Sheet1", "range" => "A1:C3", "header" => true),
        nothing)
    from_clause = QueryDuckDB.source_to_from(source)
    @test startswith(from_clause, "read_xlsx('C:\\data\\test file.xlsx'")
    @test occursin("sheet = 'Sheet1'", from_clause)
    @test occursin("range = 'A1:C3'", from_clause)
    @test occursin("header = true", from_clause)
end

@testitem "excel fallback for xls" begin
    using ExcelFiles

    @test QueryDuckDB.detect_source(ExcelFiles.ExcelFile("data.xls", "Sheet1", ())) ==
          (:table, nothing, Dict{String,Any}())
    @test QueryDuckDB.detect_source(ExcelFiles.ExcelFile("DATA.XLS", "Sheet1", ()))[1] == :table
end

@testitem "excel fallback for unsupported keywords" setup=[ExcelTestData] begin
    using ExcelFiles

    @test QueryDuckDB.detect_source(load(ExcelTestData.xlsx_path, "Sheet1", colnames=[:a, :b, :c]))[1] == :table
    @test QueryDuckDB.detect_source(load(ExcelTestData.xlsx_path, "Sheet1", skipstartrows=1))[1] == :table
    @test QueryDuckDB.detect_source(load(ExcelTestData.xlsx_path, "Sheet1", header=false))[1] == :table
end

@testitem "excel native filter" setup=[ExcelTestData] begin
    using Query, DataFrames, ExcelFiles

    result = load(ExcelTestData.xlsx_path, "Sheet1") |> @duckdb() |> @filter(_.age > 28) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["Alice", "Charlie"])
end

@testitem "excel native range read" setup=[ExcelTestData] begin
    using Query, DataFrames, ExcelFiles

    result = load(ExcelTestData.xlsx_path, "Sheet1!A1:C3") |> @duckdb() |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["Alice", "Bob"])
end

@testitem "excel fallback query" setup=[ExcelTestData] begin
    using Query, DataFrames, ExcelFiles

    source = load(ExcelTestData.xlsx_path, "Sheet1", colnames=[:a, :b, :c], header=true)
    @test QueryDuckDB.detect_source(source)[1] == :table
    result = source |> @duckdb() |> @filter(_.b > 28) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.a) == Set(["Alice", "Charlie"])
end
