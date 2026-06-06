#!/usr/bin/env bash
# Migrate the truenas-proxmox / freenas-proxmox apt source from Cloudsmith
# to the GitHub Pages apt repo.
#
# Run on each Proxmox node as root (or with sudo).
#
# What this script does:
#   1. Detects the currently installed version and which repo is configured
#   2. Removes any Cloudsmith source files and keyrings for this package
#   3. Imports the GitHub Pages GPG key
#   4. Adds the correct dist track (v3 for v3.x installs, main for v2.x)
#   5. Runs apt update and confirms the new repo is reachable
#
# Safe to re-run: it detects if you're already on GitHub Pages and exits early.

set -euo pipefail

GITHUB_PAGES_BASE="https://thegrandwazoo.github.io/freenas-proxmox"
KEYRING_PATH="/etc/apt/keyrings/truenas-proxmox.gpg"
SOURCES_FILE="/etc/apt/sources.list.d/truenas-proxmox.list"
CLOUDSMITH_URL_PATTERN="dl.cloudsmith.io.*ksatechnologies.*truenas-proxmox"

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run this script as root or with sudo." >&2
  exit 1
fi

# ── Detect installed version ──────────────────────────────────────────────────
INSTALLED_PKG=""
INSTALLED_VER=""
for pkg in truenas-proxmox freenas-proxmox; do
  ver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
  if [[ -n "$ver" ]]; then
    INSTALLED_PKG="$pkg"
    INSTALLED_VER="$ver"
    break
  fi
done

if [[ -z "$INSTALLED_VER" ]]; then
  echo "Neither truenas-proxmox nor freenas-proxmox is installed on this node."
  echo "Use the install instructions in the README for a fresh install."
  exit 0
fi

MAJOR="${INSTALLED_VER%%.*}"
echo "Detected: $INSTALLED_PKG $INSTALLED_VER (major version: $MAJOR)"

# ── Determine target dist track ───────────────────────────────────────────────
case "$MAJOR" in
  2) DIST="main" ;;
  3) DIST="v3"   ;;
  4) DIST="v4"   ;;
  *)
    echo "Error: unrecognised major version '$MAJOR' — update this script." >&2
    exit 1
    ;;
esac

# ── Check if already on GitHub Pages ─────────────────────────────────────────
if grep -qr "$GITHUB_PAGES_BASE" /etc/apt/sources.list.d/ 2>/dev/null; then
  echo "Already configured to use GitHub Pages apt repo — nothing to do."
  echo "Current source:"
  grep -r "$GITHUB_PAGES_BASE" /etc/apt/sources.list.d/
  exit 0
fi

# ── Find and remove Cloudsmith sources ───────────────────────────────────────
echo ""
echo "==> Searching for Cloudsmith apt sources..."
CLOUDSMITH_FILES="$(grep -rl "$CLOUDSMITH_URL_PATTERN" /etc/apt/sources.list.d/ 2>/dev/null || true)"

if [[ -z "$CLOUDSMITH_FILES" ]]; then
  echo "    No Cloudsmith sources found for this package."
else
  echo "    Found:"
  while IFS= read -r f; do echo "      $f"; done <<< "$CLOUDSMITH_FILES"
  echo "    Removing..."
  echo "$CLOUDSMITH_FILES" | xargs rm -f
  echo "    Done."
fi

# ── Remove Cloudsmith keyrings ────────────────────────────────────────────────
echo ""
echo "==> Searching for Cloudsmith keyrings..."
CLOUDSMITH_KEYRINGS="$(find /usr/share/keyrings /etc/apt/keyrings \
  -name 'ksatechnologies-truenas-proxmox*.gpg' \
  -o -name 'ksatechnologies-freenas-proxmox*.gpg' 2>/dev/null || true)"

if [[ -z "$CLOUDSMITH_KEYRINGS" ]]; then
  echo "    No Cloudsmith keyrings found."
else
  echo "    Found:"
  while IFS= read -r f; do echo "      $f"; done <<< "$CLOUDSMITH_KEYRINGS"
  echo "    Removing..."
  echo "$CLOUDSMITH_KEYRINGS" | xargs rm -f
  echo "    Done."
fi

# ── Import GitHub Pages GPG key ───────────────────────────────────────────────
echo ""
echo "==> Importing GitHub Pages GPG key → $KEYRING_PATH"
mkdir -p /etc/apt/keyrings
curl -fsSL "${GITHUB_PAGES_BASE}/public.gpg.key" \
  | gpg --dearmor \
  | tee "$KEYRING_PATH" > /dev/null
echo "    Done."

# ── Add new source ────────────────────────────────────────────────────────────
echo ""
echo "==> Adding GitHub Pages source (dist: $DIST) → $SOURCES_FILE"
echo "deb [signed-by=${KEYRING_PATH}] ${GITHUB_PAGES_BASE} ${DIST} main" \
  > "$SOURCES_FILE"
cat "$SOURCES_FILE"

# ── apt update ───────────────────────────────────────────────────────────────
echo ""
echo "==> Running apt update..."
apt-get update 2>&1 \
  | grep -E "^(Get|Hit|Err|Fetched|W:|E:)" || true

# Confirm the package is visible from the new repo
CANDIDATE="$(apt-cache policy "$INSTALLED_PKG" 2>/dev/null \
  | awk '/Candidate:/{print $2}')"

if apt-cache policy "$INSTALLED_PKG" 2>/dev/null \
    | grep -q "$GITHUB_PAGES_BASE"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Migration complete."
  echo "  Package : $INSTALLED_PKG $INSTALLED_VER"
  echo "  Repo    : $GITHUB_PAGES_BASE"
  echo "  Dist    : $DIST"
  echo "  Candidate from new repo: $CANDIDATE"
  echo ""
  if [[ "$CANDIDATE" != "$INSTALLED_VER" ]]; then
    echo "  Note: a newer version ($CANDIDATE) is available."
    echo "  Run: apt-get install $INSTALLED_PKG"
  else
    echo "  You are on the latest release in this track."
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  echo ""
  echo "Warning: migration completed but $INSTALLED_PKG was not found in" >&2
  echo "  $GITHUB_PAGES_BASE" >&2
  echo "Run 'apt-get update && apt-cache policy $INSTALLED_PKG' to investigate." >&2
  exit 1
fi
