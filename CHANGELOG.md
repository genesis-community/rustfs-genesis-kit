# Changelog

## Unreleased

### Added

- The `resolute` feature deploys RustFS on the ubuntu-resolute (26.04) stemcell. It sets `params.stemcell_os` to `ubuntu-resolute` through `manifests/resolute.yml` and pins bpm 1.4.41 through `manifests/releases/bpm-resolute.yml`, because older bpm releases do not compile on resolute.

- The blueprint refuses the `resolute` feature together with a `stemcell_os` other than `ubuntu-resolute`, and it refuses `stemcell_os: ubuntu-resolute` without the feature.

- The pre-deploy hook checks the merged manifest of a resolute deploy. It refuses the deploy when any stemcell is not `ubuntu-resolute`, or when bpm is missing, `latest`, or older than 1.4.41.

- The rustfs-server job receives the kit CA as `rustfs.tls.ca`, so cluster peers can verify each other over https.

- The API certificate names every static IP the blueprint assigns, from `params.ips` or the ocfp subnets, as well as `rustfs_domain` and `127.0.0.1`, so cluster peers pass the TLS handshake. The blueprint writes the addresses to `meta.api_cert_ips`, and `kit.yml` names up to 16 of them.

- The blueprint refuses a cluster that has neither `params.ips` nor the `ocfp` feature, because Genesis generates the API certificate before BOSH assigns addresses from the cloud config. It also refuses a `params.ips` entry that is not a single IPv4 or IPv6 address, a `params.ips` value that is not a list, and more than 16 addresses.

- The manifest sets `features.use_dns_addresses: false`, so BOSH links hand peers the IP addresses that the API certificate names.

- The pre-deploy hook refuses a deploy that changes the node count of a running deployment, because RustFS records its erasure layout on the drives and nodes refuse to start over a different one. It reads the deployed count from BOSH, or from the exodus `instances` value when BOSH cannot answer. `params.allow_node_count_change: true` lets a cluster change size, but nothing lets a single node grow into a cluster, because RustFS formats a lone drive as single-node single-drive and logs `unsupported pool expansion` when asked to expand it. The refusal points at the section "Changing the Node Count" in the kit manual and names `genesis <env> kit-manual`.

- The pre-deploy hook reads the public API certificate from vault and refuses the deploy when it does not name `127.0.0.1` and every address in `meta.api_cert_ips`. The message says to run `genesis <env> rotate-secrets certs/api`. The hook never reads the private key.

- The pre-deploy hook refuses bpm 1.4.31, `latest`, or a bpm release without a version on noble, because bpm 1.4.31 starts no process on a cgroup v2 stemcell.

- The blueprint refuses exactly two nodes, whether they come from `params.ips`, `params.instances`, or `params.ocfp_instances`. The `new` hook refuses two as well.

- Under `ocfp`, the blueprint refuses `params.ips` and `params.instances`, which the ocfp fragment would otherwise replace without a word, and points at `params.ocfp_instances`. Outside ocfp it refuses `params.instances` when `params.ips` is set and the two disagree.

- Under `ocfp`, the exodus data carries `cluster` and `cluster_size` whether or not the `cluster` feature is on.

- The smoke-tests errand receives the kit CA as `rustfs.tls.ca`, so it verifies every node's certificate.

- A Go spec suite under `spec/` covers the base, single address, cluster with `params.ips`, ocfp, resolute, resolute with ocfp and cluster, and resolute with route-registrar environments, plus ocfp with the cluster feature, both resolute refusals, the four cluster address refusals, the two-node refusals, the ocfp parameter refusals, and the `params.ips` and `params.instances` mismatch. `spec/route_registrar_test.go` checks that every route registers `tls_port` and `server_cert_domain_san`. `spec/api_cert_test.go` generates the API certificate against a vault of its own, checks that it names every static IP, and checks that `check-secrets` and `rotate-secrets certs/api` bring it up to date after `params.ips` grows. `spec/hooks/pre-deploy.t` covers the merged-manifest checks, the API certificate check, and the node count check, and `spec/hooks/post-deploy.t` covers the health probe.

### Changed

- The kit pins the rustfs release to 0.2.1, which carries RustFS 1.0.3 with a post-start that waits until a rejoining node serves an authenticated read, a bounded drain that also waits until every peer sees every drive, and CA verification in the smoke-tests errand. The pin carries the GitHub release url and sha1, so BOSH fetches the release during the deploy.

- `manifests/releases/bpm.yml` pins bpm 1.4.22 with its bosh.io url and sha1 instead of `latest`, because bpm 1.4.31 cannot start any process on a noble stemcell.

- The check hook confirms the cloud config through the Genesis `has_entry` API, with ocfp-aware defaults for the vm type, network, and disk type. It used to call methods that do not exist.

- The route-registrar check reads the CF exodus data of the environment with the same name, through `exodus_lookup`, and looks for the system domain, the core network, and the NATS client certificate and key that the manifest uses. It used to look for NATS password fields.

- The check hook no longer queries the director for an ubuntu-noble stemcell. Genesis core checks every stemcell the manifest names, and honours `--no-stemcells`.

- The static IP fragment merges after every feature fragment. Before this, `cluster` replaced `params.ips` with the cloud config's static range, and under `ocfp` it appended a second network to the rustfs instance group.

- The instance count default lives in `meta.default.instances`, because graft fails `static_ips` when `instances` falls through to a literal default. Before this change, every environment failed to merge under graft. The cluster's exodus `cluster_size` now reads the instance group's count.

- The route-registrar routes register `tls_port` on the configured API and console ports, with `server_cert_domain_san` set to `rustfs_domain`, instead of a plain `port`. gorouter must trust the kit CA through the CF `router.ca_certs` property. The unused `route_registrar.host` property is gone.

- The `cluster` feature no longer adds the `bosh-dns-aliases` release, which nothing in a cluster used. The `route-registrar` feature still adds it.

- The access and secret keys are marked `fixed`, so `genesis rotate-secrets` leaves them alone. The `reset-credentials` addon still rotates them.

- The exodus URLs take their host from `meta.url_host`, which brackets an IPv6 address, and their ports from `rustfs_port` and `rustfs_console_port`.

- The `new` hook writes `params.ocfp_instances` under ocfp, and outside ocfp it asks for each node's static IP address and writes `params.ips`.

- The kit requires the cloud config for the blueprint, manifest, and check hooks, since the manifest takes static IPs from the cloud config network.

- The post-deploy hook probes `/health/ready` on every RustFS instance over https at the node's own IP address, bracketed for IPv6, and it verifies the certificate against the kit CA on the node with that address as the name. When the kit knows no address list, as for a single node without `params.ips`, it dials `127.0.0.1` and says so. It used to request `/health` over plain http, which a node that serves https only refuses, and `/health` answers even when a cluster has no quorum. When the CA cannot be read or does not verify the certificate, the hook probes again without verification and says so. Every probe result is a warning, never a failure.

- The post-deploy hook reads the instance list from BOSH, and it falls back to the exodus `instances` count, which the manifest now exports. It reads the exodus URLs through `exodus_lookup` and runs `bosh ssh` through the environment's BOSH connection, where it used to call `safe` and a bare `bosh -e` itself. It skips its checks when the deploy return code is missing or not zero.

- The `mc` addon passes the access and secret keys to `mc alias set` on stdin, so the secret never reaches a command line, and it redacts the secret from any mc output it shows. It installs the kit CA in `~/.mc/certs/CAs/`, or under `MC_CONFIG_DIR` when that is set, so mc verifies the API certificate, and it falls back to `--insecure` with a warning only when exodus holds no CA. It names the alias `rustfs-<env>` and accepts `mcli` as well as `mc`. When neither is on the PATH, it prints a `safe` and `mc` pipeline that configures the alias by hand, without reading the secret. It used to print the secret in an `mc alias set` command and to read it from a vault path that did not exist.

- The `reset-credentials` addon reads and writes the credentials under the environment's secrets base through the environment's vault target. It used to build the path from a method that does not exist and to pass the environment name to `safe -T`. For a cluster, it warns before the prompt that every node must restart at once, and it prints the stop, deploy, and start commands that apply the new credentials, because a node with new credentials cannot rejoin peers that hold the old ones and a rolling deploy stops at the first node.

- The MANUAL describes how to change the node count by building a new cluster beside the old one, or by rebuilding the same environment in place, with `mc mirror` and the bucket and IAM exports. It also lists the CF environment change that makes gorouter trust the kit CA for the route-registrar routes, through the exodus `ca` value.

- The README and MANUAL describe RustFS 1.0.3, the resolute feature, the corrected defaults, the TLS requirements of a cluster, and how to renew the API certificate after the static IPs change.

### Known limitations

- A change to the static IPs needs `genesis rotate-secrets certs/api` before the deploy, because `genesis deploy` does not renew a certificate whose names no longer match. `check-secrets` reports each missing address, and the pre-deploy hook refuses the deploy until the certificate names them.

- The node count is fixed for the life of a deployment. Changing it means copying the data to a new deployment, as the MANUAL section "Changing the Node Count" describes. `mc mirror` copies only the latest version of each object.

- `genesis rotate-secrets --regen-x509-keys` replaces the CA, and the nodes stop trusting each other until the rolling deploy reaches all of them.

- A single node without `params.ips` takes its address from the cloud config, so its exodus URLs do not bracket an IPv6 address, and its certificate names only `rustfs_domain` and `127.0.0.1`.

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
