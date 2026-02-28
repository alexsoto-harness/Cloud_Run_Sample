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

## Stage Variables

All configuration is driven by stage variables with sensible defaults. Override any value at runtime to deploy to a different project, region, or service.

### Deployment

| Variable | Description | Default |
|----------|-------------|---------|
| `artifact_version` | Image tag to deploy | `neutral` (select from `neutral`, `blue`, `green`) |
| `primary_artifact` | Artifact source identifier | `artifact_gcr` |
| `service_name` | Cloud Run service name | `gcrdemodev` |

### GCP

| Variable | Description | Default |
|----------|-------------|---------|
| `gcp_project` | GCP project ID | `<YOUR_GCP_PROJECT>` |
| `gcp_region` | GCP region for Cloud Run | `<YOUR_REGION>` |

### Connectors

| Variable | Description | Default |
|----------|-------------|---------|
| `docker_connector` | Docker registry connector for plugin images | `account.harnessImage` |
| `k8s_connector` | Kubernetes connector for step group infrastructure | `org.<YOUR_K8S_CONNECTOR>` |
| `gcp_connector` | GCP connector for artifact registry and infrastructure | `account.<YOUR_GCP_CONNECTOR>` |
| `github_connector` | GitHub connector for manifest repo | `<YOUR_GITHUB_CONNECTOR>` |

### Public Access

| Variable | Description | Default |
|----------|-------------|---------|
| `invoker_iam_disabled` | Controls the `run.googleapis.com/invoker-iam-disabled` annotation | `true` |

Set to `false` on the **first deploy** of a new service (before public access is configured). Set to `true` (default) for all subsequent deploys after enabling public access. See [Allowing Public Access](#allowing-public-access) for details.

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

   **First deploy handling:** On the very first deploy of a new service, the Prepare Rollback Data step has no previous revision data, so the expression resolves to `"null"`. A `when` condition on this step skips it when no previous revision exists:
   ```yaml
   when:
     stageStatus: Success
     condition: <expression for revisionMetadata[0].revisionName> != "null"
   ```
   On first deploy, the deploy step detects it's a new service and routes 100% traffic to the new revision automatically, no tagging is needed. On all subsequent deploys, the condition passes and the step runs normally.

### Phase 2: Approval Gate

5. **Cutover Approval** — A Harness Approval step where the approver can test the new revision at the staging URL before approving the cutover. The pipeline pauses here until approved.

### Phase 3: Traffic Shift (Step Group)

6. **Download Manifests** — Re-fetches the manifest (required because this is a separate step group with its own container)
7. **Shift Traffic To Primary** — Routes 100% of traffic to the `LATEST` revision and tags it as `primary`. The `staging` tag is automatically removed as part of this step.

On failure at any point, the pipeline automatically triggers a **rollback** to the previous revision.

### Key Plugin Configuration

| Setting | Value | Purpose |
|---------|-------|---------|
| Plugin image | `harness/google-cloud-run-plugin:1.0.6-linux-amd64` | Must be **1.0.6+** for correct `skipTrafficShift` behavior |
| `skipTrafficShift` | `true` | Pins traffic to the old revision during deploy |
| `revisionTrafficDetails` | On the Tag New Revision step | Assigns `staging` tag to new revision, keeps `primary` on old |

---

## Cloud Run Manifest

The manifest (`harness-cd-pipeline/manifest.yaml`) defines the Knative service:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: <+stage.variables.service_name>
  annotations:
    run.googleapis.com/minScale: '2'
    run.googleapis.com/invoker-iam-disabled: '<+stage.variables.invoker_iam_disabled>'
spec:
  template:
    spec:
      containers:
        - image: <+artifacts.primary.image>
          ports:
            - containerPort: 8080
```

The `<+stage.variables.*>` expressions are resolved from the stage variables at runtime. The `<+artifacts.primary.image>` expression resolves to the full GAR image path with the selected tag.

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

### The `invoker-iam-disabled` Annotation

The pipeline deploys using `gcloud run services replace`, which is fully declarative. The manifest must match the service's current `run.googleapis.com/invoker-iam-disabled` annotation state, or GCP will attempt to change it, requiring `run.services.setIamPolicy` permission.

The `invoker_iam_disabled` stage variable controls this. Set it to `false` for the first deploy of a new service, then to `true` (default) after enabling public access via Option A or B above.

To avoid toggling the variable entirely, grant `roles/run.admin` to the service account used in the **GCP connector** (the SA that authenticates Harness to GCP):

```bash
gcloud projects add-iam-policy-binding <YOUR_GCP_PROJECT> \
  --member="serviceAccount:<YOUR_GCP_CONNECTOR_SA>@<YOUR_GCP_PROJECT>.iam.gserviceaccount.com" \
  --role="roles/run.admin"
```

This role includes `run.services.setIamPolicy`, allowing the deploy to freely set the annotation. With this in place, you can hardcode the annotation to `true` in the manifest and remove the stage variable. Note that `roles/editor` does **not** include this permission. Some organizations may require conditions on IAM bindings, check with your security team if the binding is rejected.

---

## Documentation

- [Harness Google Cloud Run](https://developer.harness.io/docs/continuous-delivery/deploy-srv-diff-platforms/google-cloud-functions/google-cloud-run/)
- [Harness CD Artifact Sources](https://developer.harness.io/docs/continuous-delivery/x-platform-cd-features/services/artifact-sources/)
- [Cloud Run Troubleshooting](https://cloud.google.com/run/docs/troubleshooting)
- [Cloud Run Revision Tags](https://cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration#tags)