def camel:
  gsub("_(?<x>[a-z])"; .x|ascii_upcase);

def to_kind:
  sub("(?<x>[a-z])"; .x|ascii_upcase) | camel;

def convert_me:
  .name as $name
  | (.type | to_kind ) as $kind
  #TODO: iterate over all instances
  | .instances[0] as $i
  | (."module"| capture("module\\.(?<tfModule>[a-z_]+)"))
  |
  {
    apiVersion: "tf-import.ex.xxx/v1alpha1",
    kind: $kind,
    metadata: { 
      name: $name,
      labels: {
        tfModule: .tfModule
      }
    },
    spec: $i.attributes
  }
;

####### MAIN ######
.resources[]
#### TODO: iterate over ALL types and derive names automatically
#| select(.type == "aws_caller_identity")
| select(.type == $query)
| convert_me

## TIPS for generating XRD:
# - detect var type using:
##   jq 'map(type)'
##   Input	[0, false, [], {}, null, "hello"]
##   Output 	["number", "boolean", "array", "object", "null", "string"]
#
#[Ref: https://stedolan.github.io/jq/manual/#Builtinoperatorsandfunctions]
