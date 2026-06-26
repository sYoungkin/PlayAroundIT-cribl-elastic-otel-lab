# Elasticsearch Installation

Documentation for the single-node Elasticsearch deployment in the
`PlayAroundIT-cribl-elastic-otel-lab` environment. This covers the install
script, the design decisions behind it, how to verify a working node, and the
lessons learned getting there.

---

## Overview

A single Elasticsearch node (`elastic-1`) provisioned via Vagrant + VMware
Workstation, running Ubuntu 22.04. Security is enabled with TLS on the HTTP
layer, using a **custom lab Certificate Authority** rather than Elasticsearch's
auto-generated certificates. The node has a **static IP** (`192.168.65.11`) and
serves a certificate carrying SANs for all tier node names + IPs, so clients can
connect with **full TLS verification**. Built to scale out later (additional
`elastic-N` nodes) by flipping `discovery.type` and adding transport TLS.

| Property        | Value                          |
|-----------------|--------------------------------|
| Node name       | `elastic-1`                    |
| Static IP       | `192.168.65.11`                |
| Cluster name    | `cribl-elastic-otel-lab`       |
| Version line    | Elastic 9.x (latest via apt)   |
| HTTP endpoint   | `https://elastic-1:9200`       |
| Superuser       | `elastic`                      |
| Security        | Enabled, HTTP TLS via lab CA   |
| Discovery       | `single-node` (for now)        |

---

## Design Decisions

### Custom CA instead of auto-generated certificates

Elasticsearch 9.x auto-configures TLS on first install, generating its own CA
and node certificates. We deliberately **replace these** with our own lab CA
(`PlayAroundIT-Lab-CA`) and per-tier certificates.

**Why:** a single, uniform CA across the whole environment means every future
client — Kibana, Cribl, the Elastic Agent — only needs to trust **one**
`ca.crt`. With per-node auto-generated CAs, each trust relationship would be a
separate piece of cert juggling. One CA to rule them all keeps later
integration simple.

Certificates are generated **once** on the Windows host via
`scripts/generate-certs.sh` (Git Bash + OpenSSL) and distributed to VMs during
provisioning with Vagrant `file` provisioners. The `certs/` directory is
**gitignored** — private keys never reach GitHub. See the certificate-generation
doc for the SAN/chain design.

### Serving the certificate chain (leaf + CA)

ES is configured to present `elasticsearch-chain.crt` (leaf + CA concatenated),
**not** the bare leaf. This matters because some clients — notably the Elastic
Agent's `ca_trusted_fingerprint` method — require the server to present the
issuing CA as part of the chain. A leaf-only server breaks that trust method.
Presenting the full chain is also simply how production servers behave. See the
Fleet doc for the debugging story that surfaced this.

### SANs + static IP → full verification

The `elasticsearch` cert carries SANs for the service name, every node name
(`elastic-1/2/3`), `localhost`, and every tier IP (`192.168.65.11/12/13`,
`127.0.0.1`). Combined with static IPs and a generated `/etc/hosts`, clients
connect by node name (e.g. `https://elastic-1:9200`) with **full** hostname
verification — no `verificationMode: certificate` workaround needed anymore.

### HTTP TLS only (no transport TLS yet)

Only the HTTP layer (port 9200, client traffic) has TLS configured. Transport
TLS (port 9300, inter-node) is **not** configured because we're single-node.
When we scale out, transport TLS becomes mandatory — Elasticsearch refuses to
form a multi-node cluster without it.

### Keystore reset

The install **wipes and recreates** the Elasticsearch keystore. The apt package
auto-config writes transport-SSL secure passwords into the keystore. Since our
`elasticsearch.yml` doesn't configure transport SSL, those orphaned keystore
entries cause a fatal startup error:

```
invalid configuration for xpack.security.transport.ssl -
[xpack.security.transport.ssl.enabled] is not set, but the following settings
have been configured ... [keystore.secure_password, truststore.secure_password]
```

Recreating the keystore from scratch clears these, and we add only what we need:
the `bootstrap.password` for the `elastic` superuser.

### Password strategy

A single lab password (`adminuser123!`) is used for all built-in users
(`elastic`, `kibana_system`), passed in via the Vagrantfile `ADMIN_PWD`
environment variable. This is a **lab convenience** — not a production pattern.
The `elastic` password is set via keystore `bootstrap.password`; the
`kibana_system` password is set via the security API after the node is up.

---

## What the Install Script Does

`scripts/elasticsearch.sh`, in order:

1. Install dependencies, set timezone (`Europe/Berlin`).
2. Add the Elastic GPG key and 9.x apt repository.
3. Install the `elasticsearch` package.
4. Copy lab certs from `/tmp` into `/etc/elasticsearch/certs/` with correct
   ownership (`root:elasticsearch`, `640`) — `ca.crt`,
   `elasticsearch-chain.crt`, `elasticsearch.key`.
5. Reset the keystore (clear auto-config secrets), add `bootstrap.password`.
6. Write `elasticsearch.yml` (security on, HTTP TLS pointing at the chain cert).
7. **Fix runtime directory ownership** (see Lessons Learned).
8. Enable + start the service, wait for the API to respond.
9. Set the `kibana_system` password via the security API.
10. Print the endpoint and credentials.

### The TLS block in elasticsearch.yml

```yaml
xpack.security.http.ssl:
  enabled: true
  key: certs/elasticsearch.key
  certificate: certs/elasticsearch-chain.crt
  certificate_authorities: certs/ca.crt
```

Note `certificate:` points at the **chain** file.

### Certificate distribution (Vagrantfile)

`file` provisioners run **before** the shell provisioner, staging certs in
`/tmp` so the script can place them. Only `ca.crt`, the chain, and the key go to
this node — the CA **key** and other tiers' certs never touch it.

```ruby
subconfig.vm.provision "file",
  source: "certs/ca.crt", destination: "/tmp/ca.crt"
subconfig.vm.provision "file",
  source: "certs/elasticsearch-chain.crt", destination: "/tmp/elasticsearch-chain.crt"
subconfig.vm.provision "file",
  source: "certs/elasticsearch.key", destination: "/tmp/elasticsearch.key"
```

---

## Verification

After provisioning, SSH in (`vagrant ssh elastic-1`) and run these checks.

### 1. Service is running and enabled

```bash
sudo systemctl status elasticsearch --no-pager
```

Expect `active (running)` and `enabled`.

### 2. Cluster responds and authentication works

```bash
curl -k -u elastic:adminuser123! https://localhost:9200
```

Expect the JSON banner with `cluster_name: cribl-elastic-otel-lab`.
(`-k` is fine here — this is a localhost self-check, not part of the trust model.)

### 3. Cluster health

```bash
curl -k -u elastic:adminuser123! https://localhost:9200/_cluster/health?pretty
```

Single-node will report `green` or `yellow`. Yellow is normal — it just means
unassigned replica shards, which can't be placed with only one node.

### 4. Confirm the chain is being served (expect 2 certs)

```bash
echo | openssl s_client -connect localhost:9200 -showcerts 2>/dev/null \
  | grep -c "BEGIN CERTIFICATE"
```

Expect `2` — leaf + CA. A `1` means the server is presenting leaf-only, which
breaks the agent fingerprint trust method.

### 5. Full verification by node name (the payoff)

```bash
curl --cacert /etc/elasticsearch/certs/ca.crt \
  -u elastic:adminuser123! https://elastic-1:9200/_cluster/health?pretty
```

**Expected result:** this **succeeds** and returns cluster health — with full
CA *and* hostname verification, no `-k`. This works because:
- `elastic-1` is in the cert's SANs (so hostname verification passes), and
- ES presents the chain, so the CA validates cleanly.

This is the payoff of the SAN + static-IP + chain redesign. (Previously, with
CN-only certs, this same check *failed* on a hostname mismatch and we worked
around it with `verificationMode: certificate`. That workaround is no longer
needed.)

---

## How TLS Verification Works Here (important mental model)

The **client always verifies the server**, never the reverse:

- **Elasticsearch is the server** — it *presents* its certificate (chain).
- **Kibana is the client** — it *verifies* that certificate. With proper SANs we
  now use **full** verification (CA trust + hostname check).

Verification strictness is configured on the **client** (`kibana.yml`), not in
`elasticsearch.yml`. There's nothing to configure on the ES side for it.

Two separate mechanisms are easy to conflate:

1. **TLS / certificate verification** — Kibana verifying *that ES is really ES*
   and the channel is encrypted. One direction: client checks server.
2. **Authentication** — Kibana proving *who it is* to gain access. This uses
   the `kibana_system` **username + password**, not a client certificate.

Elasticsearch never inspects a cert *from* Kibana — it authenticates Kibana by
password. ES would only verify client certs under **mutual TLS (mTLS)**, which
we are not using.

---

## Lessons Learned

### Runtime directory permissions (the big one)

**Symptom:** Elasticsearch fails to start; journald shows:
```
java.nio.file.AccessDeniedException: /usr/share/elasticsearch/logs
```
and the log file `/usr/share/elasticsearch/logs/<cluster>.log` **doesn't exist**.

**Key insight:** a *missing* logs directory is a symptom, not the cause. It
means ES is dying so early it never reaches logging setup. The real error is in
journald, not the log file.

**Cause:** our root-level keystore manipulation and cert copying left the
`elasticsearch` user unable to write its runtime directories under
`/usr/share/elasticsearch/`. It can't create `logs/`, so it crashes on launch.

**Fix (baked into the script):**
```bash
mkdir -p /usr/share/elasticsearch/logs
chown -R elasticsearch:elasticsearch /usr/share/elasticsearch
```
Idempotent and safe to run every provision.

### Orphaned transport-SSL keystore entries

Covered above under Design Decisions → Keystore reset. The auto-config writes
transport-SSL secrets the yml doesn't reference, and ES refuses to start. Wipe
and recreate the keystore.

### Git Bash mangles OpenSSL subject strings

When generating certs in Git Bash, `-subj "/C=DE/..."` gets corrupted — MSYS
rewrites the leading `/` into a Windows path
(`C:/Program Files/Git/C=DE/...`). Fix: use a leading `//` and backslash
separators: `-subj "//C=DE\ST=Hesse\..."`. Do **not** set a global
`MSYS_NO_PATHCONV=1` — that fixes the subject but breaks the file-path
arguments (openssl then can't resolve `/d/...` paths). Escape per-argument
instead.

### Two interfaces — pick the right IP

Vagrant + VMware gives each VM **two NICs**: `eth0` (NAT, `192.168.248.x`, for
internet + Vagrant SSH) and `eth1` (host-only, the static `192.168.65.x` lab
IP). `hostname -I | awk '{print $1}'` returns the **NAT** IP first, which is the
wrong one for lab output. Extract the lab IP explicitly instead:
```bash
VM_IP=$(ip -4 addr show | grep -oP '192\.168\.65\.\d+' | head -1)
```

### (Historical) Missing SANs → hostname verification failed

Earlier the certs were CN-only (no SANs), so full hostname verification failed
and clients used `verificationMode: certificate` as a workaround. This was
**resolved** by the redesign: static IPs let us generate per-tier certs with
DNS + IP SANs, so full verification now works everywhere. Kept here as the
backstory for why some older configs referenced `verificationMode: certificate`.