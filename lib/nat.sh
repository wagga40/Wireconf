#!/usr/bin/env bash
# shellcheck shell=bash
# Hub PostUp/PostDown for IPv4 forwarding and MASQUERADE when any peer uses full tunnel.

nat_post_up_line() {
  local iface="$1"
  if [[ -n "${WC_HUB_EGRESS:-}" ]]; then
    printf '%s' "sysctl -q -w net.ipv4.ip_forward=1; iptables -t nat -C POSTROUTING -o ${WC_HUB_EGRESS} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${WC_HUB_EGRESS} -j MASQUERADE; iptables -C FORWARD -i ${iface} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${iface} -j ACCEPT; iptables -C FORWARD -o ${iface} -j ACCEPT 2>/dev/null || iptables -A FORWARD -o ${iface} -j ACCEPT"
  else
    printf '%s' "sysctl -q -w net.ipv4.ip_forward=1; _wg_eg=\$(ip -4 route show default 0.0.0.0/0 | awk '/default/ {print \$5; exit}'); test -n \"\$_wg_eg\" && { iptables -t nat -C POSTROUTING -o \"\$_wg_eg\" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o \"\$_wg_eg\" -j MASQUERADE; }; iptables -C FORWARD -i ${iface} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${iface} -j ACCEPT; iptables -C FORWARD -o ${iface} -j ACCEPT 2>/dev/null || iptables -A FORWARD -o ${iface} -j ACCEPT"
  fi
}

nat_post_down_line() {
  local iface="$1"
  if [[ -n "${WC_HUB_EGRESS:-}" ]]; then
    printf '%s' "iptables -t nat -D POSTROUTING -o ${WC_HUB_EGRESS} -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i ${iface} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o ${iface} -j ACCEPT 2>/dev/null || true"
  else
    printf '%s' "_wg_eg=\$(ip -4 route show default 0.0.0.0/0 | awk '/default/ {print \$5; exit}'); test -n \"\$_wg_eg\" && iptables -t nat -D POSTROUTING -o \"\$_wg_eg\" -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i ${iface} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o ${iface} -j ACCEPT 2>/dev/null || true"
  fi
}
