# Google Cloud Run Deployment Pipeline

## Overview

This project deploys an nginx-based application to Google Cloud Run using a Harness CD pipeline. It supports multiple page variants (blue, green, neutral) for blue/green deployment demos.

- **GCP Project**: `<YOUR_GCP_PROJECT>`
- **Region**: `<YOUR_REGION>`
- **Artifact Registry**: `<YOUR_REGION>-docker.pkg.dev/<YOUR_GCP_PROJECT>/<YOUR_REGISTRY>/<YOUR_IMAGE>`
- **Cloud Run Service URL**: `https://<YOUR_SERVICE>-<PROJECT_NUMBER>.<YOUR_REGION>.run.app`

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

## Pipeline Execution Steps

The pipeline runs in a single stage (`google_cloud_run_service`) with these steps:

1. **DownloadManifests** - Fetches the Cloud Run manifest from this GitHub repo
2. **Prepare Rollback Data** - Captures current revision state for rollback
3. **Google Cloud Run Deploy** - Deploys the new revision via `gcloud run services replace`
4. **Traffic Shift** - Routes 100% of traffic to the `LATEST` revision

On failure, the pipeline automatically triggers a **rollback** to the previous revision.

### Connectors

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

---

## Allowing Public Access

Cloud Run services require authentication by default. To allow unauthenticated access:

```bash
gcloud run services add-iam-policy-binding <YOUR_SERVICE> \
  --region=<YOUR_REGION> \
  --project=<YOUR_GCP_PROJECT> \
  --member="allUsers" \
  --role="roles/run.invoker"
```

---

## Documentation

- [Harness Google Cloud Run](https://developer.harness.io/docs/continuous-delivery/deploy-srv-diff-platforms/google-cloud-functions/google-cloud-run/)
- [Harness CD Artifact Sources](https://developer.harness.io/docs/continuous-delivery/x-platform-cd-features/services/artifact-sources/)
- [Cloud Run Troubleshooting](https://cloud.google.com/run/docs/troubleshooting)