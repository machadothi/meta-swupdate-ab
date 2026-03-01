# RSA Keys for SWUpdate Signing

This directory holds RSA key pairs used to sign and verify OTA update packages.

## Security Warning

- **NEVER commit the private key (`swupdate_priv.pem`) to a public repository.**
- The private key is listed in `.gitignore` by default.
- For production deployments, generate keys on a secure, offline machine.
- Store the private key in a secrets manager (HashiCorp Vault, AWS Secrets Manager, etc.).

---

## Files

| File | Purpose | Committed to git? |
|------|---------|-------------------|
| `swupdate_priv.pem` | Signs update packages at build time | **NO** (in .gitignore) |
| `swupdate_public.pem` | Installed on device to verify signatures | YES (safe to commit) |

---

## Generating Keys

If you set `GENERATE_KEYS="yes"` in your `layer.config`, `init-layer.sh`
will generate these keys automatically.

To generate manually:

```bash
# Generate a 4096-bit RSA private key (use a strong passphrase in production)
openssl genrsa -out keys/swupdate_priv.pem 4096

# Extract the public key from the private key
openssl rsa -in keys/swupdate_priv.pem -out keys/swupdate_public.pem -pubout
```

---

## Using Your Own Keys

If you already have an RSA key pair:

1. Place your private key here as `swupdate_priv.pem`
2. Place your public key here as `swupdate_public.pem`
3. Run `./init-layer.sh layer.config` — it will copy the public key into the layer

---

## Enabling Signing in the Build

In your `layer.config`:

```bash
ENABLE_SIGNING="yes"
GENERATE_KEYS="no"   # if you are providing your own keys
```

When signing is enabled, `bitbake update-image` will sign the `.swu` package
with the private key, and SWUpdate on the device will verify it using the
public key stored in `/etc/swupdate_public.pem`.
