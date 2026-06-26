# Manual Steps / Rebuild Runbook

A running list of every manual step required to bring the
`PlayAroundIT-cribl-elastic-otel-lab` environment up from a clean
`vagrant destroy` → `vagrant up`. Everything **not** handled automatically by
the provision scripts lives here.

This doubles as:
- a **rebuild runbook** (walk top to bottom after a full rebuild), and
- a **visible backlog of automation candidates**.

> Convention: append a new entry every time we introduce a manual step.

> **Note (post-redesign):** the static-IP + SAN + generated-`/etc/hosts` redesign
> **eliminated most of the manual steps** that used to live here. Kibana now
> connects to ES automatically on first boot; Cribl/Fleet connect by node name
> with full TLS verification — no per-rebuild `/etc/hosts` edits. What remains is
> a short list, mostly Cribl UI hands-on steps left manual *on purpose*.

---

## Pre-Provision (one-time / host-side)

Prerequisites that must exist in the repo before `vagrant up`. Gitignored, so
they don't travel with the repo and must be regenerated/downloaded on a fresh
clone.

- **Generate certificates.** Run once on the Windows host (Git Bash):
  ```bash
  bash scripts/generate-certs.sh
  ```
  Produces `certs/` — CA + per-tier certs **with SANs** and `-chain.crt` files.
  Gitignored.
- **Download the Cribl package.** Place the Cribl Stream tarball in `packages/`:
  ```
  packages/cribl-4.18.2-fd1f0d2f-linux-x64.tgz
  ```
  Gitignored (too large for GitHub). Must match the filename in the Vagrantfile
  Cribl `file` provisioner.

---

## Per-Rebuild Manual Steps

What's genuinely still manual after a full `vagrant up`. (Elasticsearch and
Kibana now come up fully connected with **no** manual steps.)

### 1. Cribl: change default admin password

Cribl boots with default credentials `admin / admin`. Change it after first
login (UI). Left manual deliberately — simplicity.

### 2. Cribl: configure UI TLS (HTTPS)

Cribl boots on plain HTTP. The `cribl-chain.crt` / `cribl.key` certs are parked
in `/opt/cribl/lab-certs/` for this. Configure HTTPS for the UI in the Cribl UI.
Left manual **on purpose** — good hands-on TLS practice. (Cribl presents the
chain cert, same pattern as the other servers.)

### 3. Cribl: configure the Elasticsearch destination

In the Cribl UI, set up the Elasticsearch destination:
- Bulk API URL: `https://elastic-1:9200/_bulk`  (node name; resolves via
  generated `/etc/hosts`; `elastic-1` is in the ES cert SANs)
- Auth: username/password — `elastic` / `<elastic password>`
- Validate server certs (`rejectUnauthorized`): **enabled**

CA trust is automated (`NODE_EXTRA_CA_CERTS` drop-in in `cribl.sh`), and ES
presents its chain, so full validation works on the first try. See the Cribl doc.

### 4. Fleet Server: install on kibana-1

Run the Fleet Server install (presents the lab-signed kibana cert). Requires a
fresh **service token** from the Fleet UI:
```bash
sudo ./elastic-agent install \
  --url=https://kibana-1:8220 \
  --certificate-authorities=/etc/kibana/certs/ca.crt \
  --fleet-server-es=https://elastic-1:9200 \
  --fleet-server-es-ca=/etc/kibana/certs/ca.crt \
  --fleet-server-cert=/etc/kibana/certs/kibana-chain.crt \
  --fleet-server-cert-key=/etc/kibana/certs/kibana.key \
  --fleet-server-service-token=<token> \
  --fleet-server-policy=fleet-server-policy \
  --fleet-server-port=8220 \
  --install-servers
```
Then in Fleet → Settings: set the **Fleet Server host** to `https://kibana-1:8220`
(watch for the `8200`/`8220` typo) and the **default ES output** to
`https://elastic-1:9200` with the lab CA **trusted fingerprint**. See the Fleet
doc.

### 5. Elastic Agent: enroll on app-1

Requires a fresh **enrollment token**:
```bash
sudo ./elastic-agent install \
  --url=https://kibana-1:8220 \
  --enrollment-token=<token> \
  --certificate-authorities=/etc/lab-certs/ca.crt
```
No `--insecure` — Fleet presents a lab-signed cert. See the agent-enrollment
runbook.

---

## Resolved (previously manual, now automated)

Kept for history — these used to be per-rebuild steps and are now handled
automatically by the redesign:

- **Kibana → ES bootstrap** — *gone.* Kibana points at `https://elastic-1:9200`
  directly (was an `ELASTIC_HOST` placeholder + manual `sed`).
- **Cribl `/etc/hosts` entry for `elasticsearch`** — *gone.* Cribl connects by
  `elastic-1`, resolved via the generated `/etc/hosts`.
- **Fleet `/etc/hosts` entry** — *gone.* Same reason.
- **`NODE_EXTRA_CA_CERTS` on Cribl** — automated via systemd drop-in in
  `cribl.sh`.
- **Per-rebuild IP gathering** — *gone.* Static IPs (`192.168.65.0/24`) mean IPs
  are known ahead of time; `/etc/hosts` is generated from the Vagrantfile node
  counts.

The DNS/dynamic-IP problem that drove all of the above is **solved** by static
IPs + generated `/etc/hosts` + multi-SAN certs. See the Vagrant infrastructure
and certificate-generation docs.

---

## Deferred / Environment-Wide Items

Not per-rebuild steps, but tracked so they're not lost:

- **Kibana file logging.** Kibana logs to journald only; no
  `/var/log/kibana/kibana.log` by default. How-to in the Kibana doc.
- **Least-privilege ingest user.** Cribl→ES (and the agent output) currently use
  the `elastic` superuser. Production should use a dedicated least-privilege user
  / API key scoped to the destination index.
- **Elasticsearch version pin.** Currently latest 9.x via apt. Pin the exact
  version when scaling out additional nodes.
- **Transport TLS / multi-node ES.** Single-node now; multi-node requires
  transport TLS (port 9300) and proper discovery settings (replacing
  `discovery.type: single-node`).
- **SAN headroom.** Certs pre-cover 3 elastic / 2 kibana / 3 cribl / 3 app.
  Exceeding those counts requires regenerating certs with expanded SANs.
- **Cribl admin password + UI TLS automation.** Left manual on purpose; could be
  scripted later if the hands-on value wears off.

---

## Full-Rebuild Quick Sequence

1. (Host) `bash scripts/generate-certs.sh`; ensure Cribl tarball in `packages/`.
2. `vagrant up` — ES + Kibana come up fully connected; Cribl + app base-installed.
3. Cribl UI: change admin password, configure UI TLS, configure ES destination.
4. Fleet: install Fleet Server on kibana-1; set Fleet host (`:8220`) + default ES
   output (fingerprint).
5. Agent: enroll on app-1.
6. (Pipeline) Create Cribl output in Fleet, assign to app-1 policy, restart agent.