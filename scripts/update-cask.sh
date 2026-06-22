#!/usr/bin/env bash
# Regenerate the Homebrew cask file for WhisperM8 from a version + SHA256.
#
# Single source of truth for the cask layout: both the release CI pipeline
# (.github/workflows/release.yml) and any manual run call this script so the
# generated `whisperm8.rb` never drifts between the two.
#
# The app is distributed self-signed (ad-hoc, no Developer ID / notarization).
# Gatekeeper would quarantine such a download, so the cask removes the
# quarantine attribute in a `postflight` step — allowed inside a custom tap.
#
# Usage: scripts/update-cask.sh <version> <sha256> <output-path>
#   e.g. scripts/update-cask.sh 2.0.0 abc123… ../homebrew-tap/Casks/whisperm8.rb

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <version> <sha256> <output-path>" >&2
    exit 1
fi

VERSION="$1"
SHA256="$2"
OUTPUT_PATH="$3"

mkdir -p "$(dirname "${OUTPUT_PATH}")"

cat > "${OUTPUT_PATH}" << EOF
cask "whisperm8" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/RankM8/WhisperM8/releases/download/v#{version}/WhisperM8-#{version}.dmg"
  name "WhisperM8"
  desc "Hotkey dictation and Claude/Codex agent-chat manager"
  homepage "https://github.com/RankM8/WhisperM8"

  depends_on macos: :sonoma # entspricht .macOS(.v14) in Package.swift; Symbol = ">= Sonoma"

  app "WhisperM8.app"

  # Self-signed/nicht notarisiert: Quarantine selbst entfernen, sonst blockt
  # Gatekeeper den Start. In einem eigenen Tap erlaubt.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/WhisperM8.app"]
  end

  zap trash: [
    "~/Library/Application Support/WhisperM8",
    "~/Library/Caches/com.whisperm8.app",
    "~/Library/Preferences/com.whisperm8.app.plist",
  ]
end
EOF

echo "✅ Cask geschrieben: ${OUTPUT_PATH} (version ${VERSION})"
