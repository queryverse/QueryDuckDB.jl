# Default fallback: any Tables-compatible source
detect_source(x) = (:table, nothing, Dict{String,Any}())

# DuckDB's excel extension currently crashes at LOAD time with the mingw
# libduckdb build that DuckDB_jll ships on Windows (heap corruption), so
# Excel sources fall back to Julia-side reading there.
duckdb_excel_supported() = !Sys.iswindows()
