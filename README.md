# FHIRsmith Helm Chart

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/fhirsmith)](https://artifacthub.io/packages/search?repo=fhirsmith)

Helm chart for deploying [FHIRsmith](https://github.com/HealthIntersections/FHIRsmith) on Kubernetes as a FHIR **terminology (`tx`) server**, for example as the `txServer` behind a [Matchbox](https://github.com/promptlylabs/matchbox-helm-chart) instance.

FHIRsmith is a Node.js multi-module FHIR toolkit by [Health Intersections](https://www.healthintersections.com.au). This chart runs its terminology module as a stateless HTTP service by default, with no database and no secrets.

## Installation

Available on [Artifact Hub](https://artifacthub.io/packages/search?repo=fhirsmith).

```bash
helm repo add fhirsmith https://promptlylabs.github.io/fhirsmith-helm-chart
helm repo update
helm install fhirsmith fhirsmith/fhirsmith
```

See [charts/fhirsmith/README.md](charts/fhirsmith/README.md) for full configuration documentation.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

[Apache License 2.0](LICENSE)
