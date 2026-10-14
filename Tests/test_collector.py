import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch

path = pathlib.Path(__file__).resolve().parents[1] / "Sources/HomelabCore/collector.py"
spec = importlib.util.spec_from_file_location("collector", path)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CollectorTests(unittest.TestCase):
    def test_unsupported_values_are_not_zero(self):
        for value in ["[N/A]", "N/A", "nan", "inf", -1, None]:
            self.assertIsNone(collector.number(value))
        self.assertEqual(collector.number("0"), 0)
        self.assertEqual(collector.unit_number("405MHz"), 405)

    def test_cpu_deltas(self):
        self.assertEqual(collector.cpu_percent((100, 60), (200, 80)), 80)
        self.assertIsNone(collector.cpu_percent((100, 60), (100, 60)))

    def test_csv_with_quoted_names_and_multiple_gpus(self):
        gpu = '0, "NVIDIA, GPU", GPU-1, 595, 40, 0, 1024, 12288, 19.8, 170, [N/A]\n1, GPU Two, GPU-2, 595, 41, 25, 10, 2048, 30, 170, 0'
        processes = 'GPU-1, 42, "process, name", 1024\nGPU-2, 42, ollama, [N/A]'
        with patch.object(collector, "run", side_effect=[gpu, processes]):
            gpus, procs, warnings = collector.gpu_data()
        self.assertEqual(len(gpus), 2)
        self.assertEqual(gpus[0]["name"], "NVIDIA, GPU")
        self.assertIsNone(gpus[0]["fan"])
        self.assertEqual(procs[0]["name"], "process, name")
        self.assertIsNone(procs[1]["memory"])
        self.assertEqual(warnings, [])

    def test_gpu_failure_does_not_fabricate_metrics(self):
        with patch.object(collector, "run", return_value=None):
            gpus, procs, warnings = collector.gpu_data()
        self.assertEqual(gpus, [])
        self.assertEqual(procs, [])
        self.assertTrue(warnings)

    def test_invalid_nvtop_json(self):
        for output in [None, "bad", "{}", '["invalid"]']:
            with patch.object(collector, "run", return_value=output):
                self.assertIsNone(collector.nvtop_data())

    def test_service_collection_skips_resource_queries(self):
        with patch.object(collector, "gpu_data") as gpu, patch.object(collector, "cpu_ticks") as cpu, \
             patch.object(collector, "docker_service", return_value={"name": "Docker"}), \
             patch.object(collector, "ollama_data", return_value=({"name": "Ollama"}, [])):
            result = collector.collect("services")
        gpu.assert_not_called()
        cpu.assert_not_called()
        self.assertEqual(len(result["services"]), 3)
        self.assertIsNone(result["diskTotal"])

    def test_docker_container_counts(self):
        output = '\n'.join([
            '{"State":"running","Status":"Up 3 hours (healthy)"}',
            '{"State":"running","Status":"Up 2 hours (unhealthy)"}',
            '{"State":"exited","Status":"Exited (0) 1 hour ago"}',
            '{"State":"running","Status":"Up 1 hour"}'
        ])
        self.assertEqual(collector.docker_counts(output),
                         dict(containerCount=4, runningCount=3, unhealthyCount=1))
        self.assertEqual(collector.docker_counts("")["containerCount"], 0)
        with self.assertRaises(ValueError):
            collector.docker_counts('{"unexpected":true}')

    def test_docker_permission_failure_is_not_zero_containers(self):
        with patch.object(collector, "run", side_effect=["active", None]):
            service = collector.docker_service()
        self.assertEqual(service["state"], "online")
        self.assertNotIn("containerCount", service)
        self.assertIn("indisponível", service["detail"])

    def test_docker_api_can_work_without_systemd_unit(self):
        with patch.object(collector, "run", side_effect=[None, ""]):
            service = collector.docker_service()
        self.assertEqual(service["state"], "online")
        self.assertEqual(service["containerCount"], 0)


class IdleStdin:
    """A stdin that never produces input and never reaches EOF until released."""
    def __init__(self):
        self.release = threading.Event()

    def __iter__(self):
        self.release.wait()
        return iter(())


class StreamTests(unittest.TestCase):
    def lines_until(self, process, count, timeout=10):
        lines = []
        deadline = time.monotonic() + timeout
        while len(lines) < count and time.monotonic() < deadline:
            line = process.stdout.readline()
            if not line:
                break
            lines.append(json.loads(line))
        return lines

    def spawn(self, *args):
        return subprocess.Popen([sys.executable, "-u", str(path), "stream", *args], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def test_argument_parsing_keeps_defaults_and_ignores_bad_values(self):
        intervals, options = collector.parse_stream_arguments(["fast=2", "services=abc", "system=-1"])
        self.assertEqual(intervals, dict(fast=2.0, services=8.0, system=60.0))
        self.assertEqual(options, {})
        intervals, options = collector.parse_stream_arguments(["vms=20", "vm-uri=qemu:///system", "vm-script=x=1"])
        self.assertEqual(intervals["vms"], 20.0)
        self.assertEqual(options["vm-script"], "x=1")

    def test_failed_sample_becomes_error_line_and_stream_continues(self):
        calls = []
        def sampler(group):
            calls.append(group)
            if len(calls) == 1:
                raise RuntimeError("boom")
            return dict(ok=True)
        out, stdin = io.StringIO(), IdleStdin()
        stream = collector.Stream(dict(fast=0.05), out, stdin, sampler=sampler)
        thread = threading.Thread(target=stream.run)
        thread.start()
        time.sleep(0.4)
        stdin.release.set()
        thread.join(3)
        self.assertFalse(thread.is_alive())
        rows = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual((rows[0]["group"], rows[0]["error"]), ("fast", "boom"))
        self.assertTrue(any(row.get("data") == dict(ok=True) for row in rows))
        self.assertTrue(all("ts" in row for row in rows))

    def test_broken_pipe_stops_the_stream(self):
        class Closed:
            def write(self, _): raise BrokenPipeError()
            def flush(self): pass
        stdin = IdleStdin()
        stream = collector.Stream(dict(fast=0.05), Closed(), stdin, sampler=lambda group: {})
        thread = threading.Thread(target=stream.run)
        thread.start()
        thread.join(3)
        stdin.release.set()
        self.assertFalse(thread.is_alive())

    def test_process_exits_when_stdin_reaches_eof(self):
        process = self.spawn("fast=0.5", "services=0.5", "system=30")
        try:
            self.assertEqual(len(self.lines_until(process, 3)), 3)
            began = time.monotonic()
            process.stdin.close()
            process.wait(timeout=5)
            self.assertLess(time.monotonic() - began, 3)
            self.assertEqual(process.returncode, 0)
        finally:
            if process.poll() is None:
                process.kill()

    def test_process_exits_when_stdout_pipe_closes(self):
        process = self.spawn("fast=0.5", "services=0.5", "system=30")
        try:
            self.lines_until(process, 1)
            process.stdout.close()
            process.wait(timeout=5)
            self.assertEqual(process.returncode, 0)
        finally:
            if process.poll() is None:
                process.kill()

    def test_vm_group_waits_for_probes_and_resamples_when_they_change(self):
        script = "def main(argv):\n    return dict(argv=argv)\n"
        process = self.spawn("fast=30", "services=30", "system=30", "vms=30", "vm-uri=qemu:///x", "vm-script=" + script)
        try:
            time.sleep(1)  # no probes yet: the VM group must stay silent
            process.stdin.write(json.dumps(dict(probes=dict(a=1))) + "\n")
            process.stdin.flush()
            samples = []
            while len(samples) < 2:
                row = json.loads(process.stdout.readline())
                if row["group"] == "vms":
                    samples.append(row["data"]["argv"])
                    process.stdin.write(json.dumps(dict(probes=dict(a=len(samples) + 1))) + "\n")
                    process.stdin.flush()
            self.assertEqual(samples[0][:2], ["qemu:///x", "inventory"])
            self.assertEqual(json.loads(samples[0][2]), dict(a=1))
            self.assertEqual(json.loads(samples[1][2]), dict(a=2))
        finally:
            process.stdin.close()
            process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
