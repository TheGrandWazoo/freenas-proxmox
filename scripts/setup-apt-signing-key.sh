#!/usr/bin/env bash
# One-time setup: generate the GPG key used to sign the GitHub Pages apt repo.
#
# Run this locally once. After running:
#   1. Commit public.gpg.key to the gh-pages branch (instructions printed below)
#   2. Add APT_SIGNING_KEY to GitHub Actions secrets
#   3. Add APT_SIGNING_KEY_PASSPHRASE to GitHub Actions secrets (empty string if no passphrase)
#
# Re-running is safe — it checks for an existing key first.
set -euo pipefail

REPO="TheGrandWazoo/freenas-proxmox"
KEY_NAME="truenas-proxmox"
KEY_EMAIL="packages@ksatechnologies.com"
KEY_COMMENT="truenas-proxmox apt repo signing key"

# ── Check for existing key ────────────────────────────────────────────────────
EXISTING="$(gpg --list-secret-keys --with-colons 2>/dev/null \
  | awk -F: -v name="$KEY_NAME" '$1=="uid" && $10 ~ name {found=1} END {print found+0}')"

if [[ "$EXISTING" == "1" ]]; then
  echo "Key '$KEY_NAME' already exists in your keyring — skipping generation."
  KEY_ID="$(gpg --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '/^sec/{print $5; exit}')"
else
  # ── Generate key ─────────────────────────────────────────────────────────────
  echo "Generating GPG key for apt repo signing..."
  read -r -s -p "Enter a passphrase (leave empty for no passphrase): " PASSPHRASE
  echo

  gpg --batch --gen-key <<EOF
%echo Generating truenas-proxmox apt signing key
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${KEY_NAME}
Name-Comment: ${KEY_COMMENT}
Name-Email: ${KEY_EMAIL}
Expire-Date: 0
$([ -n "$PASSPHRASE" ] && echo "Passphrase: ${PASSPHRASE}" || echo "%no-protection")
%commit
%echo Done
EOF

  KEY_ID="$(gpg --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '/^sec/{print $5; exit}')"
  echo "Generated key: $KEY_ID"
fi

# ── Export public key ─────────────────────────────────────────────────────────
echo
echo "==> Exporting public key..."
gpg --export --armor "$KEY_ID" > /tmp/truenas-proxmox-public.gpg.key
echo "Public key written to /tmp/truenas-proxmox-public.gpg.key"

# ── Export private key (base64) ───────────────────────────────────────────────
echo
echo "==> Exporting private key (base64) for GitHub Actions secret..."
PRIVATE_KEY_B64="$(gpg --export-secret-keys --armor "$KEY_ID" | base64 -w 0)"

# ── Instructions ─────────────────────────────────────────────────────────────
cat <<INSTRUCTIONS

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NEXT STEPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Add APT_SIGNING_KEY to GitHub Actions secrets:
   gh secret set APT_SIGNING_KEY --repo ${REPO} --body "${PRIVATE_KEY_B64}"

2. Add APT_SIGNING_KEY_PASSPHRASE to GitHub Actions secrets:
   gh secret set APT_SIGNING_KEY_PASSPHRASE --repo ${REPO} --body "YOUR_PASSPHRASE"
   (use empty string if you chose no passphrase:)
   gh secret set APT_SIGNING_KEY_PASSPHRASE --repo ${REPO} --body ""

3. Commit public.gpg.key to the gh-pages branch:
   git checkout gh-pages
   cp /tmp/truenas-proxmox-public.gpg.key public.gpg.key
   git add public.gpg.key
   git commit -m "chore: add apt repo GPG public key"
   git push origin gh-pages
   git checkout release/3.x

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
INSTRUCTIONS
