# Signing material, encrypted

The Apple Distribution certificate, the provisioning profile, the App Store
Connect API key and the passwords that go with them live here, encrypted with
AES-256-CBC (PBKDF2, 600,000 iterations).

    dist.p12.enc                 certificate and private key
    profile.mobileprovision.enc  "Retro-Dosbox AppStore"
    asc_key.p8.enc               App Store Connect API key
    signing.env.enc              CERT_PASSWORD, ASC_KEY_ID, ASC_ISSUER_ID

## The one secret

CI needs a single repository secret, `SIGNING_PASSPHRASE`, and decrypts all
four with it. That is the whole arrangement: six secrets became one, and the
material travels with the repository.

**The passphrase is not in this repository and must never be.** Encrypted
files plus their passphrase in the same place is the same as plaintext.

## Decrypting by hand

    export PASS='<the passphrase>'
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
      -in ios/signing/dist.p12.enc -out /tmp/dist.p12 -pass env:PASS

## Rotating

Re-encrypt every file with the new passphrase in the same commit, then change
`SIGNING_PASSPHRASE`. A half-rotated set fails in CI at `security import` with
a message about the password, which reads like a bad certificate.

## If the passphrase leaks

Treat the certificate as compromised: revoke it in the Developer portal, issue
a new one, and re-encrypt under a new passphrase. A leaked distribution
certificate lets anyone sign and upload as this developer. This certificate
was already revoked once, on 2026-08-23, and everything built before it had to
be rebuilt.
