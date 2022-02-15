# Overview

Deform is a tool that allows migrating infrastructure management from `terraform` to `crossplane`.
It does this based on the terraform **state** (rather than the `hcl` code).

The imported infrastructure can be directly managed by crossplane. Deform introduces an intermediate layer of resources imported "raw" in crossplane. This just means


# Prerequisites

1. Crossplane installed in your current kubernetes context,
2. Crossplane provider for your target cloud vendor installed and configured,
3. Basic tools installed:
    - `kubectl`
    - `jq`
    - `helm`
    - (optional) [yaml2json](https://github.com/bronze1man/yaml2json) - Only in case you need to generate extra translation configs (see below). But even then, if you don't have it, its functionality will be emulated with `kubectl`.

## Translation configurations

Please refer to [OVERVIEW.md](OVERVIEW.md) for explanation of the functional components of `deform`.
At minimum, you need to understand that `deform` needs a set of **translation configs** to be able to translate terraform resources to their crossplane counterparts. Those configs come shipped with the project, but you can expect them to be incomplete. Fortunately, the deform project also provides tooling to assist the generation of those - again, for the details, please refer to the OVERVIEW.md document.


# Workflow

## Preparation
Before you can use deform, you first need to pull the terraform state to a local file, in a standardized "show" format. You can do that in a single step like this: `terraform show -json > my_tf_module-tf-show.json`, **or** by first saving the `ftstate` with `terraform state pull > my.tfstate.json` and then transforming it to the "show" format: `terraform show -json my.tfstate.json > my_tf_module-tf-show.json`. (You can now delete the intermediate `my.tfstate.json`.)

Once you have the `my_tf_module-tf-show.json` file, it is recommended to move it into the `in` directory, so that you can reference it easily while calling `deform`: `mv /path/to/my/terraform/my_tf_module-tf-show.json in/`


1. Make sure you have the necessary translation configs for your `PROVIDER`, e.g.

```
ls -l aws/
```

2. Call `deform` to generate manifests from your terraform module:
```
./deform in/my_tf_module-tf-show.json
```

3. **Inspect** and then apply the generated manifests. This can be also done automatically in previous step, if you set `AUTOAPPLY` env variable to any value while calling `deform` in previous step.
```
kubectl apply -f out/path_reported_by_deform_in_previous_step/xrds
# inspect...
kubectl apply -f out/path_reported_by_deform_in_previous_step/xrs
# inspect...
kubectl apply -f out/path_reported_by_deform_in_previous_step/compositions
```
   **Note: If you have configured your crossplane provider properly, the cloud resources you have imported with `deform` will now be controlled by the crossplane provider controller.**


# Tools

This project also includes a set of scripts to aid you in generating translation configurations (such as the YAML files under `aws/` directory).
Those are currently a work in progress. You can find them in `helpers.sh`.
