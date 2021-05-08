  .values.root_module
  | .child_modules[].resources
  | .[]  
  | select(.mode=="managed")
  | {type,name, "values":.values}
