# Certificate Generation

Documentation for the lab's TLS certificate generation in the
`PlayAroundIT-cribl-elastic-otel-lab` environment. A single custom Certificate
Authority signs per-tier service certificates, each carrying Subject Alternative
Names (SANs) covering every node and IP in its tier, plus a concatenated chain
file. Generated once on the Windows host via Git Bash + OpenSSL.

---

## Overview

| Property        | Value                                          |
|-----------------|------------------------------------------------|
| Script          | `scripts/generate-certs.sh`                    |
| Run location    | Windows host, **Git Bash** (bundled OpenSSL)   |
| Output          | `certs/` (gitignored)                          |
| CA              | `PlayAroundIT-Lab-CA`                          |
| Cert validity   | 825 days                                       |
| Per tier        | `<tier>.key`, `<tier>.crt`, `<tier>-chain.crt` |
| Tiers           | elasticsearch, kibana, cribl, app              |

The `certs/` directory is **gitignored** — private keys never reach GitHub. On a
fresh clone, run the script once to regenerate before `vagrant up`.

---

## Design Decisions

### One CA, per-tier service certificates

A single lab CA signs one certificate per **tier** (not per node). All
Elasticsearch nodes share the `elasticsearch` cert; all Kibana nodes share the
`kibana` cert; etc. Every client in the environment only needs to trust **one**
`ca.crt`. This keeps trust uniform and simple as the lab grows.

### Service name as canonical, node names + IPs as SANs

Each tier cert uses the **service name** as its CN and canonical connect-name
(`elasticsearch`, `kibana`, `cribl`, `app`), with all node names and static IPs
included as SANs. Clients connect by the service name, so configs don't change
when a tier scales out. The SANs ensure full hostname verification still passes
whether something connects by service name, node name, or IP.

SAN coverage (pre-provisioned with headroom for scaling):

| Cert          | DNS SANs                                              | IP SANs                                  |
|---------------|-------------------------------------------------------|------------------------------------------|
| elasticsearch | elasticsearch, elastic-1, elastic-2, elastic-3, localhost | 192.168.65.11/.12/.13, 127.0.0.1     |
| kibana        | kibana, kibana-1, kibana-2, localhost                 | 192.168.65.21/.22, 127.0.0.1             |
| cribl         | cribl, cribl-1, cribl-2, cribl-3, localhost           | 192.168.65.31/.32/.33, 127.0.0.1         |
| app           | app, app-1, app-2, app-3, localhost                   | 192.168.65.41/.42/.43, 127.0.0.1         |

The IPs correspond to the static IP scheme (`.1x` elastic, `.2x` kibana, `.3x`
cribl, `.4x` app on `192.168.65.0/24`).

### SANs require an extfile

OpenSSL's `-subj` one-liner **cannot** carry SANs. SANs must be supplied via an
extension file (`subjectAltName = ...`). The script writes a small per-cert
`.ext` file, uses it during signing, then deletes it.

### Chain files (leaf + CA)

For each tier the script emits a `<tier>-chain.crt` = leaf certificate followed
by the CA certificate. **Servers present the chain file**, not the bare leaf.

This is the fix for a subtle but important failure (see Lessons Learned in the
Fleet doc): when a server presents only its leaf cert without the issuing CA in
the chain, the Elastic Agent's **`ca_trusted_fingerprint`** method cannot verify
trust, because that method inspects the issuing CA *in the presented chain*. A
server presenting leaf-only breaks fingerprint-based trust. Presenting the full
chain fixes it and is also simply how production servers behave.

Order matters: **leaf first, then CA**.

---

## What the Script Does

`scripts/generate-certs.sh`:

1. Create the CA key + self-signed CA certificate (`ca.key`, `ca.crt`).
2. For each tier, via `generate_node_cert <tier> <san-list>`:
   - Generate a 2048-bit key.
   - Create a CSR (CN = service name).
   - Write a temporary `.ext` file with the tier's SANs.
   - Sign the CSR with the CA, applying the SANs via `-extfile`.
   - Concatenate leaf + CA into `<tier>-chain.crt`.
   - Clean up the `.csr` and `.ext`.

Run it from the repo root in Git Bash:
```bash
bash scripts/generate-certs.sh
```

---

## Git Bash / MSYS Gotchas

Two OpenSSL-on-Git-Bash quirks the script works around:

### Subject string path mangling

Git Bash (MSYS) rewrites a leading `/` in `-subj` into a Windows path, corrupting
`/C=DE/...` into `C:/Program Files/Git/C=DE/...`. The fix used throughout is a
**leading `//` with backslash separators**:
```
-subj "//C=DE\ST=Hesse\L=Lab\O=PlayAroundIT\CN=${NODE}"
```
Do **not** set a global `MSYS_NO_PATHCONV=1` — it fixes the subject but breaks the
file-path arguments (OpenSSL then can't resolve `/d/...` paths). Escape the
subject per-argument instead.

### SAN strings are values, not paths

The SAN entries use `DNS:` / `IP:` prefixes with colons — these are values, not
paths, so MSYS does not mangle them. If anything looks off, this is the first
place to check.

---

## Verification

After generating, confirm the SANs and chain are correct:

### SANs present
```bash
openssl x509 -in certs/elasticsearch.crt -noout -ext subjectAltName
```
Expect all the DNS names and IP addresses for that tier.

### Chain has exactly 2 certs
```bash
grep -c "BEGIN CERTIFICATE" certs/elasticsearch-chain.crt
```
Expect `2` (leaf + CA).

### Confirm CA signed the cert
```bash
openssl verify -CAfile certs/ca.crt certs/elasticsearch.crt
```
Expect `certs/elasticsearch.crt: OK`.

Repeat for `kibana`, `cribl`, `app` as needed.

---

## Output Files

```
certs/
├── ca.crt                    # CA cert — distributed to all nodes (trust)
├── ca.key                    # CA private key — stays local, never distributed
├── ca.srl                    # CA serial (openssl bookkeeping)
├── elasticsearch.key         # leaf key
├── elasticsearch.crt         # leaf cert (with SANs)
├── elasticsearch-chain.crt   # leaf + CA (what ES presents)
├── kibana.{key,crt}          # + kibana-chain.crt
├── cribl.{key,crt}           # + cribl-chain.crt
└── app.{key,crt}             # + app-chain.crt
```

---

## How Each File Is Used Downstream

- **`ca.crt`** → distributed to clients that must *trust* a server (Kibana→ES,
  Cribl→ES, agent→Cribl). Trust-only, no identity.
- **`<tier>-chain.crt`** → installed on the **server** as the certificate it
  *presents* (ES HTTP layer, Kibana UI, Cribl TLS input).
- **`<tier>.key`** → the server's private key. Never leaves its node.
- **`ca.key`** → stays on the host. Used only to sign certs; never provisioned
  to a VM.

---

## Notes / Future

- **Scaling beyond pre-covered SANs:** SANs cover 3 elastic / 2 kibana / 3 cribl
  / 3 app. Adding nodes beyond those counts requires regenerating certs with
  expanded SANs.
- **Rotation:** certs are valid 825 days. Rotation = re-run the script and
  re-provision. Document owner/renewal if this lab becomes long-lived.
- **Bundling vs. chain file:** we keep the bare leaf and a separate
  `-chain.crt` (the `fullchain.pem` / `cert.pem` convention) rather than bundling
  the CA into the leaf file, so each file's purpose stays clean.