#!/usr/bin/env bash
#
# unifi-portforward-reconcile.sh -- Pi-side: restore UDM port-forwards if
# they go missing (e.g. wiped by a UniFi firmware upgrade).
#
# Runs LOCALLY on the Pi via a systemd timer. Compares the UDM's current
# port-forward rules against the desired set and recreates any that are
# missing. Silent on a healthy system; logs (to journald) only when it
# detects drift and takes action.
#
# Config (root-only):
#   /etc/mediaserver/unifi.env               UNIFI_GATEWAY, UNIFI_API_KEY, MEDIA_IP
#   /etc/mediaserver/unifi-portforwards.json desired forwards (same schema as repo)
#
# Exit codes: 0 ok / restored, 1 restore failed, 2 misconfig.
#
set -euo pipefail

ENV_FILE=/etc/mediaserver/unifi.env
DESIRED_FILE=/etc/mediaserver/unifi-portforwards.json
LOG_PREFIX="[unifi-pf-reconcile]"

[[ -f "$ENV_FILE" ]]     || { echo "$LOG_PREFIX ERROR: $ENV_FILE missing" >&2; exit 2; }
[[ -f "$DESIRED_FILE" ]] || { echo "$LOG_PREFIX ERROR: $DESIRED_FILE missing" >&2; exit 2; }

set -a; source "$ENV_FILE"; set +a
: "${UNIFI_GATEWAY:?$LOG_PREFIX UNIFI_GATEWAY unset}"
: "${UNIFI_API_KEY:?$LOG_PREFIX UNIFI_API_KEY unset}"
: "${MEDIA_IP:?$LOG_PREFIX MEDIA_IP unset}"

API="https://$UNIFI_GATEWAY/proxy/network/api/s/default"
CURL=(curl -sk --max-time 15 -H "X-API-KEY: $UNIFI_API_KEY" -H "Accept: application/json")

current=$("${CURL[@]}" "$API/rest/portforward" 2>/dev/null || true)
if [[ -z "$current" || "$current" != *'"rc":"ok"'* ]]; then
    echo "$LOG_PREFIX ERROR: could not query UDM port-forwards (API unreachable?)" >&2
    exit 1
fi

missing=$(CUR="$current" DESIRED="$DESIRED_FILE" python3 <<'PY'
import os, json
cur = json.loads(os.environ["CUR"]).get("data", [])
desired = json.load(open(os.environ["DESIRED"]))["forwards"]
have = {(r.get("proto"), str(r.get("dst_port"))) for r in cur}
for f in desired:
    if (f["proto"], str(f["dst_port"])) not in have:
        print("{}\t{}\t{}\t{}".format(f["name"], f["proto"], f["dst_port"], f["fwd_port"]))
PY
)

# Healthy: nothing missing -> exit silently (no journal noise).
[[ -z "$missing" ]] && exit 0

echo "$LOG_PREFIX drift detected: $(echo "$missing" | wc -l | tr -d ' ') rule(s) missing from UDM -- restoring"
rc=0
while IFS=$'\t' read -r name proto dport fport; do
    [[ -z "$name" ]] && continue
    if "${CURL[@]}" -X POST -H "Content-Type: application/json" "$API/rest/portforward" \
        -d "{\"name\":\"$name\",\"enabled\":true,\"pfwd_interface\":\"wan\",\"src\":\"any\",\"dst_port\":\"$dport\",\"fwd\":\"$MEDIA_IP\",\"fwd_port\":\"$fport\",\"proto\":\"$proto\",\"log\":false}" \
        | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("meta",{}).get("rc")=="ok" else 1)'; then
        echo "$LOG_PREFIX restored: $name ($proto :$dport -> $MEDIA_IP:$fport)"
    else
        echo "$LOG_PREFIX ERROR: failed to restore $name ($proto :$dport)" >&2
        rc=1
    fi
done <<< "$missing"

exit $rc
