# fhirsmith

A Helm chart for deploying [FHIRsmith](https://github.com/HealthIntersections/FHIRsmith)
as a FHIR **terminology (`tx`) server** — for example, to act as the `txServer`
behind a [Matchbox](https://github.com/promptlylabs/matchbox-helm-chart) instance.

FHIRsmith is a Node.js multi-module FHIR toolkit. This chart runs it as a
single stateless HTTP service with only the terminology (`tx`) module enabled by
default, so it requires no database and no secrets.

## How it works

- Listens on HTTP port **3000** (`PORT` env). Terminology endpoints are served
  under the paths configured in `config.modules.tx.endpoints` (default `/tx/r4`,
  `/tx/r5`).
- Exposes a cheap **`GET /health`** endpoint, used for the liveness, readiness
  and startup probes.
- Reads its configuration from `$FHIRSMITH_DATA_DIR` (`dataDir`, default
  `/app/data`). The chart renders `config.json` and `library.yml` into a
  ConfigMap and mounts them read-only (via `subPath`) into that directory, which
  is otherwise a writable `emptyDir` for the terminology cache and logs. A
  `checksum/config` pod annotation rolls the Deployment when either changes.

## Prerequisites

- An image registry reachable by the cluster. The default `image.repository` is
  the upstream `ghcr.io/healthintersections/fhirsmith`; override it to pull
  through a mirror or a private registry, with `imagePullSecrets` if needed.
- Egress to the FHIR package registry (HTTPS/443) when the terminology library
  uses `npm:` sources (the default does).

## Key values

| Key                                  | Default                                                      | Description                                                                                                                                                |
| ------------------------------------ | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `image.repository` / `image.tag`     | `ghcr.io/healthintersections/fhirsmith` / chart `appVersion` | Container image.                                                                                                                                           |
| `service.port`                       | `3000`                                                       | HTTP port (also exported as `PORT`).                                                                                                                       |
| `dataDir`                            | `/app/data`                                                  | `FHIRSMITH_DATA_DIR`; where `config.json`/`library.yml` are mounted.                                                                                       |
| `config`                             | tx module only                                               | Rendered to `config.json`. Other modules disabled → no secrets needed.                                                                                     |
| `library`                            | internal + 2 npm packages                                    | Rendered to `library.yml` (terminology sources).                                                                                                           |
| `ingress`                            | `{}` (disabled)                                              | Configure per environment.                                                                                                           |
| `workload.kind`                      | `Deployment`                                                 | `Deployment` or `StatefulSet`. Required to be `StatefulSet` for more than one replica with persistence (see below).                                        |
| `persistence.enabled`                | `false`                                                      | Use a PVC for `dataDir` instead of emptyDir. Enable when loading heavy code systems. Under a StatefulSet this becomes a per-replica `volumeClaimTemplate`. |
| `persistence.storageClass` / `.size` | cluster default / `10Gi`                                     | PVC storage class and size.                                                                                                                                |
| `resources`                          | `{}`                                                         | Set per environment; terminology expansion is memory-sensitive.                                                                                            |
| `networkPolicy.ingress` / `.egress`  | allow-all                                                    | Restrict per environment.                                                                                                                                  |
| `secretNames`                        | `[]`                                                         | Optional secrets exposed via `envFrom`.                                                                                                                    |
| `autoscaling`, `pdb`                 | disabled                                                     | Standard HPA/PDB toggles.                                                                                                                                  |

## Terminology content

The default `library.yml` loads only built-in providers and a couple of FHIR
npm packages (fetched at runtime). Each `library.sources` entry is
`type[!]:value` (the `!` marks the default edition when several versions of a
code system are loaded). Files other than `internal:` and `ucum:` are downloaded
from `library.base.url` and cached under `dataDir/terminology-cache`.

To serve heavy code systems, add their pre-built files (each typically hundreds
of MB to GB) and **enable `persistence`** so they survive restarts, e.g.:

```yaml
persistence:
  enabled: true
  size: 10Gi
library:
  base:
    url: https://storage.googleapis.com/tx-fhir-org
  sources:
    - internal:lang
    - ucum:tx/data/ucum-essence.xml # loaded from a local (bundled) file
    - loinc:Loinc_2.82.db # ~834 MB, downloaded + cached
    - snomed!:sct_intl_20250201.cache # ~822 MB, downloaded + cached; default edition
```

Loading SNOMED also needs substantially more memory — size `resources` accordingly.

## Running more than one replica

The Deployment mounts a **single shared PVC** for `dataDir`. A second replica
scheduled onto another node cannot attach it (`ReadWriteOnce` => Multi-Attach
error), so scaling a persistent Deployment past one replica does not work. The
chart fails to render in that combination rather than producing pods that never
schedule — including via the HPA, so `autoscaling.enabled` with
`autoscaling.maxReplicas > 1` is rejected for a persistent Deployment too.

For HA with a warm cache, use a StatefulSet — each replica then gets its own
volume from `volumeClaimTemplates`:

```yaml
workload:
  kind: StatefulSet
replicaCount: 2
persistence:
  enabled: true
pdb:
  enabled: true
  minAvailable: 1
```

This is a good fit for how FHIRsmith works: the terminology cache is immutable
("files are considered to never change once they are created") and the library
is loaded once at startup, so the cache is read-only while serving. Per-replica
copies therefore behave identically to a shared one, and each replica keeps a
warm cache across reschedules instead of re-downloading multi-GB code systems.

`persistentVolumeClaimRetentionPolicy` defaults to `Retain` for both
`whenDeleted` and `whenScaled`, so scaling down or deleting the StatefulSet
leaves the caches intact. They are not garbage-collected — delete them by hand
if a cluster is being torn down for good.

Two caveats worth knowing:

- **EBS volumes are AZ-pinned.** Each replica must reschedule into the AZ of its
  own volume; if that AZ is unavailable the pod stays pending, where an emptyDir
  pod would reschedule elsewhere and re-download. Spread replicas across zones
  and pair with a PDB so losing one zone still leaves a replica serving.
- **Migrating an existing release from `Deployment`** does not carry the cache
  over: the claim names differ (`<release>-data` vs `data-<release>-0`), so the
  first boot of each replica re-downloads. Delete the old Deployment and its PVC
  once the StatefulSet is Ready — tools that do not prune (e.g. ArgoCD without
  `prune: true`) will leave both running, sharing the Service selector.

## Notes

- Per-`messageId` validation suppression (`suppressError`) is a Matchbox
  feature; FHIRsmith has no equivalent, and the HL7 validator cannot suppress
  errors (only warnings/hints).
- `securityContext.readOnlyRootFilesystem` is `false` because FHIRsmith writes
  its cache/logs under `dataDir`. Hardening to a read-only root + non-root user
  is a follow-up once all writable paths are redirected to volumes.

## Scheduled scaling (KEDA)

`keda.enabled: true` renders a KEDA `ScaledObject` for the Deployment or StatefulSet (`workload.kind`) and drops `replicas` from the
workload, so KEDA is the field's only owner and an ArgoCD sync no longer resets it. Requires the KEDA
operator in the cluster. With `persistence.enabled` on a Deployment, the resolved `maxReplicaCount` must be 1.

```yaml
keda:
  enabled: true
  cron:
    start: "20 08 * * 1-5"
    end: "59 22 * * 1-5"
```

| Value | Default | Description |
|-------|---------|-------------|
| `keda.enabled` | `false` | Render the ScaledObject and omit `replicas`. |
| `keda.name` | `<workload name>-cron` | ScaledObject name. Keep it stable: a rename leaves the old object behind, and KEDA rejects two ScaledObjects on one target. |
| `keda.cron.start` / `.end` / `.timezone` | `""` / `""` / `Europe/Lisbon` | When start and end are set, a `cron` trigger is rendered. |
| `keda.cron.desiredReplicas` | `replicaCount`, or `keda.minReplicaCount` if higher | Replicas inside the window. |
| `keda.minReplicaCount` | `0` | Replicas outside the window. |
| `keda.maxReplicaCount` | `cron.desiredReplicas` | |
| `keda.pollingInterval` / `.cooldownPeriod` | `60` / `0` | KEDA's own defaults are `30` / `300`. |
| `keda.fallback` | `enabled: true`, `failureThreshold: 3`, `replicas: cron.desiredReplicas` | Replicas while the scaler is failing. |
| `keda.triggers` | `[]` | Extra KEDA triggers, appended as-is. |
| `keda.annotations`, `keda.advanced` | `{}` | Passed through to `metadata.annotations` and `spec.advanced`. |

Rendering fails if `keda.enabled` is set without a cron window or triggers, or together with `autoscaling.enabled` (both would create an HPA on the same workload).

When switching an existing release to KEDA, first remove `spec.replicas` from the workload's
`kubectl.kubernetes.io/last-applied-configuration` annotation (`kubectl apply set-last-applied`).
Otherwise the first sync deletes the field and the API server resets the workload to 1 replica.
