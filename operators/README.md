# Operators (Wave 1)

**RHOAI 3.3 cluster CRs:** This directory includes **`DSCInitialization`** (`default-dsci`) and **`DataScienceCluster`** (`default-dsc`) so GitOps can enforce the 3.3 component layout: **`aipipelines`** (replaces `datasciencepipelines`), **KServe** with RawDeployment / `modelsAsService: Removed`, **no `modelmeshserving`**, and **modelregistry** with `rhoai-model-registries`. If your cluster already created these objects through the console, Argo CD will reconcile toward this spec—resolve conflicts by merging or pausing sync as needed. Internal operator-managed resources use the **`data-science-`** naming prefix (for example the dashboard route **`data-science-gateway`**).

**Policy: Red Hat Certified Operators are the preferred operators.** Use the `redhat-operators` catalog from `openshift-marketplace` wherever the operator is available there.

| Operator | Catalog | Package / Name | Notes |
|----------|---------|----------------|--------|
| **Red Hat OpenShift AI (RHOAI)** | `redhat-operators` | `rhods-operator` | Red Hat certified; preferred. |
| **OpenShift Pipelines (Tekton)** | `redhat-operators` | `openshift-pipelines-operator-rh` | Red Hat certified; preferred. |
| **NVIDIA GPU Operator** | `certified-operators` | `gpu-operator-certified` | Red Hat–documented source (AI Inference Server). Prefer `redhat-operators` + `nvidia-gpu-operator` if your cluster offers it. |

All subscriptions use `sourceNamespace: openshift-marketplace`. To prefer Red Hat certified only, ensure RHOAI and Pipelines use `redhat-operators` (as in this repo) and switch NVIDIA to `redhat-operators` when that catalog lists the NVIDIA GPU Operator for your OpenShift version.
