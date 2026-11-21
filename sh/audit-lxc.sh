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
  if ! out=$("$SSHD" -T 2>&1); then
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

for id in "${IDS[@]}"; do
  name=$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}')
  echo
  echo "================ CT $id  ${name:-?} ================"
  pct exec "$id" -- sh -c "$INNER" 2>&1

  if [ "$SCAN" -eq 1 ]; then
    if ! command -v nmap >/dev/null 2>&1; then
      echo "--- nmap from host: (nmap not installed: apt install nmap)"
    else
      ips=$(lxc-info -n "$id" -iH 2>/dev/null | grep -v ':')
      [ -n "$ips" ] || echo "--- nmap from host: (no IPv4 found)"
      for ip in $ips; do
        echo "--- nmap from host ($ip, TCP only)"
        # -Pn: CT is known to be running, so a dropped ping must not skip the scan
        if scan=$(nmap -Pn -sT -p- --open -T4 "$ip" 2>&1); then
          res=$(printf '%s\n' "$scan" | awk '/^[0-9]+\/tcp/')
          echo "${res:-(no open TCP ports)}"
        else
          echo "  !! nmap failed: $(printf '%s\n' "$scan" | tail -1)"
        fi
      done
    fi
  fi
done
