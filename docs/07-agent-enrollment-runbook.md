# Elastic Agent Enrollment Runbook

A repeatable procedure for installing and enrolling an **Elastic Agent** on an
app-server node in the `PlayAroundIT-cribl-elastic-otel-lab` environment, with
the gotchas, verification, and troubleshooting commands learned along the way.

Use this whenever adding a new agent (e.g. `app-2`, `app-3`).

---

## Prerequisites

Before enrolling an agent on a node:

1. **Fleet Server is up and healthy** on `kibana-1` (see the Fleet Server doc).
2. **The node has the lab CA** at `/etc/lab-certs/ca.crt` (staged by
   `app-server.sh` via a `file` provisioner of `certs/ca.crt`).
3. **Name resolution works** — the node can resolve `kibana-1` (generated
   `/etc/hosts`).
4. **The Elastic Agent package** is available on the node (download/extract, or
   stage it like the Cribl tarball).

Quick prereq checks on the node:
```bash
ls -l /etc/lab-certs/ca.crt        # CA present
getent hosts kibana-1              # resolves to 192.168.65.21
```

---

## Two token types — don't mix them up

- **Service token** — used once to *install Fleet Server itself*. Not used for
  regular agents.
- **Enrollment token** — used to *enroll an agent* into an agent policy. This is
  the one you need here. Generate it in Kibana → Fleet → Agents → Add agent (or
  under Enrollment tokens). It can be reused for multiple agents on the same
  policy.

---

## Enrollment Procedure

### 1. Get a fresh enrollment token

Kibana → Fleet → Agents → **Add agent** → select/create the agent policy → copy
the enrollment token.

### 2. Enroll the agent

From the directory where the agent is extracted, on the target node:

```bash
sudo ./elastic-agent install \
  --url=https://kibana-1:8220 \
  --enrollment-token=<enrollment-token> \
  --certificate-authorities=/etc/lab-certs/ca.crt
```

Key points:
- **`--url=https://kibana-1:8220`** — Fleet Server's URL. Port **8220** (not
  8200 — see Gotchas). `kibana-1` is a SAN in Fleet Server's cert, so hostname
  verification passes.
- **`--certificate-authorities=/etc/lab-certs/ca.crt`** — trusts the lab CA that
  signed Fleet Server's cert. **No `--insecure` needed** — Fleet Server presents
  a real lab-signed cert, not a self-signed one.

### 3. Verify

```bash
sudo elastic-agent status
```
Both `fleet` and `elastic-agent` units should be **HEALTHY**. The agent appears
in the Fleet UI and (with the default output) starts sending system data to
Elasticsearch.

---

## Gotchas (things that actually bit us)

### Fleet Server host port: 8220, not 8200

**Symptom:** the agent enrolls fine (`fleet: HEALTHY Connected`) but then
`elastic-agent` goes **FAILED** with:
```
fail to communicate with Fleet Server API ... https://kibana-1:8200/ ...
dial tcp 192.168.65.21:8200: connect: connection refused
```

**Cause:** enrollment used the correct URL, but the **Fleet Server host** setting
in Fleet → Settings was configured as `:8200` (the APM Server default port — a
very easy transposition with Fleet's `8220`). The agent pulled a policy that
points check-ins at the wrong port.

**Fix:** Kibana → Fleet → Settings → **Fleet Server hosts** → set the URL to
`https://kibana-1:8220`. Save, then restart the agent (next gotcha). Confirm
there's only one host entry and it's the `:8220` one.

### Config changes (incl. outputs) need an agent restart

Fleet pushes policy changes and the agent is *supposed* to hot-reload, but output
and host changes often don't fully take until a restart:
```bash
sudo systemctl restart elastic-agent
```
Expected Fleet behaviour, not a misconfiguration.

### Fleet-managed config isn't in elastic-agent.yml

A Fleet-managed agent renders its policy into internal state under
`/opt/Elastic/Agent/data/...`, **not** the human-facing `elastic-agent.yml`.
Don't hand-edit it — Fleet is the source of truth and overwrites on next
check-in.

---

## Troubleshooting Toolkit

### Component health
```bash
sudo elastic-agent status
sudo elastic-agent status --output json     # detail incl. policy revision
```
Read the *reason* on a degraded/failed unit — a persistent connection/cert reason
means stuck; "starting"/"reconfiguring" clears on its own.

### Agent log (the real errors)
```bash
sudo tail -50 /opt/Elastic/Agent/data/elastic-agent-*/logs/elastic-agent-*.ndjson

# Filter for cert/TLS/connection errors
sudo tail -100 /opt/Elastic/Agent/data/elastic-agent-*/logs/elastic-agent-*.ndjson \
  | grep -iE "x509|certificate|fingerprint|tls|refused|error"

# Locate the log if the glob doesn't resolve
sudo find /opt/Elastic -name "*.ndjson" 2>/dev/null | head
```

### Watch live during enroll/restart
```bash
sudo journalctl -u elastic-agent -f
```

### Connectivity / resolution
```bash
getent hosts kibana-1                                  # name resolves
curl -k https://kibana-1:8220/api/status               # Fleet Server reachable on 8220
echo | openssl s_client -connect kibana-1:8220 \
  -showcerts 2>/dev/null | grep -c "BEGIN CERTIFICATE" # cert chain present
```

### Restart
```bash
sudo systemctl restart elastic-agent
```

---

## Uninstall / Re-enroll

To remove an agent (e.g. to re-enroll cleanly):
```bash
sudo elastic-agent uninstall
```
Then unenroll/remove it from the Fleet UI if it lingers, and re-run the
enrollment procedure with a fresh token.

---

## Output Routing (where agent data goes)

By default, an enrolled agent uses the **default Elasticsearch output** and sends
data straight to ES. To route through Cribl instead (the lab's pipeline goal):

1. Create a **Cribl output** in Fleet → Settings → Outputs.
2. Assign that output to the agent's policy.
3. Restart the agent to pick up the change.

Output config is **central** (Fleet UI), pushed to agents — not configured on the
agent host. See the Cribl / pipeline docs for the agent → Cribl → ES flow.

---

## Quick Reference

```bash
# Enroll
sudo ./elastic-agent install \
  --url=https://kibana-1:8220 \
  --enrollment-token=<token> \
  --certificate-authorities=/etc/lab-certs/ca.crt

# Verify
sudo elastic-agent status

# After any Fleet config/output change
sudo systemctl restart elastic-agent
```