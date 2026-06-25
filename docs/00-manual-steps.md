# Manual Steps / Rebuild Runbook

A running list of every manual step required to bring the
`PlayAroundIT-cribl-elastic-otel-lab` environment up from a clean
`vagrant destroy` → `vagrant up`. Everything **not** handled automatically by
the provision scripts lives here.

This doubles as:
- a **rebuild runbook** (walk top to bottom after a full rebuild), and
- a **visible backlog of automation candidates** (each manual step is a thing we
  *could* eventually script).

> Convention: append a new entry every time we introduce a manual step.

---

## Pre-Provision (one-time / host-side)

These are prerequisites that must exist in the repo before `vagrant up`. They're
gitignored, so they don't travel with the repo and must be regenerated/downloaded
on a fresh clone.

- **Generate certificates.** Run once on the Windows host (Git Bash):
  ```bash
  bash scripts/generate-certs.sh
  ```
  Produces `certs/` (CA + per-service certs). Gitignored.
- **Download the Cribl package.** Place the Cribl Stream tarball in `packages/`:
  ```
  packages/cribl-4.18.2-fd1f0d2f-linux-x64.tgz
  ```
  Gitignored (too large for GitHub). Must match the filename referenced in the
  Vagrantfile Cribl `file` provisioner.

---

## Per-Rebuild Manual Steps

### 1. Bootstrap Kibana → Elasticsearch

Kibana ships with an `ELASTIC_HOST` placeholder in `kibana.yml`; it can't reach
ES until the real IP is filled in (VMware DHCP, so the IP isn't known until boot).

```bash
# Get elastic-1's IP (from host)
vagrant ssh elastic-1 -c "hostname -I | awk '{print \$1}'"

# On kibana-1, replace the placeholder
sudo sed -i 's/ELASTIC_HOST/<elastic-1-ip>/' /etc/kibana/kibana.yml
sudo systemctl restart kibana
```

Verify: `curl -k https://localhost:5601/api/status` → moves toward `available`.

**Automation candidate:** IP injection (see DNS note below).

---

### 2. Cribl → Elasticsearch: hostname resolution

The Cribl Elasticsearch destination connects to `https://elasticsearch:9200/_bulk`.
The ES server certificate is valid for the name `elasticsearch`, **not** the IP,
so Cribl must resolve that name. Add an `/etc/hosts` entry on the Cribl node:

```bash
# On cribl-1 (use elastic-1's current DHCP IP)
echo "<elastic-1-ip> elasticsearch" | sudo tee -a /etc/hosts
```

**Automation candidate:** IP injection / DNS (see DNS note below).

> Note: `NODE_EXTRA_CA_CERTS` (Cribl trusting the lab CA) is now **automated**
> in `cribl.sh` via a systemd drop-in, so it is *not* a manual step anymore.

---

### 3. Cribl: change default admin password

Cribl boots with default credentials `admin / admin`. Change it after first
login (UI: Settings → ... → Local Users, or via the change-password prompt).

**Automation candidate:** deferred deliberately — left manual for simplicity.

---

### 4. Cribl: configure UI TLS (HTTPS)

Cribl boots on plain HTTP. The `cribl.crt` / `cribl.key` certs are parked in
`/opt/cribl/lab-certs/` for this. Configure HTTPS for the UI through the Cribl
UI (Settings → Security/TLS). Left manual **on purpose** — good hands-on TLS
practice.

---

### 5. Cribl: configure the Elasticsearch destination

Through the Cribl UI, set up the Elasticsearch destination:
- Bulk API URL: `https://elasticsearch:9200/_bulk`
- Auth: username/password — `elastic` / `<elastic password>`
- Validate server certs: **enabled**

(Depends on steps 2 and the automated `NODE_EXTRA_CA_CERTS`.) Full reasoning and
the five-test progression are documented in the Cribl→ES destination lesson page.

---

## DNS / IP-Injection Note (deferred automation)

Several manual steps above (1 and 2) exist for the same root reason: **VMware
DHCP assigns IPs dynamically**, so nodes can't refer to each other by a stable
name or IP at provision time.

A single future fix would collapse both:
- A post-`vagrant up` script that gathers every node's IP and pushes a
  consistent `/etc/hosts` block to all nodes, **or**
- A small DNS service (e.g. dnsmasq on one node) that all nodes point at.

**Decision:** deferred. With dynamic DHCP this isn't low-effort enough to justify
doing mid-flow, and the manual steps are tolerable. Revisit once the node count
grows or the manual steps become annoying.

---

## Other Deferred / Environment-Wide Items

These aren't per-rebuild manual steps, but are tracked here so they're not lost:

- **Certificate SANs.** Lab certs are CN-only (no SANs), which is why hostname
  verification requires `verificationMode: certificate` (Kibana) and the
  `/etc/hosts` name-matching trick (Cribl). Proper fix: regenerate certs with
  DNS/IP SANs. Deferred due to dynamic DHCP.
- **Kibana file logging.** Kibana logs to journald only; no
  `/var/log/kibana/kibana.log` by default. How-to captured in the Kibana doc.
- **Least-privilege ingest user.** Cribl→ES currently uses the `elastic`
  superuser. Production should use a dedicated least-privilege ingest user / API
  key.
- **Elasticsearch version pin.** Currently latest 9.x via apt. Pin the exact
  version when scaling out additional nodes.
- **Transport TLS / multi-node.** Single-node now; multi-node ES requires
  transport TLS and proper discovery settings.