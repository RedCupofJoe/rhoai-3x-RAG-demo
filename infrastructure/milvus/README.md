# Standalone Milvus + S3

Standalone Milvus vector DB for the RAG pipeline. Object storage is **S3** (or S3-compatible); **no MinIO** deployment. The repo is **storage-agnostic**: PVCs do not set a storage class by default (cluster default is used). Optional overlays let you target a specific storage class (e.g. IBM Storage Operator).

## Architecture

- **Milvus**: Single replica; etcd for metadata, S3 for object storage.
- **etcd**: Metadata store; data on PVC `milvus-etcd-data`.
- **Milvus local data**: PVC `milvus-data`.
- **Object storage**: S3 — configure endpoint and SSL in ConfigMap `milvus-s3-config`; credentials in Secret `milvus-s3-credentials`.

## Before first deploy

1. **Create the S3 credentials Secret** (do not commit real credentials):

   ```bash
   oc create secret generic milvus-s3-credentials -n rag-demo \
     --from-literal=accesskeyid="YOUR_S3_ACCESS_KEY" \
     --from-literal=secretaccesskey="YOUR_S3_SECRET_KEY"
   ```

2. **Set S3 endpoint, port, and bucket** in ConfigMap `milvus-s3-config` (or patch after deploy):

   - `S3_ENDPOINT`: e.g. `s3.amazonaws.com` or your S3-compatible endpoint host (no port).
   - `S3_PORT`: `443` for AWS S3 (HTTPS); `9000` for MinIO in-cluster.
   - `S3_USE_SSL`: `true` or `false`.
   - `S3_BUCKET_NAME`: bucket for Milvus (create the bucket in S3 first).

   Milvus uses `MINIO_ADDRESS` (host) and `MINIO_PORT`; without `S3_PORT`, it defaults to 9000 and S3 (port 443) will fail.

## Optional: Storage class for PVCs

By default, PVCs use the cluster’s default StorageClass. During deployment you can choose to use a specific storage class (e.g. for fibre channel or other backends).

- **No overlay**: Use the default infrastructure path in ArgoCD; PVCs get the cluster default.
- **IBM block storage (e.g. OpenShift IBM Storage Operator / fibre channel):**  
  The **OpenShift IBM Storage Operator** can create StorageClasses for fibre channel and other storage. To use one (e.g. `ibm-block`) for Milvus PVCs, use the optional overlay:
  - **ArgoCD:** Point the infrastructure Application at `infrastructure/milvus/overlays/ibm-block` instead of `infrastructure`, or apply the overlay once then manage with the base.
  - **Manual:** `kustomize build infrastructure/milvus/overlays/ibm-block | oc apply -f -`
- **Other storage:** Copy `overlays/ibm-block`, rename it, and change `storageClassName` in the patch files to your StorageClass name.

## Optional: MinIO instead of S3

To use MinIO in-cluster instead of S3, add a MinIO Deployment and Service, create a PVC for MinIO data, and set `milvus-s3-config` `S3_ENDPOINT` to your MinIO service and `S3_USE_SSL` to `false` (and create credentials for MinIO).
