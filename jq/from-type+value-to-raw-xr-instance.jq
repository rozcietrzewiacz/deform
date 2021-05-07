def camel:
  gsub("_(?<x>[a-z])"; .x | ascii_upcase);

def to_kind:
  sub("(?<x>[a-z])"; .x | ascii_upcase) | camel;

def nonempty:
  if type == "array" or type == "object"
  then 
    any
  else
    . != null
  end
;

def to_xr:
  .name as $name
  | ( .type | to_kind ) as $kind
  |
  {
    "apiVersion": "raw.import.tf.xxx/v1alpha1",
    "kind": $kind,
    "metadata": { 
      "name": ( ."values".id ),
    },
    "spec":{
      "values": .values
    } 
  }
;

####### MAIN ######
.
| to_xr
