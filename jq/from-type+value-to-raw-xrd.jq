def camel:  # a_bo_co -> aBoCo
  gsub("_(?<x>[a-z])"; .x | ascii_upcase);

def to_kind: # alBoCo -> AlBoCo
  sub("(?<x>[a-z])"; .x | ascii_upcase) | camel;

def to_singular: # AlBoCo -> alboco
  to_kind | ascii_downcase;

def nonempty:
  if type == "array" or type == "object"
  then
    any
  else
    . != null
  end
;

def to_plural: # policy -> policies; bucket -> buckets
  sub("y$"; "ie")+"s";

def list_types:
  if type == "object" then
    {
      "type": ( . | type),
      "properties": (.|with_entries(.value |= list_types)),
      #XXX DBG "PATH": "A",
    }
  elif type == "array" then
    {
      "type": ( . | type),
      #"items": (.[0] | list_types),
      "items":
      (
        if (.[0] | type) == "string" then
          {
            "type":"string"
          }
        else
          .[0] | with_entries(select(.value|nonempty)) | list_types
        end
      ),
      #XXX DBG "PATH": "B",
    }
  elif type != "null" then
    {
      "type": ( . | type),
      #XXX DBG "PATH": "C",
    }
  else
    empty
  end
;

def nlist:
  if type == "object" then
    with_entries(
      select(.value|nonempty)
      | .value |= (
           list_types
      )
    )
  else
   "XXXXXXXXXXXXXXXXXXXXXXXX-BUUUUUG"
  end
;

def merge_same_types:
  .
  | group_by(.type)
  | map(reduce .[] as $p ({}; . * $p))
  | .[]
;

def to_xrd:
  .name as $name
  | ( .type | to_kind ) as $kind
  | ( $kind | to_singular ) as $singular
  | ( $singular | to_plural ) as $plural
  |
  {
    "apiVersion": "apiextensions.crossplane.io/v1",
    "kind": "CompositeResourceDefinition",
    "metadata": {
      "name": ($plural + ".raw.import.tf.xxx")
    },
    "spec": {
      "group": "raw.import.tf.xxx",
      "names": {
        "kind": $kind,
        "plural": $plural
      },
      "versions": [
        {
          "name": "v1alpha1",
          "served": true,
          "referenceable": true,
          "schema": {
            "openAPIV3Schema": {
              "type": "object",
              "properties": {
                "spec": {
                  "type": "object",
                  "properties": (
                    ."values"
                    | nlist
                  )
                }
              }
            }#openAPIV3Schema
          }#schema
        }]
    }#spec
  }
;

####### MAIN ######
.
| merge_same_types
| to_xrd
