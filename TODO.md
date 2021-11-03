## completenes
- Introdce deform versioning
- Decide on the split: all vs used parameters
  * The configs (`aws/*.yaml` files) have to be groupped into categories:
    . `full` - based on the semi-automated matching between tf and crossplane rpvider specs
    . `used` - based only the values used in input tfstate
    . `minimal` - minimal set that would allow crossplane to claim existing resource and fetch its current parameters
- Introduce a global `deform` configuration file with parameters:
  * crossplane provider: name, version
  * terraform provider: name, version (?)
  * compatible terraform versions
  * compatible crossplane versions
  * compatible deform (api) versions
  * default paths/urls
  * operation modes: full/used/minimal param set conversion; 
- validate against corner cases like:
  * "servicediscovery"
  * "PublicDNSNamespace"

## functionality
- Problem: Some tf resource modules don't include region information explicitly,
  while it's required by crossplane counterparts
  Solution 1:
    In many cases, the region can be extracted from the ARN field. It can be extracted by the helm chart.
- Experiment with identifying possible input variables within a single imported tf module (state)
  * extract all defined string variables, along with their paths
  * sort by value
  * suggest creating variables above threshold of 1 occurence
- (?) With the above list established, generate an XRD+Composition set for the entire module
  * How to treat the single values?
    > Some could be generated based on the module name and some of the identified variables
    > Definitely some (under manual inspection) will be screaming to be renamed...
    > However, that would be completely out of scope. The main value in current project design lies in zero downtime migration.
- add crossplane install scripts/configs
  * kind config file for cluster creation
  * scripted(?) helm installation of crossplane+provider
  * alternatively: use the new installation means used by crossplane itself (see gh issue from a few months ago)
