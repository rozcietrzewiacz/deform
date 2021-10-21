.values.root_module
| ..          # recursively find all, which:
| .resources? # - have a "resources" field,
| .[]?        # - and the "resources" field is an array
| select(type=="object")
| select(.mode=="managed")
| select(
    .type
    | test(
        $provider # to be passed via --arg provider <value>
        +
        "_*"
      )
  )
| {type,name,address, "values":.values}
