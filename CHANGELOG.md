# Changelog

## Unreleased

### Added

- The `resolute` feature deploys RustFS on the ubuntu-resolute (26.04) stemcell. It sets `params.stemcell_os` to `ubuntu-resolute` through `manifests/resolute.yml` and pins bpm 1.4.41 through `manifests/releases/bpm-resolute.yml`, because older bpm releases do not compile on resolute.

- The blueprint refuses the `resolute` feature together with a `stemcell_os` other than `ubuntu-resolute`, and it refuses `stemcell_os: ubuntu-resolute` without the feature.

- The pre-deploy hook checks the merged manifest of a resolute deploy. It refuses the deploy when any stemcell is not `ubuntu-resolute`, or when bpm is missing, `latest`, or older than 1.4.41.

- The rustfs-server job receives the kit CA as `rustfs.tls.ca`, so cluster peers can verify each other over https.

- A Go spec suite under `spec/` covers the base, cluster, cluster with `params.ips`, ocfp, resolute, resolute with ocfp and cluster, and resolute with route-registrar environments, plus both resolute refusals. `spec/hooks/pre-deploy.t` covers the merged-manifest check.

### Changed

- The kit pins the rustfs release to 0.2.0+dev.1, which carries RustFS 1.0.3. The final release's url and sha1 replace this dev pin once it is published.

- `manifests/releases/bpm.yml` pins bpm 1.4.22 with its bosh.io url and sha1 instead of `latest`, because bpm 1.4.31 cannot start any process on a noble stemcell.

- The check hook confirms the cloud config through the Genesis `has_entry` API, with ocfp-aware defaults for the vm type, network, and disk type. It used to call methods that do not exist.

- The route-registrar check reads the CF exodus data of the environment with the same name, through `exodus_lookup`, and looks for the system domain, the core network, and the NATS client certificate and key that the manifest uses. It used to look for NATS password fields.

- The check hook no longer queries the director for an ubuntu-noble stemcell. Genesis core checks every stemcell the manifest names, and honours `--no-stemcells`.

- The static IP fragment merges after every feature fragment. Before this, `cluster` replaced `params.ips` with the cloud config's static range, and under `ocfp` it appended a second network to the rustfs instance group.

- The instance count default lives in `meta.default.instances`, because graft fails `static_ips` when `instances` falls through to a literal default. Before this change, every environment failed to merge under graft. The cluster's exodus `cluster_size` now reads the instance group's count.

- The kit requires the cloud config for the blueprint, manifest, and check hooks, since the manifest takes static IPs from the cloud config network.

- The README and MANUAL describe RustFS 1.0.3, the resolute feature, the corrected defaults, and the TLS requirements of a cluster.

### Known limitations

- A cluster fails the TLS handshake between peers, because the API certificate names only `rustfs_domain` and `127.0.0.1`, and peers dial each other by IP address. Single-node deployments are not affected.

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
