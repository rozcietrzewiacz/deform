def camel:
  gsub("_(?<x>[a-z])"; .x | ascii_upcase);

def to_kind:
  sub("(?<x>[a-z])"; .x | ascii_upcase) | camel;

def k8s_name:
  gsub("_";"-");

def to_xr:
  (.name | k8s_name) as $name
  | ( .type | to_kind ) as $kind
  |
  {
    "apiVersion": "raw.import.tf.xxx/v1alpha1",
    "kind": $kind,
    "metadata": { 
      "name": $name,
    },
    "spec": .values
  }
;

####### MAIN ######
.
| to_xr
