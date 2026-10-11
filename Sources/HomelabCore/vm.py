"""Libvirt helper sent through SSH; never installed. Calls virsh with argument lists only, never a shell."""
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

STATES = {0: "nostate", 1: "running", 2: "blocked", 3: "paused", 4: "shutdown",
          5: "shutoff", 6: "crashed", 7: "pmsuspended"}
HOSTNAME = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,252})$")
# TPKT + X.224 Connection Request + RDP negotiation (TLS | CredSSP), as sent by any RDP client.
RDP_REQUEST = bytes.fromhex("030000130ee000000000000100080003000000")


class Unavailable(Exception):
    pass


def virsh(uri, *args, timeout=20):
    try:
        result = subprocess.run(["virsh", "-c", uri, *args], capture_output=True, text=True,
                                timeout=timeout, env={**os.environ, "LC_ALL": "C"})
    except FileNotFoundError:
        raise Unavailable("virsh não encontrado no servidor. Instale o libvirt-clients.")
    except subprocess.TimeoutExpired:
        return 124, "", "virsh excedeu o tempo limite."
    return result.returncode, result.stdout, result.stderr.strip()


def number(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_domstats(text):
    domains, current = {}, None
    for line in text.splitlines():
        match = re.match(r"^Domain: '(.*)'$", line.strip())
        if match:
            current = domains.setdefault(match[1], {})
        elif current is not None and "=" in line:
            key, value = line.strip().split("=", 1)
            current[key] = value
    return domains


def summarize(name, stats):
    state = number(stats.get("state.state"))
    capacities = [number(v) for k, v in stats.items() if re.match(r"^block\.\d+\.capacity$", k)]
    memory = number(stats.get("balloon.maximum"))
    return dict(name=name, state=STATES.get(state, "nostate"),
                vcpus=number(stats.get("vcpu.maximum")) or number(stats.get("vcpu.current")),
                memory=memory * 1024 if memory else None,
                disk=sum(c for c in capacities if c) or None,
                address=None, sshReady=None, rdpReady=None)


def fill_static(uri, machine):
    """Inactive domains may omit some stats; dominfo/domblkinfo report the configuration."""
    if machine["vcpus"] is None or machine["memory"] is None:
        code, out, _ = virsh(uri, "dominfo", "--domain", machine["name"])
        if code == 0:
            for line in out.splitlines():
                key, _, value = line.partition(":")
                if key.strip() == "CPU(s)" and machine["vcpus"] is None:
                    machine["vcpus"] = number(value.strip())
                if key.strip() == "Max memory" and machine["memory"] is None:
                    kib = number(value.split()[0]) if value.split() else None
                    machine["memory"] = kib * 1024 if kib else None
    if machine["disk"] is None:
        code, out, _ = virsh(uri, "domblkinfo", "--domain", machine["name"], "--all")
        if code == 0:
            sizes = [number(line.split()[1]) for line in out.splitlines()[2:] if len(line.split()) >= 2]
            machine["disk"] = sum(s for s in sizes if s) or None


def parse_addresses(text):
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[2] == "ipv4":
            try:
                return str(ipaddress.IPv4Address(parts[3].split("/")[0]))
            except ValueError:
                continue
    return None


def discover_address(uri, name):
    for source in ("lease", "arp"):
        code, out, _ = virsh(uri, "domifaddr", "--domain", name, "--source", source)
        address = parse_addresses(out) if code == 0 else None
        if address:
            return address
    return None


def valid_host(value):
    if not isinstance(value, str) or not value:
        return False
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return bool(HOSTNAME.match(value))


def valid_port(value):
    return isinstance(value, int) and 1 <= value <= 65535


def is_rdp_response(data):
    # TPKT version 3 carrying an X.224 Connection Confirm (0xD0).
    return len(data) >= 6 and data[0] == 3 and data[5] & 0xF0 == 0xD0


def probe(host, port, kind, timeout=1.5):
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            if kind == "rdp":
                sock.sendall(RDP_REQUEST)
                return is_rdp_response(sock.recv(64))
            return sock.recv(64).startswith(b"SSH-")
    except OSError:
        return False


def inventory(uri, probes, only=None):
    code, out, err = virsh(uri, "domstats", "--raw", "--state", "--vcpu", "--balloon", "--block")
    if code != 0:
        return dict(available=False, error=err or "O libvirt não respondeu.", machines=[])
    machines = [summarize(name, stats) for name, stats in parse_domstats(out).items()
                if only is None or name == only]
    for machine in machines:
        fill_static(uri, machine)
        if machine["state"] not in ("running", "blocked"):
            continue
        spec = probes.get(machine["name"], {}) if isinstance(probes, dict) else {}
        override = spec.get("address") if isinstance(spec, dict) else None
        machine["address"] = override if valid_host(override) else discover_address(uri, machine["name"])
    with ThreadPoolExecutor(max_workers=8) as pool:
        jobs = []
        for machine in machines:
            if not machine["address"]:
                continue
            spec = probes.get(machine["name"], {}) if isinstance(probes, dict) else {}
            ssh_port = spec.get("ssh", 22) if valid_port(spec.get("ssh", 22)) else 22
            rdp_port = spec.get("rdp", 3389) if valid_port(spec.get("rdp", 3389)) else 3389
            jobs.append((machine, pool.submit(probe, machine["address"], ssh_port, "ssh"),
                         pool.submit(probe, machine["address"], rdp_port, "rdp")))
        for machine, ssh_job, rdp_job in jobs:
            machine["sshReady"] = ssh_job.result()
            machine["rdpReady"] = rdp_job.result()
    return dict(available=True, error=None, machines=machines)


def action(uri, verb, name):
    args = {"start": ["start", "--domain", name],
            "shutdown": ["shutdown", "--domain", name, "--mode", "acpi"],
            "destroy": ["destroy", "--domain", name]}[verb]
    code, _, err = virsh(uri, *args, timeout=60)
    # Idempotent: starting a running domain or stopping a stopped one is not a failure.
    if code != 0 and re.search(r"already active|domain is not running", err, re.IGNORECASE):
        code = 0
    return dict(ok=code == 0, error=None if code == 0 else (err[:400] or "virsh falhou."))


def main(argv):
    uri, verb = argv[0], argv[1]
    try:
        if verb == "inventory":
            return inventory(uri, json.loads(argv[2]))
        if verb == "status":
            return inventory(uri, json.loads(argv[3]), only=argv[2])
        if verb in ("start", "shutdown", "destroy"):
            return action(uri, verb, argv[2])
    except Unavailable as error:
        return dict(available=False, ok=False, error=str(error), machines=[])
    raise ValueError("unknown command")


if __name__ == "__main__":
    result = main(sys.argv[1:])
    print("__HL_JSON_BEGIN__")
    print(json.dumps(result, allow_nan=False))
    print("__HL_JSON_END__")
