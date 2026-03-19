# Standalone Milvus + MinIO (S3-compatible)

Standalone Milvus vector DB for the RAG pipeline. **Argo installs in-cluster MinIO** during the infrastructure sync wave and creates an S3-compatible bucket for Milvus. The repo is **storage-agnostic**: PVCs do not set a storage class by default. Optional overlays target a specific storage class (e.g. IBM Storage Operator).

## Architecture

- **Milvus**: Single replica; etcd for metadata; object storage via MinIO (sync-wave 2).
- **MinIO**: In-cluster S3-compatible object store (sync-wave 1); bucket `milvus-rag` created by a PostSync hook Job.
- **etcd**: Metadata store; data on PVC `milvus-etcd-data`.
- **Milvus local data**: PVC `milvus-data`.
- **MinIO data**: PVC `milvus-minio-data`.

Default credentials (Secret `milvus-s3-credentials`) are `minioadmin` / `minioadmin` so the stack works out of the box. For production, replace the Secret and consider switching to external S3.

## Before first deploy (default: MinIO installed by Argo)

Nothing required. Argo creates:

- ConfigMap `milvus-s3-config` (endpoint `milvus-minio.rag-demo.svc:9000`, bucket `milvus-rag`, SSL false).
- Secret `milvus-s3-credentials` (default `minioadmin`/`minioadmin`).
- MinIO Deployment + Service + PVC; PostSync Job creates the bucket.

For **production**, replace the default Secret and optionally use external S3:

1. **Replace credentials** (e.g. remove `milvus-s3-credentials.yaml` from the kustomization and create the secret manually):

   ```bash
   oc create secret generic milvus-s3-credentials -n rag-demo \
     --from-literal=accesskeyid="YOUR_ACCESS_KEY" \
     --from-literal=secretaccesskey="YOUR_SECRET"
   ```

2. **Optional: use external S3** — Patch ConfigMap `milvus-s3-config` (or use an overlay):

   - `S3_ENDPOINT`: e.g. `s3.amazonaws.com` (no port in host).
   - `S3_PORT`: `443` for AWS S3; `9000` for in-cluster MinIO.
   - `S3_USE_SSL`: `true` for AWS S3; `false` for MinIO.
   - `S3_BUCKET_NAME`: bucket name (create it in S3 first). For MinIO the PostSync Job creates it.

## Optional: Storage class for PVCs

By default, PVCs use the cluster’s default StorageClass.

- **No overlay**: Use the default infrastructure path in ArgoCD.
- **IBM block storage (e.g. OpenShift IBM Storage Operator / fibre channel):**  
  Point the infrastructure Application at `infrastructure/milvus/overlays/ibm-block`, or run:  
  `kustomize build infrastructure/milvus/overlays/ibm-block | oc apply -f -`
- **Other storage:** Copy `overlays/ibm-block`, rename it, and set `storageClassName` in the patch files.

## Optional: External S3 instead of MinIO

To use AWS S3 (or another S3-compatible endpoint) instead of in-cluster MinIO: patch `milvus-s3-config` with your endpoint, port, and SSL, create `milvus-s3-credentials` with your keys, and remove or exclude the MinIO resources (MinIO Deployment, Service, PVC, and `job-minio-create-bucket.yaml`) from the kustomization (e.g. via an overlay that drops them).
