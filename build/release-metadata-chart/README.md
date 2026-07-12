# release-metadata

A versioned **release metadata** package for cleanroom, distributed as a Helm
chart purely to reuse Helm's repository infrastructure (catalog `index.yaml`,
versioning, packaging, discovery). It is **not a deployable chart**.

- `type: library` — Helm refuses `helm install` / `helm template`.
- There are **no Kubernetes manifests**. `values.yaml` is the payload.
- Consumers read it with `helm show values` / `helm pull`, **never** `helm install`.

## Contract (`values.yaml`)

`values.yaml` is the API document, validated by `values.schema.json`:

```yaml
apiVersion: metadata.cleanroom.azure.com/v1
kind: ReleaseMetadata
metadata:
  release: 1.0.0
  published: "2026-07-03"
images:
  <logical-image-name>: <full-container-reference>   # digest-pinned or tag-based
```

`apiVersion`/`kind` here are the *domain contract* identifiers and are unrelated
to Helm's own `Chart.yaml` `apiVersion`/`type`. The provider currently reads only
the `images` map (`CcfProvider.ImageUtils`); other fields are ignored today and
reserved for future contract growth (components, compatibility, security, etc.).

## Versioning

- `Chart.yaml` `version` — the release/catalog version (drives the `.tgz` name
  and `index.yaml` entry). Mirrored in `metadata.release`.

The image references in `values.yaml` move on their own cadence and are not
tied to the chart version.

## Consuming

```bash
helm repo add release-metadata <repo-base-url>
helm search repo release-metadata --versions          # discover versions
helm show values release-metadata/release-metadata --version 1.0.0
helm pull release-metadata/release-metadata --version 1.0.0
```

## Producing

The committed `values.yaml` is a **template** with placeholders that
`build/build-release-metadata-chart.ps1` fills at release time — it resolves
image digests, writes the values, `helm package`s the chart, and merges it into
`index.yaml`. The build fails if any placeholder is left unfilled. Because the
placeholders are valid YAML strings, the raw template still passes `helm lint` and
`values.schema.json` validation in CI.
