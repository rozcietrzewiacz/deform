def camel:
  gsub("_(?<x>[a-z])"; .x | ascii_upcase);

def to_kind:
  sub("(?<x>[a-z])"; .x | ascii_upcase) | camel;

def k8s_name:
  gsub("_";"-") | ascii_downcase;

def cleanup:
  walk(
    if type == "object" then
      with_entries(
        select(
          #TODO: allow selecting whether or not empty strings should be omitted
          .value != null and .value != [] and .value !={} and .value != ""
        )
      )
    else
      .
    end
  )
;

def to_xr:
  (.name | k8s_name) as $k8s_name
  | ( .type | to_kind ) as $kind
  |
  {
    "apiVersion": "raw.import.deform.io/v1alpha1",
    "kind": $kind,
    "metadata": {
      "name": $k8s_name,
      "annotations": {
        "raw.import.deform.io/type": .type,
        "raw.import.deform.io/name": .name
      }
    },
    "spec": .values
  }
;

####### MAIN ######
.
| .[]
| cleanup
| to_xr
