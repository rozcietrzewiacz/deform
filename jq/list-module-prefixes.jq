#TODO: <CUT-HERE> -- save as function in a new include file
.values.root_module
  | ..          # recursively find all, which:
  | .resources? # - have a "resources" field,
  | .[]?        # - and the "resources" field is an array
  | select(type=="object")
  | select(.mode=="managed")
# <CUT-HERE> -- END --> use in "jq/from-tfstate-output_parse-modules.jq"
  | .type
  | sub("(?<x>[a-z])_.*"; .x)
# NOTE: This produces an unsorted list of prefixes
