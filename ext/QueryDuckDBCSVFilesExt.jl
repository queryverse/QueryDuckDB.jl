module QueryDuckDBCSVFilesExt

import QueryDuckDB
import CSVFiles

function QueryDuckDB.detect_source(x::CSVFiles.CSVFile)
    opts = Dict{String,Any}()

    # Delimiter
    opts["delim"] = string(x.delim)

    # Map TextParse keyword options to DuckDB read_csv parameters
    kw = Dict(x.keywords)

    opts["header"] = get(kw, :header_exists, true)

    if haskey(kw, :quotechar)
        opts["quote"] = string(kw[:quotechar])
    end

    if haskey(kw, :escapechar)
        opts["escape"] = string(kw[:escapechar])
    end

    if haskey(kw, :skiplines_begin)
        opts["skip"] = kw[:skiplines_begin]
    end

    if haskey(kw, :nastrings)
        opts["nullstr"] = kw[:nastrings]
    end

    if haskey(kw, :commentchar)
        opts["comment"] = string(kw[:commentchar])
    end

    return (:csv, x.filename, opts)
end

end
