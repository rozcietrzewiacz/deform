  .values.root_module
  | ..          # recursively find all, which:
  | .resources? # - have a "resources" field,
  | .[]?        # - and the "resources" field is an array
  | select(type=="object")
  | select(.mode=="managed")
  | select(
      .type
      | test(
          $ARGS.positional[0] # second arg of "deform" (provider name) goes here
          +
          "_*"
        )
    )
  | {type,name, "values":.values}
