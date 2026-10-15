#!/bin/sh
# akinn's functions, driven one by one - no root, no network, nothing
# installed. The files are sourced as akinn.sh sources them; every command
# that would touch the system (kubeadm, apt-cache, ss, ip, ...) is a stub, and
# every system path points into a temporary folder.
#
# What it pins - the Ubuntu gaps fixed on 2026-10-15 (Kamino item 9):
#   - each run backs up into its own folder, and a rollback restores only what
#     that run touched (A1);
#   - the join token and hash are owner-only and validated before writing (A2);
#   - the port check is exact, the architecture validated, the default IP the
#     default route's;
#   - Docker's repository is a signed-by list, an older entry is retired;
#   - containerd's systemd cgroup switch is checked, against the real default
#     configs of containerd 1.7 and 2.4;
#   - kubectx is optional.
#
# A real install is not tested here: that needs a machine (see README).
# Run: sh tests/test-functions.sh   (dash on Ubuntu, as akinn itself runs)

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILS=0

check() {
    desc="$1"; shift
    if "$@"; then echo "   ok   - $desc"; else echo "   FAIL - $desc"; FAILS=$((FAILS + 1)); fi
}
has() { grep -qF -- "$1" "$2"; }

# ---- stubs ---------------------------------------------------------------------
mkdir -p "$T/bin"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
stub ip       'echo "1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.5 uid 0"'
stub hostname 'echo "172.17.0.1 10.0.0.5"'
stub ss       'echo "$*" >> "$STUB_LOG"; [ -n "$SS_BUSY" ] && printf "Netid State\ntcp LISTEN\n" || printf "Netid State\n"'
stub nc       'echo "succeeded"'
stub ping     'exit 0'
stub kubeadm  'echo "kubeadm $*" >> "$STUB_LOG"; case "$1" in token) printf "%s\n" "${KUBEADM_TOKEN:-abcdef.0123456789abcdef}" ;; join) exit "${KUBEADM_JOIN_RC:-0}" ;; esac'
stub apt-cache 'exit "${APT_CACHE_RC:-0}"'
stub apt-get  'echo "apt-get $*" >> "$STUB_LOG"'
stub dpkg-query 'exit 1'
export PATH="$T/bin:$PATH" STUB_LOG="$T/log"
: > "$STUB_LOG"

# ---- the files, as akinn.sh sources them ---------------------------------------------
SCRIPT_DIR="$ROOT"
for f in regex colors parameters constants variables errors functions protocols; do
    # shellcheck disable=SC1090
    . "$ROOT/$f.sh"
done
# Every system path into the sandbox.
mkdir -p "$T/etc/apt/sources.list.d" "$T/etc/apt/keyrings" "$T/home"
FSTABF="$T/etc/fstab"; CCF="$T/etc/config.toml"; MODULES_CONF="$T/etc/modules.conf"
DOCKER_GPG="$T/etc/apt/keyrings/docker.gpg"; DOCKER_LIST="$T/etc/apt/sources.list.d/docker.list"
APT_SOURCES="$T/etc/apt/sources.list $T/etc/apt/sources.list.d"; OS_RELEASE="$T/etc/os-release"
MNJCRDFS="$T/home/master_node"; K_CA="$T/ca.crt"
TMPDIR="$T"; export TMPDIR
SUDO_USER=""

# execution_error exits; run anything that may call it in a subshell.
fails() { ( "$@" ) > "$T/out" 2>&1; [ $? -ne 0 ]; }
succeeds() { ( "$@" ) > "$T/out" 2>&1; }

echo "## architecture"
arch_is() { ARCH=""; validate_architecture "$1" > /dev/null; [ "$ARCH" = "$2" ]; }
check "amd64 is accepted" arch_is amd64 amd64
check "arm64 is accepted" arch_is arm64 arm64
check "x86_64 becomes amd64" arch_is x86_64 amd64
check "aarch64 becomes arm64" arch_is aarch64 arm64
check "i386 is refused" fails validate_architecture i386
check "  with the reason" has "Unsupported architecture" "$T/out"

echo "## default IP"
check "the default route's source address, not hostname -I's first" [ "$IP" = 10.0.0.5 ]
stub ip 'exit 1'
ip_fallback() { ( . "$ROOT/parameters.sh"; [ "$IP" = 172.17.0.1 ] ); }
check "hostname -I only without a default route" ip_fallback

echo "## port check"
: > "$STUB_LOG"
succeeds poke_it 6443
check "asks ss for that exact port" has "sport = :6443" "$STUB_LOG"
check "  and reports it free" has "Local port 6443 is free" "$T/out"
SS_BUSY=1; export SS_BUSY
succeeds poke_it 6443
check "a listener on it reports busy" has "Local port 6443 is in use" "$T/out"
unset SS_BUSY

echo "## backups: one folder per run, and only its own changes undone (A1)"
printf 'original fstab\n' > "$FSTABF"
rm -f "$CCF"
run_and_fail() {
    start_run > /dev/null
    INSTALL_STARTED=1
    backup_file "$FSTABF" > /dev/null
    backup_file "$CCF" > /dev/null
    printf 'changed\n' > "$FSTABF"
    printf 'created\n' > "$CCF"
    echo "$RUN_DIR" > "$T/run_dir"
    execution_error "simulated failure"
}
fails run_and_fail
check "a failed run restores the file it changed" has "original fstab" "$FSTABF"
check "  removes the file it created" [ ! -e "$CCF" ]
check "  and leaves no folder behind" [ ! -d "$(cat "$T/run_dir")" ]
check "nothing is written to the old fixed /tmp paths" [ ! -e /tmp/backup.fstab ] || [ "$(cat /tmp/backup.fstab 2>/dev/null)" != "changed" ]

second_run() {
    # A first run that succeeded: its folder is gone. A second one that fails
    # before backing anything up must not "restore" anything.
    start_run > /dev/null; INSTALL_STARTED=1
    backup_file "$FSTABF" > /dev/null
    printf 'first run result\n' > "$FSTABF"
    finish_run
    start_run > /dev/null
    execution_error "fails before any backup"
}
fails second_run
check "a later run that fails early leaves the earlier run's result alone" has "first run result" "$FSTABF"

twice() {
    printf 'v0\n' > "$FSTABF"
    start_run > /dev/null; INSTALL_STARTED=1
    backup_file "$FSTABF" > /dev/null; printf 'v1\n' > "$FSTABF"
    backup_file "$FSTABF" > /dev/null; printf 'v2\n' > "$FSTABF"
    execution_error "x"
}
fails twice
check "a file backed up twice goes back to its state before the run" has "v0" "$FSTABF"

echo "## the join files (A2)"
SUDO_USER=""
token_ok() {
    start_run > /dev/null; mkdir -p "$MNJCRDFS"
    generate_join_token "$MNJCRDFS"
}
succeeds token_ok
check "a valid token is written" has "abcdef.0123456789abcdef" "$MNJCRDFS/token"
check "  readable by its owner only" [ "$(ls -l "$MNJCRDFS/token" | cut -c1-10)" = "-rw-------" ]
check "  and says when it expires" has "valid for 24 hours" "$T/out"
KUBEADM_TOKEN="not a token"; export KUBEADM_TOKEN
rm -f "$MNJCRDFS/token"
check "a malformed token is refused" fails token_ok
check "  and not written" [ ! -e "$MNJCRDFS/token" ]
unset KUBEADM_TOKEN

if command -v openssl > /dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/ca.key" -out "$K_CA" -days 1 -subj "/CN=kubernetes" > /dev/null 2>&1
    expected=$(openssl x509 -pubkey -in "$K_CA" | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
    hash_ok() { start_run > /dev/null; mkdir -p "$MNJCRDFS"; generate_join_hash "$MNJCRDFS" > /dev/null; }
    succeeds hash_ok
    check "the hash matches kubeadm's documented RSA pipeline" [ "$(cat "$MNJCRDFS/hash")" = "$expected" ]
    check "  is 64 hex digits" grep -Eqx '[0-9a-f]{64}' "$MNJCRDFS/hash"
    check "  and is owner-only" [ "$(ls -l "$MNJCRDFS/hash" | cut -c1-10)" = "-rw-------" ]
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$T/ec.key" -out "$K_CA" -days 1 -subj "/CN=kubernetes" > /dev/null 2>&1
    rm -f "$MNJCRDFS/hash"
    check "an ECDSA CA works too (openssl pkey, not rsa)" succeeds hash_ok
    rm -f "$K_CA" "$MNJCRDFS/hash"
    check "a missing CA fails" fails hash_ok
    check "  without writing a hash" [ ! -e "$MNJCRDFS/hash" ]
else
    echo "   skip - openssl not found: the hash checks need it"
fi

KUBEADM_JOIN_RC=1; export KUBEADM_JOIN_RC
TOKEN=abcdef.0123456789abcdef; HASH=00; PORT=6443; IP=10.0.0.9
check "a failed join fails" fails join_master
check "  and names the likeliest cause, an expired token" has "lasts 24 hours" "$T/out"
unset KUBEADM_JOIN_RC

echo "## Docker's repository"
printf 'NAME="Ubuntu"\nVERSION_CODENAME=noble\n' > "$OS_RELEASE"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\ndeb [arch=arm64] https://download.docker.com/linux/ubuntu noble stable\n' > "$T/etc/apt/sources.list"
docker_repo() { start_run > /dev/null; ARCH=arm64; add_docker_repository > /dev/null; }
succeeds docker_repo
check "a signed-by list of its own" has "deb [arch=arm64 signed-by=$DOCKER_GPG] https://download.docker.com/linux/ubuntu noble stable" "$DOCKER_LIST"
check "an older add-apt-repository entry is commented out" has "# moved to docker.list by akinn: deb [arch=arm64] https://download.docker.com" "$T/etc/apt/sources.list"
check "  and the rest of that file is untouched" has "deb http://archive.ubuntu.com/ubuntu noble main" "$T/etc/apt/sources.list"
docker_repo_fails() { docker_repo; INSTALL_STARTED=1; execution_error "x"; }
printf 'deb http://archive.ubuntu.com/ubuntu noble main\ndeb [arch=arm64] https://download.docker.com/linux/ubuntu noble stable\n' > "$T/etc/apt/sources.list"
rm -f "$DOCKER_LIST"
fails docker_repo_fails
check "a rollback brings the older entry back" grep -qx "deb \[arch=arm64\] https://download.docker.com/linux/ubuntu noble stable" "$T/etc/apt/sources.list"
check "  and removes the list it created" [ ! -e "$DOCKER_LIST" ]

echo "## containerd's systemd cgroup"
for v in 1.7 2.4; do
    cp "$TEST_DIR/fixtures/containerd-$v.toml" "$CCF"
    check "containerd $v: switched on" succeeds enable_systemd_cgroup "$CCF"
    check "  in its runc options" has "SystemdCgroup = true" "$CCF"
done
printf '[plugins]\n' > "$CCF"
check "a config without the setting fails loudly" fails enable_systemd_cgroup "$CCF"
check "  and says so" has "no 'SystemdCgroup = false' to enable" "$T/out"

echo "## kubectx"
APT_CACHE_RC=0; export APT_CACHE_RC
check "packaged (24.04): installed and held" [ "$(install_kubectx_if_packaged 2>/dev/null)" = kubectx ]
APT_CACHE_RC=100
check "not packaged (20.04, 22.04): skipped, nothing to hold" [ -z "$(install_kubectx_if_packaged 2>"$T/out")" ]
check "  with a word about it" has "not packaged for this Ubuntu release" "$T/out"

echo
if [ "$FAILS" -ne 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "all checks passed"
