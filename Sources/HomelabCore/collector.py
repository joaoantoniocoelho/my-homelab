"""Read-only, dependency-free Linux collector, sent through SSH; never installed."""
import csv
import io
import json
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor


def run(args, timeout=3):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                                env={**os.environ, "LC_ALL": "C"})
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def number(value):
    try:
        value = float(value)
        return value if math.isfinite(value) and value >= 0 else None
    except (TypeError, ValueError):
        return None


def unit_number(value):
    match = re.match(r"^([0-9]+(?:\.[0-9]+)?)", str(value))
    return number(match[1]) if match else None


def cpu_ticks():
    with open("/proc/stat") as f:
        # guest/guest_nice are already included in user/nice.
        values = [int(x) for x in f.readline().split()[1:9]]
    return sum(values), values[3] + values[4]


def cpu_percent(before, after):
    total = after[0] - before[0]
    idle = after[1] - before[1]
    return min(100, max(0, 100 * (total - idle) / total)) if total > 0 else None


def gpu_data():
    warnings = []
    fields = "index,name,uuid,driver_version,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,power.limit,fan.speed"
    output = run(["nvidia-smi", "--query-gpu=" + fields, "--format=csv,noheader,nounits"])
    gpus = []
    if output is None:
        warnings.append("GPU indisponível: verifique o nvidia-smi e o driver NVIDIA.")
    else:
        for row in csv.reader(io.StringIO(output), skipinitialspace=True):
            if len(row) != 11 or not row[0].isdigit():
                warnings.append("Uma GPU retornou um formato de métricas desconhecido.")
                continue
            gpus.append(dict(index=int(row[0]), name=row[1], uuid=row[2], driver=row[3],
                             temperature=number(row[4]), utilization=number(row[5]),
                             memoryUsed=number(row[6]), memoryTotal=number(row[7]),
                             power=number(row[8]), powerLimit=number(row[9]), fan=number(row[10]),
                             gpuClock=None, memoryClock=None))
    processes = []
    if gpus:
        output = run(["nvidia-smi", "--query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory",
                      "--format=csv,noheader,nounits"])
        if output is None:
            warnings.append("A lista de processos da GPU está indisponível.")
        else:
            for row in csv.reader(io.StringIO(output), skipinitialspace=True):
                if len(row) == 4 and row[1].isdigit():
                    processes.append(dict(gpuUUID=row[0], pid=int(row[1]), name=row[2], memory=number(row[3])))
                elif row:
                    warnings.append("Um processo da GPU não pôde ser interpretado.")
    return gpus, processes, warnings


def nvtop_data():
    output = run(["nvtop", "--snapshot"])
    try:
        data = json.loads(output) if output is not None else None
        return data if isinstance(data, list) and all(isinstance(x, dict) for x in data) else None
    except ValueError:
        return None


def ollama_data():
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open("http://127.0.0.1:11434/api/ps", timeout=2) as response:
            data = json.load(response)
        if not isinstance(data, dict) or not isinstance(data.get("models"), list):
            raise ValueError("invalid models")
        models = []
        for model in data["models"]:
            details = model.get("details") or {}
            models.append(dict(name=model["name"], size=number(model.get("size")),
                               sizeVRAM=number(model.get("size_vram")),
                               parameterSize=details.get("parameter_size"),
                               quantization=details.get("quantization_level"), expiresAt=model.get("expires_at")))
        return dict(name="Ollama", state="online", detail="API respondendo · porta 11434"), models
    except Exception:
        return dict(name="Ollama", state="offline", detail="API local indisponível · porta 11434"), []


def docker_counts(output):
    rows = [json.loads(line) for line in output.splitlines() if line.strip()]
    if any(not isinstance(row, dict) or not isinstance(row.get("State"), str)
           or not isinstance(row.get("Status"), str) for row in rows):
        raise ValueError("unknown Docker response")
    return dict(containerCount=len(rows),
                runningCount=sum(row["State"] == "running" for row in rows),
                unhealthyCount=sum("(unhealthy)" in row["Status"] for row in rows))


def docker_service():
    state = run(["systemctl", "show", "docker.service", "--property=ActiveState", "--value"], timeout=2)
    output = run(["docker", "ps", "--all", "--format", "{{json .}}"], timeout=2)
    if output is not None:
        try:
            counts = docker_counts(output)
            detail = (f'{counts["containerCount"]} containers · '
                      f'{counts["runningCount"]} running · {counts["unhealthyCount"]} unhealthy')
            return dict(name="Docker", state="online", detail=detail, **counts)
        except (ValueError, TypeError):
            pass
    if state in ("active", "reloading"):
        return dict(name="Docker", state="online", detail="Serviço ativo · contagem de containers indisponível")
    if state in ("inactive", "failed", "deactivating", "activating"):
        return dict(name="Docker", state="offline", detail="Serviço " + state)
    return dict(name="Docker", state="unknown", detail="Estado do serviço indisponível")


def collect(group):
    data = dict(hostname=socket.gethostname(), uptime=None, cpu=None, cores=None, load=[],
                memoryUsed=None, memoryTotal=None, diskUsed=None, diskTotal=None,
                gpus=[], processes=[], models=[], services=[], warnings=[], nvtopAvailable=False)
    if group == "fast":
        before = cpu_ticks()
        began = time.monotonic()
        with ThreadPoolExecutor(max_workers=2) as pool:
            gpu_job = pool.submit(gpu_data)
            nvtop_job = pool.submit(nvtop_data)
            gpus, processes, warnings = gpu_job.result()
            nvtop = nvtop_job.result()
        if nvtop is None:
            warnings.append("Métricas adicionais do nvtop indisponíveis; usando nvidia-smi para a GPU.")
        else:
            for gpu in gpus:
                matches = [x for x in nvtop if x.get("device_name") == gpu["name"]]
                # Snapshot has no UUID: do not mix identical GPU names.
                if len(matches) == 1 and sum(x["name"] == gpu["name"] for x in gpus) == 1:
                    gpu["gpuClock"] = unit_number(matches[0].get("gpu_clock"))
                    gpu["memoryClock"] = unit_number(matches[0].get("mem_clock"))
        time.sleep(max(0, 0.25 - (time.monotonic() - began)))
        with open("/proc/meminfo") as f:
            mem = {line.split(":")[0]: int(line.split()[1]) for line in f}
        data.update(cpu=cpu_percent(before, cpu_ticks()), cores=os.cpu_count(), load=list(os.getloadavg()),
                    memoryUsed=(mem["MemTotal"] - mem["MemAvailable"]) * 1024,
                    memoryTotal=mem["MemTotal"] * 1024, gpus=gpus, processes=processes,
                    warnings=list(dict.fromkeys(warnings)), nvtopAvailable=nvtop is not None)
    elif group == "services":
        with ThreadPoolExecutor(max_workers=2) as pool:
            ollama_job = pool.submit(ollama_data)
            docker_job = pool.submit(docker_service)
            ollama, models = ollama_job.result()
            docker = docker_job.result()
        data.update(models=models, services=[dict(name="SSH", state="online", detail="Conexão autenticada"), docker, ollama])
    elif group == "system":
        with open("/proc/uptime") as f:
            uptime = float(f.read().split()[0])
        disk = shutil.disk_usage("/")
        data.update(uptime=uptime, diskUsed=disk.used, diskTotal=disk.total)
    else:
        raise ValueError("unknown collection group")
    return data


if __name__ == "__main__":
    print("__HL_JSON_BEGIN__")
    print(json.dumps(collect(sys.argv[1]), allow_nan=False))
    print("__HL_JSON_END__")
