# Fleet Server Setup

Documentation for standing up **Fleet Server** on the Kibana node (`kibana-1`)
in the `PlayAroundIT-cribl-elastic-otel-lab` environment. Fleet Server is the
control plane that manages Elastic Agent enrollment, policies, and outputs.

---

## Overview

Fleet Server runs co-located on `kibana-1` and connects to Elasticsearch on
`elastic-1` over TLS with **full certificate validation**. It listens on port
**8220** for agent enrollment and check-in, presenting the **lab-CA-signed
kibana certificate** (no self-signed cert), so enrolling agents validate it
against the lab CA — no `--insecure`.

| Property            | Value                              |
|---------------------|------------------------------------|
| Host node           | `kibana-1` (co-located with Kibana)|
| Fleet Server URL    | `https://kibana-1:8220`            |
| ES connection       | `https://elastic-1:9200`           |
| ES cert validation  | Full (CA + hostname)               |
| Fleet Server cert   | `kibana-chain.crt` (lab CA signed) |
| CA used             | `/etc/kibana/certs/ca.crt`         |

---

## Design: fully consistent TLS (no self-signed)

There are **three** TLS relationships in this setup — easy to conflate, so worth
separating:

1. **Fleet Server → Elasticsearch** (control plane). Validated with the lab CA
   via `--fleet-server-es-ca`, connecting to `https://elastic-1:9200`.
2. **Agent → Fleet Server** (enrollment / check-in). Fleet Server presents the
   **kibana chain cert**; agents trust it via the lab CA. This replaces the
   earlier self-signed-cert + `--insecure` approach.
3. **Agent data output → Elasticsearch / Cribl**. Configured centrally in the
   Fleet UI (see Outputs below), *not* on the agent host.

Fleet Server presents the **kibana** cert because it runs on `kibana-1`, and that
cert's SANs include `kibana-1` — so when an agent connects to
`https://kibana-1:8220`, hostname verification passes. The cert's URL-name match
is required: the agent's `--url` must match a SAN in `--fleet-server-cert`.

### Why not the Fleet UI's auto-generated command

The UI generates an install command with `--fleet-server-es=http://localhost:9200`
— wrong on two counts for this lab: `localhost` (ES is on a *different* VM) and
`http://` (ES is TLS-only). It also omits all the cert flags. The corrected
command below targets `elastic-1` over HTTPS and supplies the full cert set.

---

## Setup Steps (on `kibana-1`)

### 1. Generate a fresh service token

In Kibana → Fleet, use the "Add Fleet Server" flow (which also confirms the
`fleet-server-policy` exists) to generate a **service token**. Service tokens are
single-use for setup — a token from a previous session won't work; generate a new
one.

### 2. Confirm the CA and certs are present

From Kibana provisioning, `kibana-1` already has:
```bash
ls -l /etc/kibana/certs/
# ca.crt, kibana-chain.crt, kibana.key
```
(`root:kibana`, `640` — readable by the root-run installer.)

### 3. Install Fleet Server with the lab cert

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

The cert-related flags, and what each does:
- `--url=https://kibana-1:8220` — Fleet Server's own URL; the name must be a SAN
  in the presented cert (`kibana-1` is).
- `--certificate-authorities=.../ca.crt` — so Fleet Server trusts its own cert
  during bootstrap (it connects to its own URL to verify it's up).
- `--fleet-server-es-ca=.../ca.crt` — trust ES's cert (control-plane connection).
- `--fleet-server-cert` / `--fleet-server-cert-key` — present the lab-signed
  kibana chain cert instead of self-signing.

---

## Outputs (configured in the Fleet UI, not on the host)

Output config is **central** — defined in Fleet, pushed to agents. It does *not*
live in `elastic-agent.yml` on the agent host.

### Default Elasticsearch output (Fleet Server self-monitoring)

Fleet Server ships its own logs/metrics to ES via the **default output**. Out of
the box this points at `localhost:9200` (wrong — ES is remote). Fix it in
Fleet → Settings → Outputs → edit the default ES output:

- **Hosts:** `https://elastic-1:9200`
- **Elasticsearch CA trusted fingerprint:** the SHA-256 fingerprint of the lab CA

Compute the fingerprint:
```bash
openssl x509 -fingerprint -sha256 -noout -in /etc/kibana/certs/ca.crt \
  | sed 's/://g' | cut -d= -f2
```

#### Why the fingerprint method needs the chain

The `ca_trusted_fingerprint` method verifies the **issuing CA in the chain the
server presents**. So ES must present its full chain (leaf + CA) — which it now
does, because `elasticsearch.sh` installs `elasticsearch-chain.crt`. Earlier,
when ES presented only the leaf, this method failed with:
```
The remote server's certificate is presented without its certificate chain.
Using 'ca_trusted_fingerprint' requires that the server presents a certificate
chain that includes the certificate's issuing certificate authority.
... x509: certificate signed by unknown authority
```
The chain fix at the ES side resolved it. See the certificate-generation and
Elasticsearch docs.

---

## Verification

```bash
sudo elastic-agent status
```
Expect healthy. In the Fleet UI, Fleet Server shows **Healthy**.

See the Troubleshooting section for the deeper commands.

---

## Troubleshooting Toolkit

Commands we actually used to diagnose Fleet/agent issues. Keep these handy.

### Component-level health
```bash
sudo elastic-agent status
sudo elastic-agent status --output json     # more detail, incl. policy revision
```
Read the *reason* on a degraded unit, not just the colour — a persistent
connection/cert reason means it's stuck; a "starting"/"reconfiguring" reason
clears on its own.

### The agent log (where the real errors are)
```bash
# Tail the structured log
sudo tail -50 /opt/Elastic/Agent/data/elastic-agent-*/logs/elastic-agent-*.ndjson

# Filter for cert/TLS errors (how we found the x509 chain problem)
sudo tail -100 /opt/Elastic/Agent/data/elastic-agent-*/logs/elastic-agent-*.ndjson \
  | grep -iE "x509|certificate|fingerprint|tls|error"

# Find the log path if the glob doesn't resolve
sudo find /opt/Elastic -name "*.ndjson" 2>/dev/null | head
```

### Watch live during a restart/reconfig
```bash
sudo journalctl -u elastic-agent -f
```

### Confirm what cert a server presents (chain count)
```bash
echo | openssl s_client -connect elastic-1:9200 -showcerts 2>/dev/null \
  | grep -c "BEGIN CERTIFICATE"      # expect 2 (leaf + CA)
```

### Name resolution + fingerprint checks
```bash
getent hosts elastic-1
openssl x509 -fingerprint -sha256 -noout -in /etc/kibana/certs/ca.crt \
  | sed 's/://g' | cut -d= -f2
```

### Restart the agent (forces clean config pickup)
```bash
sudo systemctl restart elastic-agent
```

---

## Lessons Learned

### Output changes need an agent restart

When you change an **output** in Fleet, it pushes a new policy revision and the
agent is *supposed* to hot-reload. In practice, output changes often don't fully
take effect until the agent is restarted — output changes touch connection
plumbing that doesn't always cleanly hot-reload. A degraded output that won't
clear after a Fleet change usually just needs:
```bash
sudo systemctl restart elastic-agent
```
This is expected Fleet behaviour, not a misconfiguration.

### Fleet-managed config doesn't live in elastic-agent.yml

A Fleet-managed agent pulls its policy from Fleet Server and renders it into
internal state under `/opt/Elastic/Agent/data/...` — **not** into the
human-facing `elastic-agent.yml` (which stays minimal: just Fleet connection
info). Don't hand-edit the rendered files; Fleet is the source of truth and will
overwrite them on the next check-in. This is the key difference from a
*standalone* agent, where `elastic-agent.yml` *is* the source of truth.

### Three separate TLS relationships

Fleet→ES, Agent→Fleet, and Agent-output→ES/Cribl are independent trust
relationships, each configured in its own place. "Didn't we already do CA trust?"
usually means you configured one of the three and are now hitting another. The
client always validates the server; authentication (service token / username /
fingerprint) is a separate layer from cert validation.

### Service tokens are single-use for setup

A service token from a previous session won't work on a re-install — generate a
fresh one in the Fleet UI each time.

---

## Next Steps

- **Elastic Agent on `app-1`:** stage `ca.crt` on app-1, enroll into Fleet at
  `https://kibana-1:8220` with `--certificate-authorities=/path/to/ca.crt`
  (no `--insecure`, since Fleet now presents a lab-signed cert).
- **Cribl output:** create a second output in Fleet pointing app-1's data at
  **Cribl**, and assign it to app-1's policy. (Fleet pushes outputs centrally.)
- **Test data:** drop sample files on `app-1`, read them with the agent, and
  confirm the flow: agent → Cribl → Elasticsearch → Kibana.