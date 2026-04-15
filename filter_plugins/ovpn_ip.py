# SPDX-License-Identifier: MIT
"""IPv4 helpers for ovpn-gate role (controller-side Jinja)."""

from __future__ import annotations

import ipaddress


class FilterModule:
    def filters(self):
        return {"ovpn_ipv4_offset": self.ovpn_ipv4_offset}

    def ovpn_ipv4_offset(self, base: str, offset: int) -> str:
        """Return (base IPv4 address + offset) as dotted quad. base may be network .0 or any host."""
        addr = int(ipaddress.IPv4Address(base))
        return str(ipaddress.IPv4Address(addr + int(offset)))
