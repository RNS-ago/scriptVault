#!/usr/bin/env bash
# audit-lxc.sh - run on the Proxmox host as root.
# For every running LXC container, prints:
#   - listening TCP/UDP sockets
#   - the effective sshd settings that matter for security
#   - which SSH keys are allowed to log in
#
# Usage:
#   ./audit-lxc.sh               all running containers
#   ./audit-lxc.sh 101 105       only these container IDs
#   ./audit-lxc.sh --scan        also nmap each container from the host (needs: apt install nmap)
#   ./audit-lxc.sh --udp         --scan plus the top 100 UDP ports (slow: ~2 min per IP, Linux rate-limits ICMP)

set -u

SCAN=0
UDP=0
IDS=()
for a in "$@"; do
  case "$a" in
    --scan) SCAN=1 ;;
    --udp) SCAN=1; UDP=1 ;;
    *) IDS+=("$a") ;;
  esac
done

if [ ${#IDS[@]} -eq 0 ]; then
  mapfile -t IDS < <(pct list | awk 'NR>1 && $2=="running" {print $1}')
fi

# Colour output on a terminal only (plain when piped or NO_COLOR is set).
# Runs after cat -v, so containers still cannot inject their own escape codes.
paint() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    local e=$'\033' r=$'\033[0m'
    # each rule is anchored at ^, so a line coloured by an earlier rule is skipped by later ones
    sed -E \
      -e "s/^=+ CT .*/${e}[1;36m&$r/" \
      -e "s/^--- .*/${e}[1m&$r/" \
      -e "s/^ *!!.*/${e}[1;31m&$r/" \
      -e "s/^(tcp|udp)[0-9]* .*(127\.[0-9]|\[::1\]|::1:).*/${e}[90m&$r/" \
      -e "s/^(tcp|udp)[0-9]* .*/${e}[33m&$r/" \
      -e "s/^[0-9]+\/(tcp|udp) .*/${e}[1;33m&$r/" \
      -e "s/^\/.*: [0-9]+ key\(s\)$/${e}[35m&$r/"
  else
    cat
  fi
}

# pct only sees this node; name CTs on other cluster nodes so they are not silently skipped
me=$(uname -n); me=${me%%.*}
others=()
for c in /etc/pve/nodes/*/lxc/*.conf; do
  [ -e "$c" ] || continue
  node=${c#/etc/pve/nodes/}; node=${node%%/*}
  [ "$node" = "$me" ] || others+=("$(basename "$c" .conf)@$node")
done
[ ${#others[@]} -gt 0 ] && echo "!! NOT audited, CTs on other cluster nodes (run this script there too): ${others[*]}" | paint

if [ ${#IDS[@]} -eq 0 ]; then
  echo "No running containers found."
  exit 0
fi

# Runs inside each container. Plain POSIX sh so it also works on Alpine/BusyBox.
INNER='
echo "--- Listening sockets (only 127.x / [::1] are local-only; anything else is reachable from the network unless firewalled)"
if command -v ss >/dev/null 2>&1; then
  ss -tulpn
elif command -v netstat >/dev/null 2>&1; then
  # some BusyBox builds reject -p; fall back instead of printing nothing
  netstat -tulpn 2>/dev/null || netstat -tuln
else
  echo "(neither ss nor netstat installed)"
fi

echo "--- sshd effective settings"
SSHD=$(command -v sshd 2>/dev/null || { [ -x /usr/sbin/sshd ] && echo /usr/sbin/sshd; })
if [ -n "$SSHD" ]; then
  out=$("$SSHD" -T 2>&1); rc=$?
  # socket-activated sshd (systemd holds :22, e.g. Ubuntu 22.10+) has no privsep dir until the
  # first login, and sshd -T refuses to run without it. Create the empty dir sshd would create itself.
  dir=$(echo "$out" | sed -n "s/.*Missing privilege separation directory: \([^[:space:]]*\).*/\1/p")
  if [ "$rc" -ne 0 ] && [ -n "$dir" ] && mkdir -m 0755 "$dir"; then
    echo "  (created missing $dir so sshd -T can run)"
    out=$("$SSHD" -T 2>&1); rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "  !! sshd -T failed, settings NOT checked:"
    echo "$out" | head -3
  else
    # challengeresponseauthentication/usepam: how older OpenSSH (<8.7) controls password prompts
    echo "$out" | grep -Ei "^(port|listenaddress|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|usepam|permitrootlogin|pubkeyauthentication|permitemptypasswords|authorizedkeysfile|authorizedkeyscommand|maxauthtries|x11forwarding|allowusers|allowgroups) "
    echo "$out" | grep -qi "^passwordauthentication yes"       && echo "  !! password login is enabled"
    echo "$out" | grep -qi "^kbdinteractiveauthentication yes" && echo "  !! keyboard-interactive (password prompt) is enabled"
    echo "$out" | grep -qi "^permitrootlogin yes"              && echo "  !! root login allowed (with a password too, if password login is enabled)"
    echo "$out" | grep -qi "^permitemptypasswords yes"         && echo "  !! empty passwords are allowed"
    # sshd -T shows global settings only; Match blocks can override them
    grep -hiE "^[[:space:]]*match " /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sed "s/^/  !! Match block (not reflected above): /"
  fi
else
  echo "(sshd not installed)"
fi

# dropbear (common on Alpine) has no config dump; its running command line holds the settings
db=$(for p in /proc/[0-9]*/cmdline; do tr "\000" " " < "$p" 2>/dev/null; echo; done | grep -E "^([^ ]*/)?dropbear( |$)" | sort -u)
if [ -n "$db" ]; then
  echo "--- dropbear running"
  echo "$db"
  echo "$db" | grep -qvE " -[A-Za-z]*s" && echo "  !! password login is enabled (no -s)"
  echo "$db" | grep -qvE " -[A-Za-z]*[gsw]" && echo "  !! root can log in with a password (no -g, -s or -w)"
  echo "$db" | grep -qE " -[A-Za-z]*B" && echo "  !! empty passwords are allowed (-B)"
fi

echo "--- authorized_keys"
found=0
# every home in /etc/passwd (service accounts too), and authorized_keys2 (in OpenSSH default AuthorizedKeysFile)
# shortcut: home paths with spaces get split and skipped, switch to a while-read loop if you ever have one
for h in $(cut -d: -f6 /etc/passwd | sort -u); do
  for f in "$h/.ssh/authorized_keys" "$h/.ssh/authorized_keys2"; do
    [ -f "$f" ] || continue
    found=1
    n=$(grep -cvE "^[[:space:]]*(#|$)" "$f")
    echo "$f: $n key(s)"
    if command -v ssh-keygen >/dev/null 2>&1; then
      ssh-keygen -lf "$f" | sed "s/^/    /"
    else
      grep -vE "^[[:space:]]*(#|$)" "$f" | cut -c1-100 | sed "s/^/    /"
    fi
  done
done
[ "$found" -eq 0 ] && echo "(no authorized_keys files)"
'

# nmap_scan <nmap args...>: print open ports, or say why there are none.
# -Pn: CT is known to be running, so a dropped ping must not skip the scan.
nmap_scan() {
  local out
  if ! out=$(nmap -Pn --open -T4 "$@" 2>&1); then
    echo "  !! nmap failed: $(printf '%s\n' "$out" | tail -1)"
    return
  fi
  printf '%s\n' "$out" | awk '/^[0-9]+\/(tcp|udp)/ { if ($2 == "open") { print; o++ } else nf++ }
    END { if (nf) print "  (" nf " port(s) open|filtered: no reply, either open or firewalled)"; else if (!o) print "(no open ports)" }'
}

for id in "${IDS[@]}"; do
  name=$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}')
  echo
  echo "================ CT $id  ${name:-?} ================"
  # timeout: a hung mount in the CT must not stall the whole audit.
  # cat -v: CT output is untrusted, so show escape sequences instead of sending them to the terminal.
  # tr -d: sshd writes its errors with \r\n, which cat -v would show as ^M
  timeout 120 pct exec "$id" -- sh -c "$INNER" 2>&1 | tr -d '\r' | cat -v
  [ "${PIPESTATUS[0]}" -eq 124 ] && echo "  !! timed out after 120s, output above is incomplete"

  if [ "$SCAN" -eq 1 ]; then
    if ! command -v nmap >/dev/null 2>&1; then
      echo "--- nmap from host: (nmap not installed: apt install nmap)"
    else
      ips=$(lxc-info -n "$id" -iH 2>/dev/null | grep -v ':')
      [ -n "$ips" ] || echo "--- nmap from host: (no IPv4 found)"
      for ip in $ips; do
        echo "--- nmap TCP from host ($ip)"
        nmap_scan -sT -p- "$ip"
        if [ "$UDP" -eq 1 ]; then
          echo "--- nmap UDP top 100 from host ($ip)"
          nmap_scan -sU --top-ports 100 "$ip"
        fi
      done
    fi
  fi
done | paint
