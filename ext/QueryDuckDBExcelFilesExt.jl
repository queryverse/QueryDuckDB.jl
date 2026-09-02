module QueryDuckDBExcelFilesExt

import QueryDuckDB
import ExcelFiles

function QueryDuckDB.detect_source(x::ExcelFiles.ExcelFile)
    fallback = (:table, nothing, Dict{String,Any}())

    QueryDuckDB.duckdb_excel_supported() || return fallback

    # DuckDB's excel extension only reads .xlsx (legacy .xls is unsupported)
    endswith(lowercase(x.filename), ".xlsx") || return fallback

    kw = Dict{Symbol,Any}(x.keywords)

    # Only :header maps onto read_xlsx; colnames/skipstartrows/skipstartcols/
    # nrows/ncols (and unknowns) fall back to Julia-side reading
    all(k -> k === :header, keys(kw)) || return fallback

    # header=false: ExcelFiles names columns x1, x2, ...; DuckDB names differ
    get(kw, :header, true) === true || return fallback

    opts = Dict{String,Any}("header" => true)
    if occursin('!', x.range)
        # DuckDB takes the sheet and the cell range as separate options
        sheetname, cellrange = rsplit(x.range, '!'; limit=2)
        opts["sheet"] = String(sheetname)
        opts["range"] = String(cellrange)
    else
        opts["sheet"] = x.range
    end

    return (:excel, x.filename, opts)
end

end
