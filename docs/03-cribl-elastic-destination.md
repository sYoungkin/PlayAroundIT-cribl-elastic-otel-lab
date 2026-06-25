# Cribl → Elasticsearch Destination with HTTPS/TLS: Lesson Learned

## Context

The goal was to configure a Cribl Stream Elasticsearch destination to send events to a self-managed Elasticsearch node over HTTPS using the Elasticsearch Bulk API.

The Elasticsearch node was configured with TLS enabled on its HTTP/API layer. Therefore, Elasticsearch expected clients to connect over HTTPS, not plain HTTP.

The working Cribl destination ultimately used:

```text
https://elasticsearch:9200/_bulk
```

with:

```text
Validate server certs: enabled
```

and a systemd environment variable on the Cribl node:

```ini
Environment="NODE_EXTRA_CA_CERTS=/opt/cribl/lab-certs/ca.crt"
```

---

## Final Working Flow

The final working setup can be understood as the following sequence:

```text
1. Cribl destination uses:
   https://elasticsearch:9200/_bulk

2. The Cribl node resolves:
   elasticsearch -> 192.168.248.215

3. Elasticsearch presents its HTTP/server certificate.

4. The certificate is valid for the hostname:
   elasticsearch

5. Cribl validates the Elasticsearch server certificate because:
   Validate server certs = enabled

6. Cribl trusts the signing CA because the Cribl process has:
   NODE_EXTRA_CA_CERTS=/opt/cribl/lab-certs/ca.crt

7. After the TLS session is established, Cribl authenticates to Elasticsearch using:
   elastic username + password

8. Cribl sends events to Elasticsearch through the Bulk API.

9. Events are successfully indexed and visible in Kibana.
```

---

## Key Conceptual Lesson

There are several separate layers involved here:

```text
DNS / name resolution
TLS transport
Server certificate validation
Elasticsearch authentication
Bulk API ingestion
```

These are related, but they are not the same thing.

---

## 1. The Bulk API URL Determines HTTP vs HTTPS

In the Cribl Elasticsearch destination, the protocol is controlled by the Bulk API URL.

Plain HTTP:

```text
http://elasticsearch:9200/_bulk
```

Encrypted HTTPS/TLS:

```text
https://elasticsearch:9200/_bulk
```

Because Elasticsearch was configured to expect TLS on its HTTP layer, the plain HTTP test failed. That is expected.

The correct URL for this setup is:

```text
https://elasticsearch:9200/_bulk
```

---

## 2. Hostname Resolution Was Required Because of Certificate Identity

The Elasticsearch certificate was valid for the hostname:

```text
elasticsearch
```

It was not valid for the IP address:

```text
192.168.248.215
```

Therefore, this failed when certificate validation was active:

```text
https://192.168.248.215:9200/_bulk
```

because the TLS client checks whether the certificate is valid for the name used in the URL.

This worked after adding name resolution:

```text
https://elasticsearch:9200/_bulk
```

with `/etc/hosts` on the Cribl node containing something like:

```text
192.168.248.215 elasticsearch
```

The important point:

```text
The hostname in the URL must match the hostname/SAN in the Elasticsearch server certificate.
```

---

## 3. Cribl Does Not Need Its Own Certificate for Normal HTTPS

A key clarification:

```text
Cribl is not using its own client certificate in this setup.
```

This is normal one-way HTTPS:

```text
Cribl client  --->  Elasticsearch server
```

In this model:

```text
Elasticsearch presents the server certificate.
Cribl validates the Elasticsearch server certificate.
Cribl and Elasticsearch negotiate encrypted TLS session keys.
Cribl sends username/password authentication inside the encrypted TLS session.
```

Cribl would only need its own client certificate if Elasticsearch were configured for mutual TLS / client certificate authentication.

That was not the case here.

Authentication was handled by:

```text
username + password
```

not by a Cribl client certificate.

---

## 4. Validate Server Certs Controls Certificate Verification

When `Validate server certs` was disabled, the destination worked with HTTPS because traffic was encrypted, but Cribl was not fully validating the Elasticsearch server certificate.

That state can be summarized as:

```text
Encryption: yes
Server certificate validation: no
Username/password authentication: yes
```

When `Validate server certs` was enabled, the destination initially failed because Cribl did not yet trust the CA that signed the Elasticsearch server certificate.

That failure was expected.

---

## 5. NODE_EXTRA_CA_CERTS Adds the Elasticsearch CA to Cribl's Trust Store

The missing piece was to tell the Cribl process to trust the Elasticsearch CA.

This was done through a systemd override:

```bash
sudo systemctl edit cribl
```

with:

```ini
[Service]
Environment="NODE_EXTRA_CA_CERTS=/opt/cribl/lab-certs/ca.crt"
```

Then systemd was reloaded and Cribl was restarted:

```bash
sudo systemctl daemon-reload
sudo systemctl restart cribl
```

After this, Cribl could validate the Elasticsearch server certificate successfully.

The CA file itself is not automatically discovered just because it exists in a directory. It only becomes relevant because the Cribl process is started with:

```text
NODE_EXTRA_CA_CERTS=/opt/cribl/lab-certs/ca.crt
```

---

## Final Secure Lab Configuration

The final working destination configuration was:

```text
Bulk API URL:
https://elasticsearch:9200/_bulk

Authentication:
Manual / username-password

Username:
elastic

Password:
<elastic password>

Validate server certs:
enabled
```

The Cribl node also had hostname resolution:

```text
192.168.248.215 elasticsearch
```

And the Cribl systemd service had:

```ini
Environment="NODE_EXTRA_CA_CERTS=/opt/cribl/lab-certs/ca.crt"
```

This gives:

```text
Encrypted transport: yes
Server certificate validation: yes
Hostname validation: yes
Elasticsearch authentication: yes
Bulk API ingestion: yes
```

---

## Correct Mental Model

The final mental model is:

```text
https://elasticsearch:9200/_bulk
```

means:

```text
Use TLS for the HTTP connection to Elasticsearch.
```

The `/etc/hosts` entry means:

```text
Resolve the hostname "elasticsearch" to the current lab IP.
```

The Elasticsearch server certificate means:

```text
Elasticsearch can prove its server identity to Cribl.
```

The CA certificate means:

```text
Cribl can verify that Elasticsearch's server certificate was signed by a trusted CA.
```

The `NODE_EXTRA_CA_CERTS` setting means:

```text
Add this CA to the trusted CA list used by the Cribl process.
```

The `Validate server certs` setting means:

```text
Reject the Elasticsearch connection unless the server certificate can be validated.
```

The username/password means:

```text
Authenticate the Cribl request to Elasticsearch after the TLS session has been established.
```

---

## What Was Proven by the Tests

### Test 1: HTTPS with IP address failed

```text
https://192.168.248.215:9200
```

This failed because the certificate was valid for `elasticsearch`, not for the IP address.

Conclusion:

```text
The server certificate identity must match the URL hostname.
```

---

### Test 2: HTTPS with hostname worked when validation was disabled

```text
https://elasticsearch:9200/_bulk
Validate server certs: disabled
```

This worked because Cribl established an encrypted TLS session and authenticated with username/password, but did not fully validate the Elasticsearch server certificate.

Conclusion:

```text
HTTPS encryption was working, but full certificate validation was not yet configured.
```

---

### Test 3: HTTP failed

```text
http://elasticsearch:9200/_bulk
```

This failed because Elasticsearch expects TLS on its HTTP/API layer.

Conclusion:

```text
The Elasticsearch HTTP API requires HTTPS in this lab.
```

---

### Test 4: HTTPS with hostname and validation enabled failed before CA config

```text
https://elasticsearch:9200/_bulk
Validate server certs: enabled
```

This failed because Cribl did not yet trust the Elasticsearch CA.

Conclusion:

```text
Cribl needed the Elasticsearch CA added to its trust store.
```

---

### Test 5: HTTPS with hostname and validation enabled worked after NODE_EXTRA_CA_CERTS

```text
https://elasticsearch:9200/_bulk
Validate server certs: enabled
NODE_EXTRA_CA_CERTS=/opt/cribl/lab-certs/ca.crt
```

This worked.

Conclusion:

```text
The Cribl → Elasticsearch destination is now using HTTPS with proper server certificate validation.
```

---

## What Is Still Not Production-Ready

The TLS setup is now conceptually correct, but the full destination should not yet be considered production-ready without a few improvements.

### 1. Do not use the `elastic` superuser

For a lab, using the `elastic` user is fine.

For production, create a dedicated ingest user or API key with least-privilege permissions.

The credential should only be able to write to the required index or data stream.

Example target principle:

```text
Allow write/create_doc privileges only for the intended Cribl destination index or data stream.
Do not use a cluster superuser for ingestion.
```

---

### 2. Replace `/etc/hosts` with stable DNS

The `/etc/hosts` solution is acceptable in a Vagrant/VMware lab, but it is operationally fragile.

For production, use stable DNS such as:

```text
elasticsearch.company.local
```

or a load-balanced/service name that is included in the Elasticsearch HTTP certificate SANs.

---

### 3. Generate certificates with proper SANs

For production, certificates should include all names clients will use to connect, for example:

```text
DNS: elasticsearch.company.local
DNS: elasticsearch
DNS: elasticsearch-lb.company.local
IP: <stable IP if IP-based access is required>
```

Avoid relying on certificate validation bypasses.

---

### 4. Store the CA in a managed location

The CA file should be stored in a controlled path with appropriate ownership and permissions.

For example:

```text
/etc/cribl/certs/elasticsearch-ca.crt
```

rather than a temporary lab folder.

The file should be readable by the Cribl process but not casually writable.

---

### 5. Apply the setting on every Cribl worker

In a distributed Cribl deployment, the Elasticsearch destination runs from the worker nodes.

Therefore, the CA trust configuration must exist on every worker that may send events to Elasticsearch.

This includes:

```text
NODE_EXTRA_CA_CERTS
CA file path
file permissions
service restart
```

on each relevant worker.

---

### 6. Document the restart dependency

Changing `NODE_EXTRA_CA_CERTS` requires a Cribl service restart because it is read when the process starts.

This should be documented operationally:

```text
Changing the trusted CA file or NODE_EXTRA_CA_CERTS requires restarting the Cribl service.
```

---

### 7. Consider certificate rotation

For production, document how the Elasticsearch CA/server certificate will be rotated.

Important questions:

```text
Where is the CA stored?
Who owns renewal?
How are Cribl workers updated?
Is a restart required?
How is expiry monitored?
```

---

## Final Summary

The final lesson learned:

```text
Cribl Elasticsearch destinations use HTTPS when the Bulk API URL starts with https://.

Elasticsearch presents the server certificate.

Cribl validates that certificate only when Validate server certs is enabled.

The hostname in the Cribl URL must match the certificate identity.

The Elasticsearch CA must be trusted by the Cribl process.

NODE_EXTRA_CA_CERTS can be used to add the Elasticsearch CA to Cribl's trust store.

Username/password authentication happens after the TLS session is established.

The current lab setup now has encrypted transport and proper server certificate validation.
```

Production hardening should focus on:

```text
least-privilege credentials,
stable DNS,
proper certificate SANs,
managed CA storage,
consistent worker configuration,
and certificate lifecycle management.
```
