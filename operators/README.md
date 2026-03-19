# Operators (Wave 1)

**Policy: Red Hat Certified Operators are the preferred operators.** Use the `redhat-operators` catalog from `openshift-marketplace` wherever the operator is available there.

| Operator | Catalog | Package / Name | Notes |
|----------|---------|----------------|--------|
| **Red Hat OpenShift AI (RHOAI)** | `redhat-operators` | `rhods-operator` | Red Hat certified; preferred. |
| **OpenShift Pipelines (Tekton)** | `redhat-operators` | `openshift-pipelines-operator-rh` | Red Hat certified; preferred. |
| **NVIDIA GPU Operator** | `certified-operators` | `gpu-operator-certified` | Red Hat–documented source (AI Inference Server). Prefer `redhat-operators` + `nvidia-gpu-operator` if your cluster offers it. |

All subscriptions use `sourceNamespace: openshift-marketplace`. To prefer Red Hat certified only, ensure RHOAI and Pipelines use `redhat-operators` (as in this repo) and switch NVIDIA to `redhat-operators` when that catalog lists the NVIDIA GPU Operator for your OpenShift version.
