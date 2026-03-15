module QueryDuckDBFeatherFilesExt

import QueryDuckDB
import FeatherFiles

QueryDuckDB.detect_source(x::FeatherFiles.FeatherFile) = (:feather, x.filename, Dict{String,Any}())

end
