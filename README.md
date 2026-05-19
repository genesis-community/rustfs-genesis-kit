# rustfs-genesis-kit

> ⚠ **PRE-RELEASE WARNING** ⚠
>
> RustFS is currently pre-release (1.0.0-beta.3 as of 2026-05).
> Distributed/cluster mode is marked "Under Testing" upstream.
> Use this kit for evaluation; do not assume API stability.
> Defaults to single-instance deployment for safety.

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
- Ubuntu Noble (24.04) stemcell required (io_uring requires kernel ≥ 5.1)
- Optional Cloud Foundry route registration via `route-registrar` feature
- Apache 2.0 license

## Features

Enable features in your environment file under `kit.features`:

| Feature | Description |
|---------|-------------|
| `route-registrar` | Register S3 API and console routes with Cloud Foundry |
| `ocfp` | OCFP-managed network, VM type, and disk type names |
| `scale-small` | Small VM footprint |
| `scale-medium` | Medium VM footprint |
| `scale-large` | Large VM footprint for high-throughput workloads |

**route-registrar** requires a CF deployment in the same BOSH director. The
kit reads CF system domain from CF exodus and registers two routes via
`route_registrar` and NATS TLS.

**ocfp** derives resource names from the OCFP environment convention and
provides IPs and AZs from OCFP subnet configuration.

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
| `1` | Single-node | Stable; no erasure coding or replication |
| `3` | Cluster | Default; distributed mode (under testing upstream) |
| `N` | Cluster | N-node cluster; distributed mode |

> Distributed mode is marked **Under Testing** by the RustFS project. Validate
> thoroughly before using cluster mode for any persistent data.

## Properties

| Parameter | Default | Description |
|-----------|---------|-------------|
| `instances` | `3` | Number of RustFS instances |
| `rustfs_domain` | `rustfs.bosh` | Internal BOSH DNS domain |
| `rustfs_network` | `rustfs` | BOSH network name |
| `rustfs_vm_type` | `default` | BOSH VM type |
| `rustfs_disk_type` | `default` | BOSH persistent disk type |
| `availability_zones` | `[z1, z2, z3]` | BOSH AZs for instance spread |
| `stemcell_os` | `ubuntu-noble` | Stemcell OS (do not change) |
| `stemcell_version` | `latest` | Stemcell version |
| `log_level` | `info` | Log level: trace, debug, info, warn, error |
| `rustfs_region` | `us-east-1` | S3 region string in API responses |
| `rustfs_server_domains` | `""` | Virtual-hosted style domains |
| `rustfs_disk_path` | `/var/vcap/store/rustfs` | Base path for data volumes |
| `rustfs_volumes_per_node` | `4` | Sub-directories per node for erasure coding |
| `api_route_prefix` | `s3-api` | CF route prefix for S3 API (`route-registrar` only) |
| `console_route_prefix` | `s3-console` | CF route prefix for web console (`route-registrar` only) |
| `azure_availability_set` | `rustfs_as` | Azure availability set name (Azure only) |

See [MANUAL.md](MANUAL.md) for the complete parameter reference, platform
notes, credential management, and certificate lifecycle details.

## Addons

Run addons with `genesis do my-rustfs -- <addon>`:

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
