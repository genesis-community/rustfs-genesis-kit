# RustFS Genesis Kit Manual

The **RustFS Genesis Kit** deploys a RustFS cluster using BOSH-link peer
discovery and BPM process management. RustFS is an S3-compatible object
storage server written in Rust that implements the AWS S3 API.

This kit deploys RustFS 1.0.3 through the rustfs BOSH release 0.2.0. Upstream lists distributed mode as available from RustFS 1.0 onwards, but we still recommend testing node failure, restart, and rejoin against your own workload before a cluster holds important data. A single node has no redundancy, so keep an external backup of it.

Peer discovery is automatic through BOSH links. Every node serves the S3 API and internode traffic over TLS on port 9000, and peers verify each other with the kit's CA. The [TLS and Clusters](#tls-and-clusters) section explains what a TLS cluster needs from its certificates.

## Requirements

- **BOSH director**, which needs the following releases. The kit pins every release it uses rather than taking `latest`.

  - `rustfs` 0.2.0. The pin carries the GitHub release URL and sha1, so BOSH fetches the release during the deploy.

  - `bpm` 1.4.22 on Noble stemcells, or 1.4.41 when the `resolute` feature is on. bpm 1.4.31 cannot start jobs on Noble, and bpm releases older than 1.4.41 do not compile on Resolute. Both pins carry a bosh.io URL, so BOSH fetches bpm during the deploy.

  - `routing` 0.343.0 when the `route-registrar` feature is on.

  - `bosh-dns-aliases` 0.0.4 when the `route-registrar` feature is on.

- **Stemcell**, either Ubuntu Noble (24.04) or, when the `resolute` feature is on, Ubuntu Resolute (26.04). We upload it with `bosh upload-stemcell`.

- **Cloud config** with the network, VM type, and disk type the environment names. The `check` hook confirms that each one exists.

## Version Compatibility

This kit requires Genesis 3.1.0 or higher. It is currently at version 0.1.0.

## Overview

RustFS exposes two ports on each node:

- Port 9000 serves the S3-compatible API and internode RPC.

- Port 9001 serves the web console under `/rustfs/console/`.

In cluster mode, BOSH links wire peer discovery automatically, and each node receives the full list of peer addresses at deploy time. The API certificate must name each of those addresses, so a cluster needs `params.ips` to list every node's static IP, or the `ocfp` feature to supply them. The [TLS and Clusters](#tls-and-clusters) section explains why.

A cluster has at least three nodes, and the blueprint refuses exactly two. RustFS spreads each object over every drive as data and parity shards, and with two nodes it cannot write while either one is down, so a pair is less available than a single node.

The node count is fixed once the deployment exists. RustFS records its erasure layout on the drives when the cluster first starts, and the pre-deploy hook refuses a deploy that would change the count. The [Scaling](#scaling) section explains how to move to a different size.

## Required Config

No operator-supplied config files are required. All parameters have defaults.

## Params

### Core

- `instances` — Number of RustFS instances to deploy. Defaults to `1`, or to `3` when the `cluster` feature is on. Erasure coding spans nodes, so a cluster needs at least three of them, and the blueprint refuses exactly two. When `ips` is set, the kit deploys one node per address, and the blueprint refuses an `instances` value that disagrees with the list. The `ocfp` feature refuses this parameter, and `ocfp_instances` takes its place.

- `ocfp_instances` — Under the `ocfp` feature, the number of reserved `rustfs_ip` addresses to deploy nodes on, taken in subnet order. Defaults to every reservation.

- `allow_node_count_change` — Set it to `true` to let the pre-deploy hook pass a deploy that changes the node count of a running deployment. Defaults to `false`. The nodes keep their old drive layout and refuse to start, so set it only when the drives no longer hold data that we need. It never allows growing a single node into a cluster.

- `rustfs_domain` — Domain name in the API certificate's subject alternative names, also exported to exodus as `domain`. Defaults to `rustfs.bosh`.

- `rustfs_network` — BOSH network name to deploy into. This network must
  be defined in your cloud config. Defaults to `rustfs`.

- `rustfs_vm_type` — BOSH VM type for RustFS instances. Must exist in your
  cloud config. Defaults to `default`.

- `rustfs_disk_type` — Persistent disk type for RustFS data. Must exist in
  your cloud config. Defaults to `default`. Object storage requires
  substantial disk; provision accordingly.

- `ips` — Explicit list of static IP addresses to assign to instances. When set, the number of instances is derived from the length of this list, and the API certificate names every address in it. Each entry must be a single IPv4 or IPv6 address, not a range, and the list can hold at most 16 addresses. When not set, `instances` controls the count, and the manifest takes the first static IP in the network's static range. That fallback serves a single node only, because the blueprint refuses a cluster without this list unless the `ocfp` feature supplies the addresses. Even a single node should list its address here when clients outside the deployment verify its certificate, because without the list the certificate names only `rustfs_domain` and `127.0.0.1`. The `ocfp` feature refuses this parameter, because its subnet reservations supply the addresses.

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

- `{api_route_prefix}.{system_domain}` goes to the S3 API on `rustfs_port`, which defaults to 9000.

- `{console_route_prefix}.{system_domain}` goes to the web console on `rustfs_console_port`, which defaults to 9001.

RustFS serves https only, so both routes register a `tls_port` rather than a plain port, and gorouter talks to the nodes over TLS. gorouter checks that the node's certificate names `rustfs_domain`, which the API certificate does, and that the certificate chains to a CA in its `router.ca_certs` property. The kit CA is not there by default, so until we add it, gorouter refuses the backend and answers every request on these routes with a 502.

The RustFS kit publishes its CA in the exodus key `ca`, and the CF deployment reads it from there. This kit does not change the CF deployment, so we make the change in the CF environment file:

1. Deploy RustFS with the `route-registrar` feature, so that its exodus data, and with it the `ca` key, exists in vault.

2. Add the RustFS CA to gorouter in the CF environment file, for example `my-env.yml` in the CF deployments repo:

    ```yaml
    instance_groups:
    - name: router
      jobs:
      - name: gorouter
        properties:
          router:
            ca_certs:
            - (( append ))
            - (( vault $GENESIS_EXODUS_MOUNT genesis.env "/rustfs:ca" ))
    ```

    The path reads the exodus data of the RustFS environment that has the same name as the CF environment, which is the same pairing that the `route-registrar` feature uses to find CF. When the two environments have different names, we replace `genesis.env` with the RustFS environment name in quotes.

3. Deploy CF with `genesis deploy my-env`. gorouter restarts with the extra CA, and the RustFS routes answer instead of returning 502.

4. Check a route, for example with `curl -sS https://s3-api.<system_domain>/health/ready`, which should print the readiness JSON.

When we renew certificates with `rotate-secrets`, the CA stays the same and CF needs nothing. When we replace the CA with `--regen-x509-keys`, we deploy CF again after the RustFS deploy, so that gorouter picks up the new CA.


The `check` hook confirms that the CF exodus data holds the system domain, the core network, and the NATS client certificate and key before the deploy, and it names each one that is missing.

### ocfp

Enables OCFP-managed infrastructure naming conventions. When active:

- Network, VM type, and disk type names are derived from the OCFP environment
  convention rather than the `default` fallback.
- The blueprint hook generates a dynamic network overlay using OCFP subnet
  configuration to supply static IP addresses and AZs.

- The node count comes from the `rustfs_ip` reservations, one node per subnet, and `params.ocfp_instances` can deploy fewer. The blueprint refuses `params.ips` and `params.instances`, which the overlay would otherwise replace without a word.

- The exodus data carries `cluster` and `cluster_size` whether or not the `cluster` feature is on.

- Requires an OCFP-initialized director with appropriate subnets and cloud
  config.

### cluster

Deploys three nodes by default, or one node per address in `params.ips`, and a cluster never has fewer than three. The addresses must come from `params.ips` or from the `ocfp` feature, because the API certificate names every peer's IP address and Genesis generates it before BOSH assigns addresses from the cloud config. The blueprint refuses a cluster that has neither, and the [TLS and Clusters](#tls-and-clusters) section explains why.

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

The addon generates random values. The access key is 20 characters long, and the secret key is 40 characters long, which matches what `genesis add-secrets` creates. Both credentials are marked `fixed` in the kit, so `genesis rotate-secrets` leaves them alone, and this addon is the only way to rotate them.

### mc (m)

```bash
genesis my-rustfs do mc
```

The addon configures an alias for this deployment in the MinIO Client (`mc`), so that we can run `mc` commands against the cluster straight away. It names the alias `rustfs-<env>`, takes the API URL, the access key, and the CA from the exodus data, and reads the secret key from vault.

The secret key never appears in the addon's output or on a command line. The addon hands both keys to `mc alias set` on stdin, which `mc` reads when the keys are missing from its arguments and stdin is not a terminal, and `mc` stores them in its own config under `~/.mc`. If `mc` reports an error that repeats the secret, the addon replaces it with `<redacted>`.

The addon also writes the kit CA to `~/.mc/certs/CAs/rustfs-<env>.crt`. `mc` trusts every certificate in that directory, so every `mc` command verifies the API certificate without `--insecure`. When the exodus data holds no CA, the alias falls back to `--insecure`, the addon warns about it, and the commands it prints carry the flag.

The addon needs `mc` (or `mcli`) on the `PATH`. MinIO no longer publishes `mc` binaries at dl.min.io, so we build it from a release tag of [minio/mc](https://github.com/minio/mc), for example with `go install github.com/minio/mc@RELEASE.2025-08-13T08-35-41Z`. Without `mc`, the addon stops and prints a command that pipes the keys to `mc alias set` from `safe`, so that we can configure the alias by hand later.

## Operational Tasks

### First Deploy

On first deploy Genesis generates the TLS certificates (CA, peer, API) and
admin credentials (`access_key`, `secret_key`) automatically. No manual
vault setup is required.

### Scaling

The node count is fixed for the life of a deployment, so we choose it before the first deploy. RustFS writes its erasure layout to every drive when the cluster first starts. A node whose volume list no longer matches that layout refuses to start, so a deploy that adds or removes nodes takes the cluster down.

The pre-deploy hook guards against this. It compares the node count of the new manifest with the count that BOSH reports for the running deployment, or with the exodus `instances` value when BOSH cannot answer, and it refuses any change. A first deploy has nothing to compare and always passes.

A single node is a special case, because RustFS formats its drive as single-node single-drive (SNSD), and that layout cannot be expanded at all. A node started with a cluster's volume list over an SNSD drive logs this line in `/var/vcap/sys/log/rustfs-server/rustfs-server.stderr.log` and exits:

```
unsupported pool expansion ... single-node single-drive (SNSD) ... cannot be expanded in place
```

The hook therefore refuses to grow a single node into a cluster even when `params.allow_node_count_change` is set, and both of its refusals point to [Changing the Node Count](#changing-the-node-count).

`params.allow_node_count_change: true` lets a cluster deploy at a new size without migrating. We use it only when the drives no longer hold data that we need, because the nodes still refuse to start over the old layout.

Moving a node to a new address without changing the count is safe for the layout, but the certificate needs the new names before the deploy:

```bash
genesis my-rustfs check-secrets
genesis my-rustfs rotate-secrets certs/api
genesis deploy my-rustfs
```

`check-secrets` warns about the certificate and lists each address it is missing. `genesis deploy` does not renew the certificate on its own, and a node whose certificate lacks a peer's address cannot join that peer. The pre-deploy hook reads the public certificate from vault and refuses the deploy when it does not name every node address, and its message gives the same `rotate-secrets` command.

### Changing the Node Count

RustFS 1.0.3 cannot change the size of a deployment that holds data. A single node formats its drive as SNSD, which RustFS refuses to expand. A cluster from this kit is one erasure pool, and RustFS fixed its layout when the cluster first started. RustFS can add a second pool to a deployment, and it can decommission a pool, but only when every volume argument uses its ellipsis syntax. This kit lists each node's volume on its own, which RustFS treats as a legacy single pool, so neither operation applies. The path that the RustFS documentation gives for an SNSD deployment, and the one we use for every size change, is a new deployment at the new size and a copy of the data through the S3 API.

We make the copy with `mc`, and the [mc addon](#mc-m) configures an alias for each environment. Three commands do the work:

- `mc mirror --preserve <from> <to>`

    This copies every bucket and every object when we name an alias or a directory without a bucket, and it creates the buckets that the target lacks. It copies only the latest version of each object, so a bucket whose older versions matter needs a different tool.

- `mc admin cluster bucket export <alias>` and `mc admin cluster bucket import <alias> <file>`

    These save and restore bucket settings such as versioning, which `mc mirror` does not copy from a directory. RustFS 1.0.3 applies the import but answers with an empty body, so `mc` reports `Unable to import bucket metadata. EOF.` and exits 1. We check the result with `mc version info <alias>/<bucket>` instead of trusting the exit code.

- `mc admin cluster iam export <alias>` and `mc admin cluster iam import <alias> <file>`

    These save and restore the users, groups, and policies that we created beyond the root credentials. The IAM file holds user secrets, so we keep it private and delete it when we are done.

Each export writes its zip file to the current directory, named after the alias. We stop the clients that write to the old deployment before the copy, because `mc mirror` copies what it finds at that moment.

#### A new cluster beside the old one

This path keeps the old deployment serving while the copy runs. It needs addresses for the new nodes, and the clients move to the new cluster at the end.

1. Create an environment file for the new cluster, for example by copying `my-rustfs.yml` to `my-rustfs-v2.yml`. Add the `cluster` feature, list three or more new addresses in `params.ips`, and deploy it:

    ```bash
    genesis deploy my-rustfs-v2
    ```

2. Configure an alias for each environment:

    ```bash
    genesis my-rustfs do mc
    genesis my-rustfs-v2 do mc
    ```

3. Stop the clients that write to the old deployment, and copy the data, the bucket settings, and IAM:

    ```bash
    mc mirror --preserve rustfs-my-rustfs rustfs-my-rustfs-v2
    mc admin cluster bucket export rustfs-my-rustfs
    mc admin cluster bucket import rustfs-my-rustfs-v2 rustfs-my-rustfs-bucket-metadata.zip
    mc admin cluster iam export rustfs-my-rustfs
    mc admin cluster iam import rustfs-my-rustfs-v2 rustfs-my-rustfs-iam-info.zip
    ```

4. Check each bucket. `mc diff` prints nothing when the two sides match:

    ```bash
    mc diff rustfs-my-rustfs/<bucket> rustfs-my-rustfs-v2/<bucket>
    mc du --depth 2 rustfs-my-rustfs
    mc du --depth 2 rustfs-my-rustfs-v2
    ```

5. Point the clients at the new cluster. It has its own addresses, CA, and credentials, which its exodus data publishes as `s3_api_url`, `ca`, and `access_key`, and its secret key is under its own vault path. Anything that reads the old environment's exodus data, such as the CF router CA from the [route-registrar](#route-registrar) steps, changes to the new environment name and deploys again.

6. When nothing uses the old deployment any more, delete it with `genesis my-rustfs bosh delete-deployment`, and remove its alias with `mc alias remove rustfs-my-rustfs`.

#### Rebuilding the same environment in place

This path keeps the environment name, the credentials, and the CA, so clients need no change as long as the first address in `params.ips` stays the same. The data is offline from the delete until the copy back finishes, and we need room for a full copy outside the cluster, either in a local directory or in another S3 store.

1. Stop the clients that write, configure the alias, and copy everything out:

    ```bash
    genesis my-rustfs do mc
    mc mirror --preserve rustfs-my-rustfs /data/rustfs-stage
    mc admin cluster bucket export rustfs-my-rustfs
    mc admin cluster iam export rustfs-my-rustfs
    ```

    We check that the staging directory holds every bucket, for example with `mc diff rustfs-my-rustfs/<bucket> /data/rustfs-stage/<bucket>`, before we go on.

2. Delete the deployment:

    ```bash
    genesis my-rustfs bosh delete-deployment
    ```

    BOSH orphans the persistent disks, so the new nodes start on empty drives. We keep the orphaned disks until the copy back checks out, because they still hold the old data.

3. Edit `my-rustfs.yml`. Add the `cluster` feature and list every node's address in `params.ips`, keeping the old address first so that `s3_api_url` stays the same.

4. Renew the API certificate so that it names the new addresses, and deploy:

    ```bash
    genesis my-rustfs rotate-secrets certs/api
    genesis deploy my-rustfs
    ```

    The pre-deploy hook lets this deploy through, because there is no running deployment to compare it with. The credentials are marked `fixed` and the CA is only renewed, so both stay the same.

5. Configure the alias again, because the old one pointed at a node that no longer exists, and copy the data and settings back:

    ```bash
    genesis my-rustfs do mc
    mc mirror --preserve /data/rustfs-stage rustfs-my-rustfs
    mc admin cluster bucket import rustfs-my-rustfs rustfs-my-rustfs-bucket-metadata.zip
    mc admin cluster iam import rustfs-my-rustfs rustfs-my-rustfs-iam-info.zip
    ```

6. Check each bucket with `mc diff /data/rustfs-stage/<bucket> rustfs-my-rustfs/<bucket>` and each versioned bucket with `mc version info`, and then start the clients again. Once we trust the copy, we delete the staging directory, the IAM export, and the orphaned disks, which `genesis my-rustfs bosh disks --orphaned` lists and `genesis my-rustfs bosh delete-disk <disk-cid>` removes one at a time.

We use the same steps to shrink a cluster or to move between cluster sizes, with the new address list in step 3.

### Certificate Rotation

Genesis manages certificate rotation. To renew the API certificate, for example after the static IPs change or before it expires, name it on the command line:

```bash
genesis my-rustfs rotate-secrets certs/api
genesis deploy my-rustfs
```

To renew every certificate, name the `certs/` prefix instead:

```bash
genesis my-rustfs rotate-secrets certs/
genesis deploy my-rustfs
```

A renewal keeps each certificate's key and has the same CA sign it again, so peers that still hold the old certificate keep trusting the new one while the deploy rolls through the nodes.

That continuity holds only for a renewal. `genesis rotate-secrets --regen-x509-keys` issues new certificates with new keys, and when it reaches `certs/ca` it replaces the CA itself. During the rolling deploy, the updated nodes trust only the new CA and the others trust only the old one, so the cluster splits in two and stops serving until every node is updated. We avoid `--regen-x509-keys` on a running cluster, or we stop the whole deployment, deploy, and accept the outage.

The access and secret keys are marked `fixed`, so neither form of `rotate-secrets` touches them. The [reset-credentials](#reset-credentials-r) addon rotates them.

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
| Peer | `certs/peer` | 10 years | Rendered to the job, but RustFS 1.0 does not read it. Internode traffic uses the API certificate |
| API | `certs/api` | 2 years | S3 API and internode TLS. It names `rustfs_domain`, `127.0.0.1`, and every node's static IP |

The CA certificate is also exported to exodus for consumer kits.

## TLS and Clusters

The kit always sets the API certificate and key, so every node serves https only on port 9000 and refuses plaintext requests. RustFS serves internode RPC on that same port, and each node dials its peers at their IP addresses over https and verifies them against the kit's CA.

That verification means the API certificate must name every peer's IP address. The kit generates one certificate that all nodes share, and it names `rustfs_domain`, `127.0.0.1`, and every static IP that the blueprint assigns. The blueprint knows those addresses only when `params.ips` lists them or the `ocfp` feature reads them from the ocfp subnets. Genesis generates the certificate during `add-secrets`, before BOSH assigns any address from the cloud config's static range, so a cluster that relies on that range would get a certificate without its peers. The blueprint refuses that cluster and asks for `params.ips`. A single node never dials a peer, so it may still take its address from the static range. Its certificate then names only `rustfs_domain` and `127.0.0.1`, so clients outside the deployment that verify it by IP address refuse it. We list the node's address in `params.ips` whenever outside clients connect to it.

The certificate holds at most 16 static IP addresses, and the blueprint refuses a longer list. Each entry in `params.ips` must be a single IPv4 or IPv6 address, and the blueprint refuses a BOSH range such as `10.0.0.10 - 10.0.0.12`.

The manifest sets the deployment feature `use_dns_addresses: false`, so BOSH links hand out IP addresses even on a director that turns DNS addresses on. Peers then dial the same addresses that the certificate names.

When the static IPs change, the certificate needs the new names before the deploy. `genesis check-secrets` warns about the certificate and lists each missing address, and `genesis rotate-secrets certs/api` renews it, as [Scaling](#scaling) describes.

After a successful deploy, the post-deploy hook probes `/health/ready` on every node over https. It dials each node at its own IP address, the name that peers and clients use, and verifies the certificate against the kit CA on the node with that address as the name. When the kit knows no address list, as for a single node without `params.ips`, the certificate names only `127.0.0.1`, so the hook dials that instead and says so. It reports one of these results for each node:

- The node is ready, and its certificate verified against the kit CA.

- The node is ready, but its certificate did not verify against the kit CA. We rotate `certs/api` and redeploy.

- The node is ready, but the kit CA could not be read on the node, so the certificate was not verified.

- The probe failed, which usually means the cluster has no quorum yet, often because peers refuse each other's certificates.

Each result other than the first is a warning. The hook also warns when it cannot run the probe on a node, and none of these warnings fails the deploy.

## Resolute Stemcells

The `resolute` feature deploys RustFS on an Ubuntu Resolute (26.04) stemcell instead of Noble. It sets `params.stemcell_os` to `ubuntu-resolute` and pins bpm 1.4.41, because earlier bpm releases do not compile on Resolute. Noble deployments stay on bpm 1.4.22.

```yaml
kit:
  features:
  - resolute
```

The blueprint refuses two settings that would leave the stemcell and bpm out of step. It refuses the `resolute` feature together with a `stemcell_os` other than `ubuntu-resolute`, and it refuses `stemcell_os: ubuntu-resolute` without the feature. In both cases we remove the `stemcell_os` parameter and let the feature choose.

The pre-deploy hook then checks the merged manifest, because an environment file or a custom fragment can still override the stemcells or the bpm release. It refuses the deploy when any stemcell is not `ubuntu-resolute`, or when bpm is missing, `latest`, or older than 1.4.41.

On Noble the pre-deploy hook guards bpm as well. It refuses bpm 1.4.31, which starts no process on a cgroup v2 stemcell, and it refuses `latest` or a bpm release with no version, because either lets the director choose 1.4.31.

The director needs a Resolute stemcell before the deploy. Set `params.stemcell_version` to pin one, or leave it unset to take the latest that the director has. The cloud config hook needs no changes for Resolute, because none of its VM, disk, or network properties depend on the stemcell.

## Feature Reference

| Feature | Manifests Applied |
|---------|-------------------|
| `cluster` | `manifests/cluster.yml` |
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
| `instances` | Number of RustFS instances |
| `cluster` | `true` for a cluster. Set by the `cluster` feature, and always under `ocfp` |
| `cluster_size` | Number of cluster nodes. Set by the `cluster` feature, and always under `ocfp` |
| `domain` | The domain that the API certificate names, from `rustfs_domain` |
| `s3_api_url` | HTTPS URL of the first node's S3 API on `rustfs_port`, with an IPv6 address in brackets |
| `s3_console_url` | HTTPS URL of the first node's web console on `rustfs_console_port`, with an IPv6 address in brackets |
| `ca` | PEM-encoded CA certificate |
| `access_key` | The admin access key |

The URLs bracket an IPv6 address when `params.ips` or the `ocfp` feature supplies it. A single node without `params.ips` takes its address from the cloud config, and that address is not bracketed.
