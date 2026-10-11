import importlib.util
import pathlib
import unittest
from unittest.mock import patch

path = pathlib.Path(__file__).resolve().parents[1] / "Sources/HomelabCore/vm.py"
spec = importlib.util.spec_from_file_location("vm", path)
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)

URI = "qemu:///system"
DOMSTATS = """Domain: 'kali'
  state.state=1
  state.reason=1
  balloon.maximum=4194304
  vcpu.current=4
  vcpu.maximum=4
  vcpu.0.state=1
  block.count=1
  block.0.name=vda
  block.0.capacity=128849018880

Domain: 'debian'
  state.state=5
  state.reason=1
"""
LEASES = """ Name       MAC address          Protocol     Address
-------------------------------------------------------------------------------
 vnet3      52:54:00:ac:26:2b    ipv4         192.168.122.81/24
"""
DOMINFO = """Id:             -
Name:           debian
State:          shut off
CPU(s):         2
Max memory:     2097152 KiB
"""
BLKINFO = """ Target   Capacity      Allocation   Physical
-----------------------------------------------------
 vda      21474836480   1000         1000
"""


class FakeVirsh:
    """Answers virsh calls by subcommand and records every argument list."""

    def __init__(self, answers):
        self.answers, self.calls = answers, []

    def __call__(self, uri, *args, timeout=20):
        self.calls.append(list(args))
        answer = self.answers.get(args[0], (0, "", ""))
        return answer(args) if callable(answer) else answer


class VMTests(unittest.TestCase):
    def test_domstats_parsing_and_state_names(self):
        stats = vm.parse_domstats(DOMSTATS)
        self.assertEqual(set(stats), {"kali", "debian"})
        kali = vm.summarize("kali", stats["kali"])
        self.assertEqual(kali["state"], "running")
        self.assertEqual(kali["vcpus"], 4)
        self.assertEqual(kali["memory"], 4 * 1024 ** 3)
        self.assertEqual(kali["disk"], 128849018880)
        self.assertEqual(vm.summarize("x", {"state.state": "99"})["state"], "nostate")
        self.assertEqual(vm.summarize("x", {"state.state": "4"})["state"], "shutdown")

    def test_inactive_domain_falls_back_to_configuration(self):
        fake = FakeVirsh({"dominfo": (0, DOMINFO, ""), "domblkinfo": (0, BLKINFO, "")})
        machine = vm.summarize("debian", vm.parse_domstats(DOMSTATS)["debian"])
        with patch.object(vm, "virsh", fake):
            vm.fill_static(URI, machine)
        self.assertEqual(machine["vcpus"], 2)
        self.assertEqual(machine["memory"], 2 * 1024 ** 3)
        self.assertEqual(machine["disk"], 21474836480)
        self.assertEqual(fake.calls[0], ["dominfo", "--domain", "debian"])

    def test_address_parsing_ignores_invalid_rows(self):
        self.assertEqual(vm.parse_addresses(LEASES), "192.168.122.81")
        self.assertIsNone(vm.parse_addresses(" vnet0 52:54 ipv6 fe80::1/64\n vnet0 52:54 ipv4 999.1.1.1/24"))
        self.assertIsNone(vm.parse_addresses(""))

    def test_address_discovery_falls_back_to_arp(self):
        fake = FakeVirsh({"domifaddr": lambda args: (0, LEASES if args[-1] == "arp" else "", "")})
        with patch.object(vm, "virsh", fake):
            self.assertEqual(vm.discover_address(URI, "kali"), "192.168.122.81")
        self.assertEqual([c[-1] for c in fake.calls], ["lease", "arp"])

    def test_inventory_probes_only_running_guests(self):
        fake = FakeVirsh({"domstats": (0, DOMSTATS, ""), "domifaddr": (0, LEASES, ""),
                          "dominfo": (0, DOMINFO, ""), "domblkinfo": (0, BLKINFO, "")})
        probed = []

        def probe(host, port, kind, timeout=1.5):
            probed.append((host, port, kind))
            return kind == "ssh"

        with patch.object(vm, "virsh", fake), patch.object(vm, "probe", probe):
            result = vm.inventory(URI, {"kali": {"address": "", "ssh": 2222, "rdp": 3389}})
        self.assertTrue(result["available"])
        kali, debian = sorted(result["machines"], key=lambda m: m["name"] != "kali")
        self.assertEqual(kali["address"], "192.168.122.81")
        self.assertTrue(kali["sshReady"])
        self.assertFalse(kali["rdpReady"])
        self.assertIsNone(debian["address"])
        self.assertIsNone(debian["rdpReady"])
        self.assertEqual(sorted(probed), [("192.168.122.81", 2222, "ssh"), ("192.168.122.81", 3389, "rdp")])

    def test_status_filters_and_honors_valid_override_only(self):
        fake = FakeVirsh({"domstats": (0, DOMSTATS, ""), "domifaddr": (0, LEASES, "")})
        with patch.object(vm, "virsh", fake), patch.object(vm, "probe", return_value=False):
            result = vm.inventory(URI, {"kali": {"address": "10.0.0.9"}}, only="kali")
            self.assertEqual([m["name"] for m in result["machines"]], ["kali"])
            self.assertEqual(result["machines"][0]["address"], "10.0.0.9")
            result = vm.inventory(URI, {"kali": {"address": "-oProxyCommand=x"}}, only="kali")
            self.assertEqual(result["machines"][0]["address"], "192.168.122.81")

    def test_libvirt_unavailable_is_reported_not_raised(self):
        with patch.object(vm, "virsh", FakeVirsh({"domstats": (1, "", "error: failed to connect to the hypervisor")})):
            result = vm.inventory(URI, {})
        self.assertFalse(result["available"])
        self.assertIn("hypervisor", result["error"])
        with patch.object(vm.subprocess, "run", side_effect=FileNotFoundError):
            result = vm.main([URI, "inventory", "{}"])
        self.assertFalse(result["available"])
        self.assertIn("virsh", result["error"])

    def test_actions_use_domain_flag_and_are_idempotent(self):
        fake = FakeVirsh({"start": (1, "", "error: Requested operation is not valid: domain is already active")})
        with patch.object(vm, "virsh", fake):
            self.assertTrue(vm.action(URI, "start", "kali")["ok"])
            vm.action(URI, "shutdown", "-kali")
        self.assertEqual(fake.calls[0], ["start", "--domain", "kali"])
        self.assertEqual(fake.calls[1], ["shutdown", "--domain", "-kali", "--mode", "acpi"])
        with patch.object(vm, "virsh", FakeVirsh({"destroy": (1, "", "error: access denied")})):
            result = vm.action(URI, "destroy", "kali")
        self.assertFalse(result["ok"])
        self.assertIn("access denied", result["error"])
        with self.assertRaises(KeyError):
            vm.action(URI, "undefine", "kali")

    def test_virsh_never_uses_a_shell(self):
        with patch.object(vm.subprocess, "run") as run:
            run.return_value.returncode, run.return_value.stdout, run.return_value.stderr = 0, "", ""
            vm.virsh(URI, "start", "--domain", "a; rm -rf /")
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["virsh", "-c", URI, "start", "--domain", "a; rm -rf /"])
        self.assertNotIn("shell", kwargs)

    def test_rdp_and_ssh_probes(self):
        class Sock:
            def __init__(self, reply): self.reply, self.sent = reply, b""
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def settimeout(self, t): pass
            def sendall(self, data): self.sent += data
            def recv(self, n): return self.reply

        rdp = Sock(bytes.fromhex("0300001302d00000123400"))
        rdp.reply = bytes.fromhex("030000130ed00000123400")
        with patch.object(vm.socket, "create_connection", return_value=rdp):
            self.assertTrue(vm.probe("h", 3389, "rdp"))
        self.assertEqual(rdp.sent, vm.RDP_REQUEST)
        with patch.object(vm.socket, "create_connection", return_value=Sock(b"SSH-2.0-OpenSSH_10")):
            self.assertTrue(vm.probe("h", 22, "ssh"))
            self.assertFalse(vm.probe("h", 3389, "rdp"))
        with patch.object(vm.socket, "create_connection", side_effect=OSError):
            self.assertFalse(vm.probe("h", 22, "ssh"))

    def test_host_and_port_validation(self):
        for good in ["192.168.122.81", "kali.lan", "fd00::1"]:
            self.assertTrue(vm.valid_host(good))
        for bad in ["", None, "-oProxyCommand=x", "a b", 5]:
            self.assertFalse(vm.valid_host(bad))
        self.assertTrue(vm.valid_port(3389))
        self.assertFalse(vm.valid_port(0))
        self.assertFalse(vm.valid_port("22"))


if __name__ == "__main__":
    unittest.main()
