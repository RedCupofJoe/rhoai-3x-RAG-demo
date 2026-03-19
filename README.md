# Triple-Chatbot RAG Demo — GitOps (RHOAI 3.0, ArgoCD, SNO)

GitOps repository for a **triple-chatbot RAG demo** on **Single Node OpenShift (SNO)** with **RHOAI 3.0**, **ArgoCD**, and **standalone Milvus** vector DB.

## Environment

- **Platform:** OpenShift 4.19+, RHOAI 3.0
- **Hardware:** 2× NVIDIA H100 GPUs, 1TB RAM
- **Vector DB:** Standalone Milvus; **in-cluster MinIO** (S3-compatible) installed by Argo during the infrastructure sync wave.
- **PersistentVolumes:** Storage-agnostic (cluster default). Optional overlays for a specific storage class (e.g. **OpenShift IBM Storage Operator** for fibre channel); see [Optional: Storage class](#optional-storage-class).
- **Models:** gpt-OSS-20B, granite-7b, gemma-2-9b-it (RHOAI Model Catalog)

## Install from terminal

Follow these steps from a terminal to install the RAG demo on the OpenShift cluster you are logged into.

**Prerequisites**

- OpenShift CLI (`oc`) installed and in your `PATH`
- Logged into the target cluster (`oc login`)
- OpenShift GitOps (ArgoCD) installed (e.g. in `openshift-gitops`)
- (Optional) For **external S3** instead of in-cluster MinIO: S3 bucket and credentials; see [infrastructure/milvus/README.md](infrastructure/milvus/README.md).  
  (Optional) A specific **storage class** for PVCs—e.g. from the OpenShift IBM Storage Operator for fibre channel—see [Optional: Storage class](#optional-storage-class) below.

**Steps**

1. **Clone the repository**

   ```bash
   git clone https://github.com/your-org/rhoai-3x-RAG-demo.git
   cd rhoai-3x-RAG-demo
   ```

   If you use your own fork, clone that URL instead.

2. **Log in to OpenShift** (if not already)

   ```bash
   oc login <your-cluster-api-url>
   ```

3. **Ensure namespace and (optional) custom object storage**

   Argo installs **in-cluster MinIO** and a default credentials Secret during the infrastructure sync, so no manual secret is required for the demo. Ensure the namespace exists (the bootstrap script or Argo will create it):

   ```bash
   oc create namespace rag-demo --dry-run=client -o yaml | oc apply -f -
   ```

   For **external S3** or custom credentials, create the secret and edit `milvus-s3-config` before or after deploy. See [infrastructure/milvus/README.md](infrastructure/milvus/README.md).  
   **Storage (optional):** For a specific storage class for PVCs (e.g. IBM Storage Operator for fibre channel), see [Optional: Storage class](#optional-storage-class).

4. **Run the bootstrap script**

   The script updates the repo URL in the App-of-Apps manifest, creates the bootstrap ArgoCD Application, OAuth session secrets for the three UIs, and (optionally) ConsoleLinks and model storage patches.

   ```bash
   chmod +x scripts/bootstrap-rag-demo.sh
   ./scripts/bootstrap-rag-demo.sh
   ```

   The script uses your `git remote origin` URL as the ArgoCD repo. To override:

   ```bash
   export GIT_REPO_URL="https://github.com/myorg/rhoai-3x-RAG-demo.git"
   ./scripts/bootstrap-rag-demo.sh
   ```

5. **Push the updated manifest** (if the script changed `argocd/app-of-apps.yaml`)

   ArgoCD syncs from the repo; after the script runs, the file contains your repo URL. Commit and push so ArgoCD sees it:

   ```bash
   git add argocd/app-of-apps.yaml
   git commit -m "Set repoURL for ArgoCD"
   git push
   ```

6. **Wait for ArgoCD to sync**

   In the OpenShift console, open the GitOps application and confirm the five child applications (operators → infrastructure → models → pipelines → apps) sync in order. Or from the terminal:

   ```bash
   oc get applications -n openshift-gitops
   ```

7. **Optional: set model storage URIs and re-run**

   After the `rag-demo` namespace and InferenceServices exist, you can patch storage (e.g. S3 or RHOAI Model Catalog URIs) and optionally add ConsoleLinks:

   ```bash
   export MODEL_STORAGE_URI_GPT_OSS_20B="s3://your-bucket/gpt-OSS-20B"
   export MODEL_STORAGE_URI_GRANITE_7B="s3://your-bucket/granite-7b"
   export MODEL_STORAGE_URI_GEMMA_2_9B="s3://your-bucket/gemma-2-9b-it"
   SKIP_REPO_UPDATE=1 SKIP_BOOTSTRAP_APP=1 SKIP_OAUTH_SECRETS=1 ./scripts/bootstrap-rag-demo.sh
   ```

8. **Optional: run the RAG pipeline** (after pipelines and PVC are synced)

   To ingest PDFs from the `rag-docs` PVC into Milvus:

   ```bash
   oc create -f - <<EOF
   apiVersion: tekton.dev/v1beta1
   kind: PipelineRun
   metadata:
     generateName: rag-docling-milvus-run-
     namespace: rag-demo
   spec:
     pipelineRef:
       name: rag-docling-milvus
     params:
       - name: milvus-host
         value: milvus.rag-demo.svc
       - name: collection-name
         value: rag_docs
     workspaces:
       - name: rag-doc
         persistentVolumeClaim:
           claimName: rag-docs
       - name: parsed-output
         volumeClaimTemplate:
           spec:
             accessModes: [ReadWriteOnce]
             resources:
               requests:
                 storage: 5Gi
     timeout: 1h0m0s
   EOF
   ```

**Troubleshooting**

- **Bootstrap Application not syncing:** Ensure `argocd/app-of-apps.yaml` is pushed and the repo URL in the bootstrap Application matches your push target.
- **OAuth or ConsoleLinks:** Re-run the script without skip flags after the `rag-demo` namespace and routes exist.
- **Model storage:** Set the `MODEL_STORAGE_URI_*` environment variables and re-run the script with the skip flags above so only storage is patched.

### Optional: Storage class

The repo is **storage-agnostic**: PVCs (etcd and Milvus data) do not set a storage class by default, so the cluster default is used. During deployment you can optionally use a specific storage class (e.g. for fibre channel or other backends).

- **Cluster default:** Do nothing; use the standard install and the default StorageClass applies.
- **IBM block storage (OpenShift IBM Storage Operator):** The **OpenShift IBM Storage Operator** is often used to create StorageClasses for fibre channel and other IBM storage. If your cluster has a StorageClass created by it (e.g. `ibm-block`), you can deploy with the optional overlay so Milvus PVCs use it:
  - Point the ArgoCD **infrastructure** Application source path to **`infrastructure/milvus/overlays/ibm-block`** instead of `infrastructure` (see [infrastructure/milvus/README.md](infrastructure/milvus/README.md)), or
  - Apply the overlay once: `kustomize build infrastructure/milvus/overlays/ibm-block | oc apply -f -`
- **Other storage:** Copy `infrastructure/milvus/overlays/ibm-block` to a new overlay (e.g. `overlays/my-storage`) and set `storageClassName` in the patch files to your StorageClass name.

## Repository Layout

```
.
├── argocd/                    # App-of-Apps and ArgoCD config
│   ├── app-of-apps.yaml       # Child Applications (Wave 1–5)
│   ├── kustomization.yaml
│   └── resource-customizations.yaml  # Health checks for InferenceService/Subscription
├── operators/                 # Wave 1 — Operators
│   ├── kustomization.yaml
│   ├── namespace-*.yaml
│   ├── operator-group-*.yaml
│   └── subscription-*.yaml    # RHOAI, NVIDIA GPU, OpenShift Pipelines (GitOps optional)
├── infrastructure/            # Wave 2 — Milvus + MinIO (object store), etcd; PVCs storage-agnostic
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   └── milvus/
│       ├── README.md          # MinIO/S3 config, optional storage class
│       ├── pvc-milvus.yaml    # etcd, Milvus, MinIO PVCs
│       ├── milvus-s3-config.yaml
│       ├── milvus-s3-credentials.yaml   # Default MinIO credentials (Argo)
│       ├── job-minio-create-bucket.yaml # PostSync hook: create bucket
│       ├── overlays/
│       │   └── ibm-block/     # Optional: IBM Storage Operator / fibre channel
│       ├── deployment-milvus.yaml
│       └── service-milvus.yaml
├── models/                    # Wave 3 — Model serving (GPU slicing)
│   ├── kustomization.yaml
│   ├── serving-runtime-vllm.yaml
│   ├── inference-gpt-oss-20b.yaml
│   ├── inference-granite-7b.yaml
│   └── inference-gemma-2-9b.yaml
├── pipelines/                 # Wave 4 — Data pipeline (Docling → Milvus)
│   ├── kustomization.yaml
│   ├── pvc-rag-docs.yaml
│   ├── task-docling-parse.yaml
│   ├── task-chunk-upsert-milvus.yaml
│   ├── pipeline-rag-docling-milvus.yaml
│   ├── trigger-event-listener.yaml
│   └── scripts/
│       ├── docling_parse.py   # Docling: remove_headers, remove_footers, remove_toc
│       └── chunk_upsert_milvus.py
└── apps/                      # Wave 5 — Frontends (Open WebUI + OAuth proxy)
    ├── kustomization.yaml
    ├── open-webui-gpt-oss/
    ├── open-webui-granite/
    └── open-webui-gemma/
```

## Sync Waves (App-of-Apps)

| Wave | Directory      | Content                                      |
|------|----------------|----------------------------------------------|
| 1    | `operators`   | Nvidia GPU, OpenShift Pipelines, RHOAI, (GitOps) |
| 2    | `infrastructure` | Namespace, Milvus (standalone + S3), etcd; PVCs storage-agnostic (optional overlay) |
| 3    | `models`      | ServingRuntime, InferenceServices (3 models)  |
| 4    | `pipelines`   | Tekton Pipeline + Tasks, PVC, ConfigMaps      |
| 5    | `apps`        | 3× Open WebUI + OAuth proxy                   |

## Bootstrap ArgoCD

1. Point ArgoCD at this repo and the `argocd` path:
   - **Path:** `argocd`
   - **Repo:** set `repoURL` to your fork (replace `your-org` in `app-of-apps.yaml`).

2. Create the root Application (one-time):
   ```bash
   oc apply -f - <<EOF
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: rag-demo-app-of-apps
     namespace: openshift-gitops
   spec:
     project: default
     source:
       repoURL: https://github.com/your-org/rhoai-3x-RAG-demo.git
       path: argocd
       targetRevision: main
     destination:
       server: https://kubernetes.default.svc
       namespace: openshift-gitops
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   EOF
   ```

3. Optional: add [resource-customizations](argocd/resource-customizations.yaml) to `argocd-cm` for InferenceService and Subscription health.

### Bootstrap automation (script)

From the repo root, with `oc` logged into your cluster, you can run one script that performs steps 1–5:

```bash
# Default: uses git remote origin as repo URL, updates app-of-apps, creates bootstrap App, OAuth secrets
./scripts/bootstrap-rag-demo.sh
```

**Environment variables (optional):**

| Variable | Effect |
|----------|--------|
| `GIT_REPO_URL` | Git repo URL for ArgoCD (default: from `git remote get-url origin`) |
| `SKIP_REPO_UPDATE` | Do not modify `argocd/app-of-apps.yaml` |
| `SKIP_BOOTSTRAP_APP` | Do not create the bootstrap Application |
| `SKIP_OAUTH_SECRETS` | Do not create OAuth session secrets |
| `SKIP_MODEL_STORAGE` | Do not patch InferenceService storage |
| `SKIP_CONSOLE_LINKS` | Do not add ConsoleLinks (frontends in console application menu) |
| `CREATE_PIPELINE_RUN` | Create a PipelineRun that uses PVC `rag-docs` |
| `MODEL_STORAGE_URI_GPT_OSS_20B` | Storage URI for gpt-oss-20b (e.g. `s3://bucket/gpt-OSS-20B`) |
| `MODEL_STORAGE_URI_GRANITE_7B` | Storage URI for granite-7b |
| `MODEL_STORAGE_URI_GEMMA_2_9B` | Storage URI for gemma-2-9b-it |

**Examples:**

```bash
# Use a specific repo and set model storage (patch after sync)
export GIT_REPO_URL="https://github.com/myorg/rhoai-3x-RAG-demo.git"
export MODEL_STORAGE_URI_GPT_OSS_20B="s3://rhoai-models/gpt-OSS-20B"
export MODEL_STORAGE_URI_GRANITE_7B="s3://rhoai-models/granite-7b"
export MODEL_STORAGE_URI_GEMMA_2_9B="s3://rhoai-models/gemma-2-9b-it"
./scripts/bootstrap-rag-demo.sh
```

```bash
# Only create OAuth secrets (repo and bootstrap already done)
SKIP_REPO_UPDATE=1 SKIP_BOOTSTRAP_APP=1 SKIP_MODEL_STORAGE=1 CREATE_PIPELINE_RUN= ./scripts/bootstrap-rag-demo.sh
```

```bash
# Full automation including one PipelineRun for rag-doc
CREATE_PIPELINE_RUN=1 ./scripts/bootstrap-rag-demo.sh
```

Model storage patches are applied only if the `rag-demo` namespace and the InferenceServices already exist (e.g. after ArgoCD has synced). To patch later, set the `MODEL_STORAGE_URI_*` variables and run again with `SKIP_REPO_UPDATE=1 SKIP_BOOTSTRAP_APP=1 SKIP_OAUTH_SECRETS=1`.

The script also creates **ConsoleLinks** so the three RAG frontends appear in the OpenShift web console application launcher (dropdown). Each link uses the cluster Route URL and **default OpenShift authentication** (OAuth); users click the link and sign in with OpenShift. Create ConsoleLinks after the apps and routes exist (e.g. run the script again after ArgoCD has synced Wave 5).

## Operator Check (Wave 1)

If **Nvidia GPU**, **OpenShift Pipelines**, **OpenShift GitOps**, or **OpenShift AI** operators are missing, the manifests in `operators/` provide:

- **Namespace** + **OperatorGroup** + **Subscription** for:
  - RHOAI (`redhat-ods-operator`)
  - NVIDIA GPU Operator (`nvidia-gpu-operator`)
  - OpenShift Pipelines (`openshift-operators`)

Uncomment or add a GitOps Subscription in `operators/` if you manage OpenShift GitOps via GitOps.

## Model Serving & GPU Slicing (Wave 3)

- **ServingRuntime:** `vllm-gpu-runtime` (vLLM, GPU).
- **InferenceServices:** `gpt-oss-20b`, `granite-7b`, `gemma-2-9b-it` with resource limits for 2× H100.
- To run **3 models + 2 Jupyter Workbenches** without OOM, use **NVIDIA MIG** or **time-slicing** and set fractional `nvidia.com/gpu` (e.g. `"0.5"`) in the model and workbench specs. The current manifests use 1 GPU per model; adjust limits and replicas to match your SNO capacity.

Model storage paths reference RHOAI Model Catalog; set `spec.predictor.model.storage` (or S3/URI) to your actual model locations.

## Data Pipeline (Wave 4)

- **Tekton Pipeline** `rag-docling-milvus`:
  1. **Task 1 — Docling:** Reads from `rag-doc/` (PVC `rag-docs`), parses PDFs, applies **remove_headers**, **remove_footers**, **remove_toc** (see [scripts/docling_parse.py](pipelines/scripts/docling_parse.py)), writes markdown to a workspace.
  2. **Task 2 — Chunk & upsert:** Chunks markdown and upserts vectors into the standalone Milvus instance (S3 object storage).

- **Docling script:** [pipelines/scripts/docling_parse.py](pipelines/scripts/docling_parse.py) — Python logic for header/footer/TOC removal (post-process on exported markdown).
- **rag-doc/** is in [.gitignore](.gitignore); do not commit raw PDFs.

Run the pipeline manually or via Trigger/Cron (see `pipelines/trigger-event-listener.yaml`). PipelineRun example:

```bash
oc create -f pipelines/trigger-event-listener.yaml  # reference only
# Or create a PipelineRun that references pipeline rag-docling-milvus and PVC rag-docs
```

## Frontends (Wave 5) — Open WebUI + OAuth

Three deployments:

- **open-webui-gpt-oss** — header "RAG Chat — gpt-OSS-20B", endpoint `gpt-oss-20b-predictor`
- **open-webui-granite** — "RAG Chat — Granite 7B", endpoint `granite-7b-predictor`
- **open-webui-gemma** — "RAG Chat — Gemma 2 9B", endpoint `gemma-2-9b-it-predictor`

Each has:

- **ENV:** `OPEN_WEBUI_HEADER_TITLE`, `OLLAMA_BASE_URL` (RHOAI InferenceService), `ENABLE_CONTEXT_UPLOAD=true` (context stuffing).
- **OAuth proxy** (sidecar) using OpenShift authentication; TLS secret is created by OpenShift via `service.alpha.openshift.io/serving-cert-secret-name` on the Service.

Before first use, create the session secret for each UI:

```bash
oc create secret generic open-webui-gpt-oss-oauth -n rag-demo --from-literal=session_secret=$(openssl rand -base64 32)
oc create secret generic open-webui-granite-oauth -n rag-demo --from-literal=session_secret=$(openssl rand -base64 32)
oc create secret generic open-webui-gemma-oauth -n rag-demo --from-literal=session_secret=$(openssl rand -base64 32)
```

(Or replace `CHANGE_ME_USE_OC_CREATE_SECRET` in the Git secrets and use a secrets manager.)

## Kustomization

Each directory has a `kustomization.yaml`:

- **argocd:** `argocd/`
- **operators:** `operators/`
- **infrastructure:** `infrastructure/` (includes `milvus/`)
- **models:** `models/`
- **pipelines:** `pipelines/` (includes configMapGenerator for Docling and chunk-upsert scripts)
- **apps:** `apps/` (includes `open-webui-gpt-oss`, `open-webui-granite`, `open-webui-gemma`)

Build/test locally:

```bash
kubectl kustomize operators
kubectl kustomize infrastructure
kubectl kustomize models
kubectl kustomize pipelines
kubectl kustomize apps
```

## .gitignore

`rag-doc/` and `*.pdf` are ignored so raw documents are not committed.

---

**Vector DB and storage:** Argo installs **in-cluster MinIO** and configures Milvus to use it (bucket `milvus-rag`). Default credentials are in Secret `milvus-s3-credentials`; for production or external S3, see [infrastructure/milvus/README.md](infrastructure/milvus/README.md). **PersistentVolumes** are storage-agnostic (cluster default); optionally use [infrastructure/milvus/overlays/ibm-block](infrastructure/milvus/overlays/ibm-block) for IBM Storage Operator / fibre channel.

**Summary:** App-of-Apps in `argocd/` drives five child Applications (operators → infrastructure → models → pipelines → apps). Operators and health checks are conditional/documentary; model storage and GPU limits should be tuned for your 2× H100 SNO and RHOAI Model Catalog.
