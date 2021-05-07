

#TODO: try to use recursion (..resources[]) instead of splitting into root and children

def root_resources:
  .resources
  ;

def child_resources:
  .child_modules[]
  |.resources
  ;

### MAIN ###
.values
| .root_module
| map(root_resources|select(.mode=="managed")|.type) as $root_types
| map(child_resources|select(.mode=="managed")|.type) as $children_types
| $root_types + $children_types
| unique
|.[]
