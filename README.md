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
- BOSH-link-driven cluster peer discovery, for a single node or a cluster of three or more nodes
- BPM process management
- RustFS 1.0.3 through the rustfs BOSH release 0.2.0+dev.2
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

**route-registrar** requires a CF deployment in the same BOSH director. The kit reads the CF system domain from CF exodus and registers two routes through `route_registrar` and NATS TLS. RustFS serves https only, so the routes use `tls_port`, and gorouter must trust the kit CA. Add the RustFS exodus `ca` to the CF `router.ca_certs` property, or gorouter answers these routes with a 502.

**ocfp** derives resource names from the OCFP environment convention and provides IPs and AZs from OCFP subnet configuration. It refuses `params.ips` and `params.instances`, and `params.ocfp_instances` chooses how many of the reserved addresses to use.

**cluster** deploys three nodes by default, and a cluster never has fewer than three. Peers verify each other over TLS, and the API certificate names every node's IP address, so a cluster needs `params.ips` to list those addresses or the `ocfp` feature to supply them. The [MANUAL](MANUAL.md#tls-and-clusters) explains why.

**resolute** moves the deployment to the ubuntu-resolute stemcell and pins bpm 1.4.41. Leave `params.stemcell_os` unset when you use it, because the blueprint refuses a stemcell os that disagrees with the feature.

**scale-small / scale-medium / scale-large** select pre-defined VM type sizes
from your cloud config. Override with explicit `rustfs_vm_type` if needed.

## Quick Start

```bash
genesis new my-rustfs
genesis deploy my-rustfs
```

The wizard asks for the node count, and outside ocfp it asks for each node's static IP address, the network, the VM type, the disk type, and the availability zones. With the `route-registrar` feature it also asks for the route prefixes.

After deployment, retrieve credentials and endpoint info:

```bash
genesis info my-rustfs
```

## Routes

When using the `route-registrar` feature:

| Route | TLS port | Purpose |
|-------|----------|---------|
| `s3-api.{system_domain}` | `rustfs_port`, 9000 by default | S3 API endpoint |
| `s3-console.{system_domain}` | `rustfs_console_port`, 9001 by default | Web console UI |

Customize route prefixes with `params.api_route_prefix` and
`params.console_route_prefix`.

## Scaling

List one address per node in `params.ips`, or under ocfp set `params.ocfp_instances`. The node count chooses the mode.

| Nodes | Mode | Notes |
|-------|------|-------|
| 1 | Single-node | The default. It has no erasure coding or replication |
| 2 | Refused | A pair stops writing when either node is down |
| 3 | Cluster | The default with the `cluster` feature |
| N | Cluster | Any count from 3 to 16 |

The node count is fixed once the deployment exists. RustFS records its erasure layout on the drives at first start, so the pre-deploy hook refuses a deploy that changes the count. A single node cannot grow into a cluster at all, because RustFS formats its drive as single-node single-drive and logs `unsupported pool expansion` when asked to expand it. To change size, copy the data out through S3, delete the deployment, set the new addresses, run `genesis my-rustfs rotate-secrets certs/api`, deploy fresh, and copy the data back. The [MANUAL](MANUAL.md#scaling) gives the steps in full.

Upstream lists distributed mode as available from RustFS 1.0. We still recommend testing node failure and rejoin against your workload before a cluster holds important data.

## Properties

| Parameter | Default | Description |
|-----------|---------|-------------|
| `instances` | `1` (`3` with `cluster`) | Number of RustFS instances when `ips` is not set. Never 2 |
| `ips` | none | One static IP per node. Required for a cluster outside ocfp, and for a single node that outside clients verify |
| `ocfp_instances` | every reservation | Number of ocfp `rustfs_ip` reservations to deploy on (`ocfp` only) |
| `allow_node_count_change` | `false` | Let a cluster deploy at a new size. The nodes refuse to start over the old layout, so use it only when the data is expendable |
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
| `certs/peer:certificate` | Peer certificate. It is rendered to the job, but RustFS 1.0 does not read it |
| `certs/peer:key` | Peer private key, which RustFS 1.0 does not read either |

Internode traffic uses the API certificate, which names every node's address.

Rotate admin credentials with the `reset-credentials` addon. The credentials are marked `fixed`, so `genesis rotate-secrets` leaves them alone. Renew the certificates with `genesis my-rustfs rotate-secrets certs/api`, or `certs/` for all of them. Avoid `--regen-x509-keys` on a running cluster, because a new CA splits the nodes in two during the rolling deploy.

## License

Licensed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0).
