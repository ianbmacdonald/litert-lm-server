#!/usr/bin/env bash
# Smoke-test a musl bundle tarball inside the prplOS rootfs (bubblewrap, host network, 2 CPUs), the
# way procd would start it: through the bundle's `run` wrapper, with procd's musl
# LD_PRELOAD=/lib/libsetlbf.so in the environment and no LD_LIBRARY_PATH (lib/ is found via RUNPATH).
# Runs one non-streaming and one streaming chat completion and saves every response under <out>.
#
#   musl/smoke-prplos.sh <bundle.tar.gz> <prplOS root-x86 dir> <model.litertlm> <out dir> [port]
set -uo pipefail
TARBALL=$1 ROOTFS=$2 MODEL=$3 OUT=$4 PORT=${5:-18197}
die() { echo "smoke-prplos.sh: ERROR: $*" >&2; exit 1; }
[ -f "$TARBALL" ] || die "no tarball $TARBALL"
[ -d "$ROOTFS" ] || die "no rootfs $ROOTFS"
[ -f "$MODEL" ] || die "no model $MODEL"
[ -e "$ROOTFS/lib/libsetlbf.so" ] || die "rootfs has no /lib/libsetlbf.so to preload"
command -v bwrap >/dev/null || die "bwrap not installed"
NAME=$(basename "$TARBALL" .tar.gz)
rm -rf "$OUT" && mkdir -p "$OUT/run/model" || die "cannot create $OUT"
tar -xzf "$TARBALL" -C "$OUT/run" || die "cannot extract $TARBALL"
[ -x "$OUT/run/$NAME/run" ] || die "tarball does not unpack to $NAME/run"
ln "$MODEL" "$OUT/run/model/" 2>/dev/null || cp "$MODEL" "$OUT/run/model/"
M=/tmp/litert/model/$(basename "$MODEL")

bwrap --ro-bind "$ROOTFS" / --dev /dev --proc /proc --tmpfs /tmp --bind "$OUT/run" /tmp/litert \
    --clearenv --setenv PATH /usr/sbin:/usr/bin:/sbin:/bin --setenv LD_PRELOAD /lib/libsetlbf.so \
    --die-with-parent -- nice -n 19 taskset -c 2,3 /bin/sh "/tmp/litert/$NAME/run" \
    --model "$M" --host 127.0.0.1 --port "$PORT" > "$OUT/server.log" 2>&1 &
BW=$!
cleanup() { kill "$BW" 2>/dev/null; wait "$BW" 2>/dev/null; }
trap cleanup EXIT

up=0
for _ in $(seq 1 240); do
    if curl -sf "http://127.0.0.1:$PORT/health" > "$OUT/health.json" 2>/dev/null; then up=1; break; fi
    kill -0 "$BW" 2>/dev/null || break
    sleep 0.5
done
[ "$up" = 1 ] || { tail -20 "$OUT/server.log" >&2; die "server did not come up (see $OUT/server.log)"; }
echo "health: $(cat "$OUT/health.json")"
PID=$(pgrep -f "^/tmp/litert/$NAME/bin/litert-lm-server" | head -1)
if [ -n "$PID" ]; then
    grep -E '^(Name|NSpid|VmRSS)' "/proc/$PID/status" | tr -s ' \t' ' ' | tr '\n' ' ' > "$OUT/proc-status.txt"
    tr '\0' '\n' < "/proc/$PID/environ" | grep -E '^(LD_PRELOAD|LD_LIBRARY_PATH)=' > "$OUT/proc-env.txt"
    grep -E 'libsetlbf|libkissfft|ld-musl' "/proc/$PID/maps" | awk '{print $6}' | sort -u > "$OUT/proc-maps.txt"
    echo "process: $(cat "$OUT/proc-status.txt")"
    echo "environ: $(tr '\n' ' ' < "$OUT/proc-env.txt")"
    echo "mapped: $(tr '\n' ' ' < "$OUT/proc-maps.txt")"
fi

REQ='{"model":"m","messages":[{"role":"user","content":"In one sentence: what does a home internet gateway do?"}],"max_tokens":64}'
curl -s -m 300 -H 'Content-Type: application/json' -d "$REQ" "http://127.0.0.1:$PORT/v1/chat/completions" > "$OUT/chat.json"
rc_chat=$?
curl -s -N -m 300 -H 'Content-Type: application/json' \
    -d '{"model":"m","stream":true,"max_tokens":48,"chat_template_kwargs":{"enable_thinking":false},"messages":[{"role":"user","content":"Name three router brands."}]}' \
    "http://127.0.0.1:$PORT/v1/chat/completions" > "$OUT/stream.txt"
rc_stream=$?
python3 - "$OUT/chat.json" "$OUT/stream.txt" > "$OUT/verdict.txt" <<'PY'
import json, sys
ok = True
try:
    d = json.load(open(sys.argv[1]))
    c = d["choices"][0]
    print("chat:", c["finish_reason"], d.get("usage"), repr(c["message"]["content"][:240]))
    ok &= bool(c["message"]["content"])
except Exception as e:
    print("chat: FAILED", e); ok = False
text, frames, done = "", 0, False
for line in open(sys.argv[2]):
    if line.startswith("data: [DONE]"):
        done = True
    elif line.startswith("data: {"):
        frames += 1
        text += json.loads(line[6:])["choices"][0].get("delta", {}).get("content", "") or ""
print(f"stream: frames={frames} done={done} text={text[:240]!r}")
ok &= frames > 0 and done and bool(text)
print("VERDICT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
rc_verdict=$?
cat "$OUT/verdict.txt"
cleanup
trap - EXIT
sleep 1
if pgrep -f "^/tmp/litert/$NAME/bin/litert-lm-server" > /dev/null; then echo "server still alive"; else echo "server stopped"; fi
[ $rc_chat = 0 ] && [ $rc_stream = 0 ] && [ $rc_verdict = 0 ] || die "smoke test failed (curl chat=$rc_chat stream=$rc_stream verdict=$rc_verdict)"
echo "smoke-prplos.sh: PASS"
