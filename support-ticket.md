# Google Cloud Run Deploy Step: `skipTrafficShift: true` Does Not Prevent Traffic From Shifting to New Revision

## Summary

When `skipTrafficShift: true` is configured on the `GoogleCloudRunDeploy` step, the new revision still receives 100% of traffic immediately upon deployment. The documentation states that this option "only creates a new revision without shifting traffic to it," but the plugin's internal behavior defeats this by injecting the existing service's traffic configuration (which contains `latestRevision: true`) into the manifest before running `gcloud run services replace`. Since `latestRevision: true` always resolves to the newest revision, traffic is shifted to the new revision despite the skip flag being enabled.

## Environment

- **Harness Account**: EeRjnXTnS4GrLG5VNNJZUw
- **Organization**: sandbox
- **Project**: soto_sandbox
- **Pipeline**: GCR_Pipeline_Sample (Cloud Run Blue Green)
- **Plugin Version**: `harness/google-cloud-run-plugin:1.0.4-linux-amd64`
- **GCP Region**: northamerica-northeast2
- **GCP Project**: sales-209522
- **Cloud Run Service**: gcrdemo

## Pipeline Setup

We are implementing a blue/green deployment pattern for Google Cloud Run:

1. **Step Group 1 — Deploy to Staging**: Downloads manifest, prepares rollback data, and deploys a new revision with `skipTrafficShift: true` (intended to deploy at 0% traffic).
2. **Approval Gate**: A `HarnessApproval` step between the two step groups allows manual verification of the new revision before cutover.
3. **Step Group 2 — Traffic Shift**: After approval, a `GoogleCloudRunTrafficShift` step shifts 100% traffic to the new revision.

The approval step cannot be inside a containerized step group, so the deploy and traffic shift steps are in separate step groups with the approval in between.

### Deploy Step Configuration

```yaml
- step:
    type: GoogleCloudRunDeploy
    name: Deploy To Staging
    identifier: Deploy_To_Staging
    spec:
      connectorRef: account.harnessImage
      image: harness/google-cloud-run-plugin:1.0.4-linux-amd64
      imagePullPolicy: Always
      skipTrafficShift: true
    timeout: 10m
```

### Manifest (manifest.yaml)

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: gcrdemo
  labels:
    owner: soto
  annotations:
    run.googleapis.com/minScale: '2'
    run.googleapis.com/invoker-iam-disabled: 'true'
spec:
  template:
    spec:
      containers:
        - image: <+artifacts.primary.image>
          ports:
            - containerPort: 8080
```

Note: The manifest intentionally has **no `traffic` section**. We also tested with a `traffic` section specifying `percent: 0` and `tag: staging`, but the plugin overwrites it regardless.

## Observed Behavior

The deploy step logs show:

```
Executing Deploy step
Manifest content written to path for deploy step
Container image url successfully updated in the cloud run service manifest file
Service Name: gcrdemo
Skipping traffic update in deploy step                          <-- ✅ Flag is acknowledged
Updating Old Traffic Values And Tags Details In Provided ServiceManifest   <-- ⚠️ But then this happens
Executing command: /google-cloud-sdk/bin/gcloud run services describe gcrdemo --format yaml
```

The plugin then fetches the current service state via `gcloud run services describe`, which returns:

```yaml
spec:
  traffic:
  - latestRevision: true
    percent: 100
```

This existing traffic config is **injected into the manifest** before `gcloud run services replace` is executed. Because `latestRevision: true` always resolves to the **newest** revision (which is the one being created by this very `replace` command), the new revision receives 100% traffic immediately.

The post-deploy `gcloud run services describe` confirms 100% traffic on the new revision:

```json
"traffic": [
  {
    "latestRevision": true,
    "percent": 100,
    "revisionName": "gcrdemo-00003-tzz"
  }
]
```

### Step Input Confirmation

The Harness UI confirms `skipTrafficShift: true` was correctly passed to the step:

| Input Name | Input Value |
|---|---|
| skipTrafficShift | true |

## Expected Behavior

When `skipTrafficShift: true` is set:

1. The plugin should create the new revision **without routing any traffic to it**.
2. The existing revision should continue serving 100% of traffic.
3. Traffic should only shift when the `GoogleCloudRunTrafficShift` step is explicitly executed.

Per the [documentation](https://developer.harness.io/docs/continuous-delivery/deploy-srv-diff-platforms/google-cloud-functions/google-cloud-run/):

> "The Deploy step only creates a new revision without shifting traffic to it. Traffic shifting will be performed explicitly in the Google Cloud Run Traffic Shift step."

## Root Cause Analysis

We extracted and analyzed the plugin binary across multiple versions using `strings`. The issue is in the `UpdateOldTrafficValuesAndTagsDetailsInProvidedServiceManifest` function:

1. When `skipTrafficShift: true`, the plugin logs `"Skipping traffic update in deploy step"` — it skips adding *new* traffic routing.
2. It then calls `gcloud run services describe` to get the **current** service state.
3. It copies the existing `traffic` section (including `latestRevision: true, percent: 100`) into the manifest.
4. It runs `gcloud run services replace` with this modified manifest.
5. Since `latestRevision: true` resolves to the newly created revision, traffic shifts to it.

**The fix should be**: When `skipTrafficShift: true`, the plugin should replace `latestRevision: true` with the **specific old revision name** (e.g., `revisionName: gcrdemo-00002-k2w`) before injecting the traffic config. This would pin traffic to the old revision and leave the new revision at 0%.

## Plugin Version History

We compared binaries across all available versions:

| Feature | 1.0.0 | 1.0.2 | 1.0.4 | 1.0.6 |
|---|---|---|---|---|
| `SkipTrafficUpdateInDeployStep` | ❌ | ❌ | ✅ | ✅ |
| `UpdateOldTrafficValuesAndTags` | ❌ | ❌ | ✅ | ✅ |
| `PLUGIN_CLOUD_RUN_UPDATE_TAGS_IN_TRAFFIC_SHIFT` | ❌ | ❌ | ✅ | ✅ |

The feature was introduced in plugin version 1.0.3 (per release notes: CDS-112371, October 2025, Version 1.114.8). The behavior is identical in 1.0.4 and 1.0.6 — the bug has existed since the feature was first released.

## Secondary Issue: Tags in Traffic Shift Step

The `PLUGIN_CLOUD_RUN_UPDATE_TAGS_IN_TRAFFIC_SHIFT` env var defaults to `false` in the binary:

```
envconfig:"PLUGIN_CLOUD_RUN_UPDATE_TAGS_IN_TRAFFIC_SHIFT" label:"boolean to check if we should update tags in traffic shift step" default:"false"
```

However, the [documentation](https://developer.harness.io/docs/continuous-delivery/deploy-srv-diff-platforms/google-cloud-functions/google-cloud-run/) states that tags are supported natively with the `tag` field in `revisionTrafficDetails`:

```yaml
revisionTrafficDetails:
  - revisionName: latest
    trafficValue: 100
    tag: canary, latest
```

It is unclear whether the `tag` field works without explicitly setting `PLUGIN_CLOUD_RUN_UPDATE_TAGS_IN_TRAFFIC_SHIFT=true` as an environment variable on the step. The docs do not mention this env var requirement.

## Pipeline Execution Links

- **Execution #14 (Success, but traffic shifted despite skipTrafficShift)**: https://app.harness.io/ng/#/account/EeRjnXTnS4GrLG5VNNJZUw/cd/orgs/sandbox/projects/soto_sandbox/pipelines/GCR_Pipeline_Sample/executions/ByBebwpcS-u3Byyz9zWgEg/pipeline
- **Execution #13 (Success, same issue)**: https://app.harness.io/ng/#/account/EeRjnXTnS4GrLG5VNNJZUw/cd/orgs/sandbox/projects/soto_sandbox/pipelines/GCR_Pipeline_Sample/executions/kVe7vQYiRDm8P99KjGxFzA/pipeline

## Steps to Reproduce

1. Create a Google Cloud Run service with at least one existing revision serving traffic.
2. Configure a `GoogleCloudRunDeploy` step with `skipTrafficShift: true`.
3. Run the pipeline to deploy a new revision.
4. Observe that 100% traffic shifts to the new revision despite `skipTrafficShift: true`.
5. Check the deploy step logs — you will see `"Skipping traffic update in deploy step"` followed by `"Updating Old Traffic Values And Tags Details In Provided ServiceManifest"`, which injects `latestRevision: true, percent: 100` into the manifest.

## Impact

This prevents implementing a true blue/green deployment pattern with Google Cloud Run, where:
- A new revision is deployed with 0% traffic (staging)
- The revision is validated before cutover
- Traffic is explicitly shifted after approval

Currently, the new revision receives 100% traffic immediately on deploy, making the approval gate ineffective as a pre-cutover verification step.

## Reference

- **Feature Release**: CDS-112371
- **Documentation**: https://developer.harness.io/docs/continuous-delivery/deploy-srv-diff-platforms/google-cloud-functions/google-cloud-run/
- **Plugin Docker Hub**: https://hub.docker.com/r/harness/google-cloud-run-plugin/tags
