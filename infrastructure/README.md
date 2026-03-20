# Infrastructure (Wave 2)

This wave deploys the **`rag-demo`** namespace (if not already present), **Milvus**, in-cluster **MinIO**, and related PVCs. See [milvus/README.md](milvus/README.md) for storage details.

**RHOAI 3.3:** `DataScienceCluster` / `DSCInitialization` live under [`operators/`](../operators/) (cluster-scoped, Wave 1) so they are not namespaced as `rag-demo` by this kustomization.
