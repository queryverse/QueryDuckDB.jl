@testmodule TestData begin
    using DataFrames

    const df = DataFrame(
        name=["Alice", "Bob", "Charlie", "Diana"],
        age=[30, 25, 35, 28],
        city=["NYC", "LA", "NYC", "LA"]
    )
end

@testitem "filter" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @filter(_.age > 28) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["Alice", "Charlie"])
end

@testitem "filter string ==" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @filter(_.name == "Bob") |> DataFrame
    @test nrow(result) == 1
    @test result.name[1] == "Bob"
end

@testitem "filter AND" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @filter(_.age > 25 && _.city == "LA") |> DataFrame
    @test nrow(result) == 1
    @test result.name[1] == "Diana"
end

@testitem "map" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @map({_.name, _.age}) |> DataFrame
    @test ncol(result) == 2
    @test nrow(result) == 4
    @test "name" in string.(names(result)) || :name in Symbol.(names(result))
end

@testitem "select explicit columns" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @select(:name, :age) |> DataFrame
    @test ncol(result) == 2
    @test nrow(result) == 4
    @test Set(Symbol.(names(result))) == Set([:name, :age])
end

@testitem "select remove column" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @select(-:city) |> DataFrame
    @test ncol(result) == 2
    @test :city ∉ Symbol.(names(result))
end

@testitem "rename" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @rename(:name => :full_name) |> DataFrame
    @test :full_name in Symbol.(names(result))
    @test :name ∉ Symbol.(names(result))
    @test nrow(result) == 4
end

@testitem "filter then select" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @filter(_.age > 28) |> @select(:name) |> DataFrame
    @test ncol(result) == 1
    @test nrow(result) == 2
    @test Set(result.name) == Set(["Alice", "Charlie"])
end

@testitem "orderby + take" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @orderby(_.age) |> @take(2) |> DataFrame
    @test nrow(result) == 2
    @test result.age[1] <= result.age[2]
    @test result.age[2] <= 28  # youngest two
end

@testitem "orderby_descending + take" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @orderby_descending(_.age) |> @take(1) |> DataFrame
    @test nrow(result) == 1
    @test result.name[1] == "Charlie"
end

@testitem "drop" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @orderby(_.age) |> @drop(2) |> DataFrame
    @test nrow(result) == 2
end

@testitem "unique" setup=[TestData] begin
    using Query, DataFrames

    df = DataFrame(name=["Alice", "Alice", "Bob"], age=[30, 30, 25])
    result = df |> @duckdb() |> @unique() |> DataFrame
    @test nrow(result) == 2

    plan = df |> @duckdb() |> @unique() |> @duckdbplan()
    @test occursin("SELECT DISTINCT ", plan.sql)
    @test !occursin("DISTINCT ON", plan.sql)
end

@testitem "unique with key" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @unique(_.city) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.city) == Set(["NYC", "LA"])

    plan = TestData.df |> @duckdb() |> @unique(_.city) |> @duckdbplan()
    @test occursin("SELECT DISTINCT ON (\"city\") *", plan.sql)
end

@testitem "unique with multiple keys" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @unique({_.name, _.city}) |> DataFrame
    @test nrow(result) == 4

    plan = TestData.df |> @duckdb() |> @unique({_.name, _.city}) |> @duckdbplan()
    @test occursin("DISTINCT ON (\"name\", \"city\")", plan.sql)
end

@testitem "columnar materialization" setup=[TestData] begin
    using Query, DataFrames
    import TableTraits
    import IteratorInterfaceExtensions

    source = QueryDuckDB.create_duckdb_source(TestData.df)
    q = source |> @filter(_.age > 25)
    it = IteratorInterfaceExtensions.getiterator(q)

    @test it isa QueryDuckDB.DuckDBQueryResult
    @test TableTraits.isiterabletable(it) == true
    @test TableTraits.supports_get_columns_copy_using_missing(it) == true

    cols = TableTraits.get_columns_copy_using_missing(it)
    @test cols isa NamedTuple
    @test length(cols.name) == 3  # Alice (30), Charlie (35), Diana (28)
end

@testitem "empty result" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @filter(_.age > 100) |> DataFrame
    @test nrow(result) == 0
end

@testitem "single row result" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> @filter(_.name == "Alice") |> DataFrame
    @test nrow(result) == 1
    @test result.age[1] == 30
end

@testitem "passthrough" setup=[TestData] begin
    using Query, DataFrames

    result = TestData.df |> @duckdb() |> DataFrame
    @test nrow(result) == 4
    @test ncol(result) == 3
end

@testitem "queryplan" setup=[TestData] begin
    using Query, DataFrames
    import QueryableBackend

    plan = TestData.df |> @duckdb() |> @filter(_.age > 28) |> @orderby(_.name) |> @queryplan()
    @test plan isa QueryableBackend.QueryPlan
    @test length(plan.nodes) == 3  # source, filter, orderby

    output = sprint(show, MIME("text/plain"), plan)
    @test occursin("Source", output)
    @test occursin("Filter", output)
    @test occursin("OrderBy", output)

    compact = sprint(show, plan)
    @test occursin("QueryPlan", compact)
    @test occursin("→", compact)
end

@testitem "duckdbplan" setup=[TestData] begin
    using Query, DataFrames

    plan = TestData.df |> @duckdb() |> @filter(_.age > 28) |> @select(:name, :age) |> @duckdbplan()
    @test plan isa QueryDuckDB.DuckDBQueryPlan
    @test occursin("SELECT", plan.sql)
    @test occursin("WHERE", plan.sql)
    @test plan.explain_output === nothing

    output = sprint(show, MIME("text/plain"), plan)
    @test occursin("DuckDB Query Plan", output)
    @test occursin("SQL:", output)
    @test occursin("Parameters:", output)
end

@testitem "duckdbplan explain" setup=[TestData] begin
    using Query, DataFrames

    plan = TestData.df |> @duckdb() |> @filter(_.age > 28) |> @duckdbplan(explain=true)
    @test plan isa QueryDuckDB.DuckDBQueryPlan
    @test plan.explain_output !== nothing
    @test !isempty(plan.explain_output)

    output = sprint(show, MIME("text/plain"), plan)
    @test occursin("Physical Plan:", output)
end

@testitem "duckdbplan explain with join" setup=[TestData] begin
    using Query, DataFrames

    df1 = DataFrame(a=[1, 2, 3], b=[4, 5, 6])
    df2 = DataFrame(c=[2, 3, 4], d=["John", "Sally", "Kirk"])
    plan = df1 |> @duckdb() |> @join(df2 |> @duckdb(), _.a, _.c, {_.a, _.b, __.d}) |> @duckdbplan(explain=true)
    @test plan.explain_output !== nothing
    @test !isempty(plan.explain_output)
end

@testitem "duckdbplan explain with non-literal argument" setup=[TestData] begin
    using Query, DataFrames

    e = true
    plan = TestData.df |> @duckdb() |> @filter(_.age > 28) |> @duckdbplan(explain=e)
    @test plan.explain_output !== nothing
end

@testitem "duckdbplan rejects unknown arguments" begin
    @test_throws LoadError @macroexpand @duckdbplan(explan=true)
end
