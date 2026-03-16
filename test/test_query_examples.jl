# Tests derived from Query.jl examples, documentation, and common tabular patterns.
# Each test uses the @duckdb() pipeline to execute queries via DuckDB.

# ============================================================
# Test data modules
# ============================================================

@testmodule PeopleData begin
    using DataFrames

    const df = DataFrame(
        name=["John", "Sally", "Kirk"],
        age=[23.0, 42.0, 59.0],
        children=[3, 5, 2]
    )
end

@testmodule JoinData begin
    using DataFrames

    const df1 = DataFrame(a=[1, 2, 3], b=[1.0, 2.0, 3.0])
    const df2 = DataFrame(c=[2, 4, 2], d=["John", "Jim", "Sally"])
end

@testmodule SortData begin
    using DataFrames

    const df = DataFrame(a=[2, 1, 1, 2, 1, 3], b=[2, 2, 1, 1, 3, 2])
end

@testmodule FruitData begin
    using DataFrames

    const df = DataFrame(
        fruit=["Apple", "Banana", "Cherry"],
        amount=[2, 6, 1000],
        price=[1.2, 2.0, 0.4],
        isyellow=[false, true, false]
    )
end

@testmodule GroupData begin
    using DataFrames

    const df = DataFrame(
        name=["John", "Sally", "Kirk"],
        age=[23.0, 42.0, 59.0],
        children=[3, 2, 2]
    )
end

@testmodule DplyrData begin
    using DataFrames

    const df = DataFrame(
        name=repeat(["John", "Sally", "Kirk"], outer=2),
        age=vcat([10.0, 20.0, 30.0], [10.0, 20.0, 30.0] .+ 3),
        children=repeat([3, 2, 2], outer=2),
        state=["a", "a", "a", "b", "b", "b"]
    )
end

@testmodule MissingData begin
    using DataFrames

    const df = DataFrame(
        a=[1, 2, 3],
        b=[4, missing, 5]
    )

    const df2 = DataFrame(
        a=[1, 2, missing],
        b=["One", missing, "Three"]
    )
end

# ============================================================
# Basic filter tests (from Query.jl Example 01 - DataFrame)
# ============================================================

@testitem "filter: age and children (Example 01)" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.age > 30.0 && _.children > 2) |> DataFrame
    @test nrow(result) == 1
    @test result.name[1] == "Sally"
end

@testitem "filter then map lowercase name (Example 01)" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.age > 30.0 && _.children > 2) |> @map({Name=lowercase(_.name)}) |> DataFrame
    @test nrow(result) == 1
    @test result.Name[1] == "sally"
end

# ============================================================
# Select/map tests (from Query.jl documentation - Projecting)
# ============================================================

@testitem "map: select two columns" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @map({_.name, _.age}) |> DataFrame
    @test ncol(result) == 2
    @test nrow(result) == 3
    @test Set(Symbol.(names(result))) == Set([:name, :age])
end

@testitem "map: rename columns" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @map({Name=_.name, Age=_.age}) |> DataFrame
    @test ncol(result) == 2
    @test nrow(result) == 3
    @test Set(Symbol.(names(result))) == Set([:Name, :Age])
    @test result.Name == ["John", "Sally", "Kirk"]
end

# ============================================================
# Filter with string functions
# ============================================================

@testitem "filter: startswith string" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(startswith(_.name, "J")) |> DataFrame
    @test nrow(result) == 1
    @test result.name[1] == "John"
end

@testitem "filter: endswith string" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(endswith(_.name, "rk")) |> DataFrame
    @test nrow(result) == 1
    @test result.name[1] == "Kirk"
end

@testitem "filter: occursin string" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(occursin("all", _.name)) |> DataFrame
    @test nrow(result) == 1
    @test result.name[1] == "Sally"
end

# ============================================================
# Map with string functions
# ============================================================

@testitem "map: uppercase" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @map({Upper=uppercase(_.name)}) |> DataFrame
    @test result.Upper == ["JOHN", "SALLY", "KIRK"]
end

@testitem "map: lowercase" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @map({Lower=lowercase(_.name)}) |> DataFrame
    @test result.Lower == ["john", "sally", "kirk"]
end

@testitem "map: string length" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @map({_.name, NameLen=length(_.name)}) |> DataFrame
    @test result.NameLen == [4, 5, 4]  # John=4, Sally=5, Kirk=4
end

# ============================================================
# Map with arithmetic expressions
# ============================================================

@testitem "map: arithmetic expression" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @map({_.name, kids_per_year=_.children / _.age}) |> DataFrame
    @test nrow(result) == 3
    @test result.kids_per_year[1] ≈ 3 / 23.0
end

@testitem "map: multiply and add" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @map({_.fruit, total=_.amount * _.price}) |> DataFrame
    @test nrow(result) == 3
    @test result.total[1] ≈ 2 * 1.2
    @test result.total[2] ≈ 6 * 2.0
    @test result.total[3] ≈ 1000 * 0.4
end

# ============================================================
# Orderby tests (from Query.jl Example 10)
# ============================================================

@testitem "orderby: ascending by age" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @orderby(_.age) |> DataFrame
    @test result.age == [23.0, 42.0, 59.0]
    @test result.name == ["John", "Sally", "Kirk"]
end

@testitem "orderby_descending: descending by age" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @orderby_descending(_.age) |> DataFrame
    @test result.age == [59.0, 42.0, 23.0]
    @test result.name == ["Kirk", "Sally", "John"]
end

# ============================================================
# Multi-key ordering (from Query.jl Example 18)
# ============================================================

@testitem "orderby_descending + thenby" setup=[SortData] begin
    using Query, DataFrames

    result = SortData.df |> @duckdb() |> @orderby_descending(_.a) |> @thenby(_.b) |> DataFrame
    @test result.a == [3, 2, 2, 1, 1, 1]
    @test result.b == [2, 1, 2, 1, 2, 3]
end

@testitem "orderby + thenby_descending" setup=[SortData] begin
    using Query, DataFrames

    result = SortData.df |> @duckdb() |> @orderby(_.a) |> @thenby_descending(_.b) |> DataFrame
    @test result.a == [1, 1, 1, 2, 2, 3]
    @test result.b == [3, 2, 1, 2, 1, 2]
end

# ============================================================
# Take and drop tests (from Query.jl documentation)
# ============================================================

@testitem "take: first 2 rows" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @orderby(_.age) |> @take(2) |> DataFrame
    @test nrow(result) == 2
    @test result.name == ["John", "Sally"]
end

@testitem "drop: skip 1 row" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @orderby(_.age) |> @drop(1) |> DataFrame
    @test nrow(result) == 2
    @test result.name == ["Sally", "Kirk"]
end

@testitem "orderby + drop + take: paging" setup=[SortData] begin
    using Query, DataFrames

    result = SortData.df |> @duckdb() |> @orderby(_.a) |> @drop(2) |> @take(2) |> DataFrame
    @test nrow(result) == 2
end

# ============================================================
# Unique / distinct (from Query.jl documentation)
# ============================================================

@testitem "unique: distinct cities" begin
    using Query, DataFrames

    df = DataFrame(city=["NYC", "LA", "NYC", "LA", "Chicago"])
    result = df |> @duckdb() |> @unique() |> DataFrame
    @test nrow(result) == 3
end

# ============================================================
# Filter then map (chained operations - common pattern)
# ============================================================

@testitem "filter then map" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.age > 30) |> @map({_.name, _.age}) |> DataFrame
    @test nrow(result) == 2
    @test ncol(result) == 2
    @test Set(result.name) == Set(["Sally", "Kirk"])
end

@testitem "filter then orderby" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.children >= 3) |> @orderby_descending(_.children) |> DataFrame
    @test nrow(result) == 2
    @test result.children == [5, 3]
end

@testitem "map then filter" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @map({_.name, _.age, kids_per_year=_.children / _.age}) |> @filter(_.kids_per_year > 0.1) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["John", "Sally"])
end

# ============================================================
# Select columns by name (from Query.jl @select documentation)
# ============================================================

@testitem "select: single column" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @select(:fruit) |> DataFrame
    @test ncol(result) == 1
    @test names(result) == ["fruit"]
    @test result.fruit == ["Apple", "Banana", "Cherry"]
end

@testitem "select: multiple columns" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @select(:fruit, :price) |> DataFrame
    @test ncol(result) == 2
    @test Set(names(result)) == Set(["fruit", "price"])
end

@testitem "select: remove column" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @select(-:amount) |> DataFrame
    @test "amount" ∉ names(result)
    @test ncol(result) == 3
end

# ============================================================
# Select with predicates (from Query.jl @select documentation)
# ============================================================

@testitem "select: startswith predicate" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @select(startswith("fr")) |> DataFrame
    @test ncol(result) == 1
    @test names(result) == ["fruit"]
end

@testitem "select: endswith predicate" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @select(endswith("e")) |> DataFrame
    @test "price" in names(result)
end

@testitem "select: occursin predicate" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @select(occursin("ui")) |> DataFrame
    @test "fruit" in names(result)
end

# ============================================================
# Rename tests (from Query.jl @rename documentation)
# ============================================================

@testitem "rename: single column" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @rename(:fruit => :food) |> DataFrame
    @test "food" in names(result)
    @test "fruit" ∉ names(result)
    @test nrow(result) == 3
end

@testitem "rename: multiple columns" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @rename(:fruit => :food, :price => :cost) |> DataFrame
    @test "food" in names(result)
    @test "cost" in names(result)
    @test "fruit" ∉ names(result)
    @test "price" ∉ names(result)
end

# ============================================================
# Mutate tests (from Query.jl @mutate documentation)
# ============================================================

@testitem "mutate: computed column" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @mutate(total = _.amount * _.price) |> DataFrame
    @test "total" in names(result)
    @test nrow(result) == 3
    @test result.total[1] ≈ 2 * 1.2
end

@testitem "mutate: modify existing column" setup=[FruitData] begin
    using Query, DataFrames

    result = FruitData.df |> @duckdb() |> @mutate(price = 2 * _.price + _.amount) |> DataFrame
    @test result.price[1] ≈ 2 * 1.2 + 2
    @test result.price[2] ≈ 2 * 2.0 + 6
end

# ============================================================
# Filter with comparison operators
# ============================================================

@testitem "filter: OR condition" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.name == "John" || _.name == "Kirk") |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["John", "Kirk"])
end

@testitem "filter: NOT condition" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(!(_.name == "John")) |> DataFrame
    @test nrow(result) == 2
    @test "John" ∉ result.name
end

@testitem "filter: less than or equal" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.age <= 42.0) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["John", "Sally"])
end

@testitem "filter: not equal" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.name != "John") |> DataFrame
    @test nrow(result) == 2
    @test "John" ∉ result.name
end

@testitem "filter: in operator" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.name in ["John", "Kirk"]) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["John", "Kirk"])
end

# ============================================================
# Comparison chain (a < b < c)
# ============================================================

@testitem "filter: comparison chain" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(25.0 < _.age < 50.0) |> DataFrame
    @test nrow(result) == 1
    @test result.name[1] == "Sally"
end

# ============================================================
# Math functions in map
# ============================================================

@testitem "map: abs function" begin
    using Query, DataFrames

    df = DataFrame(x=[-1, 2, -3, 4])
    result = df |> @duckdb() |> @map({absval=abs(_.x)}) |> DataFrame
    @test result.absval == [1, 2, 3, 4]
end

@testitem "map: round function" begin
    using Query, DataFrames

    df = DataFrame(x=[1.4, 2.5, 3.6, 4.1])
    result = df |> @duckdb() |> @map({rounded=round(_.x)}) |> DataFrame
    @test result.rounded == [1.0, 3.0, 4.0, 4.0]
end

@testitem "map: floor and ceil" begin
    using Query, DataFrames

    df = DataFrame(x=[1.2, 2.7, 3.5])
    result = df |> @duckdb() |> @map({fl=floor(_.x), cl=ceil(_.x)}) |> DataFrame
    @test result.fl == [1.0, 2.0, 3.0]
    @test result.cl == [2.0, 3.0, 4.0]
end

# ============================================================
# ismissing filter (NULL handling)
# ============================================================

@testitem "filter: ismissing" setup=[MissingData] begin
    using Query, DataFrames

    result = MissingData.df |> @duckdb() |> @filter(ismissing(_.b)) |> DataFrame
    @test nrow(result) == 1
    @test result.a[1] == 2
end

@testitem "filter: not ismissing" setup=[MissingData] begin
    using Query, DataFrames

    result = MissingData.df |> @duckdb() |> @filter(!ismissing(_.b)) |> DataFrame
    @test nrow(result) == 2
    @test result.a == [1, 3]
end

# ============================================================
# Coalesce (handle missing values)
# ============================================================

@testitem "map: coalesce missing" setup=[MissingData] begin
    using Query, DataFrames

    result = MissingData.df |> @duckdb() |> @map({_.a, b=coalesce(_.b, 0)}) |> DataFrame
    @test nrow(result) == 3
    @test result.b == [4, 0, 5]
end

# ============================================================
# Groupby + Map aggregation (from Query.jl @groupby docs)
# ============================================================

@testitem "groupby: count per group" setup=[GroupData] begin
    using Query, DataFrames

    result = GroupData.df |> @duckdb() |> @groupby(_.children) |> @map({Key=_.children, Count=length(_.children)}) |> @orderby(_.Key) |> DataFrame
    @test nrow(result) == 2
    @test result.Key == [2, 3]
    @test result.Count == [2, 1]
end

@testitem "groupby: sum per group" begin
    using Query, DataFrames

    df = DataFrame(category=["A", "B", "A", "B", "A"], value=[10, 20, 30, 40, 50])
    result = df |> @duckdb() |> @groupby(_.category) |> @map({cat=_.category, total=sum(_.value)}) |> @orderby(_.cat) |> DataFrame
    @test result.cat == ["A", "B"]
    @test result.total == [90, 60]
end

@testitem "groupby: min and max per group" begin
    using Query, DataFrames

    df = DataFrame(group=["X", "X", "Y", "Y", "Y"], val=[10, 20, 5, 15, 25])
    result = df |> @duckdb() |> @groupby(_.group) |> @map({g=_.group, lo=minimum(_.val), hi=maximum(_.val)}) |> @orderby(_.g) |> DataFrame
    @test result.g == ["X", "Y"]
    @test result.lo == [10, 5]
    @test result.hi == [20, 25]
end

@testitem "groupby: mean per group" begin
    using Query, DataFrames, Statistics

    df = DataFrame(group=["A", "A", "B", "B"], val=[10.0, 20.0, 30.0, 40.0])
    result = df |> @duckdb() |> @groupby(_.group) |> @map({g=_.group, avg=mean(_.val)}) |> @orderby(_.g) |> DataFrame
    @test result.g == ["A", "B"]
    @test result.avg ≈ [15.0, 35.0]
end

# ============================================================
# Split-Apply-Combine / dplyr style (from Query.jl Example 25)
# ============================================================

@testitem "groupby: multi-aggregation dplyr style" setup=[DplyrData] begin
    using Query, DataFrames, Statistics

    result = DplyrData.df |> @duckdb() |> @groupby(_.state) |> @map({
        group=_.state,
        mage=mean(_.age),
        oldest=maximum(_.age),
        youngest=minimum(_.age)
    }) |> @orderby(_.group) |> DataFrame
    @test nrow(result) == 2
    @test result.group == ["a", "b"]
    @test result.mage ≈ [20.0, 23.0]
    @test result.oldest ≈ [30.0, 33.0]
    @test result.youngest ≈ [10.0, 13.0]
end

# ============================================================
# Groupby + filter (having equivalent)
# ============================================================

@testitem "groupby + map + filter (HAVING)" begin
    using Query, DataFrames

    df = DataFrame(a=[1, 1, 2, 3], b=[4, 5, 6, 8])
    result = df |> @duckdb() |> @groupby(_.a) |> @map({a=_.a, avg_b=sum(_.b)}) |> @filter(_.avg_b > 5) |> @orderby_descending(_.avg_b) |> DataFrame
    @test nrow(result) == 3
    @test result.a == [1, 3, 2]
end

# ============================================================
# Join tests (from Query.jl Example 08 / join docs)
# ============================================================

@testitem "join: inner join two dataframes" setup=[JoinData] begin
    using Query, DataFrames

    result = JoinData.df1 |> @duckdb() |> @join(JoinData.df2 |> @duckdb(), _.a, _.c, {_.a, _.b, __.c, __.d}) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.d) == Set(["John", "Sally"])
    @test all(result.a .== 2)
end

# ============================================================
# Complex chained operations (from Query.jl docs combined example)
# ============================================================

@testitem "chain: groupby + map + filter + orderby" begin
    using Query, DataFrames, Statistics

    df = DataFrame(a=[1, 1, 2, 3], b=[4, 5, 6, 8])
    result = df |> @duckdb() |>
        @groupby(_.a) |>
        @map({a=_.a, b=mean(_.b)}) |>
        @filter(_.b > 5) |>
        @orderby_descending(_.b) |>
        DataFrame
    @test nrow(result) == 2
    @test result.a == [3, 2]
    @test result.b ≈ [8.0, 6.0]
end

@testitem "chain: filter + orderby + take" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.age > 20) |> @orderby(_.age) |> @take(2) |> DataFrame
    @test nrow(result) == 2
    @test result.name == ["John", "Sally"]
end

@testitem "chain: filter + map + orderby" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.age > 25) |> @map({_.name, _.age}) |> @orderby_descending(_.age) |> DataFrame
    @test nrow(result) == 2
    @test result.name == ["Kirk", "Sally"]
end

# ============================================================
# Edge cases
# ============================================================

@testitem "empty result from filter" begin
    using Query, DataFrames

    df = DataFrame(x=[1, 2, 3])
    result = df |> @duckdb() |> @filter(_.x > 100) |> DataFrame
    @test nrow(result) == 0
end

@testitem "single column dataframe" begin
    using Query, DataFrames

    df = DataFrame(x=[10, 20, 30])
    result = df |> @duckdb() |> @filter(_.x > 15) |> DataFrame
    @test nrow(result) == 2
    @test result.x == [20, 30]
end

@testitem "passthrough no ops" begin
    using Query, DataFrames

    df = DataFrame(a=[1, 2], b=[3, 4])
    result = df |> @duckdb() |> DataFrame
    @test nrow(result) == 2
    @test ncol(result) == 2
end

@testitem "all rows filtered out then take" begin
    using Query, DataFrames

    df = DataFrame(x=[1, 2, 3])
    result = df |> @duckdb() |> @filter(_.x > 100) |> @take(5) |> DataFrame
    @test nrow(result) == 0
end

@testitem "boolean column filter" begin
    using Query, DataFrames

    df = DataFrame(name=["Alice", "Bob", "Carol"], active=[true, false, true])
    result = df |> @duckdb() |> @filter(_.active == true) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["Alice", "Carol"])
end

# ============================================================
# String operations in map
# ============================================================

@testitem "map: strip whitespace" begin
    using Query, DataFrames

    df = DataFrame(name=["  Alice  ", "  Bob  ", "  Carol  "])
    result = df |> @duckdb() |> @map({trimmed=strip(_.name)}) |> DataFrame
    @test result.trimmed == ["Alice", "Bob", "Carol"]
end

@testitem "map: replace in string" begin
    using Query, DataFrames

    df = DataFrame(text=["hello world", "hello julia", "hello duckdb"])
    result = df |> @duckdb() |> @map({replaced=replace(_.text, "hello", "hi")}) |> DataFrame
    @test result.replaced == ["hi world", "hi julia", "hi duckdb"]
end

# ============================================================
# Multiple filters (AND composition)
# ============================================================

@testitem "multiple filter stages" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.age > 20) |> @filter(_.children > 2) |> DataFrame
    @test nrow(result) == 2
    @test Set(result.name) == Set(["John", "Sally"])
end

# ============================================================
# Large datasets
# ============================================================

@testitem "larger dataset: filter + orderby + take" begin
    using Query, DataFrames

    n = 1000
    df = DataFrame(id=1:n, value=rand(n), category=repeat(["A", "B", "C", "D"], inner=250))
    result = df |> @duckdb() |> @filter(_.id > 500) |> @orderby(_.id) |> @take(10) |> DataFrame
    @test nrow(result) == 10
    @test result.id == 501:510
end

# ============================================================
# Integer types and type preservation
# ============================================================

@testitem "integer arithmetic" begin
    using Query, DataFrames

    df = DataFrame(a=[10, 20, 30], b=[3, 7, 11])
    result = df |> @duckdb() |> @map({_.a, _.b, sum_ab=_.a + _.b, diff=_.a - _.b, prod=_.a * _.b}) |> DataFrame
    @test result.sum_ab == [13, 27, 41]
    @test result.diff == [7, 13, 19]
    @test result.prod == [30, 140, 330]
end

# ============================================================
# Negative numbers and unary minus
# ============================================================

@testitem "map: unary minus" begin
    using Query, DataFrames

    df = DataFrame(x=[1, 2, 3])
    result = df |> @duckdb() |> @map({neg=-_.x}) |> DataFrame
    @test result.neg == [-1, -2, -3]
end

# ============================================================
# Filter + rename (chain different op types)
# ============================================================

@testitem "filter + rename" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @filter(_.age > 30) |> @rename(:name => :person_name) |> DataFrame
    @test nrow(result) == 2
    @test "person_name" in names(result)
    @test "name" ∉ names(result)
end

# ============================================================
# Select then filter
# ============================================================

@testitem "select then filter" setup=[PeopleData] begin
    using Query, DataFrames

    result = PeopleData.df |> @duckdb() |> @select(:name, :age) |> @filter(_.age > 30) |> DataFrame
    @test nrow(result) == 2
    @test ncol(result) == 2
end

# ============================================================
# Orderby with expressions
# ============================================================

@testitem "orderby: by expression" begin
    using Query, DataFrames

    df = DataFrame(name=["Alice", "Bob", "Carol"], score=[80, 95, 70])
    result = df |> @duckdb() |> @orderby(_.score) |> DataFrame
    @test result.name == ["Carol", "Alice", "Bob"]
end

# ============================================================
# Multiple unique/distinct
# ============================================================

@testitem "unique: removes all duplicates" begin
    using Query, DataFrames

    df = DataFrame(a=[1, 1, 2, 2, 3, 3], b=["x", "x", "y", "y", "z", "z"])
    result = df |> @duckdb() |> @unique() |> @orderby(_.a) |> DataFrame
    @test nrow(result) == 3
    @test result.a == [1, 2, 3]
end

# ============================================================
# Filter with modulo
# ============================================================

@testitem "filter: modulo operator" begin
    using Query, DataFrames

    df = DataFrame(x=1:10)
    result = df |> @duckdb() |> @filter(_.x % 2 == 0) |> @orderby(_.x) |> DataFrame
    @test result.x == [2, 4, 6, 8, 10]
end

# ============================================================
# Map: select all original columns plus computed
# ============================================================

@testitem "select columns + filter + orderby + take" begin
    using Query, DataFrames

    df = DataFrame(name=["Alice", "Bob", "Carol", "Dave", "Eve"],
                   score=[85, 92, 78, 96, 88])
    result = df |> @duckdb() |> @filter(_.score >= 85) |> @orderby_descending(_.score) |> @take(3) |> DataFrame
    @test nrow(result) == 3
    @test result.name == ["Dave", "Bob", "Eve"]
end
