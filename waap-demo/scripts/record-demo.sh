#!/usr/bin/env bash
# ============================================================================
# record-demo.sh - optional screen + narration recorder for the demo.
# Uses the vendored ffmpeg static build if present, else a system ffmpeg.
# Captures the primary screen and default microphone to a timestamped MP4,
# and prints a shot list / narration script so you can walk the stages.
#
# Usage:
#   scripts/record-demo.sh            # start recording; Ctrl-C to stop
#   scripts/record-demo.sh --list     # just print the shot list and exit
#
# Notes:
#   - Linux (X11): uses x11grab + pulse. Wayland users should use their DE's
#     recorder; the shot list still applies.
#   - macOS: uses avfoundation (screen + mic). Adjust device indices if needed.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG="$HERE/vendor/ffmpeg/ffmpeg"
[[ -x "$FFMPEG" ]] || FFMPEG="$(command -v ffmpeg || true)"

shotlist(){
cat <<'EOF'

  ================= WAAP for AI / MCP demo - narration shot list =================

  Setup shot (topology):
    - Open the dashboard. Point out the living topology: Agent on the left,
      Avi in the center as the AI/API security gateway and enforcement point,
      Keycloak as the authorization server, two unauthenticated MCP nodes and
      an inference node on the right. Emphasize: the backends have no auth of
      their own; Avi is the only thing protecting them.

  Stage 1 - Mutual TLS at the edge:
    - Run the stage. Narrate: before any token or tool call, the agent must
      present a client certificate. A connection with no cert is rejected;
      the agent's cert is accepted. Machine identity is proven at the edge.
    - Call out the OWASP badges: MCP07 (auth), API2 / API8.

  Stage 2 - Agent self-onboarding (RFC 9728):
    - Run the stage. Narrate: an unauthenticated agent discovers how to
      authenticate via the protected-resource metadata. Discovery is
      tier-agnostic; the agent has no identity yet.

  Stage 3 - Least-privilege tool authorization:
    - Run the stage. Narrate the three tiers (catalog, ops, finance): each
      reaches its own namespace and is blocked cross-lane on the mcp_tier
      claim. This is Avi's SSO / JWT authorization policy in action.
    - Call out MCP02 (scope creep) and API5 (BFLA).

  Stage 4a - Forged and invalid tokens:
    - Run the stage. Narrate: alg:none, expired, wrong audience, forged tier
      claim - all rejected. No valid token, no access.
    - Call out MCP01 (token mismanagement), API2.

  Stage 4b - Prompt-injection guardrails:
    - Run the stage. Narrate: injection phrases in tool arguments and chat are
      blocked by the WAF custom rules and the positive security model.
    - Call out MCP06 (prompt injection via contextual payloads).

  Stage 4c - Positive security model:
    - Run the stage. Narrate: only well-formed, short queries pass; anything
      not shaped like a legitimate search is rejected before signatures run.
    - Call out API9 (inventory) and MCP06.

  Stage 5 - Session resilience under failover:
    - Run the stage. Narrate: the session is pinned to one backend; when that
      node is stopped, Avi re-pins to the healthy node and the conversation
      continues. Point out the NOTE footnote on production session state.

  Close:
    - Toggle dark/light to show polish. Recap: one enforcement point (Avi) in
      front of unauthenticated AI/MCP backends, mapped to both the OWASP API
      Top 10 and the OWASP MCP Top 10.

  ===============================================================================

EOF
}

if [[ "${1:-}" == "--list" ]]; then shotlist; exit 0; fi
shotlist

[[ -n "$FFMPEG" ]] || { echo "No ffmpeg found (vendored or system). Shot list printed above; record with your own tool."; exit 0; }

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HERE/demo-recording-$TS.mp4"
OS="$(uname -s)"

echo "Recording to: $OUT"
echo "Press Ctrl-C to stop."
echo

if [[ "$OS" == "Darwin" ]]; then
  # macOS: list devices with: ffmpeg -f avfoundation -list_devices true -i ""
  # "1:0" = screen 1, audio device 0. Adjust if your indices differ.
  exec "$FFMPEG" -f avfoundation -framerate 30 -i "1:0" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac "$OUT"
else
  # Linux X11: capture :0.0 full screen + default pulse mic
  SIZE="$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}')"; SIZE="${SIZE:-1920x1080}"
  exec "$FFMPEG" -video_size "$SIZE" -framerate 30 -f x11grab -i :0.0 \
    -f pulse -i default \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac "$OUT"
fi
