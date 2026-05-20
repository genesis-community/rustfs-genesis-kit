# Changelog

## 0.0.1 (2026-05-20) — initial pre-release scaffold

Initial kit scaffold for RustFS 1.0.0-beta.3 (upstream pre-release).
Targets the [rustfs-boshrelease](https://github.com/cloudfoundry-community/rustfs-boshrelease).

### Added

- `kit.yml` — metadata, services (s3), supports (aws, azure, gcp, openstack,
  vsphere, stackit), certificates block (ca, peer, api)

- `manifests/rustfs.yml` — base manifest with single `rustfs` instance group,
  `rustfs-server` + `bpm` jobs, BOSH `rustfs-peer` link, ubuntu-noble stemcell,
  defaults to `instances: 1`

- `manifests/route-registrar.yml` — multi-route registrar overlay
  (`s3-api.{system-domain}` + `s3-console.{system-domain}`, prefixes configurable
  via `params.api_route_prefix` and `params.console_route_prefix`)

- `manifests/cluster.yml` — cluster feature overlay; scales via `params.instances`

- `manifests/scale-{small,medium,large}.yml` — vm + persistent disk size tiers

- `manifests/upgrade-{serial,all-at-once}.yml` — update strategy overlays

- `manifests/{azure,stackit,ocfp}.yml` — IaaS + OCFP platform overlays

- `manifests/releases/{rustfs,bpm,routing,bosh-dns-aliases}.yml` — pinned releases

- `hooks/{blueprint,new,check,info,cloud-config}.pm` — core lifecycle hooks
  (Perl OO, parent `Genesis::Hook::*`, min Genesis 3.1.0)

- `hooks/{pre-deploy,post-deploy}.pm` — deploy lifecycle hooks

- `hooks/{addon,addon-smoke~s,addon-reset-credentials~r,addon-mc~m}.pm` —
  addon dispatcher + smoke-tests, credential rotation, mc client addons

- `README.md`, `MANUAL.md`, Apache-2.0 `LICENSE`

### Status

This release is a scaffold. RustFS upstream is pre-release (1.0.0-beta.3); the
distributed/cluster mode is labelled "Under Testing" by the project. Suitable for
evaluation only. The pinned `manifests/releases/rustfs.yml` sha1 is a placeholder
until the corresponding `rustfs-boshrelease` v0.1.0 final release is published.
