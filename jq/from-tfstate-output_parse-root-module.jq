  .values.root_module
  | .resources
  | .[]  
  | select(.mode=="managed")
  | {type,name, "values":.values}
