
# Workflow

1. [2b auto] Convert the state file into the standardized output format: `terraform show -json > in/my_tf_module-tf-show.json`. You can now delete `here.tfstate.json`.
1. Generate "raw XRDs" for your terraform resources using `deform`: 
```
./deform in/my_tf_module-tf-show.json xrd aws | kubectl apply -f -
```
1. Create "raw XRs" that represent 1-to-1 your terraform resources:
```
./deform in/my_tf_module-tf-show.json xr aws | kubectl apply -f -
```
1. [2b auto] Apply Compositions converting your "raw XRs" into Crossplane provider resources:
```
helm template deform-role deform-composer/ --values=aws/AwsIamRole.yaml | kubectl apply -f -
helm template deform-policy deform-composer/ --values= aws/AwsIamPolicy.yaml | kubectl apply -f -
helm template deform-role-policy-attcmnt deform-composer/ --values=aws/AwsIamRolePolicyAttachment.yaml | kubectl apply -f -
...
```
   **Note: If you have configured your crossplane provider properly, the cloud resources you have imported with `deform` will now be controlled by the crossplane provider controller.**


# Tools

This project also includes a set of scripts to aid you in generating convertion configurations (such as the YAML files under `aws/` directory.
Those are currently a work in progress. You can find them in `helpers.sh`.
