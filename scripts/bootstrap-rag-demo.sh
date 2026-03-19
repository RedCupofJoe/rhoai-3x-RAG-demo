#!/usr/bin/env bash
#
# Bootstrap RAG demo on the OpenShift cluster you are logged into (oc login).
# Automates: repoURL, bootstrap Application, OAuth secrets, InferenceService storage, optional PipelineRun.
#
# Usage:
#   ./scripts/bootstrap-rag-demo.sh [OPTIONS]
#
# Env (optional):
#   GIT_REPO_URL          Git repo for ArgoCD (default: from git remote origin)
#   SKIP_REPO_UPDATE      If set, do not modify argocd/app-of-apps.yaml
#   SKIP_BOOTSTRAP_APP    If set, do not create the bootstrap Application
#   SKIP_GITOPS_INSTALL   If set, do not check or install OpenShift GitOps operator
#   SKIP_OAUTH_SECRETS    If set, do not create OAuth session secrets
#   SKIP_MODEL_STORAGE    If set, do not patch InferenceService storage
#   CREATE_PIPELINE_RUN   If set, create a PipelineRun using PVC rag-docs
#   SKIP_CONSOLE_LINKS   If set, do not add ConsoleLinks (frontends in console dropdown)
#   MODEL_STORAGE_URI_GPT_OSS_20B    e.g. s3://bucket/gpt-OSS-20B
#   MODEL_STORAGE_URI_GRANITE_7B     e.g. s3://bucket/granite-7b
#   MODEL_STORAGE_URI_GEMMA_2_9B    e.g. s3://bucket/gemma-2-9b-it
#   STORAGE_CLASS                   Optional: name of StorageClass for PVCs (e.g. ibm-block);
#                                   if set, use infrastructure/milvus/overlays/ibm-block or see README.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARGOCD_DIR="${REPO_ROOT}/argocd"
APPS_FILE="${ARGOCD_DIR}/app-of-apps.yaml"
NAMESPACE_RAG_DEMO="rag-demo"
NAMESPACE_GITOPS="openshift-gitops"
BOOTSTRAP_APP_NAME="rag-demo-app-of-apps"

# --- helpers ---
log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }
die() { err "$1"; exit "${2:-1}"; }

# JSON-escape a string for safe embedding in a JSON payload (oc patch -p "...").
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

check_oc() {
  if ! command -v oc &>/dev/null; then
    die "oc CLI not found. Install OpenShift CLI and ensure it is in PATH."
  fi
  if ! oc whoami &>/dev/null; then
    die "Not logged into OpenShift. Run: oc login <cluster>"
  fi
  log "Using cluster: $(oc whoami --show-server)"
}

# --- Check for and install Red Hat OpenShift GitOps operator if missing ---
ensure_gitops_operator() {
  if [[ -n "${SKIP_GITOPS_INSTALL:-}" ]]; then
    log "Skipping GitOps operator check/install (SKIP_GITOPS_INSTALL is set)."
    return 0
  fi

  # OpenShift 4.20 / GitOps 1.10+: install in openshift-gitops-operator (recommended); older used openshift-operators
  local sub_ns="openshift-gitops-operator"
  local sub_name="openshift-gitops-operator"
  local wait_timeout=600
  local interval=15
  local csv_timeout=300

  # Prefer openshift-gitops-operator; accept existing install in legacy openshift-operators
  if oc get subscription "${sub_name}" -n "${sub_ns}" &>/dev/null; then
    log "OpenShift GitOps operator Subscription already present (${sub_ns}/${sub_name})."
  elif oc get subscription "${sub_name}" -n openshift-operators &>/dev/null; then
    log "OpenShift GitOps operator found in legacy namespace openshift-operators; using it (consider reinstalling in ${sub_ns} for 4.20)."
    sub_ns="openshift-operators"
  else
    log "OpenShift GitOps operator not found. Creating namespace ${sub_ns}, OperatorGroup, and Subscription (OpenShift 4.20 / GitOps 1.10+)."
    oc create namespace "${sub_ns}" --dry-run=client -o yaml | oc apply -f -
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: ${sub_ns}
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${sub_name}
  namespace: ${sub_ns}
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    log "Subscription created. Waiting up to ${csv_timeout}s for operator CSV to succeed, then for ${NAMESPACE_GITOPS}."
  fi

  # Wait for ClusterServiceVersion (operator install) to succeed so operator can create openshift-gitops
  local elapsed=0
  local csv_phase=""
  while [[ $elapsed -lt $csv_timeout ]]; do
    local csv_name
    csv_name=$(oc get csv -n "${sub_ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -m1 openshift-gitops || true)
    if [[ -n "${csv_name}" ]]; then
      csv_phase=$(oc get csv "${csv_name}" -n "${sub_ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    else
      csv_phase=""
    fi
    if [[ "$csv_phase" == "Succeeded" ]]; then
      log "OpenShift GitOps operator CSV succeeded."
      break
    fi
    if [[ "$csv_phase" == "Failed" ]]; then
      err "OpenShift GitOps operator CSV is Failed. Check: oc get csv -n ${sub_ns}; oc describe csv -n ${sub_ns}"
      err "Ensure redhat-operators catalog is available: oc get catalogsource -n openshift-marketplace"
      return 1
    fi
    # Log InstallPlan/CSV status every 60s
    if [[ $((elapsed % 60)) -eq 0 && $elapsed -gt 0 ]]; then
      log "Operator install status: CSV phase=${csv_phase:-'(none)'}. Check: oc get subscription,installplan,csv -n ${sub_ns}"
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  if [[ "$csv_phase" != "Succeeded" ]]; then
    err "Timeout waiting for OpenShift GitOps operator CSV to succeed (${csv_timeout}s)."
    err "Diagnose: oc get subscription,installplan,csv -n ${sub_ns}; oc get catalogsource -n openshift-marketplace"
    err "On sandbox clusters, ensure Marketplace/redhat-operators is enabled, or install GitOps from the web console (Operators -> OperatorHub -> OpenShift GitOps), then re-run with SKIP_GITOPS_INSTALL=1"
    return 1
  fi

  # Wait for openshift-gitops namespace (operator creates it when it deploys the default Argo CD instance)
  elapsed=0
  while ! oc get namespace "${NAMESPACE_GITOPS}" &>/dev/null; do
    if [[ $elapsed -ge $wait_timeout ]]; then
      err "Timeout waiting for namespace ${NAMESPACE_GITOPS}."
      err "The operator is installed but did not create the namespace. Check: oc get pods -n ${sub_ns}; oc get pods -n ${NAMESPACE_GITOPS}"
      err "Install OpenShift GitOps from the web console (Operators -> OperatorHub -> OpenShift GitOps) if needed, then re-run with SKIP_GITOPS_INSTALL=1"
      return 1
    fi
    log "Waiting for namespace ${NAMESPACE_GITOPS}... (${elapsed}s)"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  # Wait for Argo CD application controller (indicates instance is ready to accept Applications)
  elapsed=0
  while true; do
    if oc get statefulset -n "${NAMESPACE_GITOPS}" -o name 2>/dev/null | grep -q application-controller; then
      if oc get statefulset -n "${NAMESPACE_GITOPS}" -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'; then
        log "OpenShift GitOps (Argo CD) is ready in ${NAMESPACE_GITOPS}."
        return 0
      fi
    fi
    if oc get deployment -n "${NAMESPACE_GITOPS}" -o name 2>/dev/null | grep -q gitops-server; then
      if oc get deployment openshift-gitops-server -n "${NAMESPACE_GITOPS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'; then
        log "OpenShift GitOps (Argo CD) is ready in ${NAMESPACE_GITOPS}."
        return 0
      fi
    fi
    if [[ $elapsed -ge $wait_timeout ]]; then
      err "Timeout waiting for Argo CD workload in ${NAMESPACE_GITOPS}. Check: oc get pods -n ${NAMESPACE_GITOPS}"
      return 1
    fi
    log "Waiting for Argo CD instance in ${NAMESPACE_GITOPS}... (${elapsed}s)"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}

# --- 1. Set repoURL in argocd/app-of-apps.yaml ---
set_repo_url() {
  local repo_url="${1:?need GIT_REPO_URL}"
  if [[ -n "${SKIP_REPO_UPDATE:-}" ]]; then
    log "Skipping repoURL update (SKIP_REPO_UPDATE is set)."
    return 0
  fi
  if [[ ! -f "${APPS_FILE}" ]]; then
    die "App-of-Apps file not found: ${APPS_FILE}"
  fi
  # Normalize URL (ensure .git for comparison)
  local normalized="${repo_url}"
  [[ "$normalized" != *.git ]] && normalized="${normalized}.git"
  # Escape for sed replacement: \ and & are special
  local escaped
  escaped=$(printf '%s' "${normalized}" | sed 's/\\/\\\\/g; s/&/\\&/g')
  if grep -q "repoURL:.*your-org" "${APPS_FILE}"; then
    # Replace placeholder (portable sed: backup then remove)
    sed -i.bak "s|repoURL: https://github.com/your-org/rhoai-3x-RAG-demo\\.git|repoURL: ${escaped}|g" "${APPS_FILE}" && rm -f "${APPS_FILE}.bak"
    log "Updated repoURL in ${APPS_FILE} to ${normalized}"
  else
    # Already set or different format; replace any existing repoURL for this repo
    if grep -q "rhoai-3x-RAG-demo" "${APPS_FILE}"; then
      sed -i.bak "s|repoURL: .*rhoai-3x-RAG-demo.*|repoURL: ${escaped}|g" "${APPS_FILE}" && rm -f "${APPS_FILE}.bak"
      log "Updated repoURL in ${APPS_FILE} to ${normalized}"
    else
      log "No placeholder repoURL found in ${APPS_FILE}; leaving as-is. Set GIT_REPO_URL if you need to change it."
    fi
  fi
}

# --- 2. Create bootstrap Application pointing at argocd path ---
create_bootstrap_app() {
  local repo_url="${1:?need GIT_REPO_URL}"
  [[ -n "${SKIP_BOOTSTRAP_APP:-}" ]] && log "Skipping bootstrap Application (SKIP_BOOTSTRAP_APP is set)." && return 0
  local normalized="${repo_url}"
  [[ "$normalized" != *.git ]] && normalized="${normalized}.git"
  if oc get application "${BOOTSTRAP_APP_NAME}" -n "${NAMESPACE_GITOPS}" &>/dev/null; then
    log "Bootstrap Application ${BOOTSTRAP_APP_NAME} already exists; updating repoURL."
    local escaped_url
    escaped_url=$(json_escape "${normalized}")
    oc patch application "${BOOTSTRAP_APP_NAME}" -n "${NAMESPACE_GITOPS}" --type=merge -p "{\"spec\":{\"source\":{\"repoURL\":\"${escaped_url}\",\"path\":\"argocd\",\"targetRevision\":\"main\"}}}"
    return 0
  fi
  log "Creating bootstrap Application ${BOOTSTRAP_APP_NAME} in ${NAMESPACE_GITOPS}."
  oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${BOOTSTRAP_APP_NAME}
  namespace: ${NAMESPACE_GITOPS}
spec:
  project: default
  source:
    repoURL: ${normalized}
    path: argocd
    targetRevision: main
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE_GITOPS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
}

# --- 3. Create OAuth session secrets for the three UIs ---
create_oauth_secrets() {
  [[ -n "${SKIP_OAUTH_SECRETS:-}" ]] && log "Skipping OAuth secrets (SKIP_OAUTH_SECRETS is set)." && return 0
  if ! oc get namespace "${NAMESPACE_RAG_DEMO}" &>/dev/null; then
    log "Namespace ${NAMESPACE_RAG_DEMO} does not exist yet; creating it (ArgoCD may create it later if not)."
    oc create namespace "${NAMESPACE_RAG_DEMO}" || true
  fi
  local secret_name session_secret
  for name in open-webui-gpt-oss open-webui-granite open-webui-gemma; do
    secret_name="${name}-oauth"
    if oc get secret "${secret_name}" -n "${NAMESPACE_RAG_DEMO}" &>/dev/null; then
      log "Secret ${secret_name} already exists in ${NAMESPACE_RAG_DEMO}; skipping."
      continue
    fi
    session_secret=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64 -w 0 2>/dev/null | tr -d '\n')
    oc create secret generic "${secret_name}" -n "${NAMESPACE_RAG_DEMO}" --from-literal=session_secret="${session_secret}"
    log "Created secret ${secret_name} in ${NAMESPACE_RAG_DEMO}."
  done
}

# --- 4. Point InferenceService storage at RHOAI Model Catalog or S3 ---
patch_model_storage() {
  [[ -n "${SKIP_MODEL_STORAGE:-}" ]] && log "Skipping InferenceService storage patches (SKIP_MODEL_STORAGE is set)." && return 0
  if ! oc get namespace "${NAMESPACE_RAG_DEMO}" &>/dev/null; then
    log "Namespace ${NAMESPACE_RAG_DEMO} not found; skip patching InferenceServices (run again after sync)."
    return 0
  fi
  local uri name
  # gpt-oss-20b
  uri="${MODEL_STORAGE_URI_GPT_OSS_20B:-}"
  if [[ -n "${uri}" ]]; then
    name="gpt-oss-20b"
    if oc get inferenceservice "${name}" -n "${NAMESPACE_RAG_DEMO}" &>/dev/null; then
      local escaped_uri
      escaped_uri=$(json_escape "${uri}")
      oc patch inferenceservice "${name}" -n "${NAMESPACE_RAG_DEMO}" --type=merge -p "{\"spec\":{\"predictor\":{\"model\":{\"storage\":{\"uri\":\"${escaped_uri}\"}}}}}"
      log "Patched InferenceService ${name} storage to ${uri}"
    else
      log "InferenceService ${name} not found; skipping storage patch."
    fi
  fi
  # granite-7b
  uri="${MODEL_STORAGE_URI_GRANITE_7B:-}"
  if [[ -n "${uri}" ]]; then
    name="granite-7b"
    if oc get inferenceservice "${name}" -n "${NAMESPACE_RAG_DEMO}" &>/dev/null; then
      escaped_uri=$(json_escape "${uri}")
      oc patch inferenceservice "${name}" -n "${NAMESPACE_RAG_DEMO}" --type=merge -p "{\"spec\":{\"predictor\":{\"model\":{\"storage\":{\"uri\":\"${escaped_uri}\"}}}}}"
      log "Patched InferenceService ${name} storage to ${uri}"
    else
      log "InferenceService ${name} not found; skipping storage patch."
    fi
  fi
  # gemma-2-9b-it
  uri="${MODEL_STORAGE_URI_GEMMA_2_9B:-}"
  if [[ -n "${uri}" ]]; then
    name="gemma-2-9b-it"
    if oc get inferenceservice "${name}" -n "${NAMESPACE_RAG_DEMO}" &>/dev/null; then
      escaped_uri=$(json_escape "${uri}")
      oc patch inferenceservice "${name}" -n "${NAMESPACE_RAG_DEMO}" --type=merge -p "{\"spec\":{\"predictor\":{\"model\":{\"storage\":{\"uri\":\"${escaped_uri}\"}}}}}"
      log "Patched InferenceService ${name} storage to ${uri}"
    else
      log "InferenceService ${name} not found; skipping storage patch."
    fi
  fi
  if [[ -z "${MODEL_STORAGE_URI_GPT_OSS_20B:-}${MODEL_STORAGE_URI_GRANITE_7B:-}${MODEL_STORAGE_URI_GEMMA_2_9B:-}" ]]; then
    log "No MODEL_STORAGE_URI_* env vars set; InferenceService storage left as in Git."
  fi
}

# --- 5. Optionally create a PipelineRun using PVC rag-docs ---
create_pipeline_run() {
  [[ -z "${CREATE_PIPELINE_RUN:-}" ]] && log "Skipping PipelineRun (CREATE_PIPELINE_RUN not set)." && return 0
  if ! oc get namespace "${NAMESPACE_RAG_DEMO}" &>/dev/null; then
    log "Namespace ${NAMESPACE_RAG_DEMO} not found; skipping PipelineRun (run again after sync)."
    return 0
  fi
  local run_name="rag-docling-milvus-run-$(date +%Y%m%d%H%M%S)"
  log "Creating PipelineRun ${run_name} in ${NAMESPACE_RAG_DEMO}."
  oc apply -f - <<EOF
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: ${run_name}
  namespace: ${NAMESPACE_RAG_DEMO}
spec:
  pipelineRef:
    name: rag-docling-milvus
  params:
    - name: milvus-host
      value: milvus.${NAMESPACE_RAG_DEMO}.svc
    - name: collection-name
      value: rag_docs
  workspaces:
    - name: rag-doc
      persistentVolumeClaim:
        claimName: rag-docs
    - name: parsed-output
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 5Gi
  timeout: 1h0m0s
EOF
  log "PipelineRun ${run_name} created. Watch with: oc get pipelinerun -n ${NAMESPACE_RAG_DEMO}"
}

# --- 6. Add frontends to OpenShift console application launcher (ConsoleLinks, default OpenShift auth) ---
create_console_links() {
  [[ -n "${SKIP_CONSOLE_LINKS:-}" ]] && log "Skipping ConsoleLinks (SKIP_CONSOLE_LINKS is set)." && return 0
  if ! oc get namespace "${NAMESPACE_RAG_DEMO}" &>/dev/null; then
    log "Namespace ${NAMESPACE_RAG_DEMO} not found; skipping ConsoleLinks (run after ArgoCD syncs apps)."
    return 0
  fi
  local route_name route_host url text
  # Format: route_name:Display Label
  local -a routes=("open-webui-gpt-oss:gpt-OSS-20B" "open-webui-granite:Granite 7B" "open-webui-gemma:Gemma 2 9B")
  for entry in "${routes[@]}"; do
    route_name="${entry%%:*}"
    text="${entry#*:}"
    route_host=$(oc get route "${route_name}" -n "${NAMESPACE_RAG_DEMO}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [[ -z "${route_host}" ]]; then
      log "Route ${route_name} not found in ${NAMESPACE_RAG_DEMO}; skipping ConsoleLink (run after sync)."
      continue
    fi
    url="https://${route_host}"
    # ConsoleLink names must be DNS-style; use rag-demo-<name>
    local link_name="rag-demo-${route_name}"
    if oc get consolelink "${link_name}" &>/dev/null; then
      local escaped_url escaped_text
      escaped_url=$(json_escape "${url}")
      escaped_text=$(json_escape "RAG Chat (${text})")
      oc patch consolelink "${link_name}" --type=merge -p "{\"spec\":{\"href\":\"${escaped_url}\",\"text\":\"${escaped_text}\"}}"
      log "Updated ConsoleLink ${link_name} -> ${url}"
    else
      oc apply -f - <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleLink
metadata:
  name: ${link_name}
spec:
  href: ${url}
  location: ApplicationMenu
  text: "RAG Chat (${text})"
  applicationMenu:
    section: RAG Demo
EOF
      log "Created ConsoleLink ${link_name} -> ${url}"
    fi
  done
}

# --- resolve GIT_REPO_URL ---
get_repo_url() {
  if [[ -n "${GIT_REPO_URL:-}" ]]; then
    echo "${GIT_REPO_URL}"
    return
  fi
  local origin
  if origin=$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null); then
    # Convert git@github.com:org/repo to https://github.com/org/repo
    if [[ "$origin" =~ ^git@github\.com:(.+)$ ]]; then
      echo "https://github.com/${BASH_REMATCH[1]}"
    elif [[ "$origin" =~ ^https://github\.com/(.+)$ ]]; then
      echo "${origin}"
    else
      echo "${origin}"
    fi
  else
    die "GIT_REPO_URL not set and could not detect from git remote (not a git repo or no origin). Set GIT_REPO_URL and re-run."
  fi
}

# --- main ---
main() {
  log "Bootstrap RAG demo (cluster: $(oc whoami --show-server 2>/dev/null || echo 'not logged in'))."
  if [[ -n "${STORAGE_CLASS:-}" ]]; then
    log "STORAGE_CLASS=${STORAGE_CLASS} set: for PVCs to use it, deploy with overlay infrastructure/milvus/overlays/ibm-block or a custom overlay (see README 'Optional: Storage class')."
  fi
  check_oc
  ensure_gitops_operator
  local repo_url
  repo_url=$(get_repo_url)
  log "Using Git repo: ${repo_url}"

  set_repo_url "${repo_url}"
  create_bootstrap_app "${repo_url}"
  create_oauth_secrets
  patch_model_storage
  create_pipeline_run
  create_console_links

  log "Done. If you just created the bootstrap Application, push your repo (with updated app-of-apps.yaml) and ArgoCD will sync the rest."
  log "To patch model storage after sync, set MODEL_STORAGE_URI_GPT_OSS_20B, MODEL_STORAGE_URI_GRANITE_7B, MODEL_STORAGE_URI_GEMMA_2_9B and re-run with SKIP_REPO_UPDATE=1 SKIP_BOOTSTRAP_APP=1 SKIP_OAUTH_SECRETS=1"
}

main "$@"
