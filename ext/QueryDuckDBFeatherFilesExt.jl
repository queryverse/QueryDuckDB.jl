module QueryDuckDBFeatherFilesExt

import QueryDuckDB
import FeatherFiles

# DuckDB cannot read Feather files natively: read_arrow lives in the
# non-bundled nanoarrow community extension, and FeatherFiles writes the
# legacy Feather v1 format, which is not Arrow IPC. Fall back to reading
# the file with FeatherFiles on the Julia side.
QueryDuckDB.detect_source(::FeatherFiles.FeatherFile) = (:table, nothing, Dict{String,Any}())

end
