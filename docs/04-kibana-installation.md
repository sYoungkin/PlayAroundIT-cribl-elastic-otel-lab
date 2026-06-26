# Kibana Installation

Documentation for the single-node Kibana deployment in the
`PlayAroundIT-cribl-elastic-otel-lab` environment. Covers the install script,
design decisions, verification, and the lessons learned getting there.

---

## Overview

A single Kibana node (`kibana-1`) provisioned via Vagrant + VMware Workstation
on Ubuntu 22.04. Kibana serves its web UI over **HTTPS** using the lab CA, and
connects to Elasticsearch over TLS with **full verification** by node name. This
node is also the home of **Fleet Server** (see the Fleet doc). With static IPs
and proper SANs, Kibana connects to ES on first boot — **no manual bootstrap
step**.

| Property        | Value                              |
|-----------------|------------------------------------|
| Node name       | `kibana-1`                         |
| Static IP       | `192.168.65.21`                    |
| Version line    | Elastic 9.x (latest via apt)       |
| UI endpoint     | `https://kibana-1:5601` (HTTPS)    |
| ES connection   | `https://elastic-1:9200`           |
| ES auth user    | `kibana_system`                    |
| Resources       | 2 vCPU / 4096 MB RAM               |
| TLS (UI)        | Enabled, lab CA (`kibana-chain.crt`)|
| TLS (to ES)     | CA trust + `verificationMode: full`|

---

## Design Decisions

### HTTPS on the Kibana UI

The Kibana web UI runs over HTTPS using our lab `kibana-chain.crt` /
`kibana.key`. Browsers will warn about an untrusted certificate (our CA isn't in
the OS trust store) — expected in a lab; click through. This keeps the lab
faithful to production, where the UI is essentially always behind TLS.

Kibana serves the **chain** file (leaf + CA), consistent with the other servers
in the lab. The `kibana-chain.crt` / `kibana.key` pair exists **only** for
serving the UI. For the Kibana → Elasticsearch connection, Kibana only needs
`ca.crt` to *trust* ES — it does not present a client certificate.

### Full verification + direct ES connection (no bootstrap)

Kibana connects to Elasticsearch with:
```yaml
elasticsearch.hosts: ["https://elastic-1:9200"]
elasticsearch.ssl.verificationMode: full
```

Two things this gives us, both products of the static-IP + SAN redesign:

- **Direct connection, no placeholder.** Because `elastic-1` is a static IP
  resolved via the generated `/etc/hosts`, the script points Kibana straight at
  `https://elastic-1:9200`. The old `ELASTIC_HOST` placeholder and its manual
  `sed` bootstrap step are **gone**.
- **Full verification.** Because the ES cert carries `elastic-1` as a SAN and ES
  presents the chain, Kibana uses `verificationMode: full` (CA trust *and*
  hostname check) — the previous `verificationMode: certificate` workaround is
  no longer needed.

> **Startup dependency:** Kibana now connects to `elastic-1` at startup, so ES
> should be up when Kibana provisions. In a full `vagrant up`, Vagrant boots
> nodes in definition order (elastic before kibana), so this is generally fine.
> And Kibana retries the ES connection, so a brief "not yet ready" window while
> ES finishes starting resolves itself. If `kibana-1` is provisioned while
> `elastic-1` is down, Kibana stays unhealthy until ES returns — expected.

### Authentication via kibana_system

Kibana authenticates to Elasticsearch using the built-in `kibana_system` user
and password — **not** a client certificate. The password is set during the
Elasticsearch provisioning (via the security API) and reused here. The browser
login uses the `elastic` superuser; `kibana_system` is reserved for
Kibana↔ES background communication and cannot log in via the browser.

### Resources: 2 vCPU / 4 GB

Kibana 9.x runs on Node.js and is memory-hungry, especially during startup
optimization. The default lab VM size (1 vCPU / 1 GB) causes a Node heap OOM
crash-loop (see Lessons Learned). The provider override in the Vagrantfile sets
`kibana-1` to 2 vCPU / 4096 MB.

---

## What the Install Script Does

`scripts/kibana.sh`, in order:

1. Install dependencies, set timezone (`Europe/Berlin`).
2. Add the Elastic GPG key and 9.x apt repository.
3. Install the `kibana` package.
4. Copy lab certs from `/tmp` into `/etc/kibana/certs/`
   (`root:kibana`, `640`) — `ca.crt`, `kibana-chain.crt`, `kibana.key`.
5. Write `kibana.yml`: UI HTTPS (chain cert) + the ES connection pointing
   directly at `https://elastic-1:9200` with `verificationMode: full`.
6. Generate Kibana encryption keys.
7. Enable + start the service.
8. Print the UI URL.

### The relevant kibana.yml blocks

```yaml
# Kibana UI HTTPS (browser -> Kibana)
server.ssl.enabled: true
server.ssl.certificate: /etc/kibana/certs/kibana-chain.crt
server.ssl.key: /etc/kibana/certs/kibana.key

# Elasticsearch connection (direct, full verification)
elasticsearch.hosts: ["https://elastic-1:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "adminuser123!"
elasticsearch.ssl.certificateAuthorities: ["/etc/kibana/certs/ca.crt"]
elasticsearch.ssl.verificationMode: full
```

### Certificate distribution (Vagrantfile)

`file` provisioners stage certs in `/tmp` before the shell provisioner. Only
`ca.crt`, the chain, and the key go to this node.

```ruby
subconfig.vm.provider "vmware_desktop" do |v|
  v.cpus   = 2
  v.memory = 4096
end

subconfig.vm.provision "file",
  source: "certs/ca.crt", destination: "/tmp/ca.crt"
subconfig.vm.provision "file",
  source: "certs/kibana-chain.crt", destination: "/tmp/kibana-chain.crt"
subconfig.vm.provision "file",
  source: "certs/kibana.key", destination: "/tmp/kibana.key"
```

> **Note:** the `provider` override (2 vCPU / 4 GB) **must** be inside the
> `define` block. It was accidentally dropped once during development, causing
> the OOM crash-loop below.

---

## Scaling Later

For an Elasticsearch cluster, `elasticsearch.hosts` becomes an array of node
names; Kibana round-robins and fails over across them:
```yaml
elasticsearch.hosts: ["https://elastic-1:9200", "https://elastic-2:9200", "https://elastic-3:9200"]
```
All node names are already in the ES cert SANs, so full verification keeps
working as nodes are added.

---

## Verification

### 1. /etc/hosts has the full generated block
```bash
cat /etc/hosts
```
Expect the `LAB-HOSTS-BLOCK` marker and all tier node entries (elastic-1,
kibana-1, cribl-1, app-1 at their static IPs) — present even if only some nodes
are booted, since the block is generated from the count variables.

### 2. Cluster health (Kibana Dev Tools)
```
GET _cluster/health
```
Expect `green`/`yellow`, `number_of_nodes: 1`.

### 3. Correct cluster (Dev Tools)
```
GET /
```
Expect `cluster_name: cribl-elastic-otel-lab`, 9.x version.

### 4. Kibana status available — on first boot, no bootstrap (terminal)
```bash
curl -k https://localhost:5601/api/status | python3 -m json.tool | grep -A2 '"overall"'
```
Expect `"level": "available"` — reached on its own because Kibana connected
directly to `elastic-1`.

### 5. UI serves the chain (terminal)
```bash
echo | openssl s_client -connect localhost:5601 -showcerts 2>/dev/null \
  | grep -c "BEGIN CERTIFICATE"
```
Expect `2` (leaf + CA).

### Browser
`https://192.168.65.21:5601` (or `https://kibana-1:5601` if your host resolves
it) → click through the cert warning → log in as `elastic` / `adminuser123!`.
Lands on a **real login page**, not "server not ready".

---

## Lessons Learned

### Node.js heap OOM crash-loop (the big one)

**Symptom:** the UI shows "Elastic did not load properly" or just spins
forever; `ss` shows port 5601 listening one moment, `curl` gets *connection
refused* the next.

**Real cause (from journald):**
```
FATAL ERROR: ... JavaScript heap out of memory
kibana.service: Main process exited, code=dumped, status=6/ABRT
```
Kibana was starting, exhausting its Node heap, aborting, and being restarted by
systemd — a crash-loop. The "listening then refused" pattern is the tell:
`ss` catches an "up" blip, `curl` catches a "down" blip.

**Cause:** the VM had only 1 GB RAM — the Vagrantfile `provider` override (2
vCPU / 4 GB) had been accidentally dropped. Confirm actual RAM with `free -h`.

**Fix:** restore the `provider` override inside the Kibana `define` block,
then `vagrant destroy kibana-1 -f && vagrant up kibana-1` (RAM is set at VM
creation, so a reload won't apply it).

### s_client against a key vs. a cert

Running `openssl x509` against a **key** file (instead of a cert) gives
`Could not read certificate from <stdin>` / `Unable to load certificate`. That's
operator error, not a real cert problem — point `x509` at the `.crt`, and use
`openssl rsa -check` for the `.key`.

### (Historical) Manual ES bootstrap

Earlier, with dynamic DHCP, `kibana.yml` shipped with an `ELASTIC_HOST`
placeholder that had to be `sed`-replaced with elastic-1's IP and Kibana
restarted — a per-rebuild manual step. The static-IP redesign **eliminated**
this: Kibana points at `https://elastic-1:9200` directly and comes up connected
on first boot. (If you ever see a Kibana "not ready" state now, it's a genuine
ES-reachability problem, not the old expected pre-bootstrap state.)

---

## Known Items / TODO

- **File logging not yet configured.** Kibana logs to **stdout/stderr**, which
  systemd captures in the journal (`journalctl -u kibana`). Unlike
  Elasticsearch, Kibana writes **no** `/var/log/kibana/kibana.log` by default —
  the missing file is expected, not a fault. To add file logging later, set a
  `logging.appenders` file appender in `kibana.yml`, create
  `/var/log/kibana` owned by `kibana:kibana`, and bake both into `kibana.sh`,
  then rebuild to verify. Deferred to avoid disturbing the working stack.

---

## Next Steps

- **Cribl** (`cribl-1`): install, distribute `ca.crt` + `cribl-chain.crt` +
  `cribl.key`, stand up a single-node Cribl Stream; configure the ES destination
  and (manual) UI TLS.
- **App server** (`app-1`): base config, later the Elastic Agent / OTel
  collector for generating test data into the pipeline.