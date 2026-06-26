# Cribl Installation & Elasticsearch Destination

Documentation for the single-node Cribl Stream deployment (`cribl-1`) in the
`PlayAroundIT-cribl-elastic-otel-lab` environment, and the TLS-validated
Elasticsearch destination it sends events to.

---

## Overview

Cribl Stream runs on `cribl-1` (static IP `192.168.65.31`), installed from a
local tarball, running as a dedicated `cribl` user. It connects to Elasticsearch
over HTTPS with **full certificate validation**, using the Bulk API. The Cribl
node trusts the lab CA via a `NODE_EXTRA_CA_CERTS` systemd drop-in (automated in
the install script).

| Property            | Value                                   |
|---------------------|-----------------------------------------|
| Node name           | `cribl-1`                               |
| Static IP           | `192.168.65.31`                         |
| Version             | Cribl Stream 4.18.2 (local tarball)     |
| Run-as user         | `cribl`                                 |
| UI                  | `http://cribl-1:9000` (HTTP, default)   |
| Default login       | `admin / admin` (change after first login) |
| ES destination URL  | `https://elastic-1:9200/_bulk`          |
| CA trust            | `NODE_EXTRA_CA_CERTS` drop-in (lab CA)  |

---

## Install Design Decisions

### Local package, not a repo

Cribl isn't installed from an apt repo — the versioned tarball lives in
`packages/` (gitignored) and is pushed to the VM via a `file` provisioner, then
extracted to `/opt`. This pins the version deterministically (4.18.2) and works
offline, sidestepping CDN URL/hash fragility.

### Dedicated `cribl` user

Cribl is installed and run as the same dedicated `cribl` user (per Cribl's
guidance) to avoid permission issues. Ownership of `/opt/cribl` is set to
`cribl:cribl` before `boot-start`.

### boot-start generates the systemd unit

`cribl boot-start enable -m systemd -u cribl` generates the `cribl.service`
unit — we don't hand-write it.

### CA trust via systemd drop-in (automated)

The Cribl process (Node.js) trusts the lab CA through:
```ini
[Service]
Environment="NODE_EXTRA_CA_CERTS=/opt/cribl/lab-certs/ca.crt"
```
This is written as a **drop-in** at
`/etc/systemd/system/cribl.service.d/ca-trust.conf` — *not* by editing the
generated unit directly. The drop-in survives `boot-start` regenerating
`cribl.service`. This was originally done by hand (`systemctl edit cribl`); it's
now automated in `cribl.sh` so a fresh build trusts the CA on first start.

### Certs parked, TLS-input + password left manual

The install parks `ca.crt`, `cribl-chain.crt`, and `cribl.key` in
`/opt/cribl/lab-certs/` (owned `cribl:cribl`). The ES destination only needs the
CA trust (above). The `cribl-chain.crt` / `cribl.key` are there for when Cribl's
own **TLS input** (agent → Cribl) is configured later — Cribl will present the
chain, same pattern as every other server. Cribl boots on **HTTP** with default
`admin/admin`; UI TLS and the password change are deliberately left as manual
hands-on steps.

---

## The Elasticsearch Destination

The working destination (Bulk API, full validation). Key fields from the
exported config:

```json
{
  "type": "elastic",
  "index": "test",
  "urls": [{ "weight": 1, "url": "https://elastic-1:9200/_bulk" }],
  "rejectUnauthorized": true,
  "auth": { "authType": "manual", "username": "elastic", "password": "<elastic password>" },
  "writeAction": "create",
  "loadBalanced": true,
  "compress": true
}
```

What matters:

- **`url: https://elastic-1:9200/_bulk`** — connects by **node name** (not IP,
  not a `/etc/hosts` alias). `elastic-1` resolves via the generated `/etc/hosts`
  and is in the ES cert SANs, so full hostname verification passes.
- **`rejectUnauthorized: true`** — Cribl fully validates the ES server cert. Works
  because ES presents the chain and Cribl trusts the CA via `NODE_EXTRA_CA_CERTS`.
- **`auth: manual` with `elastic` / password** — authentication happens *inside*
  the established TLS session (username/password, not a client cert).
- **`writeAction: create`**, **`index: test`** — events land in the `test` index.

### How the current flow works

```
1. Cribl destination → https://elastic-1:9200/_bulk
2. cribl-1 resolves elastic-1 → 192.168.65.11 (generated /etc/hosts)
3. Elasticsearch presents its cert chain (leaf + CA)
4. Cribl validates it: hostname (elastic-1 is a SAN) + CA trust
   (NODE_EXTRA_CA_CERTS) → full validation passes
5. Cribl authenticates with elastic username/password inside TLS
6. Events sent via Bulk API, indexed, visible in Kibana
```

Compared to the original setup, this is dramatically simpler: no `/etc/hosts`
service alias, no IP-vs-hostname juggling — the cert identity matches the node
name we connect by.

---

## Conceptual Lessons (timeless)

These hold regardless of the IP/SAN specifics.

### Several layers, not one thing

A working destination is the sum of separate, independent layers:
```
DNS / name resolution
TLS transport (https:// vs http://)
Server certificate validation (rejectUnauthorized)
CA trust (NODE_EXTRA_CA_CERTS)
Authentication (username/password)
Bulk API ingestion
```
A failure in any one looks different. Diagnosing means knowing *which* layer.

### The URL scheme decides HTTP vs HTTPS

`http://...` vs `https://...` in the Bulk API URL is what selects plaintext vs
TLS. ES requires HTTPS on its HTTP layer, so a plain-HTTP URL fails by design.

### Cribl needs no client cert for one-way HTTPS

This is normal one-way TLS: ES (server) presents a cert; Cribl (client)
validates it. Cribl does **not** present a client cert. It would only need one
under **mutual TLS (mTLS)**, which we don't use. Authentication is by
username/password inside the TLS session.

### NODE_EXTRA_CA_CERTS is opt-in, and read at process start

A CA file isn't trusted just by existing on disk. The Cribl (Node.js) process
only trusts it because it's started with
`NODE_EXTRA_CA_CERTS=/opt/cribl/lab-certs/ca.crt`. **Changing it requires a Cribl
restart** — it's read at process startup.

---

## How We Learned This (historical test progression)

> This progression is from the **original** setup (dynamic DHCP, CN-only certs,
> a `/etc/hosts` alias mapping `elasticsearch` → the ES node). The current lab
> uses static IPs, multi-SAN certs, and connects by node name — so most of these
> failures no longer occur. Kept because the reasoning is instructive.

**Test 1 — HTTPS by IP, validation on → failed.** The CN-only cert was valid for
the name `elasticsearch`, not an IP. *Lesson: the cert identity must match the
name in the URL.* (Today: certs carry IP SANs too, so even IP-based URLs could
validate — but we use node names.)

**Test 2 — HTTPS by hostname, validation off → worked (encrypted, unvalidated).**
TLS encryption up, auth via password, but the server cert wasn't fully
validated. *Lesson: encryption ≠ validation.*

**Test 3 — HTTP → failed.** ES requires TLS on its HTTP layer. *Lesson: scheme
matters.*

**Test 4 — HTTPS by hostname, validation on, before CA trust → failed.** Cribl
didn't yet trust the signing CA. *Lesson: validation needs CA trust.*

**Test 5 — HTTPS by hostname, validation on, after NODE_EXTRA_CA_CERTS → worked.**
Adding the CA to Cribl's trust store via the systemd env var completed the chain.
*Lesson: NODE_EXTRA_CA_CERTS is how Node-based Cribl trusts a private CA.*

The current setup is effectively "Test 5, but by node name with SAN-backed certs
and an automated drop-in" — the end state, reached without the intermediate
failures.

---

## What Is Still Not Production-Ready

Lab conveniences to revisit for production:

1. **Don't use the `elastic` superuser.** Create a least-privilege ingest user or
   API key scoped to write only the destination index/data stream.
2. **Real DNS over `/etc/hosts`.** The generated hosts file is fine for the lab;
   production wants stable DNS (and the cert SANs should cover those names).
3. **Managed CA storage.** `/opt/cribl/lab-certs/` is a lab path. Production
   should store the CA in a controlled location, readable by Cribl, not casually
   writable.
4. **Every worker in a distributed Cribl.** In a Cribl cluster, the destination
   runs from worker nodes — so `NODE_EXTRA_CA_CERTS`, the CA file, permissions,
   and a restart must be applied on **every** worker.
5. **Document the restart dependency.** Changing the CA trust env requires a Cribl
   restart (read at startup).
6. **Certificate rotation.** Define where the CA lives, who renews, how workers
   update, whether a restart is needed, and how expiry is monitored.

---

## Verification

```bash
# Service healthy
sudo systemctl status cribl --no-pager | head -10

# CA trust env actually applied (the automation check)
systemctl show cribl | grep NODE_EXTRA

# Parked certs present
ls -l /opt/cribl/lab-certs/
```

Then in the Cribl UI: configure/confirm the Elasticsearch destination, use its
built-in **send test events** feature, and verify the events land in the `test`
index in Kibana.

---

## Next Steps

- **Cribl UI TLS** (manual): configure HTTPS on the Cribl UI using
  `cribl-chain.crt` / `cribl.key` — deliberate hands-on practice.
- **Agent → Cribl TLS input**: when the Elastic Agent ships to Cribl, Cribl
  becomes a *server* on its data-input port and must present its chain
  (`cribl-chain.crt`) — same chain lesson as ES. The agent must trust the CA.
- **Change the default `admin` password.**