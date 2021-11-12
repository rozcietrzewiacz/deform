def camel:
  gsub("_(?<x>[a-z])"; .x | ascii_upcase);

def to_kind:
  sub("(?<x>[a-z])"; .x | ascii_upcase) | camel;

def k8s_name:
  gsub("(.*[:/])*(?<x>[A-Za-z0-9])"; .x) | gsub("_";"-") | ascii_downcase;

def cleanup:
  walk(
    if type == "object" then
      with_entries(
        select(
          #TODO: allow selecting whether or not empty strings should be omitted
          #TODO: utilize "scalars" builtin
          .value != null and .value != [] and .value !={} and .value != ""
        )
      )
    else
      .
    end
  )
;

def provider_extractor:
## empty placeholder
{}
;

def provider_extractor:
# TODO: provider_extractor should be sourced (include ...) from provider config

{
  "metadata": {
    "annotations": {
      "extracted.import.deform.io/awsRegion": ( (.values.arn // "::::" ) | split(":")[3] ),
      "extracted.import.deform.io/awsAccount": ( (.values.arn // "::::" ) | split(":")[4] )
    }
  },
##### TODO: the below snippet has one issue: it diverges from schema defined in xrd!
#  "spec": (
#    if .values.tags?
#    then
#      { "tags": .values.tags | to_entries }
#    else
#      {}
#    end
#  )
}
;

def to_xr:
  .
  | ( .type | to_kind ) as $kind
  | ( .values.id | k8s_name) as $k8s_name
  |
  {
    "apiVersion": "raw.import.deform.io/v1alpha1",
    "kind": $kind,
    "metadata": {
      "name": $k8s_name,
      "annotations": {
        "raw.import.deform.io/type": .type,
        "raw.import.deform.io/name": .name,
        "raw.import.deform.io/address": .address
      }
    },
    "spec": .values
  }
  * ( . | provider_extractor )
;

####### MAIN ######
.
| .[]
| cleanup
| to_xr
