module QueryDuckDBParquetFilesExt

import QueryDuckDB
import ParquetFiles

QueryDuckDB.detect_source(x::ParquetFiles.ParquetFile) = (:parquet, x.filename, Dict{String,Any}())

end
