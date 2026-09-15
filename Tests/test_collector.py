import importlib.util
import pathlib
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


if __name__ == "__main__":
    unittest.main()
