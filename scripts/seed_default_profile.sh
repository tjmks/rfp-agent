#!/usr/bin/env bash
set -euo pipefail

TARGET_ORG="${1:-SandmannOrg}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "→ Seeding 'Default RFP' extraction profile in $TARGET_ORG"
sf apex run \
  --file "$SCRIPT_DIR/seed_default_profile.apex" \
  --target-org "$TARGET_ORG"

echo "✓ Done."
