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

set -u

SCAN=0
IDS=()
for a in "$@"; do
  case "$a" in
    --scan) SCAN=1 ;;
    *) IDS+=("$a") ;;
  esac
done

if [ ${#IDS[@]} -eq 0 ]; then
  mapfile -t IDS < <(pct list | awk 'NR>1 && $2=="running" {print $1}')
fi

if [ ${#IDS[@]} -eq 0 ]; then
  echo "No running containers found."
  exit 0
fi

# Runs inside each container. Plain POSIX sh so it also works on Alpine/BusyBox.
INNER='
echo "--- Listening sockets (anything on 0.0.0.0 / [::] / * is reachable from the network)"
if command -v ss >/dev/null 2>&1; then
  ss -tulpnH
elif command -v netstat >/dev/null 2>&1; then
  netstat -tulpn 2>/dev/null | awk "NR>2"
else
  echo "(neither ss nor netstat installed)"
fi

echo "--- sshd effective settings"
SSHD=$(command -v sshd 2>/dev/null || { [ -x /usr/sbin/sshd ] && echo /usr/sbin/sshd; })
if [ -n "$SSHD" ]; then
  out=$("$SSHD" -T 2>&1)
  echo "$out" | grep -Ei "^(port|listenaddress|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication|permitemptypasswords|maxauthtries|x11forwarding|allowusers|allowgroups) " \
    || echo "$out" | head -3
  echo "$out" | grep -qi "^passwordauthentication yes"       && echo "  !! password login is enabled"
  echo "$out" | grep -qi "^kbdinteractiveauthentication yes" && echo "  !! keyboard-interactive (password prompt) is enabled"
  echo "$out" | grep -qi "^permitrootlogin yes"              && echo "  !! root can log in with a password"
  echo "$out" | grep -qi "^permitemptypasswords yes"         && echo "  !! empty passwords are allowed"
else
  echo "(sshd not installed)"
fi

echo "--- authorized_keys"
found=0
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [ -f "$f" ] || continue
  found=1
  n=$(grep -cvE "^[[:space:]]*(#|$)" "$f")
  echo "$f: $n key(s)"
  grep -vE "^[[:space:]]*(#|$)" "$f" | awk "{ if (NF>=3) print \"    \" \$1 \"  \" \$NF; else print \"    \" \$1 \"  (no comment)\" }"
done
[ "$found" -eq 0 ] && echo "(no authorized_keys files)"
'

for id in "${IDS[@]}"; do
  name=$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}')
  echo
  echo "================ CT $id  ${name:-?} ================"
  pct exec "$id" -- sh -c "$INNER" 2>&1

  if [ "$SCAN" -eq 1 ]; then
    ip=$(lxc-info -n "$id" -iH 2>/dev/null | grep -v ':' | head -1)
    echo "--- nmap from host (${ip:-no IPv4 found})"
    if [ -n "$ip" ] && command -v nmap >/dev/null 2>&1; then
      nmap -sT -p- --open -T4 "$ip" | awk '/^[0-9]+\/(tcp|udp)/'
    elif ! command -v nmap >/dev/null 2>&1; then
      echo "(nmap not installed: apt install nmap)"
    fi
  fi
done
