
# Workflow

1. [2b auto] Pull your terraform state to a local file
```
terraform state pull > here.tfstate.json
```

1. [2b auto] Convert the state file into the standardized "show" format
```
terraform show -json here.tfstate.json > in/my_tf_module-tf-show.json
```
(You can now delete `here.tfstate.json`)

1. Make sure you have the necessary conversion configs for your `PROVIDER`, e.g.

```
ls -l aws/
```

1. Call `deform` to generate manifests from your terraform module:
```
./deform in/my_tf_module-tf-show.json
```

1. **Inspect** and then apply the generated manifests. This can be also done automatically in previous step, if oyu set `AUTOAPPLY` env variable to any value while calling `deform` in previous step.
```
kubectl apply -f out/path_reported_by_deform_in_previous_step/xrds
# inspect...
kubectl apply -f out/path_reported_by_deform_in_previous_step/xrs
# inspect...
kubectl apply -f out/path_reported_by_deform_in_previous_step/compositions
```
   **Note: If you have configured your crossplane provider properly, the cloud resources you have imported with `deform` will now be controlled by the crossplane provider controller.**


# Tools

This project also includes a set of scripts to aid you in generating convertion configurations (such as the YAML files under `aws/` directory.
Those are currently a work in progress. You can find them in `helpers.sh`.
