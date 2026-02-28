# Google Cloud Run Blue/Green Deployment Pipeline

## Overview

This project deploys an nginx-based application to Google Cloud Run using a Harness CD pipeline with a **blue/green deployment pattern**. It supports multiple page variants (blue, green, neutral), deploying new revisions at 0% traffic, gating cutover behind an approval step, and shifting traffic only after manual verification.

- **GCP Project**: `<YOUR_GCP_PROJECT>`
- **Region**: `<YOUR_REGION>`
- **Artifact Registry**: `<YOUR_REGION>-docker.pkg.dev/<YOUR_GCP_PROJECT>/<YOUR_REGISTRY>/<YOUR_IMAGE>`
- **Cloud Run Service URL**: `https://<YOUR_SERVICE>-<PROJECT_NUMBER>.<YOUR_REGION>.run.app`
- **Staging URL pattern**: `https://staging---<YOUR_SERVICE>-<PROJECT_NUMBER>.<YOUR_REGION>.run.app`

---

## Project Structure

```
.
├── Dockerfile                                  # Multi-variant Dockerfile (uses build args)
├── nginx.conf                                  # Custom nginx config (listens on port 8080)
├── pages/
│   ├── blue.html                               # Blue variant page
│   ├── green.html                              # Green variant page
│   └── neutral.html                            # Neutral/default variant page
└── harness-cd-pipeline/
    ├── pipeline.yaml                           # Harness CD pipeline definition
    ├── service.yaml                            # Harness service definition
    ├── environment.yaml                        # Harness environment definition
    ├── infrastructureDefinition.yaml           # GCP infrastructure config
    └── manifest.yaml                           # Cloud Run Knative service manifest
```

---

## Building Container Images

The Dockerfile uses a `VARIANT` build arg to select which page to include. Default is `neutral`.

```bash
# Set your variables
export REGION=<YOUR_REGION>
export PROJECT=<YOUR_GCP_PROJECT>
export REGISTRY=<YOUR_REGISTRY>
export IMAGE=<YOUR_IMAGE>
export GAR_PATH=${REGION}-docker.pkg.dev/${PROJECT}/${REGISTRY}/${IMAGE}

# Authenticate to Google Artifact Registry
gcloud auth configure-docker ${REGION}-docker.pkg.dev

# Build and push blue variant
docker build --platform linux/amd64 --build-arg VARIANT=blue \
  -t ${GAR_PATH}:blue .
docker push ${GAR_PATH}:blue

# Build and push green variant
docker build --platform linux/amd64 --build-arg VARIANT=green \
  -t ${GAR_PATH}:green .
docker push ${GAR_PATH}:green

# Build and push neutral variant
docker build --platform linux/amd64 \
  -t ${GAR_PATH}:neutral .
docker push ${GAR_PATH}:neutral
```

---

## Pipeline Variables

The pipeline exposes two runtime variables with defaults:

| Variable | Description | Default |
|----------|-------------|---------|
| `artifact_version` | Image tag to deploy — one of `neutral`, `blue`, `green` | `neutral` |
| `primary_artifact` | Artifact source identifier | `artifact_gcr` |

When running the pipeline, set `artifact_version` to the desired image tag.

---

## Blue/Green Deployment Flow

The pipeline implements a blue/green pattern across three phases:

### Phase 1: Deploy to Staging (Step Group)

1. **Download Manifests** — Fetches the Cloud Run manifest from this GitHub repo
2. **Prepare Rollback Data** — Captures current revision state for rollback and exposes the current production revision name via output variables
3. **Deploy To Staging** — Deploys the new revision with `skipTrafficShift: true`, keeping 100% traffic on the current (old) revision. The new revision is created but receives 0% traffic.
4. **Tag New Revision** — A `GoogleCloudRunTrafficShift` step that tags the new revision as `staging` (with 0% traffic) and explicitly keeps the previous revision at 100% with the `primary` tag. The previous revision name is resolved dynamically from the Prepare Rollback Data step's output using the expression:
   ```
   <+pipeline.stages.<STAGE_ID>.spec.execution.steps.<STEP_GROUP_ID>.steps.<PREPARE_ROLLBACK_STEP_ID>.GoogleCloudRunPrepareRollbackDataOutcome.revisionMetadata[0].revisionName>
   ```
   This gives the new revision a testable URL (`https://staging---<YOUR_SERVICE>-<PROJECT_NUMBER>.<YOUR_REGION>.run.app`) without receiving any production traffic.

### Phase 2: Approval Gate

5. **Cutover Approval** — A Harness Approval step where the approver can test the new revision at the staging URL before approving the cutover. The pipeline pauses here until approved.

### Phase 3: Traffic Shift (Step Group)

6. **Download Manifests** — Re-fetches the manifest (required because this is a separate step group with its own container)
7. **Shift Traffic To Primary** — Routes 100% of traffic to the `LATEST` revision and tags it as `primary`. The `staging` tag is automaticallyremoved as part of this step.

On failure at any point, the pipeline automatically triggers a **rollback** to the previous revision.

### Key Plugin Configuration

| Setting | Value | Purpose |
|---------|-------|---------|
| Plugin image | `harness/google-cloud-run-plugin:1.0.6-linux-amd64` | Must be **1.0.6+** for correct `skipTrafficShift` behavior |
| `skipTrafficShift` | `true` | Pins traffic to the old revision during deploy |
| `revisionTrafficDetails` | On the Tag New Revision step | Assigns `staging` tag to new revision, keeps `primary` on old |

---

## Connectors

| Purpose | Connector | Type |
|---------|-----------|------|
| Plugin image pull | `account.harnessImage` | Docker Registry |
| Step group K8s infra | `account.<YOUR_K8S_CONNECTOR>` | Kubernetes |
| GCP authentication | `account.<YOUR_GCP_CONNECTOR>` | GCP (in infra definition) |
| Git repo access | `<YOUR_GITHUB_CONNECTOR>` | GitHub |

---

## Cloud Run Manifest

The manifest (`harness-cd-pipeline/manifest.yaml`) defines the Knative service:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: <YOUR_SERVICE>
  labels:
    owner: <YOUR_LABEL>
  annotations:
    run.googleapis.com/minScale: '2'
spec:
  template:
    spec:
      containers:
        - image: <+artifacts.primary.image>
          ports:
            - containerPort: 8080
```

The `<+artifacts.primary.image>` expression is resolved by Harness at runtime to the full GAR image path with the selected tag.

**Do not** include the `run.googleapis.com/invoker-iam-disabled` annotation in the manifest. Setting it during service creation requires `run.services.setIamPolicy` permission, which most service accounts don't have. Once public access is configured via IAM (see below), Cloud Run sets this annotation automatically and preserves it across subsequent deploys.

---

## Allowing Public Access

Cloud Run services require authentication by default. There are two ways to allow unauthenticated access, depending on your needs.

### Option A: Per-Service (recommended for production)

Run this **after the first deploy** of each new service. The service must already exist.

```bash
gcloud run services add-iam-policy-binding <YOUR_SERVICE> \
  --region=<YOUR_REGION> \
  --project=<YOUR_GCP_PROJECT> \
  --member="allUsers" \
  --role="roles/run.invoker"
```

- **When to run**: Once per service, after the first successful deploy
- **Trade-off**: You control exactly which services are public. Requires a manual step after each new service is created.

### Option B: Project-Wide (convenient for sandbox/demo)

Run this **once, at any time** — even before any services exist. All current and future Cloud Run services in the project become publicly accessible.

```bash
gcloud projects add-iam-policy-binding <YOUR_GCP_PROJECT> \
  --member="allUsers" \
  --role="roles/run.invoker"
```

- **When to run**: Once per project, can be run ahead of time before any deploys
- **Trade-off**: Every Cloud Run service in the project is publicly accessible. No per-service setup needed, but not suitable for projects with services that should remain private.

---

## Documentation

- [Harness Google Cloud Run](https://developer.harness.io/docs/continuous-delivery/deploy-srv-diff-platforms/google-cloud-functions/google-cloud-run/)
- [Harness CD Artifact Sources](https://developer.harness.io/docs/continuous-delivery/x-platform-cd-features/services/artifact-sources/)
- [Cloud Run Troubleshooting](https://cloud.google.com/run/docs/troubleshooting)
- [Cloud Run Revision Tags](https://cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration#tags)