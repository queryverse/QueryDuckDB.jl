@testsnippet NewOpData begin
    using Query, QueryDuckDB, DataFrames, DataValues
    import IteratorInterfaceExtensions

    # A Queryable is consumed through getiterator, not Base.collect, so this is
    # how a non-table-shaped result is drained.
    drain(q) = collect(IteratorInterfaceExtensions.getiterator(q))

    people = DataFrame(id=[1, 2, 3], name=["John", "Sally", "Kirk"])
    pets = DataFrame(owner=[1, 3], pet=["Judy", "Ruff"])

    nums = DataFrame(x=[1, 2, 2, 3])
    other = DataFrame(x=[3, 4])

    # Set operations have no guaranteed row order in SQL, so results are
    # compared as sorted vectors.
    sorted(df, col) = sort(collect(skipmissing(df[!, col])))
end

@testitem "left join pushes down to a LEFT OUTER JOIN" setup=[NewOpData] begin
    plan = people |> @duckdb() |> @left_join(pets |> @duckdb(), _.id, _.owner, {_.name, __.pet}) |> @duckdbplan()

    @test occursin("LEFT OUTER JOIN", plan.sql)

    res = people |> @duckdb() |> @left_join(pets |> @duckdb(), _.id, _.owner, {_.name, __.pet}) |> DataFrame

    @test size(res) == (3, 2)
    @test sort(res[!, :name]) == ["John", "Kirk", "Sally"]
    @test count(ismissing, res[!, :pet]) == 1
end

@testitem "right and full joins push down" setup=[NewOpData] begin
    right_plan = people |> @duckdb() |> @right_join(pets |> @duckdb(), _.id, _.owner, {_.name, __.pet}) |> @duckdbplan()
    @test occursin("RIGHT OUTER JOIN", right_plan.sql)

    full_plan = people |> @duckdb() |> @full_join(pets |> @duckdb(), _.id, _.owner, {_.name, __.pet}) |> @duckdbplan()
    @test occursin("FULL OUTER JOIN", full_plan.sql)

    right = people |> @duckdb() |> @right_join(pets |> @duckdb(), _.id, _.owner, {_.name, __.pet}) |> DataFrame
    @test size(right) == (2, 2)

    full = people |> @duckdb() |> @full_join(pets |> @duckdb(), _.id, _.owner, {_.name, __.pet}) |> DataFrame
    @test size(full) == (3, 2)
end

@testitem "outer joins agree with the in-memory backend" setup=[NewOpData] begin
    duck = people |> @duckdb() |> @left_join(pets |> @duckdb(), _.id, _.owner, {_.name, __.pet}) |> DataFrame
    mem = people |> @left_join(pets, _.id, _.owner, {_.name, __.pet}) |> DataFrame

    @test sort(duck[!, :name]) == sort(mem[!, :name])
    @test sorted(duck, :pet) == sorted(mem, :pet)
    @test count(ismissing, duck[!, :pet]) == count(ismissing, mem[!, :pet])
end

@testitem "an outer join needs a DuckDB source on both sides" setup=[NewOpData] begin
    @test_throws QueryDuckDB.TranslationError begin
        people |> @duckdb() |> @left_join(pets, _.id, _.owner, {_.name, __.pet}) |> DataFrame
    end
end

@testitem "concat, union, except and intersect push down" setup=[NewOpData] begin
    @test occursin("UNION ALL", (nums |> @duckdb() |> @concat(other |> @duckdb()) |> @duckdbplan()).sql)
    @test occursin("UNION", (nums |> @duckdb() |> @union(other |> @duckdb()) |> @duckdbplan()).sql)
    @test occursin("EXCEPT", (nums |> @duckdb() |> @except(other |> @duckdb()) |> @duckdbplan()).sql)
    @test occursin("INTERSECT", (nums |> @duckdb() |> @intersect(other |> @duckdb()) |> @duckdbplan()).sql)

    @test sorted(nums |> @duckdb() |> @concat(other |> @duckdb()) |> DataFrame, :x) == [1, 2, 2, 3, 3, 4]
    @test sorted(nums |> @duckdb() |> @union(other |> @duckdb()) |> DataFrame, :x) == [1, 2, 3, 4]
    @test sorted(nums |> @duckdb() |> @except(other |> @duckdb()) |> DataFrame, :x) == [1, 2]
    @test sorted(nums |> @duckdb() |> @intersect(other |> @duckdb()) |> DataFrame, :x) == [3]
end

@testitem "set operations agree with the in-memory backend" setup=[NewOpData] begin
    @test sorted(nums |> @duckdb() |> @concat(other |> @duckdb()) |> DataFrame, :x) ==
          sorted(nums |> @concat(other) |> DataFrame, :x)
    @test sorted(nums |> @duckdb() |> @union(other |> @duckdb()) |> DataFrame, :x) ==
          sorted(nums |> @union(other) |> DataFrame, :x)
    @test sorted(nums |> @duckdb() |> @except(other |> @duckdb()) |> DataFrame, :x) ==
          sorted(nums |> @except(other) |> DataFrame, :x)
    @test sorted(nums |> @duckdb() |> @intersect(other |> @duckdb()) |> DataFrame, :x) ==
          sorted(nums |> @intersect(other) |> DataFrame, :x)
end

@testitem "the _by set operations push down to a key comparison" setup=[NewOpData] begin
    a = DataFrame(k=[1, 2, 3], v=["a", "b", "c"])
    b = DataFrame(k=[2, 3], v=["B", "C"])

    except_plan = a |> @duckdb() |> @except_by(b |> @duckdb(), _.k) |> @duckdbplan()
    @test occursin("NOT IN", except_plan.sql)

    intersect_plan = a |> @duckdb() |> @intersect_by(b |> @duckdb(), _.k) |> @duckdbplan()
    @test occursin("IN (SELECT", intersect_plan.sql)

    @test sorted(a |> @duckdb() |> @except_by(b |> @duckdb(), _.k) |> DataFrame, :k) == [1]
    @test sorted(a |> @duckdb() |> @intersect_by(b |> @duckdb(), _.k) |> DataFrame, :k) == [2, 3]
    @test sorted(a |> @duckdb() |> @union_by(b |> @duckdb(), _.k) |> DataFrame, :k) == [1, 2, 3]
end

@testitem "a computed key in a _by set operation is rejected with an explanation" setup=[NewOpData] begin
    a = DataFrame(k=[1, 2], v=["a", "b"])
    b = DataFrame(k=[2], v=["B"])

    err = try
        a |> @duckdb() |> @except_by(b |> @duckdb(), _.k * 2) |> DataFrame
        nothing
    catch e
        e
    end

    @test err isa QueryDuckDB.TranslationError
    @test occursin("@map", err.msg)
end

@testitem "order and order_descending push down to ORDER BY ALL" setup=[NewOpData] begin
    asc = nums |> @duckdb() |> @order() |> @duckdbplan()
    @test occursin("ORDER BY ALL ASC", asc.sql)

    desc = nums |> @duckdb() |> @order_descending() |> @duckdbplan()
    @test occursin("ORDER BY ALL DESC", desc.sql)

    @test (nums |> @duckdb() |> @order() |> DataFrame)[!, :x] == [1, 2, 2, 3]
    @test (nums |> @duckdb() |> @order_descending() |> DataFrame)[!, :x] == [3, 2, 2, 1]
end

@testitem "orderby with a real key selector is unaffected by order" setup=[NewOpData] begin
    plan = people |> @duckdb() |> @orderby(_.name) |> @duckdbplan()

    @test occursin("ORDER BY", plan.sql)
    @test !occursin("ORDER BY ALL", plan.sql)
    @test (people |> @duckdb() |> @orderby(_.name) |> DataFrame)[!, :name] == ["John", "Kirk", "Sally"]
end

@testitem "shuffle pushes down to ORDER BY random()" setup=[NewOpData] begin
    plan = nums |> @duckdb() |> @shuffle() |> @duckdbplan()
    @test occursin("random()", plan.sql)

    @test sort((nums |> @duckdb() |> @shuffle() |> DataFrame)[!, :x]) == [1, 2, 2, 3]
end

@testitem "shuffle with an explicit rng cannot be pushed down" setup=[NewOpData] begin
    using Random

    err = try
        nums |> @duckdb() |> @shuffle(rng=MersenneTwister(1)) |> DataFrame
        nothing
    catch e
        e
    end

    @test err isa QueryDuckDB.TranslationError
    @test occursin("rng", err.msg)
end

@testitem "take_last and drop_last push down with a window function" setup=[NewOpData] begin
    df = DataFrame(x=[1, 2, 3, 4, 5])

    plan = df |> @duckdb() |> @take_last(2) |> @duckdbplan()
    @test occursin("ROW_NUMBER() OVER ()", plan.sql)
    @test occursin("QUALIFY", plan.sql)

    @test (df |> @duckdb() |> @take_last(2) |> DataFrame)[!, :x] == [4, 5]
    @test (df |> @duckdb() |> @drop_last(2) |> DataFrame)[!, :x] == [1, 2, 3]

    # A count of zero or less behaves as it does in memory.
    @test nrow(df |> @duckdb() |> @take_last(0) |> DataFrame) == 0
    @test (df |> @duckdb() |> @drop_last(0) |> DataFrame)[!, :x] == [1, 2, 3, 4, 5]
end

@testitem "take_last and drop_last agree with the in-memory backend" setup=[NewOpData] begin
    df = DataFrame(x=[1, 2, 3, 4, 5])

    @test (df |> @duckdb() |> @take_last(2) |> DataFrame) == (df |> @take_last(2) |> DataFrame)
    @test (df |> @duckdb() |> @drop_last(2) |> DataFrame) == (df |> @drop_last(2) |> DataFrame)
end

@testitem "count_by pushes down to GROUP BY with COUNT" setup=[NewOpData] begin
    df = DataFrame(k=["a", "b", "a"], v=[1, 2, 3])

    plan = df |> @duckdb() |> @count_by(_.k) |> @duckdbplan()
    @test occursin("COUNT(*)", plan.sql)
    @test occursin("GROUP BY", plan.sql)

    duck = df |> @duckdb() |> @count_by(_.k) |> DataFrame
    mem = df |> @count_by(_.k) |> DataFrame

    @test names(duck) == ["key", "count"]
    @test sort(duck, :key) == sort(mem, :key)
end

@testitem "terminal operators push down into the SQL" setup=[NewOpData] begin
    df = DataFrame(x=[1, 2, 3, 4])

    @test (df |> @duckdb() |> @count()) == 4
    @test (df |> @duckdb() |> @filter(_.x > 2) |> @count()) == 2
    @test (df |> @duckdb() |> @any()) == true
    @test @any(df |> @duckdb(), _.x > 3) == true
    @test @any(df |> @duckdb(), _.x > 9) == false
    @test (df |> @duckdb() |> @all(_.x > 0)) == true
    @test (df |> @duckdb() |> @all(_.x > 1)) == false

    @test (df |> @duckdb() |> @first()).x == 1
    @test (df |> @duckdb() |> @element_at(2)).x == 2
    @test (df |> @duckdb() |> @min_by(_.x)).x == 1
    @test (df |> @duckdb() |> @max_by(_.x)).x == 4
end

@testitem "terminal operators agree with the in-memory backend" setup=[NewOpData] begin
    df = DataFrame(x=[3, 1, 4, 1, 5])

    @test (df |> @duckdb() |> @count()) == (df |> @count())
    @test (df |> @duckdb() |> @any()) == (df |> @any())
    @test (df |> @duckdb() |> @all(_.x > 0)) == (df |> @all(_.x > 0))
    @test (df |> @duckdb() |> @min_by(_.x)).x == (df |> @min_by(_.x)).x
    @test (df |> @duckdb() |> @max_by(_.x)).x == (df |> @max_by(_.x)).x
end

@testitem "count on a DuckDB query used to have no method" setup=[NewOpData] begin
    # Regression: QueryOperators.count had no Queryable method before
    # QueryableScalar, so this call failed outright.
    @test (people |> @duckdb() |> @filter(_.id > 1) |> @count()) == 2
end

@testitem "terminal operators with no SQL translation fall back to memory" setup=[NewOpData] begin
    df = DataFrame(x=[1, 2, 3])

    # aggregate, last, single, contains and sequence_equal are not translated,
    # so they materialize and run the in-memory implementation.
    @test (df |> @duckdb() |> @aggregate((acc, cur) -> (x = acc.x + cur.x,))).x == 6
    @test (df |> @duckdb() |> @last()).x == 3
    @test @single(df |> @duckdb(), _.x == 2).x == 2
    @test (df |> @duckdb() |> @contains((x=2,))) == true
end

@testitem "terminal operators report empty sequences the same way" setup=[NewOpData] begin
    empty = DataFrame(x=Int[])

    @test (empty |> @duckdb() |> @count()) == 0
    @test (empty |> @duckdb() |> @any()) == false
    @test_throws ErrorException (empty |> @duckdb() |> @first())
    @test_throws ErrorException (empty |> @duckdb() |> @min_by(_.x))
    @test_throws ErrorException (empty |> @duckdb() |> @element_at(1))
end

@testitem "operators with no SQL equivalent explain themselves" setup=[NewOpData] begin
    df = DataFrame(x=[1, 2, 3])

    cases = [
        (() -> drain(df |> @duckdb() |> @chunk(2)), "@chunk"),
        (() -> df |> @duckdb() |> @reverse() |> DataFrame, "@reverse"),
        (() -> drain(df |> @duckdb() |> @index()), "@index"),
        (() -> df |> @duckdb() |> @take_while(_.x < 3) |> DataFrame, "@take_while"),
        (() -> df |> @duckdb() |> @drop_while(_.x < 3) |> DataFrame, "@drop_while"),
        (() -> df |> @duckdb() |> @append((x=4,)) |> DataFrame, "@append"),
        (() -> df |> @duckdb() |> @prepend((x=0,)) |> DataFrame, "@prepend"),
        (() -> drain(df |> @duckdb() |> @of_type(NamedTuple)), "@of_type"),
        (() -> drain(df |> @duckdb() |> @cast(Any)), "@cast"),
        (() -> df |> @duckdb() |> @aggregate_by(_.x, 0, (a, c) -> a + c.x) |> DataFrame, "@aggregate_by"),
    ]

    for (f, name) in cases
        err = try
            f()
            nothing
        catch e
            e
        end

        @test err isa QueryDuckDB.TranslationError
        # The message names the operator and suggests a way forward, rather
        # than just printing the node type.
        @test occursin(name, err.msg)
        @test occursin("Materialize", err.msg) || occursin("materialize", err.msg) || occursin("Use ", err.msg)
    end
end

@testitem "DuckDB rows carry DataValue, not missing" setup=[NewOpData] begin
    rows = drain(people |> @duckdb() |> @left_join(pets |> @duckdb(), _.id, _.owner, {_.name, __.pet}))

    @test length(rows) == 3
    @test all(r -> r.pet isa DataValue, rows)
    @test !any(r -> ismissing(r.pet), rows)
    @test count(r -> isna(r.pet), rows) == 1
end

@testitem "a DuckDB result still lands in a DataFrame as missing" setup=[NewOpData] begin
    # The column interface still speaks Missing, which is what TableTraits'
    # _using_missing protocol and table sinks expect.
    res = people |> @duckdb() |> @left_join(pets |> @duckdb(), _.id, _.owner, {_.name, __.pet}) |> DataFrame

    @test count(ismissing, res[!, :pet]) == 1
    @test eltype(res[!, :pet]) == Union{Missing,String}
end

@testitem "a DuckDB result can be piped back through query operators" setup=[NewOpData] begin
    res = people |> @duckdb() |> @filter(_.id > 1) |> @map({_.name})

    # Consuming a DuckDB result through the in-memory operators agrees with
    # running the whole thing in memory.
    again = res |> @order() |> DataFrame
    mem = people |> @filter(_.id > 1) |> @map({_.name}) |> @order() |> DataFrame

    @test again == mem
end
