# Triple-Chatbot RAG Demo — GitOps (RHOAI 3.3, ArgoCD, SNO)

GitOps repository for a **triple-chatbot RAG demo** on **Single Node OpenShift (SNO)** with **RHOAI 3.3**, **ArgoCD**, and **standalone Milvus** vector DB.

## Environment

- **Platform:** OpenShift 4.19 / 4.20+, RHOAI 3.3
- **Hardware:** 2× NVIDIA H100 GPUs, 1TB RAM
- **Vector DB:** Standalone Milvus; **in-cluster MinIO** (S3-compatible) installed by Argo during the infrastructure sync wave.
- **PersistentVolumes:** Storage-agnostic (cluster default). Optional overlays for a specific storage class (e.g. **OpenShift IBM Storage Operator** for fibre channel); see [Optional: Storage class](#optional-storage-class).
- **Models:** gpt-OSS-20B, granite-7b, gemma-2-9b-it (AI Hub Model Catalog / Model Registry). This repo deploys three **InferenceServices** and a **single Open WebUI** (model dropdown via OpenAI-compatible endpoints) plus Milvus for RAG; see [OpenShift AI Model Catalog vs this repo](#openshift-ai-model-catalog-vs-this-repo).

## Install from terminal

Follow these steps from a terminal to install the RAG demo on the OpenShift cluster you are logged into.

**Prerequisites**

- OpenShift CLI (`oc`) installed and in your `PATH`
- Logged into the target cluster as **cluster-admin** (or equivalent) so the bootstrap script and ArgoCD can create namespaces, operators, and resources
- OpenShift GitOps (ArgoCD) installed (e.g. in `openshift-gitops`); the bootstrap script can install it if missing
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

   The script updates the repo URL in the App-of-Apps manifest, creates the bootstrap ArgoCD Application, OAuth session secret for Open WebUI, and (optionally) ConsoleLinks.

   ```bash
   chmod +x scripts/bootstrap-rag-demo.sh
   ./scripts/bootstrap-rag-demo.sh
   ```

   The repo URL is set automatically from your **git remote origin** (so it stays correct if you fork and push to your own org). To override:

   ```bash
   export GIT_REPO_URL="https://github.com/YOUR_ORG/rhoai-3x-RAG-demo.git"
   ./scripts/bootstrap-rag-demo.sh
   ```

5. **Push the updated manifest** (if the script changed `argocd/app-of-apps.yaml`)

   ArgoCD syncs from the repo; after the script runs, the file contains your repo URL. Either run with **`GIT_PUSH=1`** to have the script commit and push for you, or push manually:

   ```bash
   GIT_PUSH=1 ./scripts/bootstrap-rag-demo.sh
   # or manually:
   git add argocd/app-of-apps.yaml
   git commit -m "Set repoURL for ArgoCD"
   git push
   ```

6. **Wait for ArgoCD to sync**

   In the OpenShift console, open the GitOps application and confirm the five child applications (operators → infrastructure → models → pipelines → apps) sync in order. Or from the terminal (use `applications.argoproj.io` so Argo CD apps are listed, not the other Applications CRD):

   ```bash
   oc get applications.argoproj.io -n openshift-gitops
   ```

7. **Optional: run the RAG pipeline** (after pipelines and PVC are synced)

   To ingest PDFs from the `rag-docs` PVC into Milvus (pipeline syncs PVC → S3, then downloads from S3 and runs Docling):

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
       # Optional: override S3 (defaults: s3://milvus-rag/rag-docs/, MinIO in-cluster)
       # - name: s3-uri
       #   value: s3://milvus-rag/rag-docs/
       # - name: s3-endpoint-url
       #   value: http://milvus-minio.rag-demo.svc:9000
     workspaces:
       - name: rag-doc
         persistentVolumeClaim:
           claimName: rag-docs
       - name: s3-downloaded
         emptyDir: {}
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

- **Application deployment stalling:** (1) **Repo URL must match where you push:** If you see only `rag-demo-app-of-apps` with Sync Status `Unknown`, the bootstrap app is likely pointing at the wrong repo (e.g. wrong org vs your fork). Fix: `oc patch applications.argoproj.io rag-demo-app-of-apps -n openshift-gitops --type=merge -p '{"spec":{"source":{"repoURL":"https://github.com/YOUR_ORG/rhoai-3x-RAG-demo.git","path":"argocd","targetRevision":"main","directory":{"recurse":true}}}}'` (replace `YOUR_ORG` with your GitHub org/user). Then push your repo and wait for Argo to sync. (2) Check apps: `oc get applications.argoproj.io -n openshift-gitops` — after a good sync you should see the bootstrap app plus child apps (rag-demo-operators, -infrastructure, -models, -pipelines, -apps). (3) In Argo CD UI, open each application to see sync errors or waiting resources (e.g. PVC Pending, ImagePullBackOff).
- **Bootstrap Application not syncing:** Ensure `argocd/app-of-apps.yaml` is pushed and the repo URL in the bootstrap Application matches your push target.
- **OAuth or ConsoleLinks:** Re-run the script without skip flags after the `rag-demo` namespace and routes exist.
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
├── rag-doc/                   # Local document drop (add PDFs here; contents ignored except .gitkeep)
├── argocd/                    # App-of-Apps and ArgoCD config
│   ├── app-of-apps.yaml       # Child Applications (Wave 1–5)
│   ├── kustomization.yaml
│   └── resource-customizations.yaml  # Health checks for InferenceService/Subscription
├── operators/                 # Wave 1 — Operators + RHOAI cluster CRs (DSCI, DSC)
│   ├── kustomization.yaml
│   ├── dscinitialization-default.yaml
│   ├── datasciencecluster-default.yaml
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
│   ├── task-sync-rag-docs-to-s3.yaml
│   ├── task-download-from-s3.yaml
│   ├── task-chunk-upsert-milvus.yaml
│   ├── pipeline-rag-docling-milvus.yaml
│   ├── trigger-event-listener.yaml
│   └── scripts/
│       ├── docling_parse.py   # Docling: remove_headers, remove_footers, remove_toc
│       └── chunk_upsert_milvus.py
└── apps/                      # Wave 5 — Open WebUI + OAuth proxy (all models)
    ├── kustomization.yaml
    └── open-webui/
```

## Sync Waves (App-of-Apps)

| Wave | Directory      | Content                                      |
|------|----------------|----------------------------------------------|
| 1    | `operators`   | DSCI/DSC (RHOAI 3.3), Nvidia GPU, OpenShift Pipelines, RHOAI Subscription, (GitOps) |
| 2    | `infrastructure` | Namespace, Milvus (standalone + S3), etcd; PVCs storage-agnostic (optional overlay) |
| 3    | `models`      | ServingRuntime, InferenceServices (3 models)  |
| 4    | `pipelines`   | Tekton Pipeline + Tasks, PVC, ConfigMaps      |
| 5    | `apps`        | Open WebUI + OAuth proxy (multi-model)        |

## Bootstrap ArgoCD

1. Point ArgoCD at this repo and the `argocd` path:
   - **Path:** `argocd`
   - **Repo:** `argocd/app-of-apps.yaml` uses a placeholder `your-org`; the **bootstrap script** replaces it with your actual repo URL from `git remote origin` (or `GIT_REPO_URL`). Run the script so no manual edit is needed when you fork.

2. Create the root Application (one-time). Include `directory.recurse: true` so the app-of-apps manifests are applied (the bootstrap script does this when it creates/patches the app):

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
       directory:
         recurse: true
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
| `GIT_REPO_URL` | Git repo URL for ArgoCD (default: from `git remote get-url origin`). Keeps the repo portable for forks. |
| `SKIP_REPO_UPDATE` | Do not modify `argocd/app-of-apps.yaml` |
| `SKIP_BOOTSTRAP_APP` | Do not create the bootstrap Application |
| `SKIP_OAUTH_SECRETS` | Do not create OAuth session secrets |
| `SKIP_CONSOLE_LINKS` | Do not add ConsoleLinks (frontends in console application menu) |
| `CREATE_PIPELINE_RUN` | Create a PipelineRun that uses PVC `rag-docs` |

**Examples:**

```bash
# Use a specific repo URL
export GIT_REPO_URL="https://github.com/YOUR_ORG/rhoai-3x-RAG-demo.git"
./scripts/bootstrap-rag-demo.sh
```

```bash
# Only create OAuth secret and optional PipelineRun (repo and bootstrap already done)
SKIP_REPO_UPDATE=1 SKIP_BOOTSTRAP_APP=1 CREATE_PIPELINE_RUN= ./scripts/bootstrap-rag-demo.sh
```

```bash
# Full automation including one PipelineRun for rag-doc
CREATE_PIPELINE_RUN=1 ./scripts/bootstrap-rag-demo.sh
```

The script also creates a **ConsoleLink** so the RAG Open WebUI route appears in the OpenShift web console application launcher. It uses the cluster Route URL and **default OpenShift authentication** (OAuth). Run the script again after Wave 5 if the route did not exist on the first run.

## Operator Check (Wave 1)

If **Nvidia GPU**, **OpenShift Pipelines**, **OpenShift GitOps**, or **OpenShift AI** operators are missing, the manifests in `operators/` provide:

- **Namespace** + **OperatorGroup** + **Subscription** for:
  - RHOAI (`redhat-ods-operator`)
  - NVIDIA GPU Operator (`nvidia-gpu-operator`)
  - OpenShift Pipelines (`openshift-operators`)

Uncomment or add a GitOps Subscription in `operators/` if you manage OpenShift GitOps via GitOps.

## OpenShift AI Model Catalog vs this repo

**What OpenShift AI automates:** The [OpenShift AI Model Catalog](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.25/html-single/working_with_the_model_catalog/) lets you **deploy a model** from the validated catalog (UI or API). That creates an **InferenceService** in a project you choose. The catalog does **not** create frontends, wire them to models, or configure a vector DB.

**What this repo automates (GitOps):** This repo deploys the **full RAG stack** in one flow: three **InferenceServices** with `spec.predictor.model.storage.uri` aimed at catalog/registry-friendly schemes (`hf://…` or replace with `oci://registry.redhat.io/…` ModelCars from AI Hub), **one Open WebUI** wired to all three predictors via `OPENAI_API_BASE_URLS`, **Milvus** (and MinIO) for the vector store, and a **Tekton pipeline** to ingest documents into Milvus.

**Using catalog models here:** Edit each InferenceService `storage.uri` to the exact **HF** or **OCI** URI from **AI Hub → Catalog** or your **Model Registry** so pulls use normal cluster registry auth (global pull secret) instead of ad hoc S3 staging.

**Alternative:** Red Hat’s [RAG AI quickstart](https://docs.redhat.com/en/learn/ai-quickstarts/rh-RAG) uses a different stack (Llama Stack, PGVector, Kubeflow Pipelines, Helm). Use it if you prefer that blueprint; this repo is a GitOps alternative with a unified chat UI and Milvus.

**Using OpenShift 4.20 to configure frontends and Milvus:** Deploy via ArgoCD (and the bootstrap script). ArgoCD syncs Open WebUI (OpenAI-compatible endpoints to each InferenceService), Milvus, MinIO, and the Tekton ingestion pipeline. The RHOAI dashboard is reachable at **`data-science-gateway.apps.<cluster>`** (not the legacy `rhods-dashboard-redhat-ods-applications` hostname).

### Who deploys what (full automation)

| Step | Who | What |
|------|-----|------|
| 1 | **You** (cluster admin) | Log in (`oc login`), run the bootstrap script (and push, or `GIT_PUSH=1`). The script can install OpenShift GitOps if missing. |
| 2 | **GitOps (ArgoCD)** | Syncs this repo and deploys **everything**: infrastructure (Milvus, MinIO, etc.), **InferenceService CRs**, pipelines, and **Open WebUI**. |
| 3 | **OpenShift AI (RHOAI)** | Supplies the Model Catalog / registry and the serving stack that **reconciles** InferenceService CRs and runs model pods (weights from `storage.uri`). |

So the **whole deployment is automated** as long as you are logged into the OpenShift cluster with a cluster-admin account, run the bootstrap script, and push the updated manifest (or use `GIT_PUSH=1`). You do not need to deploy models separately from the OpenShift AI catalog UI; GitOps deploys the InferenceService CRs from this repo, and OpenShift AI runs them.

**Will GitOps configure the S3 infrastructure for Milvus?** Yes. The infrastructure wave includes **in-cluster MinIO** (S3-compatible): MinIO Deployment, Service, PVC, ConfigMap (`milvus-s3-config`), Secret (`milvus-s3-credentials` with default credentials), and a PostSync Job that creates the `milvus-rag` bucket. So GitOps configures the object storage Milvus needs with no extra steps. For **external AWS S3** instead of MinIO, you create the bucket and credentials and patch the ConfigMap/Secret (or use an overlay); see [infrastructure/milvus/README.md](infrastructure/milvus/README.md).

## Model Serving & GPU Slicing (Wave 3)

- **ServingRuntime:** `vllm-gpu-runtime` (vLLM, GPU, RawDeployment).
- **InferenceServices:** `gpt-oss-20b`, `granite-7b`, `gemma-2-9b-it` with resource limits for 2× H100.
- **Hardware profiles (RHOAI 3.3):** Accelerator profiles and container-size selectors are deprecated. These manifests use **`nodeSelector`** / **tolerations** aligned with **NVIDIA H100** (`nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3`). Adjust to match your nodes (`oc get nodes --show-labels`) and any **HardwareProfile** you define in the dashboard.
- To run **3 models + 2 Jupyter Workbenches** without OOM, use **NVIDIA MIG** or **time-slicing** and set fractional `nvidia.com/gpu` (e.g. `"0.5"`) in the model and workbench specs. The current manifests use 1 GPU per model; adjust limits and replicas to match your SNO capacity.

**Weights:** `spec.predictor.model.storage.uri` uses `hf://…` by default (RHOAI 3.3 KServe CSI + HF flow). Swap each URI for the **OCI ModelCar** reference from AI Hub / Model Registry when you want registry-only pulls via the cluster pull secret.

## Data Pipeline (Wave 4)

- **Tekton Pipeline** `rag-docling-milvus`:
  1. **Sync to S3:** Copies the local `rag-docs` PVC contents to an S3 bucket (default: in-cluster MinIO `s3://milvus-rag/rag-docs/`).
  2. **Download from S3:** Downloads from that S3 URI into an ephemeral workspace for Docling.
  3. **Docling:** Reads the downloaded files, parses PDFs, applies **remove_headers**, **remove_footers**, **remove_toc** (see [scripts/docling_parse.py](pipelines/scripts/docling_parse.py)), writes markdown to a workspace.
  4. **Chunk & upsert:** Chunks markdown and upserts vectors into the standalone Milvus instance (S3 object storage).

  Pipeline params `s3-uri` (default `s3://milvus-rag/rag-docs/`) and `s3-endpoint-url` (default `http://milvus-minio.rag-demo.svc:9000`) can be overridden for AWS S3 or another MinIO endpoint.

- **Docling script:** [pipelines/scripts/docling_parse.py](pipelines/scripts/docling_parse.py) — Python logic for header/footer/TOC removal (post-process on exported markdown).
- **rag-doc/** exists in the repo (with [.gitignore](.gitignore) so only `rag-doc/.gitkeep` is tracked; add PDFs locally and do not commit raw PDFs).

**Where to put files for the vector database:** Put your **PDFs** (or other documents the pipeline supports) into the **`rag-docs`** PVC in the **`rag-demo`** namespace. The pipeline **syncs that PVC to S3** (MinIO bucket `milvus-rag/rag-docs/` by default), **downloads from S3** into a workspace, then runs Docling and chunk/upsert. After the pipeline runs, chunks are embedded and upserted into Milvus.

**Copying files into the PVC:** Run a pod that mounts the `rag-docs` PVC, then copy your PDFs into it from your machine.

```bash
# 1. Create a pod that mounts the PVC (ensure rag-demo namespace and rag-docs PVC exist)
oc apply -n rag-demo -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: rag-doc-upload
  namespace: rag-demo
spec:
  containers:
    - name: upload
      image: registry.access.redhat.com/ubi9/minimal
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: rag-docs
  restartPolicy: Never
EOF

# 2. Wait for the pod to be Running, then sync your local PDFs into it (e.g. from ./rag-doc/ or ./my-pdfs/)
oc wait --for=condition=Ready pod/rag-doc-upload -n rag-demo --timeout=60s
oc rsync ./rag-doc/ rag-doc-upload:/data/ -n rag-demo

# 3. Delete the pod when done (the data remains in the PVC)
oc delete pod rag-doc-upload -n rag-demo
```

The pipeline reads everything under the PVC root as `/workspace/rag-doc`, so PDFs in `/data/` (or any subfolder) in this pod are the ones that get processed. If your PVC uses **ReadWriteOnce**, the upload pod must run in a node that can attach the volume (same as the pipeline).

Run the pipeline manually or via Trigger/Cron (see `pipelines/trigger-event-listener.yaml`). The template in that file wires the `rag-docs` PVC (workspace name `rag-doc`), `s3-downloaded` emptyDir, and `parsed-output` volumeClaimTemplate; override params `s3-uri` and `s3-endpoint-url` for a different S3 bucket or endpoint.

## Frontends (Wave 5) — Open WebUI + OAuth

Single deployment **`open-webui`**:

- **ENV:** `ENABLE_OPENAI_API=true`, **`OPENAI_API_BASE_URLS`** (semicolon-separated KServe OpenAI endpoints for `gpt-oss-20b-predictor`, `granite-7b-predictor`, `gemma-2-9b-it-predictor`), **`OPENAI_API_KEYS`** (placeholders; KServe does not require keys), `OPEN_WEBUI_HEADER_TITLE`, `ENABLE_CONTEXT_UPLOAD=true`.
- **OAuth proxy** (sidecar) using OpenShift authentication; TLS secret is created by OpenShift via `service.alpha.openshift.io/serving-cert-secret-name` on the Service.

Before first use, create the session secret (or let the bootstrap script create it):

```bash
oc create secret generic open-webui-oauth -n rag-demo --from-literal=session_secret=$(openssl rand -base64 32)
```

(Or replace `CHANGE_ME_USE_OC_CREATE_SECRET` in the Git manifest and use a secrets manager.)

## Kustomization

Each directory has a `kustomization.yaml`:

- **argocd:** `argocd/`
- **operators:** `operators/`
- **infrastructure:** `infrastructure/` (includes `milvus/`)
- **models:** `models/`
- **pipelines:** `pipelines/` (includes configMapGenerator for Docling and chunk-upsert scripts)
- **apps:** `apps/` (includes `open-webui/`)

Build/test locally:

```bash
kubectl kustomize operators
kubectl kustomize infrastructure
kubectl kustomize models
kubectl kustomize pipelines
kubectl kustomize apps
```

## .gitignore

Contents of `rag-doc/` are ignored (except `rag-doc/.gitkeep`) and `*.pdf` are ignored everywhere, so raw documents are not committed. The `rag-doc/` folder itself is in the repo so clones get an empty drop directory.

---

**Vector DB and storage:** Argo installs **in-cluster MinIO** and configures Milvus to use it (bucket `milvus-rag`). Default credentials are in Secret `milvus-s3-credentials`; for production or external S3, see [infrastructure/milvus/README.md](infrastructure/milvus/README.md). **PersistentVolumes** are storage-agnostic (cluster default); optionally use [infrastructure/milvus/overlays/ibm-block](infrastructure/milvus/overlays/ibm-block) for IBM Storage Operator / fibre channel.

**Summary:** App-of-Apps in `argocd/` drives five child Applications (operators → infrastructure → models → pipelines → apps). Tune `storage.uri`, GPU fractions, and **nodeSelector** labels for your cluster and catalog entries.
