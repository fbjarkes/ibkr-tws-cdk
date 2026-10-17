#!/usr/bin/env bash
set -euo pipefail
# Runs once per persistent data volume. Seed user defaults without overwriting them.
install -d -o trader -g trader /home/trader/scripts /home/trader/Documents
