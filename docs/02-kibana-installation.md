# Kibana Installation

Documentation for the single-node Kibana deployment in the
`PlayAroundIT-cribl-elastic-otel-lab` environment. Covers the install script,
design decisions, the manual bootstrap to Elasticsearch, verification, and the
lessons learned getting there.

---

## Overview

A single Kibana node (`kibana-1`) provisioned via Vagrant + VMware Workstation
on Ubuntu 22.04. Kibana serves its web UI over **HTTPS** using the lab CA, and
connects to Elasticsearch over TLS using `verificationMode: certificate`. This
node is also the intended future home of **Fleet Server**.

| Property        | Value                              |
|-----------------|------------------------------------|
| Node name       | `kibana-1`                         |
| Version line    | Elastic 9.x (latest via apt)       |
| UI endpoint     | `https://<vm-ip>:5601` (HTTPS)     |
| ES connection   | `https://<elastic-1-ip>:9200`      |
| ES auth user    | `kibana_system`                    |
| Resources       | 2 vCPU / 4096 MB RAM               |
| TLS (UI)        | Enabled, lab CA (`kibana.crt`)     |
| TLS (to ES)     | CA trust, `verificationMode: certificate` |

---

## Design Decisions

### HTTPS on the Kibana UI

The Kibana web UI runs over HTTPS using our lab `kibana.crt` / `kibana.key`.
Browsers will warn about an untrusted certificate (our CA isn't in the OS trust
store) — expected in a lab; click through. This keeps the lab faithful to
production, where the UI is essentially always behind TLS.

The `kibana.crt` / `kibana.key` pair exists **only** for this purpose (serving
the UI). For the Kibana → Elasticsearch connection, Kibana only needs `ca.crt`
to *trust* ES — it does not present a client certificate.

### verificationMode: certificate

Kibana connects to Elasticsearch with:
```yaml
elasticsearch.ssl.verificationMode: certificate
```
This keeps **full CA trust** (the cert must be validly signed by our CA) but
**skips hostname verification**. Required because our certs are CN-only (no
SANs), and because VMware DHCP assigns IPs dynamically — so pinning a hostname
isn't practical. This setting lives on the **client** (Kibana); there is nothing
to configure on Elasticsearch for it. See the Elasticsearch doc's TLS mental
model for why verification is the client's job.

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
   (`root:kibana`, `640`).
5. Write `kibana.yml`: UI HTTPS, plus the ES connection block with an
   **`ELASTIC_HOST` placeholder** (filled in at bootstrap).
6. Generate Kibana encryption keys.
7. Enable + start the service.
8. Print the UI URL and the manual bootstrap instructions.

### Certificate distribution (Vagrantfile)

`file` provisioners stage certs in `/tmp` before the shell provisioner. Only
`ca.crt` and the `kibana.*` pair go to this node.

```ruby
subconfig.vm.provider "vmware_desktop" do |v|
  v.cpus   = 2
  v.memory = 4096
end

subconfig.vm.provision "file",
  source: "certs/ca.crt", destination: "/tmp/ca.crt"
subconfig.vm.provision "file",
  source: "certs/kibana.crt", destination: "/tmp/kibana.crt"
subconfig.vm.provision "file",
  source: "certs/kibana.key", destination: "/tmp/kibana.key"
```

> **Note:** the `provider` override (2 vCPU / 4 GB) **must** be inside the
> `define` block. It was accidentally dropped once during development, causing
> the OOM crash-loop below.

---

## Manual Bootstrap to Elasticsearch

The install deliberately leaves the ES host as a placeholder, so installation
and wiring are separate, debuggable steps. To bootstrap:

**1. Get `elastic-1`'s IP** (from the host):
```bash
vagrant ssh elastic-1 -c "hostname -I | awk '{print \$1}'"
```

**2. Replace the placeholder** (on `kibana-1`):
```bash
sudo sed -i 's/ELASTIC_HOST/<elastic-1-ip>/' /etc/kibana/kibana.yml
```

**3. Verify:**
```bash
sudo grep elasticsearch.hosts /etc/kibana/kibana.yml
```

**4. Restart:**
```bash
sudo systemctl restart kibana
```

**5. Wait ~30–60s, confirm:**
```bash
curl -k https://localhost:5601/api/status
```
Status should move toward `available`.

### Scaling later

For an Elasticsearch cluster, `elasticsearch.hosts` becomes an array; Kibana
round-robins across nodes:
```yaml
elasticsearch.hosts: ["https://ip1:9200", "https://ip2:9200", "https://ip3:9200"]
```

---

## Verification

### 1. Cluster health (Kibana Dev Tools)
```
GET _cluster/health
```
Expect `green`/`yellow`, `number_of_nodes: 1`.

### 2. Correct cluster (Dev Tools)
```
GET /
```
Expect `cluster_name: cribl-elastic-otel-lab`, 9.x version.

### 3. Fleet loads
Management → **Fleet** should load without error (no agents enrolled yet).

### 4. Kibana status available (terminal)
```bash
curl -k https://localhost:5601/api/status | python3 -m json.tool | grep -A2 '"overall"'
```
Expect `"level": "available"`.

### 5. UI serves our cert (terminal)
```bash
echo | openssl s_client -connect localhost:5601 2>/dev/null \
  | openssl x509 -noout -issuer -subject
```
Expect `issuer=CN = PlayAroundIT-Lab-CA`, `subject=CN = kibana`.

### Browser
`https://<kibana-1-ip>:5601` → click through the cert warning → log in as
`elastic` / `adminuser123!`.

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

### "Elastic did not load properly" / endless spinner is EXPECTED pre-bootstrap

Before bootstrap, `kibana.yml` still has the literal `ELASTIC_HOST` placeholder,
so Kibana can't reach ES. The UI shell loads but can't hydrate — you get the
error screen or an endless spinner. This is **expected**, not a bug. The
terminal `/api/status` returning `unavailable` is the same fact reported
cleanly. Both resolve the moment you bootstrap. Two distinct "not available"
causes to keep separate: (1) can't reach ES (placeholder), (2) reaches ES but
ES is unhealthy.

### s_client against a key vs. a cert

Running `openssl x509` against a **key** file (instead of a cert) gives
`Could not read certificate from <stdin>` / `Unable to load certificate`. That's
operator error, not a real cert problem — point `x509` at the `.crt`, and use
`openssl rsa -check` for the `.key`.

---

## Known Items / TODO

- **File logging not yet configured.** Kibana logs to **stdout/stderr**, which
  systemd captures in the journal (`journalctl -u kibana`). Unlike
  Elasticsearch, Kibana writes **no** `/var/log/kibana/kibana.log` by default —
  the missing file is expected, not a fault. To add file logging later, set a
  `logging.appenders` file appender in `kibana.yml`, create
  `/var/log/kibana` owned by `kibana:kibana`, and bake both into `kibana.sh`,
  then rebuild to verify. Deferred to avoid disturbing the working stack.
- **Fleet Server** not yet set up on this node (planned).
- **File logging + SANs** carry over as environment-wide hardening items.

---

## Next Steps

- **Cribl** (`cribl-1`): install, distribute `ca.crt` + `cribl.*`, stand up a
  single-node Cribl Stream with its HTTPS UI.
- **App server** (`app-1`): base config, later the Elastic Agent / OTel
  collector for generating test data into the pipeline.