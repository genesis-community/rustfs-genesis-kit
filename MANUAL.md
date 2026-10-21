# RustFS Genesis Kit Manual

The **RustFS Genesis Kit** deploys a RustFS cluster using BOSH-link peer
discovery and BPM process management. RustFS is an S3-compatible object
storage server written in Rust that implements the AWS S3 API.

This kit deploys RustFS 1.0.3 through the rustfs BOSH release 0.2.0+dev.1. Upstream lists distributed mode as available from RustFS 1.0 onwards, but we still recommend testing node failure, restart, and rejoin against your own workload before a cluster holds important data. A single node has no redundancy, so keep an external backup of it.

Peer discovery is automatic through BOSH links. Every node serves the S3 API and internode traffic over TLS on port 9000, and peers verify each other with the kit's CA. The [TLS and Clusters](#tls-and-clusters) section explains what a TLS cluster needs from its certificates.

## Requirements

- **BOSH director**, which needs the following releases. The kit pins every release it uses rather than taking `latest`.

  - `rustfs` 0.2.0+dev.1. This dev release has no public tarball, so we build it from the release repository and upload it with `genesis <env> bosh upload-release` before the deploy.

  - `bpm` 1.4.22 on Noble stemcells, or 1.4.41 when the `resolute` feature is on. bpm 1.4.31 cannot start jobs on Noble, and bpm releases older than 1.4.41 do not compile on Resolute. Both pins carry a bosh.io URL, so BOSH fetches bpm during the deploy.

  - `routing` 0.343.0 when the `route-registrar` feature is on.

  - `bosh-dns-aliases` 0.0.4 when the `route-registrar` or `cluster` feature is on.

- **Stemcell**, either Ubuntu Noble (24.04) or, when the `resolute` feature is on, Ubuntu Resolute (26.04). We upload it with `bosh upload-stemcell`.

- **Cloud config** with the network, VM type, and disk type the environment names. The `check` hook confirms that each one exists.

## Version Compatibility

This kit requires Genesis 3.1.0 or higher. It is currently at version 0.1.0.

## Overview

RustFS exposes two ports on each node:

- Port 9000 serves the S3-compatible API and internode RPC.

- Port 9001 serves the web console under `/rustfs/console/`.

In cluster mode (instances > 1), BOSH links wire peer discovery automatically.
Each node receives the full list of peer addresses at deploy time. The kit does
not require explicit peer IP lists in the environment file.

## Required Config

No operator-supplied config files are required. All parameters have defaults.

## Params

### Core

- `instances` — Number of RustFS instances to deploy. Defaults to `1`, or to `3` when the `cluster` feature is on. Erasure coding spans nodes, so a cluster needs at least three of them.

- `rustfs_domain` — Domain name in the API certificate's subject alternative names, also exported to exodus as `domain`. Defaults to `rustfs.bosh`.

- `rustfs_network` — BOSH network name to deploy into. This network must
  be defined in your cloud config. Defaults to `rustfs`.

- `rustfs_vm_type` — BOSH VM type for RustFS instances. Must exist in your
  cloud config. Defaults to `default`.

- `rustfs_disk_type` — Persistent disk type for RustFS data. Must exist in
  your cloud config. Defaults to `default`. Object storage requires
  substantial disk; provision accordingly.

- `ips` — Explicit list of static IP addresses to assign to instances. When
  set, the number of instances is derived from the length of this list.
  When not set, `instances` controls the count, and the manifest takes the first static IPs in the network's static range.

- `availability_zones` — BOSH AZs to spread instances across. The chosen
  network must have subnets in each listed zone. Defaults to `[z1, z2, z3]`.

- `stemcell_os` — Stemcell OS to deploy on. Defaults to `ubuntu-noble` (Ubuntu 24.04). Leave it unset and enable the `resolute` feature to deploy on Ubuntu Resolute, because the blueprint refuses `ubuntu-resolute` without the feature and refuses any other value with it.

- `stemcell_version` — Specific stemcell version. Defaults to `latest`.

### RustFS Configuration

- `log_level` — RustFS server log level. Valid values: `trace`, `debug`,
  `info`, `warn`, `error`. Defaults to `info`.

- `rustfs_region` — S3 region the server reports, for example in `GetBucketLocation`. Defaults to `us-east-1`. RustFS accepts requests signed for any region.

- `rustfs_server_domains` — Comma-separated list of domains for virtual-hosted
  style bucket addressing (e.g., `example.com`). Defaults to empty string
  (path-style addressing only).

- `rustfs_disk_path` — Filesystem path for RustFS data volumes on each node. Defaults to `/var/vcap/store/rustfs-server`.

- `rustfs_volumes_per_node` — Number of data sub-directories per node. Defaults to `1`, and it should stay there. RustFS requires each local data volume to live on its own physical disk, and a BOSH instance has one persistent disk, so a higher value fails at startup.

- `rustfs_port` — S3 API listen port. Defaults to `9000`.

- `rustfs_console_port` — Web console listen port. Defaults to `9001`.

- `rustfs_console_enable` — Enable the web console UI. Defaults to `true`.

### Route Registrar (feature: route-registrar)

- `api_route_prefix` — CF route prefix for the S3 API. Registered as
  `{prefix}.{system_domain}`. Defaults to `s3-api`.

- `console_route_prefix` — CF route prefix for the web console. Registered
  as `{prefix}.{system_domain}`. Defaults to `s3-console`.

### Azure-specific

- `azure_availability_set` — Name of the Azure availability set VM extension
  for RustFS nodes. Has no effect on non-Azure platforms. Defaults to
  `rustfs_as`.

### OCFP (feature: ocfp)

When the `ocfp` feature is active, the following params are computed
automatically from the OCFP environment convention and should not be set
manually:

- `rustfs_network` — Computed as `{env}.{type}.net-rustfs`
- `rustfs_vm_type` — Computed as `{env}.{type}.vm-rustfs`
- `rustfs_disk_type` — Computed as `{env}.{type}.disk-rustfs`

## Features

### route-registrar

Registers S3 API and web console routes with Cloud Foundry via
`route_registrar`. Requires:

- CF deployed in the same BOSH director
- CF system domain readable from CF exodus at deploy time

The feature adds a `route_registrar` job and `bosh-dns-aliases` job to each
RustFS instance. The bosh-dns-aliases job enables NATS TLS resolution using
CF NATS credentials from CF exodus.

Two routes are registered:

- `{api_route_prefix}.{system_domain}` → port 9000 (S3 API)
- `{console_route_prefix}.{system_domain}` → port 9001 (web console)

The `check` hook confirms that the CF exodus data holds the system domain, the core network, and the NATS client certificate and key before the deploy, and it names each one that is missing.

### ocfp

Enables OCFP-managed infrastructure naming conventions. When active:

- Network, VM type, and disk type names are derived from the OCFP environment
  convention rather than the `default` fallback.
- The blueprint hook generates a dynamic network overlay using OCFP subnet
  configuration to supply static IP addresses and AZs.
- Requires an OCFP-initialized director with appropriate subnets and cloud
  config.

### cluster

Deploys three nodes by default, or `params.instances` nodes, and takes their addresses from the network's static range unless `params.ips` or the `ocfp` feature supplies them. The static IP overlay merges after the cluster overlay, so `params.ips` and the ocfp addresses still win. A TLS cluster needs every peer's IP address in the API certificate, as the [TLS and Clusters](#tls-and-clusters) section explains.

### resolute

Deploys RustFS on an Ubuntu Resolute (26.04) stemcell. The [Resolute Stemcells](#resolute-stemcells) section covers it in full.

### scale-small

Applies a `scale-small` manifest overlay that configures a smaller VM type
suitable for development or low-throughput workloads. Requires a matching
`scale-small` VM type in your cloud config.

### scale-medium

Applies a `scale-medium` manifest overlay. Suitable for moderate workloads.
Requires a matching VM type in cloud config.

### scale-large

Applies a `scale-large` manifest overlay for high-throughput object storage
workloads. Requires a matching VM type in cloud config.

## Addons

### smoke (s)

```bash
genesis my-rustfs do smoke
```

Runs the `smoke-tests` BOSH errand. The errand exercises these operations:

- A health check on every node

- Bucket create

- Object put, get with content verification, and delete

- A head request that expects a 404 after the delete

- Bucket delete

It signs every request with AWS Signature Version 4.

Requires that the RustFS deployment is running and accessible from the BOSH
director. The errand runs in `--keep-alive` mode so you can inspect the errand
VM if it fails.

### reset-credentials (r)

```bash
genesis my-rustfs do reset-credentials
```

Rotates the admin `access_key` and `secret_key` in vault. The new credentials
take effect on the next `genesis deploy`. Existing S3 clients will fail
authentication until reconfigured with the new credentials.

You may provide a specific value for either credential or let the addon
generate a random value. Random access keys are 16 characters; random secret
keys are 32 characters.

### mc (m)

```bash
genesis my-rustfs do mc
```

Configures and launches the MinIO Client (`mc`) pointed at this RustFS
deployment. The addon reads credentials from vault and the primary node IP
from exodus, configures an `mc` alias, and launches an interactive session.

Requires the `mc` binary in your PATH. Download from
[dl.min.io](https://dl.min.io/client/mc/release/).

## Operational Tasks

### First Deploy

On first deploy Genesis generates the TLS certificates (CA, peer, API) and
admin credentials (`access_key`, `secret_key`) automatically. No manual
vault setup is required.

### Scaling

Change `params.instances` in your environment file and redeploy:

```bash
genesis deploy my-rustfs
```

When scaling from 1 to N nodes, the cluster enters distributed mode and BOSH links wire peer discovery automatically. Data is not migrated between modes, so plan the topology before the first deploy.

### Certificate Rotation

Genesis manages certificate rotation. Renew with:

```bash
genesis rotate-secrets my-rustfs
genesis deploy my-rustfs
```

### Credential Rotation

Use the `reset-credentials` addon as described above, then redeploy.

### Accessing the Console

Navigate to `https://{node_ip}:9001` or `https://s3-console.{system_domain}`
(if `route-registrar` is active). Log in with the `access_key` and
`secret_key` from vault.

## Credentials

Genesis generates and stores admin credentials in vault at:

```
{vault_mount}/{env}/rustfs/credentials/access_key
{vault_mount}/{env}/rustfs/credentials/secret_key
```

If these paths are absent at deploy time, Genesis generates random values.
Retrieve them with:

```bash
safe get secret/{env}/rustfs/credentials
```

## Certificates

Genesis manages three certificates via the `certificates` block in `kit.yml`:

| Certificate | Vault Path | Validity | Purpose |
|-------------|-----------|---------|---------|
| CA | `certs/ca` | 10 years | Root CA that signs the peer and API certificates, and that peers trust |
| Peer | `certs/peer` | 10 years | Still rendered to the job, but RustFS 1.0 does not read it |
| API | `certs/api` | 2 years | S3 API and internode TLS |

The CA certificate is also exported to exodus for consumer kits.

## TLS and Clusters

The kit always sets the API certificate and key, so every node serves https only on port 9000 and refuses plaintext requests. RustFS serves internode RPC on that same port, and each node dials its peers at their IP addresses over https and verifies them against the kit's CA.

That verification means every peer's API certificate must name the peer's own IP address. The kit's API certificate names only `rustfs_domain` and `127.0.0.1`, so a cluster built with it fails the TLS handshake between peers and never reaches quorum, and the deploy fails in post-start. A single node is not affected, because it never dials a peer. Until the kit generates certificates that carry the peer addresses, a cluster needs an API certificate whose subject alternative names include every node's static IP, stored at `certs/api` in the environment's vault path.

## Resolute Stemcells

The `resolute` feature deploys RustFS on an Ubuntu Resolute (26.04) stemcell instead of Noble. It sets `params.stemcell_os` to `ubuntu-resolute` and pins bpm 1.4.41, because earlier bpm releases do not compile on Resolute. Noble deployments stay on bpm 1.4.22.

```yaml
kit:
  features:
  - resolute
```

The blueprint refuses two settings that would leave the stemcell and bpm out of step. It refuses the `resolute` feature together with a `stemcell_os` other than `ubuntu-resolute`, and it refuses `stemcell_os: ubuntu-resolute` without the feature. In both cases we remove the `stemcell_os` parameter and let the feature choose.

The pre-deploy hook then checks the merged manifest, because an environment file or a custom fragment can still override the stemcells or the bpm release. It refuses the deploy when any stemcell is not `ubuntu-resolute`, or when bpm is missing, `latest`, or older than 1.4.41.

The director needs a Resolute stemcell before the deploy. Set `params.stemcell_version` to pin one, or leave it unset to take the latest that the director has. The cloud config hook needs no changes for Resolute, because none of its VM, disk, or network properties depend on the stemcell.

## Feature Reference

| Feature | Manifests Applied |
|---------|-------------------|
| `cluster` | `manifests/cluster.yml`, `manifests/releases/bosh-dns-aliases.yml` |
| `route-registrar` | `manifests/route-registrar.yml`, `manifests/releases/routing.yml`, `manifests/releases/bosh-dns-aliases.yml` |
| `ocfp` | `manifests/ocfp.yml` |
| `scale-small` | `manifests/scale-small.yml` |
| `scale-medium` | `manifests/scale-medium.yml` |
| `scale-large` | `manifests/scale-large.yml` |
| `upgrade-serial` | `manifests/upgrade-serial.yml` |
| `upgrade-all-at-once` | `manifests/upgrade-all-at-once.yml` |
| `resolute` | `manifests/resolute.yml`, `manifests/releases/bpm-resolute.yml` |

IaaS overlays (`azure`, `stackit`) are applied automatically by the blueprint hook based on the detected IaaS type, so they do not need to be listed in `features:`.

## Exodus Exports

Downstream kits and operators can read the following keys from RustFS exodus:

| Key | Description |
|-----|-------------|
| `ips` | Comma-separated list of RustFS instance IPs |
| `domain` | Internal BOSH DNS domain |
| `s3_api_url` | HTTPS URL to primary node S3 API (port 9000) |
| `s3_console_url` | HTTPS URL to primary node web console (port 9001) |
| `ca` | PEM-encoded CA certificate |
