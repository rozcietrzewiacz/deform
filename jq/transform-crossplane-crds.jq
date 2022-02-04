def param_summary:
  if type == "object" then
    with_entries( .value = .value.description )
  else
    {}
  end
;

.
# | select(.spec.names.kind == "SNSTopic")
| .spec
| (.versions[] | select(.served == true)) as $version
| $version.schema.openAPIV3Schema.properties as $schema
### TODO: ADD .description
|
{
  kind: .names.kind,
  apiVersion: (.group + "/" + $version.name),
  group: (.group / "." | .[0]),
  id: ((.group / "." | .[0]) + "." + .names.kind),
  description: $version.schema.openAPIV3Schema.description,
  args:
    (
      $schema.spec.properties.forProvider.properties
      | param_summary
    ),
  attrs:
    (
      $schema.status.properties.atProvider.properties
      | param_summary
    )
}
