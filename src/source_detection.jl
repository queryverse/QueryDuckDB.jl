# Default fallback: any Tables-compatible source
detect_source(x) = (:table, nothing, Dict{String,Any}())
