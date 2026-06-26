# Vagrant Infrastructure

Documentation for the Vagrant + VMware Workstation infrastructure that defines
the `PlayAroundIT-cribl-elastic-otel-lab` environment: the VM topology, the
static IP scheme, how the host-only subnet was chosen, and the dynamically
generated `/etc/hosts` distribution.

---

## Overview

All lab VMs are defined in a single `Vagrantfile`, provisioned on **VMware
Workstation** via the `vagrant-vmware-desktop` provider, running Ubuntu 22.04
(`generic/ubuntu2204`). Nodes are organized into four tiers, each driven by a
count variable so the topology scales by changing one number.

| Tier          | Count var | Hostnames          | Static IPs              |
|---------------|-----------|--------------------|-------------------------|
| Elasticsearch | `ELASTIC` | `elastic-1..N`     | `192.168.65.11..13`     |
| Kibana        | `KIBANA`  | `kibana-1..N`      | `192.168.65.21..22`     |
| Cribl         | `CRIBL`   | `cribl-1..N`       | `192.168.65.31..33`     |
| App server    | `APP`     | `app-1..N`         | `192.168.65.41..43`     |

Current counts: 1 of each (single-node per tier), expandable.

---

## Design Decisions

### Count-variable-driven topology

Each tier is defined in a loop over a count variable (`ELASTIC`, `KIBANA`,
`CRIBL`, `APP`). To add a node, increment the count — the loop creates the VM,
assigns its IP, and wires its provisioners automatically. This keeps the
topology declarative and the Vagrantfile DRY.

### Static IPs on a VMware host-only network

Earlier iterations assumed VMware DHCP forced **dynamic** IPs (a long-standing
pain point), which drove a lot of manual per-rebuild IP wrangling. Testing showed
that **static IPs via `private_network` work reliably** on a VMware host-only
adapter. This was the single biggest simplification in the lab's design:

- IPs are stable across rebuilds → certs can carry IP SANs, `/etc/hosts` can be
  generated deterministically, and most manual bootstrap steps disappear.
- Full TLS hostname verification works everywhere (no `verificationMode:
  certificate` workaround needed).

#### IP scheme

A per-tier numbering on `192.168.65.0/24`:

```
.1x → Elasticsearch   (elastic-1 = .11, elastic-2 = .12, ...)
.2x → Kibana          (kibana-1  = .21, ...)
.3x → Cribl           (cribl-1   = .31, ...)
.4x → App server      (app-1     = .41, ...)
```

Implemented as `192.168.65.<tier-digit>#{i}` in each loop. Note: this scheme
assumes ≤ 9 nodes per tier (`.1#{10}` would overflow to `.110`). Fine given the
≤ 3-per-tier plan.

### How the host-only subnet was chosen

VMware Workstation creates several virtual network adapters on the Windows host.
To pick a subnet that VMware actually serves on a **host-only** adapter (not NAT,
not in use by other VMs), list the host's VMware adapters:

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -like "192.168.*" } |
  Select IPAddress, InterfaceAlias
```

Example output showed:

```
192.168.248.1  VMware Network Adapter VMnet8   (NAT)
192.168.10.1   VMware Network Adapter VMnet2
192.168.65.1   VMware Network Adapter VMnet1   (host-only)
...
```

`192.168.65.0/24` on **VMnet1** (a host-only adapter, host = `.65.1`) was chosen
because it was a host-only network and unused by any existing VMs. Picking an IP
on a subnet VMware does **not** serve is the usual reason static IPs appear "not
to work" — so confirming the adapter/subnet first is the key step.

#### Verifying static IPs work (the test that unblocked this design)

A throwaway node with a static IP was booted to confirm:

```ruby
config.vm.define "iptest" do |subconfig|
  subconfig.vm.hostname = "iptest"
  subconfig.vm.network "private_network", ip: "192.168.65.11"
end
```

Checks:
- `vagrant ssh iptest -c "ip -4 addr show | grep 192.168"` → the IP stuck.
- `ping 192.168.65.11` from the Windows host → success.
- Ping to the gateway `192.168.65.1` → **failed, and that's expected**: VMware
  host-only gateways commonly don't answer ICMP (host firewall), even though the
  network works. Host→guest success is the meaningful signal.

### Dynamically generated `/etc/hosts`

Because IPs are static and derived from the same count variables, the
`/etc/hosts` content is **generated in Ruby** from those counts and pushed to
every node via a global provisioner. One source of truth (the counts) drives both
the VMs and their name resolution, so they can't drift.

```ruby
def build_hosts_entries(elastic, kibana, cribl, app)
  entries = []
  (1..elastic).each { |i| entries << "192.168.65.1#{i} elastic-#{i}" }
  (1..kibana).each  { |i| entries << "192.168.65.2#{i} kibana-#{i}"  }
  (1..cribl).each   { |i| entries << "192.168.65.3#{i} cribl-#{i}"   }
  (1..app).each     { |i| entries << "192.168.65.4#{i} app-#{i}"     }
  entries.join("\n")
end
```

A global provisioner appends these to `/etc/hosts` on every node (idempotent via
a `grep` guard), running **before** the per-node install scripts so name
resolution is in place when they run.

#### Node names only — service names live in cert SANs

`/etc/hosts` contains **node names only** (`elastic-1`, etc.), not tier "service
names" (`elasticsearch`). Reasoning:

- The certs include both node names *and* the service name as SANs, so connecting
  by node name passes full verification — the service name isn't needed for
  resolution.
- A service-name alias in `/etc/hosts` would only point at one node and provides
  no load balancing or failover (`/etc/hosts` can't do either reliably).
- Clustering is done the Elastic-native way instead: **client-side multi-host
  lists** of node names (e.g. Kibana's `elasticsearch.hosts` array). Node names
  scale cleanly; the service name stays in the SANs as a future option for a
  VIP/load balancer without re-issuing certs.

### Synced folders disabled

`config.vm.synced_folder ".", "/vagrant", disabled: true`. The lab doesn't need
the repo mounted in the guests; files that must reach a VM (certs, the Cribl
package) are pushed explicitly via `file` provisioners. Keeps guests clean and
avoids VMware shared-folder quirks.

### Per-node resource overrides

Global default is `1 vCPU / 1024 MB`. Kibana overrides to `2 vCPU / 4096 MB`
inside its `define` block — Kibana's Node.js process OOM-crashes on 1 GB.
(Dropping that override once caused a crash-loop; see the Kibana doc.)

---

## Provisioner Ordering

Within each node, provisioners run in definition order, which matters:

1. **Global hosts provisioner** (defined at the `config` level) — runs first.
2. **`file` provisioners** — stage certs / packages into `/tmp`.
3. **`shell` provisioner** — the install script, which reads from `/tmp`.

`file` before `shell` is essential: the install scripts expect their certs to
already be in `/tmp` when they run.

---

## Certificate Distribution

Each server node receives only what it needs (least exposure):

| Node tier | Files pushed to `/tmp`                                   |
|-----------|----------------------------------------------------------|
| elastic   | `ca.crt`, `elasticsearch-chain.crt`, `elasticsearch.key` |
| kibana    | `ca.crt`, `kibana-chain.crt`, `kibana.key`               |
| cribl     | `ca.crt`, `cribl-chain.crt`, `cribl.key`, Cribl package  |
| app       | (none yet — base config only)                            |

Servers receive the **`-chain.crt`** (leaf + CA) — what they present — not the
bare leaf. The CA **key** is never distributed. See the certificate-generation
doc for why the chain matters.

---

## Adding a Node (worked example)

To add `elastic-2`:

1. Set `ELASTIC = 2`.
2. `vagrant up elastic-2` — it gets `192.168.65.12`, the generated `/etc/hosts`
   includes it, and it receives the same `elasticsearch` tier certs (its name and
   IP are already in the SANs).
3. Add it to client host-arrays (Kibana `elasticsearch.hosts`, etc.) when you
   actually want clients to use it.
4. (For a real ES cluster: also configure transport TLS and replace
   `discovery.type: single-node` with proper discovery settings — a separate
   exercise.)

No cert regeneration needed until a tier exceeds its pre-covered SAN count
(3 elastic / 2 kibana / 3 cribl / 3 app).

---

## Prerequisites Before `vagrant up`

Both gitignored — regenerate/download on a fresh clone:

- **Certificates:** `bash scripts/generate-certs.sh` → populates `certs/`.
- **Cribl package:** place the tarball in `packages/` matching the filename in
  the Cribl `file` provisioner.