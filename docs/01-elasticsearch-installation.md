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
auto-generated certificates. The node is built to scale out later (additional
`elastic-N` nodes) by flipping `discovery.type` and adding transport TLS.

| Property        | Value                          |
|-----------------|--------------------------------|
| Node name       | `elastic-1`                    |
| Cluster name    | `cribl-elastic-otel-lab`       |
| Version line    | Elastic 9.x (latest via apt)   |
| HTTP endpoint   | `https://<vm-ip>:9200`         |
| Superuser       | `elastic`                      |
| Security        | Enabled, HTTP TLS via lab CA   |
| Discovery       | `single-node` (for now)        |

---

## Design Decisions

### Custom CA instead of auto-generated certificates

Elasticsearch 9.x auto-configures TLS on first install, generating its own CA
and node certificates. We deliberately **replace these** with our own lab CA
(`PlayAroundIT-Lab-CA`) and per-service certificates.

**Why:** a single, uniform CA across the whole environment means every future
client — Kibana, Cribl, the Elastic Agent — only needs to trust **one**
`ca.crt`. With per-node auto-generated CAs, each trust relationship would be a
separate piece of cert juggling. One CA to rule them all keeps later
integration simple.

Certificates are generated **once** on the Windows host via
`scripts/generate-certs.sh` (Git Bash + OpenSSL) and distributed to VMs during
provisioning with Vagrant `file` provisioners. The `certs/` directory is
**gitignored** — private keys never reach GitHub.

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
   ownership (`root:elasticsearch`, `640`).
5. Reset the keystore (clear auto-config secrets), add `bootstrap.password`.
6. Write `elasticsearch.yml` (security on, HTTP TLS pointing at lab certs).
7. **Fix runtime directory ownership** (see Lessons Learned).
8. Enable + start the service, wait for the API to respond.
9. Set the `kibana_system` password via the security API.
10. Print the endpoint and credentials.

### Certificate distribution (Vagrantfile)

`file` provisioners run **before** the shell provisioner, staging certs in
`/tmp` so the script can place them. Only `ca.crt` and the `elasticsearch.*`
pair go to this node — the CA **key** and other services' certs never touch it.

```ruby
subconfig.vm.provision "file",
  source: "certs/ca.crt", destination: "/tmp/ca.crt"
subconfig.vm.provision "file",
  source: "certs/elasticsearch.crt", destination: "/tmp/elasticsearch.crt"
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
(`-k` skips hostname verification — expected, our certs are CN-only.)

### 3. Cluster health

```bash
curl -k -u elastic:adminuser123! https://localhost:9200/_cluster/health?pretty
```

Single-node will report `green` or `yellow`. Yellow is normal — it just means
unassigned replica shards, which can't be placed with only one node.

### 4. Confirm OUR certificate is being served

```bash
echo | openssl s_client -connect localhost:9200 2>/dev/null \
  | openssl x509 -noout -issuer -subject
```

Expect:
```
issuer=...CN = PlayAroundIT-Lab-CA
subject=...CN = elasticsearch
```

This proves the cert swap worked and the auto-config certs are gone.

### 5. Confirm the CA validates the certificate

```bash
curl --cacert /etc/elasticsearch/certs/ca.crt \
  -u elastic:adminuser123! https://localhost:9200/_cluster/health?pretty
```

**Expected result:** this *fails* with:
```
SSL: certificate subject name 'elasticsearch' does not match target host name 'localhost'
```

This is the **correct** outcome and worth understanding: the CA **did**
validate the certificate (no "unable to verify" error). It failed only on
**hostname verification** — the cert's name (`elasticsearch`) doesn't match the
host we connected to (`localhost`). Our certs have no Subject Alternative Names
(SANs), so they're only valid for a host literally named `elasticsearch`.

We handle this on the **client** side (Kibana) with
`elasticsearch.ssl.verificationMode: certificate`, which keeps full CA trust
but skips the hostname check. See the TLS note below.

---

## How TLS Verification Works Here (important mental model)

The **client always verifies the server**, never the reverse:

- **Elasticsearch is the server** — it *presents* its certificate.
- **Kibana is the client** — it *verifies* that certificate, and decides how
  strictly (full hostname check vs. certificate-only).

This is why `verificationMode: certificate` lives in **`kibana.yml`**, not in
`elasticsearch.yml`. There's nothing to configure on the ES side for this.

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

### Missing SANs → hostname verification fails

Our certs carry only a CN, no SANs. Modern TLS checks the hostname against
SANs, so the cert is only valid for the literal name `elasticsearch`. For the
lab we accept this and use `verificationMode: certificate` on clients. The
production-correct alternative is to regenerate certs with SANs covering all
DNS names and IPs each node is reached by — deferred because VMware DHCP assigns
IPs dynamically.

---

## Next Steps

- **Kibana** (`kibana-1`): install, distribute `ca.crt` + `kibana.*`, configure
  connection to Elasticsearch using `kibana_system` + `verificationMode:
  certificate`, then bootstrap from the running `elastic-1`.
- **Scale-out** (later): pin the exact 9.x version, set up transport TLS,
  switch `discovery.type: single-node` to proper `discovery.seed_hosts` /
  `cluster.initial_master_nodes`.