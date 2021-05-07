[
  .values.root_module
  | .resources + (.child_modules[].resources)
  | map(select(.mode=="managed"))
  | .[]  
  | {type, "values":.values}
]
#TODO: somehow at this step some modules are duplicated 5 times :shrug:
| unique_by(.type)
| .[]
