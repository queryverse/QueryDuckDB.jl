@testmodule ParquetTestData begin
    using DataFrames, DuckDB, DBInterface

    const df = DataFrame(
        name=["Alice", "Bob", "Charlie", "Diana"],
        age=[30, 25, 35, 28],
        city=["NYC", "LA", "NYC", "LA"]
    )

    # ParquetFiles is load-only, so generate the fixture with DuckDB itself
    const parquet_path = joinpath(mktempdir(), "testdata.parquet")
    let con = DBInterface.connect(DuckDB.DB())
        DBInterface.execute(con, "CREATE TABLE t (name VARCHAR, age INTEGER, city VARCHAR)")
        DBInterface.execute(con, "INSERT INTO t VALUES ('Alice', 30, 'NYC'), ('Bob', 25, 'LA'), ('Charlie', 35, 'NYC'), ('Diana', 28, 'LA')")
        DBInterface.execute(con, "COPY t TO '$(replace(parquet_path, '\\' => '/'))' (FORMAT PARQUET)")
        DBInterface.close!(con)
    end
end

@testitem "parquet detect_source" setup=[ParquetTestData] begin
    using ParquetFiles

    source_type, path, opts = QueryDuckDB.detect_source(load(ParquetTestData.parquet_path))
    @test source_type == :parquet
    @test path == ParquetTestData.parquet_path
    @test opts == Dict{String,Any}()
end

@testitem "parquet sql generation" begin
    source = QueryDuckDB.DuckDBQueryableSource(
        nothing, :parquet, "data.parquet", Dict{String,Any}(), nothing)
    @test QueryDuckDB.source_to_from(source) == "read_parquet('data.parquet')"
end

@testitem "parquet native filter" setup=[ParquetTestData] begin
    using Query, DataFrames, ParquetFiles

    result = load(ParquetTestData.parquet_path) |> @duckdb() |> @filter(_.age > 28) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["Alice", "Charlie"])
end
