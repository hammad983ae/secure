#!/usr/bin/env bash
# Generates App/AgentHub.xcodeproj from project.yml and opens it.
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Installing XcodeGen with Homebrew…"
  brew install xcodegen
fi
xcodegen generate
open AgentHub.xcodeproj
