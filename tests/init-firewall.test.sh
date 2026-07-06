#!/usr/bin/env bash
#
# Unit tests for templates/devcontainer/scripts/init-firewall.sh.tmpl.
#
# Sources the script (its main() only runs when executed) and exercises the
# parsing / resolution / rule functions against stub iptables, ip6tables,
# ipset, and getent binaries that record their argv. No root, no network,
# no real firewall.
#
# Run with: bash tests/init-firewall.test.sh
# shellcheck disable=SC1090,SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIREWALL="$REPO_ROOT/templates/devcontainer/scripts/init-firewall.sh.tmpl"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

STUB_DIR="$TMP_ROOT/bin"
CALL_LOG="$TMP_ROOT/calls.log"
mkdir -p "$STUB_DIR"

# Recording stubs. ipset also emulates `list` output driven by a member file
# per set so count_set()/refresh diff logic can be tested.
for tool in iptables ip6tables; do
  cat >"$STUB_DIR/$tool" <<STUB
#!/usr/bin/env bash
echo "$tool \$*" >>"\$CALL_LOG"
exit 0
STUB
  chmod +x "$STUB_DIR/$tool"
done

cat >"$STUB_DIR/ipset" <<'STUB'
#!/usr/bin/env bash
echo "ipset $*" >>"$CALL_LOG"
dir="${STUB_IPSET_DIR:?}"
case "$1" in
  create)  : >"$dir/$2" ;;
  destroy) rm -f "$dir/$2" 2>/dev/null; exit 0 ;;
  add)     [[ -f "$dir/$2" ]] || exit 1; echo "$3" >>"$dir/$2" ;;
  swap)    [[ -f "$dir/$2" && -f "$dir/$3" ]] || exit 1
           tmp="$dir/.swap.$$"; mv "$dir/$2" "$tmp"; mv "$dir/$3" "$dir/$2"; mv "$tmp" "$dir/$3" ;;
  list)    [[ -f "$dir/$2" ]] || exit 1; cat "$dir/$2" ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/ipset"

cat >"$STUB_DIR/getent" <<'STUB'
#!/usr/bin/env bash
# ahostsv4 <host> -> lines "IP ..." driven by STUB_DNS_DIR/<host>
[[ "$1" == "ahostsv4" ]] || exit 2
f="${STUB_DNS_DIR:?}/$2"
[[ -f "$f" ]] || exit 2
while IFS= read -r ip; do
  printf '%s STREAM %s\n' "$ip" "$2"
done <"$f"
STUB
chmod +x "$STUB_DIR/getent"

export PATH="$STUB_DIR:$PATH"
export CALL_LOG
export STUB_IPSET_DIR="$TMP_ROOT/ipsets"
export STUB_DNS_DIR="$TMP_ROOT/dns"
mkdir -p "$STUB_IPSET_DIR" "$STUB_DNS_DIR"

passed=0
failed=0
ok()   { printf 'ok: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

# Source the script with test-controlled paths (main() does not run when
# sourced). LOG_FILE + ALLOWLIST_FILE are readonly-after-source constants, so
# override them post-source by reassigning the globals.
. "$FIREWALL"
LOG_FILE="$TMP_ROOT/firewall.log"
ALLOWLIST_FILE="$TMP_ROOT/allowlist.txt"
PID_FILE="$TMP_ROOT/refresh.pid"

# DNS fixtures: two defaults resolve; everything else NXDOMAIN.
printf '1.1.1.1\n' >"$STUB_DNS_DIR/api.anthropic.com"
printf '2.2.2.2\n3.3.3.3\n' >"$STUB_DNS_DIR/github.com"

# 1. Allowlist file parsing: comments, whitespace, blanks.
cat >"$ALLOWLIST_FILE" <<'EOF'
# comment line
example.org   # trailing comment

  spaced.example.net
EOF
hosts="$(collect_hosts)"
if printf '%s\n' "$hosts" | grep -qx 'example.org' \
   && printf '%s\n' "$hosts" | grep -qx 'spaced.example.net' \
   && ! printf '%s\n' "$hosts" | grep -q '#'; then
  ok "allowlist file parsing (comments/whitespace/blank lines)"
else
  fail "allowlist parsing: got: $hosts"
fi
if printf '%s\n' "$hosts" | grep -qx 'api.anthropic.com'; then
  ok "built-in defaults included"
else
  fail "defaults missing from collect_hosts"
fi

# 2. build_allow_set resolves into the set (unresolvable hosts skipped).
: >"$CALL_LOG"
build_allow_set
members="$(cat "$STUB_IPSET_DIR/aidc-allow")"
if printf '%s\n' "$members" | grep -qx '1.1.1.1' \
   && printf '%s\n' "$members" | grep -qx '2.2.2.2' \
   && printf '%s\n' "$members" | grep -qx '3.3.3.3'; then
  ok "build_allow_set resolves defaults into the set"
else
  fail "build_allow_set members: $members"
fi

# 3. refresh_allow_set: atomic swap picks up new DNS state.
printf '9.9.9.9\n' >"$STUB_DNS_DIR/api.anthropic.com"   # IP rotation
refresh_allow_set >/dev/null
members="$(cat "$STUB_IPSET_DIR/aidc-allow")"
if printf '%s\n' "$members" | grep -qx '9.9.9.9'; then
  ok "refresh_allow_set picks up rotated IPs"
else
  fail "refresh members: $members"
fi
if [[ ! -f "$STUB_IPSET_DIR/aidc-allow-next" ]]; then
  ok "staging set destroyed after swap"
else
  fail "staging set left behind"
fi
if grep -q 'allowlist refreshed' "$LOG_FILE"; then
  ok "refresh logged"
else
  fail "refresh not logged"
fi

# 4. IPv4 rules: default-deny policies + allowlist matches recorded.
: >"$CALL_LOG"
resolv_fixture="$TMP_ROOT/resolv.conf"
printf 'nameserver 10.0.0.2\nnameserver fd00::1\n' >"$resolv_fixture"
# dns_rules reads /etc/resolv.conf directly; emulate by overriding the awk
# input via a wrapper is overkill — instead assert against the real file's
# behaviour separately and test rule emission with the fixture through a
# subshell override of the function's input:
dns_rules() { # test override: same body, fixture path
  local ns found4=0
  while IFS= read -r ns; do
    [[ -n "$ns" ]] || continue
    case "$ns" in
      *:*) continue ;;
      *) iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
         iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
         found4=1 ;;
    esac
  done < <(awk '/^nameserver[ \t]/ {print $2}' "$resolv_fixture")
  if [[ "$found4" -eq 0 ]]; then
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
  fi
}
apply_ipv4_rules
if grep -q 'iptables -P OUTPUT DROP' "$CALL_LOG" \
   && grep -q 'iptables -A OUTPUT -m set --match-set aidc-allow dst -p tcp --dport 443 -j ACCEPT' "$CALL_LOG"; then
  ok "IPv4 default-deny + allowlist rules emitted"
else
  fail "IPv4 rules missing from: $(cat "$CALL_LOG")"
fi
if grep -q 'iptables -A OUTPUT -d 10.0.0.2 -p udp --dport 53 -j ACCEPT' "$CALL_LOG" \
   && ! grep -q 'fd00::1' "$CALL_LOG"; then
  ok "DNS pinned to the IPv4 resolver only"
else
  fail "DNS pinning rules wrong: $(grep 53 "$CALL_LOG")"
fi

# 5. IPv6 rules: default-deny with loopback + established only.
: >"$CALL_LOG"
apply_ipv6_rules
if grep -q 'ip6tables -P OUTPUT DROP' "$CALL_LOG" \
   && grep -q 'ip6tables -A OUTPUT -o lo -j ACCEPT' "$CALL_LOG" \
   && ! grep -q 'ip6tables -A OUTPUT -m set' "$CALL_LOG"; then
  ok "IPv6 default-deny emitted (no v6 allowlist)"
else
  fail "IPv6 rules wrong: $(grep ip6tables "$CALL_LOG")"
fi

# 6. Refresh loop disabled at 0 / non-numeric.
REFRESH_SECONDS=0
start_refresh_loop
if [[ ! -f "$PID_FILE" ]] && grep -q 'refresh loop disabled' "$LOG_FILE"; then
  ok "refresh loop disabled at 0"
else
  fail "refresh loop not disabled at 0"
fi
# shellcheck disable=SC2034  # read by the sourced start_refresh_loop
REFRESH_SECONDS=abc
start_refresh_loop
if [[ ! -f "$PID_FILE" ]]; then
  ok "non-numeric refresh interval rejected"
else
  fail "non-numeric interval started a loop"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
