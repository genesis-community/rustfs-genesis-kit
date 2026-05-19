# RustFS Genesis Kit Manual

The **RustFS Genesis Kit** deploys a RustFS cluster using BOSH-link peer
discovery and BPM process management. RustFS is an S3-compatible object
storage server written in Rust that implements the AWS S3 API.

> ⚠ **PRE-RELEASE WARNING** ⚠
>
> This kit packages RustFS 1.0.0-beta.3. RustFS distributed cluster mode is
> explicitly marked "Under Testing" by the RustFS project. Do not deploy in
> production without thorough validation. API and configuration may change
> between beta versions. Single-node mode (`instances: 1`) is more stable.
>
> See: https://github.com/rustfs/rustfs

Peer discovery is automatic via BOSH links. All inter-node communication is
secured with mTLS using the cluster peer certificate.

## Version Compatibility

This kit requires Genesis 3.1.0 or higher. It is currently at version 0.1.0.

## Overview

RustFS exposes two ports on each node:

- Port 9000 — S3-compatible API endpoint
- Port 9001 — Web console UI

In cluster mode (instances > 1), BOSH links wire peer discovery automatically.
Each node receives the full list of peer addresses at deploy time. The kit does
not require explicit peer IP lists in the environment file.

## Required Config

No operator-supplied config files are required. All parameters have defaults.

## Params

### Core

- `instances` — Number of RustFS instances to deploy. Defaults to `3`. Set
  to `1` for single-node mode. Set to 3 or more for cluster mode. Note that
  cluster mode is under testing upstream; odd counts provide better quorum
  behavior.

- `rustfs_domain` — Domain name used in TLS certificate subject alternative
  names. Defaults to `rustfs.bosh`.

- `rustfs_network` — BOSH network name to deploy into. This network must
  be defined in your cloud config. Defaults to `rustfs`.

- `rustfs_vm_type` — BOSH VM type for RustFS instances. Must exist in your
  cloud config. Defaults to `default`.

- `rustfs_disk_type` — Persistent disk type for RustFS data. Must exist in
  your cloud config. Defaults to `default`. Object storage requires
  substantial disk; provision accordingly.

- `ips` — Explicit list of static IP addresses to assign to instances. When
  set, the number of instances is derived from the length of this list.
  When not set, `instances` controls the count and the base manifest uses
  `static_ips 0 1 2` for the first three IPs in the network range.

- `availability_zones` — BOSH AZs to spread instances across. The chosen
  network must have subnets in each listed zone. Defaults to `[z1, z2, z3]`.

- `stemcell_os` — Stemcell OS to deploy on. Defaults to `ubuntu-noble`
  (Ubuntu 24.04). RustFS requires io_uring support (kernel ≥ 5.1); do not
  change this to an older OS.

- `stemcell_version` — Specific stemcell version. Defaults to `latest`.

### RustFS Configuration

- `log_level` — RustFS server log level. Valid values: `trace`, `debug`,
  `info`, `warn`, `error`. Defaults to `info`.

- `rustfs_region` — S3 region string returned in API responses. Defaults to
  `us-east-1`. Change if clients expect a specific region in responses.

- `rustfs_server_domains` — Space-separated list of domains for virtual-hosted
  style bucket addressing (e.g., `example.com`). Defaults to empty string
  (path-style addressing only).

- `rustfs_disk_path` — Filesystem path for RustFS data volumes on each node.
  Defaults to `/var/vcap/store/rustfs`.

- `rustfs_volumes_per_node` — Number of sub-directories per node used as
  erasure coding data drives. Defaults to `4`. Only relevant in cluster mode.

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

The `check` hook validates that the CF system domain is present in CF exodus
before deploy. If not found, a descriptive error is emitted.

### ocfp

Enables OCFP-managed infrastructure naming conventions. When active:

- Network, VM type, and disk type names are derived from the OCFP environment
  convention rather than the `default` fallback.
- The blueprint hook generates a dynamic network overlay using OCFP subnet
  configuration to supply static IP addresses and AZs.
- Requires an OCFP-initialized director with appropriate subnets and cloud
  config.

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
genesis do my-rustfs -- smoke
```

Runs the `smoke-tests` BOSH errand. The errand exercises:

- S3 API health check
- Bucket create
- Object put, get, and delete
- Bucket delete

Requires that the RustFS deployment is running and accessible from the BOSH
director. The errand runs in `--keep-alive` mode so you can inspect the errand
VM if it fails.

### reset-credentials (r)

```bash
genesis do my-rustfs -- reset-credentials
```

Rotates the admin `access_key` and `secret_key` in vault. The new credentials
take effect on the next `genesis deploy`. Existing S3 clients will fail
authentication until reconfigured with the new credentials.

You may provide a specific value for either credential or let the addon
generate a random value. Random access keys are 16 characters; random secret
keys are 32 characters.

### mc (m)

```bash
genesis do my-rustfs -- mc
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

When scaling from 1 to N nodes, the cluster enters distributed mode and
BOSH links wire peer discovery automatically. Data is not migrated between
modes — plan topology before initial deploy.

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
| CA | `certs/ca` | 10 years | Root CA; signs peer and API certs |
| Peer | `certs/peer` | 10 years | Cluster mTLS between nodes |
| API | `certs/api` | 2 years | Client-facing S3 TLS |

The CA certificate is also exported to exodus for consumer kits.

## Exodus Exports

Downstream kits and operators can read the following keys from RustFS exodus:

| Key | Description |
|-----|-------------|
| `ips` | Comma-separated list of RustFS instance IPs |
| `domain` | Internal BOSH DNS domain |
| `s3_api_url` | HTTPS URL to primary node S3 API (port 9000) |
| `s3_console_url` | HTTPS URL to primary node web console (port 9001) |
| `ca` | PEM-encoded CA certificate |
