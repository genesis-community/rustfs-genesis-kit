# rustfs-genesis-kit

Deploy [RustFS](https://github.com/rustfs/rustfs) — an S3-compatible object
storage server written in Rust — as a BOSH deployment using
[Genesis](https://genesisproject.io).

RustFS implements the S3 API and provides a web console UI. It scales from a
single-node deployment to a distributed cluster using BOSH-link peer
discovery. No external coordination service is required.

## Overview

- S3-compatible API on port 9000
- Web console on port 9001
- BOSH-link-driven cluster peer discovery — scale from 1 to N nodes
- BPM process management
- RustFS 1.0.3 through the rustfs BOSH release 0.2.0+dev.1
- Ubuntu Noble (24.04) stemcells by default, or Ubuntu Resolute (26.04) with the `resolute` feature
- Optional Cloud Foundry route registration via `route-registrar` feature
- Apache 2.0 license

## Features

Enable features in your environment file under `kit.features`:

| Feature | Description |
|---------|-------------|
| `route-registrar` | Register S3 API and console routes with Cloud Foundry |
| `ocfp` | OCFP-managed network, VM type, and disk type names |
| `cluster` | Three or more nodes in distributed mode |
| `resolute` | Ubuntu Resolute (26.04) stemcell with bpm 1.4.41 |
| `scale-small` | Small VM footprint |
| `scale-medium` | Medium VM footprint |
| `scale-large` | Large VM footprint for high-throughput workloads |

**route-registrar** requires a CF deployment in the same BOSH director. The
kit reads CF system domain from CF exodus and registers two routes via
`route_registrar` and NATS TLS.

**ocfp** derives resource names from the OCFP environment convention and
provides IPs and AZs from OCFP subnet configuration.

**cluster** deploys three nodes by default. Peers verify each other over TLS, so a cluster needs an API certificate that names every node's IP address. The [MANUAL](MANUAL.md#tls-and-clusters) explains why.

**resolute** moves the deployment to the ubuntu-resolute stemcell and pins bpm 1.4.41. Leave `params.stemcell_os` unset when you use it, because the blueprint refuses a stemcell os that disagrees with the feature.

**scale-small / scale-medium / scale-large** select pre-defined VM type sizes
from your cloud config. Override with explicit `rustfs_vm_type` if needed.

## Quick Start

```bash
genesis new my-rustfs
genesis deploy my-rustfs
```

The wizard asks about route registration, instance count, disk type, VM type,
and network. All have sensible defaults.

After deployment, retrieve credentials and endpoint info:

```bash
genesis info my-rustfs
```

## Routes

When using the `route-registrar` feature:

| Route | Port | Purpose |
|-------|------|---------|
| `s3-api.{system_domain}` | 9000 | S3 API endpoint |
| `s3-console.{system_domain}` | 9001 | Web console UI |

Customize route prefixes with `params.api_route_prefix` and
`params.console_route_prefix`.

## Scaling

Set `params.instances` to control cluster size:

| Value | Mode | Notes |
|-------|------|-------|
| `1` | Single-node | Default; no erasure coding or replication |
| `3` | Cluster | Default with the `cluster` feature; distributed mode |
| `N` | Cluster | N-node cluster; distributed mode |

Upstream lists distributed mode as available from RustFS 1.0. We still recommend testing node failure and rejoin against your workload before a cluster holds important data.

## Properties

| Parameter | Default | Description |
|-----------|---------|-------------|
| `instances` | `1` (`3` with `cluster`) | Number of RustFS instances |
| `rustfs_domain` | `rustfs.bosh` | Domain in the API certificate and exodus |
| `rustfs_network` | `rustfs` | BOSH network name |
| `rustfs_vm_type` | `default` | BOSH VM type |
| `rustfs_disk_type` | `default` | BOSH persistent disk type |
| `availability_zones` | `[z1, z2, z3]` | BOSH AZs for instance spread |
| `stemcell_os` | `ubuntu-noble` | Stemcell OS. Use the `resolute` feature rather than setting it. |
| `stemcell_version` | `latest` | Stemcell version |
| `log_level` | `info` | Log level: trace, debug, info, warn, error |
| `rustfs_region` | `us-east-1` | S3 region the server reports |
| `rustfs_server_domains` | `""` | Comma-separated virtual-hosted style domains |
| `rustfs_disk_path` | `/var/vcap/store/rustfs-server` | Base path for data volumes |
| `rustfs_volumes_per_node` | `1` | Data sub-directories per node. Keep at 1, because a BOSH instance has one persistent disk. |
| `api_route_prefix` | `s3-api` | CF route prefix for S3 API (`route-registrar` only) |
| `console_route_prefix` | `s3-console` | CF route prefix for web console (`route-registrar` only) |
| `azure_availability_set` | `rustfs_as` | Azure availability set name (Azure only) |

See [MANUAL.md](MANUAL.md) for the complete parameter reference, platform
notes, credential management, and certificate lifecycle details.

## Addons

Run addons with `genesis my-rustfs do <addon>`:

| Addon | Shortcut | Description |
|-------|----------|-------------|
| `smoke` | `s` | Run S3 smoke tests via BOSH errand |
| `reset-credentials` | `r` | Rotate admin access key and secret key |
| `mc` | `m` | Open an interactive MinIO Client session |

## Vault Credential Paths

Genesis generates and stores admin credentials in vault automatically on first
deploy. Paths relative to `{vault_mount}/{env}/rustfs/`:

| Path | Description |
|------|-------------|
| `credentials/access_key` | S3 admin access key |
| `credentials/secret_key` | S3 admin secret key |
| `certs/ca:certificate` | CA certificate (exported to exodus) |
| `certs/api:certificate` | Client-facing S3 TLS certificate |
| `certs/api:key` | Client-facing S3 TLS private key |
| `certs/peer:certificate` | Cluster mTLS certificate |
| `certs/peer:key` | Cluster mTLS private key |

Rotate admin credentials with the `reset-credentials` addon. Certificate
rotation is handled by Genesis.

## License

Licensed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0).
