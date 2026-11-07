#!/bin/bash
# SC2016: the client scripts are single-quoted on purpose; $RSH, $SSH and $SRV expand in
# the client container. SC2329: the test functions are called through run_test.
# shellcheck disable=SC2016,SC2329
# Behaviour tests of the rsync image. Run from the repository root with the docker CLI
# against a built image, on Linux/WSL or in Git Bash on Windows:
#
#   bash tests/run.sh rsync:local
#   TEST_FILTER='refused|confined' bash tests/run.sh rsync:local   # only matching tests
#
# Everything runs in docker on a private test network, with two containers for the whole
# run: one server started from the image (users alice and alice2, each with the folder
# "upload"), and one long-running client from the same image with the entrypoint
# overridden (it has the ssh client and rsync). Every check is a `docker exec` into
# them; no test restarts the server. The ed25519 test keys are generated for this run
# into docker volumes; the public keys are mounted into the server read-only at
# /opt/rsync/ssh_keys/<user>/, the way a deployment does, and users.conf at
# /etc/rsync/users.conf. The server generates its host keys at start. No host directory
# is bind-mounted. Readiness is polled (health status), there are no fixed waits.
# Containers, volumes and the network have names starting with a unique prefix and are
# removed at the end, also on failure; nothing else is touched.
#
# Each check prints "PASS: <name>" or "FAIL: <name>: <reason>". The last line is
# "ALL <n> TESTS PASSED" (exit 0) or "<m> OF <n> TESTS FAILED" (exit 1).
# TEST_FILTER is an extended regex matched against the test names (default: all tests).
set -euo pipefail

# Git Bash: do not rewrite /paths in docker arguments into Windows paths
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

IMAGE="${1:-}"
[ -n "$IMAGE" ] && [ $# -eq 1 ] || { echo "Usage: $0 <image>" >&2; exit 2; }
command -v docker >/dev/null || { echo "docker not found" >&2; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image not found: $IMAGE" >&2; exit 2; }
TEST_FILTER="${TEST_FILTER:-}"

PFX="rsync-test-$$"
NET="$PFX-net"
SRV="$PFX-srv"
CLI="$PFX-cli"
VOL_SRVKEYS="$PFX-srvkeys"   # /opt/rsync/ssh_keys/<user>/id_ed25519.pub (server, read-only)
VOL_CLIKEYS="$PFX-clikeys"   # /keys/<user> private keys (clients, read-only)
VOL_CONF="$PFX-conf"         # /etc/rsync/users.conf (server, read-only)

cleanup() {
  local rc=$?
  trap - EXIT
  local ids
  ids="$(docker ps -aq --filter "name=${PFX}-" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1 || true
  ids="$(docker volume ls -q --filter "name=${PFX}-" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker volume rm -f $ids >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- helpers -------------------------------------------------------------------------

fail_t() { echo "$*"; exit 1; }                       # fail the current test (runs in a subshell)
expect() { [ "$2" = "$3" ] || fail_t "$1: expected [$3], got [$2]"; }
contains() { case "$2" in *"$3"*) ;; *) fail_t "$1: output does not contain [$3]: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) fail_t "$1: output contains [$3]: $2" ;; esac; }

wait_until() {   # wait_until <tries> <cmd...>: run cmd every 0.25 s until it succeeds
  local n=$1; shift
  while [ "$n" -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; sleep 0.25; n=$((n - 1)); done
  return 1
}
health_is() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = "$2" ]; }

# Run a shell script as root in the server container
on_srv() { docker exec "$SRV" bash -c "$1"; }

# Run a shell script in the client container: cli <key> <script>
# /tmp is emptied first, so each script starts clean. The script has $SSH (ssh with the
# key <key> and test options), $RSH (the same for rsync -e) and $SRV (the server host
# name). Prints stdout and stderr; returns the script's exit code. A non-zero exit is
# often what a test expects.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"
cli() {
  docker exec -i -e "SSH=ssh -i /keys/$1 $SSH_OPTS" -e "RSH=ssh -i /keys/$1 $SSH_OPTS -o LogLevel=ERROR" \
    "$CLI" bash -c "find /tmp -mindepth 1 -delete; cd /tmp; $2" 2>&1 | tr -d '\000'
}

PASSED=0 FAILED=0
run_test() {   # run_test <name> <function> [args...]
  local name="$1" fn="$2"; shift 2
  if [ -n "$TEST_FILTER" ] && ! [[ "$name" =~ $TEST_FILTER ]]; then return 0; fi
  local out rc=0
  out="$($fn "$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    PASSED=$((PASSED + 1)); echo "PASS: $name"
  else
    FAILED=$((FAILED + 1)); echo "FAIL: $name: $(printf '%s' "$out" | head -n 12 | sed '2,$s/^/    /')"
  fi
}

# ---- setup: network, client, keys, users.conf, server ----------------------------------
# Always done, whatever TEST_FILTER selects. A server that does not become healthy is
# reported by the "server starts and becomes healthy" test.

docker network create "$NET" >/dev/null
docker volume create "$VOL_SRVKEYS" >/dev/null
docker volume create "$VOL_CLIKEYS" >/dev/null
docker volume create "$VOL_CONF" >/dev/null
docker run -d --name "$CLI" --network "$NET" -e "SRV=$SRV" -v "$VOL_SRVKEYS:/srvkeys" \
  -v "$VOL_CLIKEYS:/keys" -v "$VOL_CONF:/conf" --entrypoint sleep "$IMAGE" infinity >/dev/null \
  || { echo "SETUP FAILED: could not start the client container"; exit 1; }
docker exec "$CLI" bash -c '
    set -e
    for u in alice alice2; do
      ssh-keygen -q -t ed25519 -N "" -C "rsync-test-$u" -f "/keys/$u"
      chmod 600 "/keys/$u"
      mkdir -p "/srvkeys/$u"
      cp "/keys/$u.pub" "/srvkeys/$u/id_ed25519.pub"
    done
    printf "%s\n" "# test users" "alice::1001::upload" "alice2::1002::upload" > /conf/users.conf
  ' >/dev/null || { echo "SETUP FAILED: could not generate the test keys and users.conf"; exit 1; }

# Health checked every second for the test; command, timeout and retries are the image's.
docker run -d --name "$SRV" --network "$NET" --health-interval 1s \
  -v "$VOL_SRVKEYS:/opt/rsync/ssh_keys:ro" -v "$VOL_CONF:/etc/rsync:ro" "$IMAGE" >/dev/null \
  || { echo "SETUP FAILED: could not start the server container"; exit 1; }
SRV_HEALTHY=0
wait_until 240 health_is "$SRV" healthy && SRV_HEALTHY=1

need_srv() { [ "$SRV_HEALTHY" -eq 1 ] || fail_t "the server did not start"; }

# Server-side fixtures for all tests, in one go (each file is used by one test)
SRV_HOSTNAME=""
if [ "$SRV_HEALTHY" -eq 1 ]; then
  on_srv 'set -e; cd /home/alice/upload
    echo "down-content-42" > down.txt; echo x > listed.txt; echo rooted-ok > abs.txt; echo first > first.txt
    mkdir del; echo old > del/old.txt; head -c 4M /dev/zero > big.bin
    chown -R alice /home/alice/upload
    echo secret-of-alice2 > /home/alice2/upload/a2.txt; chown alice2 /home/alice2/upload/a2.txt' \
    || { echo "SETUP FAILED: could not write the server fixtures"; exit 1; }
  SRV_HOSTNAME="$(on_srv 'cat /etc/hostname')"
fi

# ---- image and server ----------------------------------------------------------------

t_healthcheck_defined() {
  local hc
  hc="$(docker inspect -f '{{json .Config.Healthcheck}}' "$IMAGE")"
  contains "image healthcheck" "$hc" "/dev/tcp/127.0.0.1/22"
  contains "interval" "$hc" '"Interval":60000000000'
}

t_starts_healthy() {
  [ "$SRV_HEALTHY" -eq 1 ] || fail_t "never healthy (status: $(docker inspect -f '{{.State.Health.Status}}' "$SRV" 2>&1)): $(docker logs "$SRV" 2>&1 | tail -n 8)"
  expect "host keys and users" "$(on_srv 'test -s /etc/ssh/ssh_host_ed25519_key && test -s /etc/ssh/ssh_host_rsa_key && echo keys; getent passwd alice alice2 | cut -d: -f1,3')" "keys
alice:1001
alice2:1002"
}

t_ssh_root_owned() {
  need_srv
  local u want=""
  for u in alice alice2; do
    want="$want$u
root:root 755 /home/$u
root:root 755 /home/$u/.ssh
root:root 755 /home/$u/.ssh/keys
root:root 644 /home/$u/.ssh/authorized_keys
lines 1, without restrict 0
$u 755 /home/$u/upload
"
  done
  expect "owners, modes and authorized_keys" "$(on_srv 'for u in alice alice2; do echo "$u"
    stat -c "%U:%G %a %n" /home/$u /home/$u/.ssh /home/$u/.ssh/keys /home/$u/.ssh/authorized_keys
    echo "lines $(wc -l < /home/$u/.ssh/authorized_keys), without restrict $(grep -vc "^restrict ssh-ed25519 " /home/$u/.ssh/authorized_keys)"
    stat -c "%U %a %n" /home/$u/upload; done')
" "$want"
}

t_wrong_key() {
  need_srv
  local out
  out="$(cli alice2 'rsync -e "$RSH" alice@$SRV:upload/; echo "rc1=$?"
    rsync -e "${RSH/alice2/alice}" alice2@$SRV:upload/; echo "rc2=$?"')"
  expect "Permission denied lines" "$(printf '%s\n' "$out" | grep -c 'Permission denied')" "2"
  lacks "alice with alice2's key" "$out" "rc1=0"
  lacks "alice2 with alice's key" "$out" "rc2=0"
}

# ---- allowed: transfers inside the home folder ---------------------------------------

t_upload() {
  need_srv
  local out
  out="$(cli alice 'set -e; mkdir -p /tmp/d/sub; echo "up-$$-content" > /tmp/d/sub/up.txt
    rsync -a -e "$RSH" /tmp/d/ alice@$SRV:upload/ && echo "rc=0"; cat /tmp/d/sub/up.txt')"
  contains "rsync push" "$out" "rc=0"
  expect "uploaded content and owner" "$(on_srv 'cat /home/alice/upload/sub/up.txt; stat -c %U /home/alice/upload/sub/up.txt')" "$(printf '%s' "$out" | tail -n 1)
alice"
}

t_download() {
  need_srv
  local out
  out="$(cli alice 'mkdir /tmp/out && rsync -a -e "$RSH" alice@$SRV:upload/down.txt /tmp/out/ && cat /tmp/out/down.txt')"
  expect "downloaded content" "$out" "down-content-42"
}

t_list() {
  need_srv
  local out
  out="$(cli alice 'rsync -e "$RSH" alice@$SRV:upload/; echo "[home]"; rsync -e "$RSH" alice@$SRV:')"
  contains "listing of upload/" "${out%%"[home]"*}" "listed.txt"
  contains "listing of the home folder" "${out#*"[home]"}" " upload"
}

t_delete() {
  need_srv
  local out
  out="$(cli alice 'mkdir -p /tmp/d && echo new > /tmp/d/new.txt
    rsync -a --delete -e "$RSH" /tmp/d/ alice@$SRV:upload/del/ && echo "rc=0"')"
  contains "rsync --delete" "$out" "rc=0"
  expect "folder after --delete" "$(on_srv 'ls -A /home/alice/upload/del')" "new.txt"
}

# ---- refused -------------------------------------------------------------------------

t_shell_command() {
  need_srv
  local out
  out="$(cli alice '$SSH alice@$SRV id; echo "rc=$?"
    $SSH alice@$SRV "rsync --server --sender -logDtpre.iLsfxCIvu . upload/ ; touch /tmp/pwned1 && id" </dev/null
    $SSH alice@$SRV "rsync --server --sender -logDtpre.iLsfxCIvu . \$(touch /tmp/pwned2) upload/\`touch /tmp/pwned3\`" </dev/null')"
  contains "ssh id" "$out" "SSH_ORIGINAL_COMMAND does not run rsync"
  lacks "ssh id" "$out" "rc=0"
  lacks "ssh id, rsync followed by a shell command, command substitution" "$out" "uid="
  expect "files created by the shell commands" "$(on_srv 'ls /tmp/pwned* /home/alice/upload/pwned* 2>/dev/null || true')" ""
}

t_pty() {
  need_srv
  local out
  out="$(cli alice '$SSH -tt alice@$SRV </dev/null; echo "rc=$?"')"
  contains "ssh -tt" "$out" "PTY allocation request failed"
  lacks "ssh -tt" "$out" "rc=0"
}

t_dotdot_path() {
  need_srv
  local out
  out="$(cli alice 'mkdir /tmp/out; echo x > /tmp/f.txt
    rsync -a -e "$RSH" alice@$SRV:../alice2/upload/ /tmp/out/
    rsync -a -e "$RSH" /tmp/f.txt alice@$SRV:../alice2/upload/
    rsync -e "$RSH" alice@$SRV:upload/../../alice2/
    ls -A /tmp/out')"
  expect "refusals of pull ../alice2/upload/, push to ../alice2/upload/, upload/../../alice2/" \
    "$(printf '%s\n' "$out" | grep -c 'do not use .. in arg')" "3"
  lacks "pull ../alice2/upload/" "$out" "a2.txt"
  expect "alice2 upload folder" "$(on_srv 'ls -A /home/alice2/upload')" "a2.txt"
}

t_dotdot_options() {
  need_srv
  local out
  out="$(cli alice 'rsync -M--log-file=../alice2/upload/log -e "$RSH" alice@$SRV:upload/
    echo x > /tmp/f.txt; rsync -a --temp-dir=../alice2/upload -e "$RSH" /tmp/f.txt alice@$SRV:upload/')"
  contains "--log-file=../alice2/upload/log" "$out" "do not use .. in --log-file"
  contains "--temp-dir=../alice2/upload" "$out" "do not use .. in --temp-dir"
  expect "alice2 upload folder" "$(on_srv 'ls -A /home/alice2/upload | grep -v a2.txt || true')" ""
}

t_secluded_args() {
  need_srv
  local out
  out="$(cli alice 'rsync -s -e "$RSH" alice@$SRV:/etc/; echo "rc=$?"')"
  contains "rsync -s" "$out" "option -s has been disabled"
  lacks "rsync -s" "$out" "passwd"
}

t_home_root_readonly() {
  need_srv
  local out
  out="$(cli alice 'echo x > /tmp/f.txt; rsync -e "$RSH" /tmp/f.txt alice@$SRV:; echo "rc=$?"')"
  lacks "push into the home folder root" "$out" "rc=0"
  expect "home folder" "$(on_srv 'ls -A /home/alice')" ".ssh
upload"
}

t_inplace_authorized_keys() {
  need_srv
  local before out
  before="$(on_srv 'sha256sum /home/alice/.ssh/authorized_keys; ls -A /home/alice/.ssh /home/alice/.ssh/keys')"
  out="$(cli alice 'echo "ssh-ed25519 AAAAevil" > /tmp/ak
    rsync --inplace -e "$RSH" /tmp/ak alice@$SRV:.ssh/authorized_keys; echo "rc=$?"
    rsync -e "$RSH" /tmp/ak alice@$SRV:.ssh/authorized_keys; echo "rc=$?"
    rsync -e "$RSH" /tmp/ak alice@$SRV:.ssh/keys/evil.pub; echo "rc=$?"')"
  contains "rsync --inplace .ssh/authorized_keys" "$out" "Permission denied"
  lacks "writes into .ssh" "$out" "rc=0"
  expect "authorized_keys and .ssh content" "$(on_srv 'sha256sum /home/alice/.ssh/authorized_keys; ls -A /home/alice/.ssh /home/alice/.ssh/keys')" "$before"
  contains ".ssh content" "$before" "/home/alice/.ssh/keys:
id_ed25519.pub"
}

t_port_forwarding() {
  need_srv
  local out
  out="$(cli alice 'timeout 20 $SSH -N -o ExitOnForwardFailure=yes -R 127.0.0.1:2222:127.0.0.1:22 alice@$SRV
    $SSH -N -L 127.0.0.1:2222:127.0.0.1:22 alice@$SRV & pid=$!
    for _ in $(seq 100); do (exec 3<>/dev/tcp/127.0.0.1/2222) 2>/dev/null && break; sleep 0.1; done
    timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/2222; head -c 7 <&3"; echo; kill $pid 2>/dev/null; wait')"
  contains "ssh -R" "$out" "remote port forwarding failed"
  lacks "ssh -L to the server's port 22" "$out" "SSH-2.0"
  contains "ssh -L" "$out" "administratively prohibited"
}

t_one_session_per_user() {
  need_srv
  local out
  # The first session is a slow download; it holds the lock once its temp file appears.
  out="$(cli alice 'mkdir /tmp/bg; rsync --bwlimit=8 -e "$RSH" alice@$SRV:upload/big.bin /tmp/bg/ >/dev/null 2>&1 & pid=$!
    for _ in $(seq 200); do [ -n "$(ls -A /tmp/bg)" ] && break; sleep 0.1; done
    echo "[second alice session]"; rsync -e "$RSH" alice@$SRV:upload/; echo "rc=$?"
    echo "[alice2 session]"; rsync -e "ssh -i /keys/alice2 ${RSH#ssh -i /keys/alice }" alice2@$SRV:upload/ >/dev/null; echo "rc2=$?"
    kill $pid 2>/dev/null; wait')"
  contains "second alice session" "$out" "Another instance of rrsync is already accessing this directory"
  contains "alice2 session in parallel" "$out" "rc2=0"
  # The server side of the killed session ends on its next write; wait for the lock to go.
  wait_until 80 alice_unlocked || fail_t "alice's lock was not released"
}

alice_unlocked() {
  ! cli alice 'rsync -e "$RSH" alice@$SRV:' | grep -q "Another instance"
}

# ---- confined: paths are rooted at the home folder, nothing outside is reached ---------

t_confined_absolute() {
  need_srv
  local out
  out="$(cli alice 'mkdir /tmp/abs /tmp/out; rsync -e "$RSH" alice@$SRV:/upload/abs.txt /tmp/abs/ && cat /tmp/abs/abs.txt
    rsync -e "$RSH" alice@$SRV:/etc/passwd /tmp/out/; echo "rc=$?"; cat /tmp/out/* 2>/dev/null
    rsync -r -e "$RSH" alice@$SRV:/')"
  expect "/upload/abs.txt is rooted at the home folder" "$(printf '%s\n' "$out" | head -n 1)" "rooted-ok"
  lacks "/etc/passwd" "$out" "root:x:0:0"
  lacks "/etc/passwd" "$out" "rc=0"
  lacks "listing of /" "$out" "etc/passwd"
  lacks "listing of /" "$out" "usr/bin"
}

t_confined_other_user() {
  need_srv
  local out
  out="$(cli alice 'mkdir /tmp/out; rsync -a -e "$RSH" alice@$SRV:/home/alice2/upload/ /tmp/out/; echo "rc1=$?"; ls -A /tmp/out; cat /tmp/out/* 2>/dev/null
    echo x > /tmp/f.txt; rsync -e "$RSH" /tmp/f.txt alice@$SRV:/home/alice2/upload/; echo "rc2=$?"')"
  lacks "alice reading /home/alice2/upload/" "$out" "a2.txt"
  lacks "alice reading /home/alice2/upload/" "$out" "secret-of-alice2"
  lacks "alice reading /home/alice2/upload/" "$out" "rc1=0"
  lacks "alice writing /home/alice2/upload/" "$out" "rc2=0"
  expect "alice2 upload folder" "$(on_srv 'ls -A /home/alice2/upload')" "a2.txt"
}

t_confined_second_source() {
  need_srv
  local real="$SRV_HOSTNAME" out
  [ -n "$real" ] || fail_t "server hostname unknown"
  out="$(cli alice 'mkdir /tmp/out; rsync -e "$RSH" alice@$SRV:upload/first.txt :/etc/hostname /tmp/out/; echo "rc=$?"; ls -A /tmp/out; cat /tmp/out/* 2>/dev/null')"
  contains "first source" "$out" "first"
  lacks "second source /etc/hostname" "$out" "$real"
  lacks "second source /etc/hostname" "$out" "rc=0"
}

t_confined_files_from() {
  need_srv
  local out
  out="$(cli alice 'mkdir /tmp/out /tmp/out2; printf "etc/passwd\netc/hostname\n" | rsync -a --files-from=- -e "$RSH" alice@$SRV:/ /tmp/out/
    rsync -a --files-from=:/etc/passwd -e "$RSH" alice@$SRV:/ /tmp/out2/; echo "rc=$?"; find /tmp/out /tmp/out2 -type f')"
  lacks "--files-from with etc/passwd" "$out" "/tmp/out/etc/"
  lacks "--files-from=:/etc/passwd" "$out" "rc=0"
  lacks "--files-from=:/etc/passwd" "$out" "/tmp/out2/"
}

t_confined_log_file() {
  need_srv
  local out
  out="$(cli alice 'rsync -M--log-file=/tmp/x -e "$RSH" alice@$SRV:upload/ >/dev/null 2>&1
    rsync -M--log-file=/upload/log.txt -e "$RSH" alice@$SRV:upload/ >/dev/null; echo "rc=$?"')"
  contains "--log-file=/upload/log.txt" "$out" "rc=0"
  expect "/tmp/x, /home/alice/tmp, /home/alice/upload/log.txt in the server" \
    "$(on_srv 'ls -d /tmp/x /home/alice/tmp 2>/dev/null; test -s /home/alice/upload/log.txt && echo log-rooted')" "log-rooted"
}

t_confined_temp_dir() {
  need_srv
  local before after out
  before="$(on_srv 'ls -A /')"
  out="$(cli alice 'echo tmpdir-content > /tmp/t.txt; rsync --temp-dir=/ -e "$RSH" /tmp/t.txt alice@$SRV:upload/; echo "rc1=$?"
    rsync --temp-dir=/upload -e "$RSH" /tmp/t.txt alice@$SRV:upload/; echo "rc2=$?"')"
  after="$(on_srv 'ls -A /; cat /home/alice/upload/t.txt')"
  expect "server / after --temp-dir=/, and the upload with --temp-dir=/upload" "$after" "$before
tmpdir-content"
  lacks "--temp-dir=/" "$out" "rc1=0"
  contains "--temp-dir=/upload" "$out" "rc2=0"
}

t_confined_symlink() {
  need_srv
  local out
  out="$(cli alice 'set -e; mkdir -p /tmp/d; ln -s /etc /tmp/d/etclink; ln -s ../../alice2/upload /tmp/d/a2link
    rsync -a -e "$RSH" /tmp/d/ alice@$SRV:upload/links/; echo "rc=0"')"
  contains "symlink upload" "$out" "rc=0"
  local stored
  stored="$(on_srv 'find /home/alice/upload/links -type l -printf "%f -> %l\n" | sort')"
  lacks "stored link" "$stored" "etclink -> /etc"
  out="$(cli alice 'mkdir /tmp/out
    rsync -e "$RSH" alice@$SRV:upload/links/etclink/passwd /tmp/out/; echo "rc=$?"
    rsync -e "$RSH" alice@$SRV:upload/links/etclink/ /tmp/out/; echo "rc=$?"
    rsync -e "$RSH" alice@$SRV:upload/links/a2link/a2.txt /tmp/out/; echo "rc=$?"
    rsync -a -e "$RSH" alice@$SRV:upload/links/etclink/./ /tmp/out/; echo "rc=$?"
    find /tmp/out -type f; cat /tmp/out/* 2>/dev/null')"
  lacks "read through the uploaded link to /etc" "$out" "root:x:0:0"
  lacks "read through the uploaded link to /etc" "$out" "/tmp/out/passwd"
  lacks "read through the uploaded link to alice2" "$out" "secret-of-alice2"
  lacks "reads through the links" "$out" "rc=0"
}

# ---- run -----------------------------------------------------------------------------

run_test "image defines a healthcheck (TCP connect to 22, interval 1m)" t_healthcheck_defined
run_test "server starts and becomes healthy, host keys generated, users created" t_starts_healthy
run_test "home, .ssh and authorized_keys are root-owned, each key has restrict" t_ssh_root_owned
run_test "a user can't log in with the other user's key" t_wrong_key

run_test "allowed: upload with a relative path, content matches" t_upload
run_test "allowed: download" t_download
run_test "allowed: listing" t_list
run_test "allowed: --delete inside upload/" t_delete

run_test "refused: shell command (also after rsync, and command substitution)" t_shell_command
run_test "refused: pty (ssh -tt)" t_pty
run_test "refused: .. in paths (../alice2/, upload/../../alice2/)" t_dotdot_path
run_test "refused: .. in --log-file and --temp-dir" t_dotdot_options
run_test "refused: -s (arguments sent outside the command line)" t_secluded_args
run_test "refused: writing into the home folder root" t_home_root_readonly
run_test "refused: overwriting .ssh/authorized_keys (also --inplace), file unchanged" t_inplace_authorized_keys
run_test "refused: port forwarding (-R and -L)" t_port_forwarding
run_test "refused: a second session of the same user while one runs (other users unaffected)" t_one_session_per_user

run_test "confined: absolute paths are rooted at the home folder, /etc/passwd not reached" t_confined_absolute
run_test "confined: alice reading /home/alice2/upload gets nothing of alice2's" t_confined_other_user
run_test "confined: a second source /etc/hostname does not leak" t_confined_second_source
run_test "confined: --files-from can't reach /etc" t_confined_files_from
run_test "confined: --log-file=/tmp/x is rooted, no /tmp/x in the server" t_confined_log_file
run_test "confined: --temp-dir=/ is rooted, nothing written to the server's /" t_confined_temp_dir
run_test "confined: an uploaded symlink to /etc is munged, reads through it get nothing" t_confined_symlink

TOTAL=$((PASSED + FAILED))
if [ "$TOTAL" -eq 0 ]; then
  echo "NO TESTS MATCH TEST_FILTER [$TEST_FILTER]"
  exit 1
fi
if [ "$FAILED" -eq 0 ]; then
  echo "ALL $TOTAL TESTS PASSED"
  exit 0
fi
echo "$FAILED OF $TOTAL TESTS FAILED"
exit 1
