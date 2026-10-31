#!/usr/bin/env bash
# Container-style smoke test of a musl bundle inside the prplOS rootfs: the server runs as PID 1 of
# its own PID namespace (bubblewrap --as-pid-1) in a systemd user unit, bound to --host 0.0.0.0.
# Checks /health, one chat completion, the listening socket (ss -ltnp), and how long the server takes
# to exit after SIGTERM (PID 1 ignores a signal it has no handler for, so a server without one
# never exits and the test reports FAIL).
#
#   musl/smoke-feed.sh <bundle dir> <prplOS rootfs> <model.litertlm> <out dir> [port] [max_tokens]
set -uo pipefail
B=$1 ROOTFS=$2 MODEL=$3 OUT=$4 PORT=${5:-18198} MAXTOK=${6:-48}
UNIT=litertlm-smoke-$PORT
die() { echo "smoke-feed.sh: ERROR: $*" >&2; exit 1; }
[ -x "$B/bin/litert-lm-server" ] || die "no $B/bin/litert-lm-server"
[ -d "$ROOTFS/lib" ] || die "no rootfs $ROOTFS"
[ -f "$MODEL" ] || die "no model $MODEL"
command -v bwrap > /dev/null || die "bwrap not installed"
mkdir -p "$OUT" || die "cannot create $OUT"
B=$(cd "$B" && pwd) MD=$(cd "$(dirname "$MODEL")" && pwd)
systemctl --user stop "$UNIT" 2> /dev/null; systemctl --user reset-failed "$UNIT" 2> /dev/null

systemd-run --user --unit="$UNIT" --quiet -p KillMode=mixed -p TimeoutStopSec=5 \
    --setenv=PATH=/usr/sbin:/usr/bin:/sbin:/bin -- \
    bwrap --ro-bind "$ROOTFS" / --dev /dev --proc /proc --tmpfs /tmp --dir /tmp/llm --ro-bind "$B" /tmp/llm \
    --dir /tmp/models --bind "$MD" /tmp/models --unshare-pid --as-pid-1 --die-with-parent \
    /tmp/llm/bin/litert-lm-server --model "/tmp/models/$(basename "$MODEL")" --host 0.0.0.0 --port "$PORT" \
    || die "systemd-run failed"
cleanup() { systemctl --user stop "$UNIT" 2> /dev/null; systemctl --user reset-failed "$UNIT" 2> /dev/null; }
trap cleanup EXIT

up=0
for _ in $(seq 1 600); do
    if curl -sf "http://127.0.0.1:$PORT/health" > "$OUT/health.json" 2> /dev/null; then up=1; break; fi
    systemctl --user is-active -q "$UNIT" || break
    sleep 0.5
done
journalctl --user -u "$UNIT" --no-pager -o cat > "$OUT/server.log" 2>&1
[ "$up" = 1 ] || { tail -20 "$OUT/server.log" >&2; die "server did not come up"; }
echo "health: $(cat "$OUT/health.json")"
ss -ltnp "sport = :$PORT" > "$OUT/ss.txt" 2>&1
echo "listen: $(grep -o "[0-9.*:]*:$PORT" "$OUT/ss.txt" | sort -u | tr '\n' ' ')"
grep -q -E "(0\.0\.0\.0|\*):$PORT" "$OUT/ss.txt" || die "not listening on 0.0.0.0:$PORT (see $OUT/ss.txt)"

REQ="{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"In one sentence: what does a home internet gateway do?\"}],\"max_tokens\":$MAXTOK,\"chat_template_kwargs\":{\"enable_thinking\":false}}"
t0=$(date +%s.%N)
curl -s -m 600 -H 'Content-Type: application/json' -d "$REQ" "http://127.0.0.1:$PORT/v1/chat/completions" > "$OUT/chat.json"
rc_chat=$?
t1=$(date +%s.%N)
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d["choices"][0]; print("chat:", c["finish_reason"], d.get("usage"), repr(c["message"]["content"][:200])); sys.exit(0 if c["message"]["content"] else 1)' "$OUT/chat.json"
rc_verdict=$?
echo "chat seconds: $(python3 -c "print(round($t1 - $t0, 2))")"

# SIGTERM only the server (PID 1 of the namespace), not bwrap's parent.
SRV=$(systemctl --user show -p ControlGroup --value "$UNIT")
PID=""
for p in $(cat "/sys/fs/cgroup$SRV/cgroup.procs" 2> /dev/null); do
    [ "$(cat "/proc/$p/comm" 2> /dev/null)" = "litert-lm-serve" ] && PID=$p
done
[ -n "$PID" ] || die "server pid not found in $SRV"
echo "server: pid $PID, ns pid $(awk '/^NSpid/ {print $NF}' "/proc/$PID/status")"
ts=$(date +%s.%N)
kill -TERM "$PID"
gone=0
for _ in $(seq 1 100); do kill -0 "$PID" 2> /dev/null || { gone=1; break; }; sleep 0.05; done
te=$(date +%s.%N)
sigterm=$(python3 -c "print(round($te - $ts, 3))")
journalctl --user -u "$UNIT" --no-pager -o cat > "$OUT/server.log" 2>&1
if [ "$gone" = 1 ]; then echo "SIGTERM: exited in ${sigterm}s"; else echo "SIGTERM: still running after ${sigterm}s"; fi
[ $rc_chat = 0 ] && [ $rc_verdict = 0 ] || die "chat failed (curl=$rc_chat verdict=$rc_verdict)"
[ "$gone" = 1 ] && python3 -c "import sys; sys.exit(0 if $sigterm < 2 else 1)" || die "SIGTERM exit took ${sigterm}s (limit 2 s)"
echo "smoke-feed.sh: PASS"
