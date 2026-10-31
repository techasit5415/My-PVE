#!/usr/bin/env python3
"""
PVE Physical Disk & Motherboard SATA Port Visualizer Dashboard
Author: CSNIS Team / Antigravity
Port: 8088 (Default)
Runs on Proxmox VE / Debian / Linux Storage Nodes
"""

import os
import re
import sys
import time
import json
import glob
import socket
import argparse
import threading
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Active blinking tasks: { "sda": expire_timestamp }
BLINK_LOCK = threading.Lock()
ACTIVE_BLINKS = {}

# Motherboard ATA to SATA Port Label Mapping for ASUS PRIME A520M-K (and general boards)
BOARD_MAPPING = {
    "ata-1": {"port": "SATA6G_1", "bay": "Slot 1 (Top Bay)", "order": 1},
    "ata-2": {"port": "SATA6G_2", "bay": "Slot 2 (2nd Bay)", "order": 2},
    "ata-5": {"port": "SATA6G_3", "bay": "Slot 3 (3rd Bay)", "order": 3},
    "ata-6": {"port": "SATA6G_4", "bay": "Slot 4 (Bottom Bay)", "order": 4},
    "nvme-1": {"port": "M.2 PCIe 3.0", "bay": "M.2 Slot (Motherboard)", "order": 0},
}

CACHE_LOCK = threading.Lock()
DISK_CACHE = {"timestamp": 0, "data": []}
SYSTEM_CACHE = {"timestamp": 0, "data": {}}

def run_cmd(cmd):
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
        return res.stdout.strip()
    except Exception as e:
        return ""

def get_zfs_info():
    """Extract ZFS pool info, resilvering progress, and disk-to-pool mapping."""
    pools = {}
    disk_to_pool = {}
    
    # Map by-id symlinks to dev names
    id_to_dev = {}
    for p in glob.glob("/dev/disk/by-id/*"):
        if "-part" in p:
            continue
        try:
            target = os.path.realpath(p)
            dev_name = os.path.basename(target)
            id_name = os.path.basename(p)
            id_to_dev[id_name] = dev_name
        except Exception:
            pass

    zpool_out = run_cmd(["zpool", "status"])
    if not zpool_out:
        return pools, disk_to_pool

    current_pool = None
    current_vdev = ""
    resilver_info = None

    for line in zpool_out.splitlines():
        line_str = line.strip()
        if line_str.startswith("pool:"):
            current_pool = line_str.split("pool:", 1)[1].strip()
            pools[current_pool] = {"state": "ONLINE", "resilver": None, "vdevs": []}
        elif line_str.startswith("scan:") and current_pool:
            if "resilver in progress" in line_str or "resilvering" in line_str:
                pools[current_pool]["resilver"] = line_str
        elif line_str.startswith("state:") and current_pool:
            pools[current_pool]["state"] = line_str.split("state:", 1)[1].strip()
        elif current_pool:
            parts = line_str.split()
            if len(parts) >= 2:
                name, state = parts[0], parts[1]
                if name.startswith("mirror-") or name.startswith("raidz"):
                    current_vdev = name
                else:
                    dev_name = id_to_dev.get(name, "")
                    if not dev_name and name.startswith("sd"):
                        dev_name = name
                    if dev_name:
                        disk_to_pool[dev_name] = {
                            "pool": current_pool,
                            "vdev": current_vdev,
                            "zfs_id": name,
                            "zfs_state": state
                        }

    return pools, disk_to_pool

def get_system_summary():
    with CACHE_LOCK:
        if time.time() - SYSTEM_CACHE["timestamp"] < 5:
            return SYSTEM_CACHE["data"]

    hostname = socket.gethostname()
    uptime_raw = run_cmd(["uptime", "-p"]).replace("up ", "")
    
    # Board name
    board_vendor = run_cmd(["cat", "/sys/class/dmi/id/board_vendor"]) or "ASUSTeK"
    board_name = run_cmd(["cat", "/sys/class/dmi/id/board_name"]) or "PRIME A520M-K"
    board_full = f"{board_vendor} {board_name}".strip()

    pools, _ = get_zfs_info()
    pool_summary = []
    for p_name, p_info in pools.items():
        pool_summary.append({
            "name": p_name,
            "state": p_info.get("state", "UNKNOWN"),
            "resilver": p_info.get("resilver")
        })

    data = {
        "hostname": hostname,
        "uptime": uptime_raw,
        "motherboard": board_full,
        "pools": pool_summary,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S")
    }

    with CACHE_LOCK:
        SYSTEM_CACHE["timestamp"] = time.time()
        SYSTEM_CACHE["data"] = data

    return data

def scan_disks():
    with CACHE_LOCK:
        if time.time() - DISK_CACHE["timestamp"] < 3:
            return DISK_CACHE["data"]

    # 1. By-path mapping
    by_path_map = {}
    for p in glob.glob("/dev/disk/by-path/*"):
        if "-part" in p:
            continue
        try:
            target = os.path.realpath(p)
            dev_name = os.path.basename(target)
            by_path_map[dev_name] = os.path.basename(p)
        except Exception:
            pass

    # 2. Block devices via lsblk
    lsblk_json_raw = run_cmd(["lsblk", "-d", "-b", "-J", "-o", "NAME,MODEL,SERIAL,SIZE,TYPE,TRAN,ROTA"])
    disks = []
    if not lsblk_json_raw:
        return disks

    try:
        devices = json.loads(lsblk_json_raw).get("blockdevices", [])
    except Exception:
        devices = []

    _, disk_to_pool = get_zfs_info()

    for d in devices:
        name = d.get("name", "")
        # Filter only disks (ignore loop, ram, zd, sr)
        if not name or d.get("type") != "disk" or name.startswith("loop") or name.startswith("zd") or name.startswith("ram"):
            continue

        dev_path = f"/dev/{name}"
        by_path_str = by_path_map.get(name, "")
        
        # Match motherboard port & bay
        sata_port = "Unknown"
        bay_label = f"Disk {name}"
        order = 99

        for key, conf in BOARD_MAPPING.items():
            if key in by_path_str:
                sata_port = conf["port"]
                bay_label = conf["bay"]
                order = conf["order"]
                break

        if sata_port == "Unknown":
            # Auto fallback for generic sata
            ata_m = re.search(r"ata-([0-9]+)", by_path_str)
            if ata_m:
                port_num = ata_m.group(1)
                sata_port = f"SATA Port {port_num}"
                bay_label = f"SATA Slot {port_num}"
                order = int(port_num)
            elif "nvme" in name or "nvme" in by_path_str:
                sata_port = "PCIe NVMe"
                bay_label = "M.2 NVMe Slot"
                order = 0

        # Query SMART data via smartctl JSON
        smart_raw = run_cmd(["smartctl", "-j", "-a", dev_path])
        temp_c = None
        smart_passed = True
        reallocated = 0
        pending = 0
        uncorrectable = 0
        health_status = "HEALTHY"

        if smart_raw:
            try:
                sj = json.loads(smart_raw)
                smart_passed = sj.get("smart_status", {}).get("passed", True)
                
                # Temperature
                temp_c = sj.get("temperature", {}).get("current")
                if temp_c is None:
                    # Try nvme temperature
                    temp_c = sj.get("nvme_smart_health_information_log", {}).get("temperature")

                # ATA attributes
                attrs = sj.get("ata_smart_attributes", {}).get("table", [])
                for attr in attrs:
                    aid = attr.get("id")
                    raw_val = attr.get("raw", {}).get("value", 0)
                    if aid == 5:
                        reallocated = raw_val
                    elif aid == 197:
                        pending = raw_val
                    elif aid == 198:
                        uncorrectable = raw_val

                # NVMe media errors
                nvme_log = sj.get("nvme_smart_health_information_log", {})
                if nvme_log:
                    uncorrectable += nvme_log.get("media_errors", 0)

            except Exception:
                pass

        total_bad = reallocated + pending + uncorrectable
        if not smart_passed or uncorrectable > 0:
            health_status = "CRITICAL"
        elif total_bad > 0:
            health_status = "WARNING"

        # Check if currently blinking
        is_blinking = False
        with BLINK_LOCK:
            if name in ACTIVE_BLINKS:
                if time.time() < ACTIVE_BLINKS[name]:
                    is_blinking = True
                else:
                    del ACTIVE_BLINKS[name]

        # Size formatting
        size_bytes = d.get("size", 0)
        size_gb = size_bytes / (1024**3)
        if size_gb >= 1000:
            size_str = f"{size_gb/1024:.1f} TB"
        else:
            size_str = f"{size_gb:.0f} GB"

        zfs_meta = disk_to_pool.get(name, {})

        disk_entry = {
            "name": name,
            "dev": dev_path,
            "model": d.get("model") or "Generic Disk",
            "serial": d.get("serial") or "N/A",
            "size": size_str,
            "type": "NVMe SSD" if "nvme" in name else ("HDD" if d.get("rota") else "SSD"),
            "by_path": by_path_str,
            "sata_port": sata_port,
            "bay_label": bay_label,
            "order": order,
            "temp": f"{temp_c}°C" if temp_c is not None else "N/A",
            "temp_raw": temp_c or 0,
            "smart_passed": smart_passed,
            "health_status": health_status,
            "bad_sectors": {
                "reallocated": reallocated,
                "pending": pending,
                "uncorrectable": uncorrectable,
                "total": total_bad
            },
            "zfs": zfs_meta,
            "is_blinking": is_blinking
        }
        disks.append(disk_entry)

    # Sort by physical order
    disks.sort(key=lambda x: x["order"])

    with CACHE_LOCK:
        DISK_CACHE["timestamp"] = time.time()
        DISK_CACHE["data"] = disks

    return disks

def blink_worker(dev_name, duration=10):
    """Runs bursts of direct block I/O to blink the physical HDD activity LED."""
    end_time = time.time() + duration
    dev_path = f"/dev/{dev_name}"
    
    with BLINK_LOCK:
        ACTIVE_BLINKS[dev_name] = end_time

    # Burst reads
    while time.time() < end_time:
        with BLINK_LOCK:
            if dev_name not in ACTIVE_BLINKS:
                break
        try:
            # Read 20MB direct block
            subprocess.run(
                ["dd", f"if={dev_path}", "of=/dev/null", "bs=4M", "count=5", "iflag=direct"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2
            )
        except Exception:
            pass
        time.sleep(0.1)

    with BLINK_LOCK:
        if dev_name in ACTIVE_BLINKS:
            del ACTIVE_BLINKS[dev_name]


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>PVE Storage & SATA Port Visualizer</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg-base: #0b0f19;
      --bg-surface: #111827;
      --bg-card: #172033;
      --bg-card-hover: #1e293b;
      --border: #243049;
      --border-accent: #3b82f6;
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
      --text-dim: #64748b;
      --green: #10b981;
      --green-glow: rgba(16, 185, 129, 0.25);
      --amber: #f59e0b;
      --amber-glow: rgba(245, 158, 11, 0.25);
      --red: #ef4444;
      --red-glow: rgba(239, 68, 68, 0.3);
      --blue: #3b82f6;
      --cyan: #06b6d4;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Plus Jakarta Sans', -apple-system, sans-serif;
      background: var(--bg-base);
      color: var(--text-main);
      min-height: 100vh;
      padding: 24px 20px;
      line-height: 1.5;
    }
    .container {
      max-width: 1280px;
      margin: 0 auto;
    }
    header {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 20px 24px;
      margin-bottom: 24px;
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      align-items: center;
      gap: 16px;
      box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.5);
    }
    .logo-group {
      display: flex;
      align-items: center;
      gap: 16px;
    }
    .logo-badge {
      background: linear-gradient(135deg, #2563eb, #1d4ed8);
      width: 48px;
      height: 48px;
      border-radius: 12px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 24px;
      box-shadow: 0 0 20px rgba(37, 99, 235, 0.4);
    }
    .header-text h1 {
      font-size: 1.25rem;
      font-weight: 700;
      letter-spacing: -0.02em;
      color: #fff;
    }
    .header-text p {
      font-size: 0.85rem;
      color: var(--text-muted);
      display: flex;
      gap: 12px;
      margin-top: 4px;
      font-family: 'JetBrains Mono', monospace;
    }
    .header-actions {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .btn {
      background: var(--bg-card);
      color: var(--text-main);
      border: 1px solid var(--border);
      padding: 8px 16px;
      border-radius: 10px;
      font-size: 0.85rem;
      font-weight: 600;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      transition: all 0.2s ease;
    }
    .btn:hover {
      background: var(--bg-card-hover);
      border-color: var(--border-accent);
      transform: translateY(-1px);
    }
    .btn-primary {
      background: #2563eb;
      border-color: #3b82f6;
    }
    .btn-primary:hover {
      background: #1d4ed8;
    }
    .btn-blink {
      background: rgba(6, 182, 212, 0.15);
      border-color: rgba(6, 182, 212, 0.4);
      color: var(--cyan);
      width: 100%;
      justify-content: center;
      margin-top: 14px;
      padding: 10px;
    }
    .btn-blink:hover {
      background: rgba(6, 182, 212, 0.25);
      box-shadow: 0 0 15px rgba(6, 182, 212, 0.3);
    }
    .btn-blink.blinking {
      background: #ef4444 !important;
      border-color: #f87171 !important;
      color: #fff !important;
      animation: pulse-glow 0.8s infinite alternate;
    }
    @keyframes pulse-glow {
      0% { box-shadow: 0 0 5px #ef4444; }
      100% { box-shadow: 0 0 25px #ef4444; }
    }
    .stats-bar {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 16px;
      margin-bottom: 24px;
    }
    .stat-card {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 16px 20px;
      display: flex;
      flex-direction: column;
    }
    .stat-label {
      font-size: 0.75rem;
      text-transform: uppercase;
      font-weight: 700;
      color: var(--text-dim);
      letter-spacing: 0.05em;
    }
    .stat-val {
      font-size: 1.4rem;
      font-weight: 700;
      margin-top: 4px;
      color: #fff;
    }
    .section-title {
      font-size: 1.1rem;
      font-weight: 700;
      margin-bottom: 16px;
      display: flex;
      align-items: center;
      gap: 10px;
      color: #fff;
    }
    .section-title span.badge {
      font-size: 0.75rem;
      background: rgba(59, 130, 246, 0.15);
      color: #60a5fa;
      border: 1px solid rgba(59, 130, 246, 0.3);
      padding: 2px 8px;
      border-radius: 6px;
    }
    /* Chassis / Bays Grid */
    .bays-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(360px, 1fr));
      gap: 20px;
      margin-bottom: 32px;
    }
    .bay-card {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 20px;
      position: relative;
      transition: all 0.25s ease;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
    }
    .bay-card:hover {
      border-color: #3b82f6;
      box-shadow: 0 10px 30px -10px rgba(0, 0, 0, 0.6);
    }
    .bay-header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      margin-bottom: 14px;
      border-bottom: 1px solid var(--border);
      padding-bottom: 12px;
    }
    .bay-title-group h3 {
      font-size: 1.05rem;
      font-weight: 700;
      color: #fff;
    }
    .port-pill {
      display: inline-block;
      margin-top: 4px;
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.75rem;
      font-weight: 600;
      color: #38bdf8;
      background: rgba(56, 189, 248, 0.12);
      border: 1px solid rgba(56, 189, 248, 0.25);
      padding: 2px 8px;
      border-radius: 6px;
    }
    .status-led {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 4px 10px;
      border-radius: 20px;
      font-size: 0.75rem;
      font-weight: 700;
      font-family: 'JetBrains Mono', monospace;
    }
    .led-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
    }
    .status-healthy {
      background: var(--green-glow);
      color: #34d399;
      border: 1px solid rgba(16, 185, 129, 0.4);
    }
    .status-healthy .led-dot { background: #10b981; box-shadow: 0 0 8px #10b981; }
    .status-warning {
      background: var(--amber-glow);
      color: #fbbf24;
      border: 1px solid rgba(245, 158, 11, 0.4);
    }
    .status-warning .led-dot { background: #f59e0b; box-shadow: 0 0 8px #f59e0b; animation: blink 1s infinite; }
    .status-critical {
      background: var(--red-glow);
      color: #f87171;
      border: 1px solid rgba(239, 68, 68, 0.4);
    }
    .status-critical .led-dot { background: #ef4444; box-shadow: 0 0 8px #ef4444; animation: blink 0.5s infinite; }
    
    @keyframes blink { 50% { opacity: 0.2; } }

    .drive-info-table {
      width: 100%;
      font-size: 0.82rem;
      margin-bottom: 8px;
    }
    .drive-info-table tr {
      border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    }
    .drive-info-table td {
      padding: 6px 0;
    }
    .drive-info-table td.label {
      color: var(--text-dim);
      font-weight: 600;
      width: 38%;
    }
    .drive-info-table td.val {
      color: #e2e8f0;
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.8rem;
    }
    .val-sn {
      font-size: 0.95rem;
      font-weight: 700;
      color: #38bdf8;
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .copy-btn {
      background: transparent;
      border: none;
      color: var(--text-dim);
      cursor: pointer;
      font-size: 0.85rem;
      padding: 2px 4px;
      border-radius: 4px;
      transition: color 0.15s;
    }
    .copy-btn:hover {
      color: #fff;
    }
    .toast {
      position: fixed;
      bottom: 24px;
      right: 24px;
      background: #1e293b;
      border: 1px solid var(--border-accent);
      color: #fff;
      padding: 12px 20px;
      border-radius: 10px;
      font-size: 0.85rem;
      box-shadow: 0 10px 25px rgba(0,0,0,0.5);
      z-index: 999;
      display: none;
      align-items: center;
      gap: 10px;
    }
    .ref-table-box {
      background: var(--bg-surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 20px;
      margin-top: 24px;
    }
    .table-responsive {
      overflow-x: auto;
    }
    table.data-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.85rem;
      text-align: left;
    }
    table.data-table th {
      padding: 10px 14px;
      background: rgba(255,255,255,0.02);
      color: var(--text-dim);
      font-weight: 700;
      border-bottom: 1px solid var(--border);
    }
    table.data-table td {
      padding: 12px 14px;
      border-bottom: 1px solid rgba(255,255,255,0.04);
      font-family: 'JetBrains Mono', monospace;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="logo-group">
        <div class="logo-badge">🖴</div>
        <div class="header-text">
          <h1 id="host-title">PVE Disk & SATA Bay Visualizer</h1>
          <p>
            <span id="board-model">ASUSTeK PRIME A520M-K</span> • 
            <span>Node IP: 192.168.100.253</span> • 
            <span id="sys-uptime">Uptime: ...</span>
          </p>
        </div>
      </div>
      <div class="header-actions">
        <button class="btn" onclick="fetchData()">🔄 Refresh</button>
        <span style="font-size: 0.75rem; color: var(--text-dim);" id="last-updated">Updating...</span>
      </div>
    </header>

    <div class="stats-bar">
      <div class="stat-card">
        <span class="stat-label">Total Attached Drives</span>
        <span class="stat-val" id="stat-total">-</span>
      </div>
      <div class="stat-card">
        <span class="stat-label">Healthy Drives</span>
        <span class="stat-val" style="color: var(--green);" id="stat-healthy">-</span>
      </div>
      <div class="stat-card">
        <span class="stat-label">Warning / Bad Sectors</span>
        <span class="stat-val" style="color: var(--amber);" id="stat-warning">-</span>
      </div>
      <div class="stat-card">
        <span class="stat-label">ZFS Pools Status</span>
        <span class="stat-val" style="font-size: 1.1rem;" id="stat-zfs">-</span>
      </div>
    </div>

    <div class="section-title">
      🖥️ Physical Chassis & Motherboard SATA Slots
      <span class="badge">Live Enclosure Map</span>
    </div>

    <div class="bays-grid" id="bays-container">
      <!-- Injected via JS -->
    </div>

    <div class="ref-table-box">
      <div class="section-title" style="margin-bottom: 12px;">
        📋 Hardware Port Mapping Reference
      </div>
      <div class="table-responsive">
        <table class="data-table" id="ref-table">
          <thead>
            <tr>
              <th>Physical Slot</th>
              <th>Motherboard Port</th>
              <th>ATA Channel</th>
              <th>Linux Node</th>
              <th>Model</th>
              <th>Serial Number (S/N)</th>
              <th>Capacity</th>
              <th>Temp</th>
              <th>Pool Role</th>
            </tr>
          </thead>
          <tbody id="ref-tbody">
            <!-- Injected via JS -->
          </tbody>
        </table>
      </div>
    </div>
  </div>

  <div class="toast" id="toast-msg">Notification</div>

  <script>
    let blinkingState = {};

    function showToast(text, duration = 3000) {
      const toast = document.getElementById('toast-msg');
      toast.innerText = text;
      toast.style.display = 'flex';
      setTimeout(() => { toast.style.display = 'none'; }, duration);
    }

    function copyToClipboard(text) {
      navigator.clipboard.writeText(text).then(() => {
        showToast('📋 Copied Serial: ' + text);
      });
    }

    function blinkDisk(devName, slotName) {
      const btn = document.getElementById('blink-btn-' + devName);
      if (btn) {
        btn.classList.add('blinking');
        btn.innerText = '🚨 Blinking LED (10s)...';
      }
      showToast('💡 Blinking physical drive activity LED on ' + slotName + ' (' + devName + ')...', 5000);

      fetch('/api/blink', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ dev: devName, duration: 10 })
      }).then(r => r.json()).then(data => {
        setTimeout(fetchData, 10500);
      });
    }

    function fetchData() {
      fetch('/api/status')
        .then(res => res.json())
        .then(payload => {
          renderDashboard(payload);
        })
        .catch(err => {
          console.error("Fetch error:", err);
        });
    }

    function renderDashboard(data) {
      const sys = data.system;
      const disks = data.disks;

      document.getElementById('host-title').innerText = 'PVE Physical Disk Visualizer (' + sys.hostname + ')';
      document.getElementById('board-model').innerText = sys.motherboard;
      document.getElementById('sys-uptime').innerText = 'Uptime: ' + sys.uptime;
      document.getElementById('last-updated').innerText = 'Updated: ' + sys.timestamp;

      // Stats
      let healthyCount = 0;
      let warnCount = 0;
      disks.forEach(d => {
        if (d.health_status === 'HEALTHY') healthyCount++;
        else warnCount++;
      });
      document.getElementById('stat-total').innerText = disks.length;
      document.getElementById('stat-healthy').innerText = healthyCount;
      document.getElementById('stat-warning').innerText = warnCount;
      
      if (sys.pools && sys.pools.length > 0) {
        document.getElementById('stat-zfs').innerText = sys.pools.map(p => p.name + ': ' + p.state).join(', ');
      } else {
        document.getElementById('stat-zfs').innerText = 'No ZFS Pools';
      }

      // Render Bay Cards
      const container = document.getElementById('bays-container');
      container.innerHTML = '';

      const tbody = document.getElementById('ref-tbody');
      tbody.innerHTML = '';

      disks.forEach(d => {
        const isBlink = d.is_blinking;
        const statusClass = d.health_status === 'HEALTHY' ? 'status-healthy' : 
                           (d.health_status === 'WARNING' ? 'status-warning' : 'status-critical');
        const statusLabel = d.health_status === 'HEALTHY' ? 'HEALTHY' : 
                           (d.health_status === 'WARNING' ? 'BAD SECTOR' : 'FAILED');

        const zfsRole = d.zfs && d.zfs.pool ? `${d.zfs.pool} (${d.zfs.vdev || 'root'})` : 'Non-ZFS / OS';

        const card = document.createElement('div');
        card.className = 'bay-card';
        card.innerHTML = `
          <div>
            <div class="bay-header">
              <div class="bay-title-group">
                <h3>${d.bay_label}</h3>
                <span class="port-pill">${d.sata_port}</span>
              </div>
              <div class="status-led ${statusClass}">
                <div class="led-dot"></div>
                ${statusLabel}
              </div>
            </div>

            <table class="drive-info-table">
              <tr>
                <td class="label">Device Node:</td>
                <td class="val" style="font-weight: 700; color: #fff;">${d.dev}</td>
              </tr>
              <tr>
                <td class="label">Serial Number:</td>
                <td class="val">
                  <div class="val-sn">
                    ${d.serial}
                    <button class="copy-btn" onclick="copyToClipboard('${d.serial}')" title="Copy S/N">📋</button>
                  </div>
                </td>
              </tr>
              <tr>
                <td class="label">Model:</td>
                <td class="val">${d.model}</td>
              </tr>
              <tr>
                <td class="label">Capacity & Type:</td>
                <td class="val">${d.size} (${d.type})</td>
              </tr>
              <tr>
                <td class="label">Temperature:</td>
                <td class="val" style="color: ${d.temp_raw > 45 ? '#f59e0b' : '#34d399'};">${d.temp}</td>
              </tr>
              <tr>
                <td class="label">Bad Sectors:</td>
                <td class="val" style="color: ${d.bad_sectors.total > 0 ? '#fbbf24' : '#94a3b8'};">
                  ${d.bad_sectors.total} (Pending: ${d.bad_sectors.pending}, Realloc: ${d.bad_sectors.reallocated})
                </td>
              </tr>
              <tr>
                <td class="label">ZFS Pool:</td>
                <td class="val" style="color: #60a5fa;">${zfsRole}</td>
              </tr>
            </table>
          </div>

          <button id="blink-btn-${d.name}" class="btn btn-blink ${isBlink ? 'blinking' : ''}" onclick="blinkDisk('${d.name}', '${d.bay_label}')">
            ${isBlink ? '🚨 Blinking LED (10s)...' : '💡 Identify / Blink LED (10s)'}
          </button>
        `;
        container.appendChild(card);

        // Reference Table row
        const tr = document.createElement('tr');
        tr.innerHTML = `
          <td style="color: #fff; font-weight: 600;">${d.bay_label}</td>
          <td><span style="color: #38bdf8;">${d.sata_port}</span></td>
          <td style="color: #94a3b8;">${d.by_path.split('-').pop() || 'N/A'}</td>
          <td style="color: #fff; font-weight: 700;">${d.dev}</td>
          <td>${d.model}</td>
          <td style="color: #38bdf8; font-weight: 700;">${d.serial}</td>
          <td>${d.size}</td>
          <td>${d.temp}</td>
          <td style="color: #60a5fa;">${zfsRole}</td>
        `;
        tbody.appendChild(tr);
      });
    }

    // Auto poll every 5 seconds
    fetchData();
    setInterval(fetchData, 5000);
  </script>
</body>
</html>
"""

class RequestHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress spammy log outputs
        return

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/" or parsed.path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML_TEMPLATE.encode("utf-8"))
        elif parsed.path == "/api/status":
            sys_info = get_system_summary()
            disks = scan_disks()
            payload = {
                "system": sys_info,
                "disks": disks
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode("utf-8"))
        elif parsed.path == "/api/blink":
            params = parse_qs(parsed.query)
            dev = params.get("dev", [""])[0].replace("/dev/", "").strip()
            duration = int(params.get("duration", [10])[0]) if params.get("duration") else 10
            if re.match(r"^(sd[a-z]|nvme[0-9]+n[0-9]+)$", dev):
                threading.Thread(target=blink_worker, args=(dev, duration), daemon=True).start()
                resp = {"status": "ok", "message": f"Blinking {dev} for {duration} seconds"}
            else:
                resp = {"status": "error", "message": f"Invalid device name: {dev}"}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps(resp).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/blink":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else ""
            params = parse_qs(parsed.query)
            
            dev = ""
            duration = 10
            
            # Query params first
            if "dev" in params and params["dev"]:
                dev = params["dev"][0]
            if "duration" in params and params["duration"]:
                try:
                    duration = int(params["duration"][0])
                except Exception:
                    pass
            
            # Parse body
            if not dev and body:
                try:
                    data = json.loads(body)
                    dev = str(data.get("dev", ""))
                    if "duration" in data:
                        duration = int(data.get("duration", 10))
                except Exception:
                    m_dev = re.search(r'dev["\']?\s*[:=]\s*["\']?([a-zA-Z0-9]+)', body)
                    m_dur = re.search(r'duration["\']?\s*[:=]\s*([0-9]+)', body)
                    if m_dev:
                        dev = m_dev.group(1)
                    if m_dur:
                        duration = int(m_dur.group(1))

            dev = dev.replace("/dev/", "").strip()
            if re.match(r"^(sd[a-z]|nvme[0-9]+n[0-9]+)$", dev):
                threading.Thread(target=blink_worker, args=(dev, duration), daemon=True).start()
                resp = {"status": "ok", "message": f"Blinking {dev} for {duration} seconds"}
            else:
                resp = {"status": "error", "message": f"Invalid device name: {dev}"}

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps(resp).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

def main():
    parser = argparse.ArgumentParser(description="PVE Physical Disk & SATA Port Dashboard")
    parser.add_argument("--port", type=int, default=8088, help="Port to listen on (default: 8088)")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="Host address (default: 0.0.0.0)")
    args = parser.parse_args()

    # Pre-cache
    print(f"[*] Starting PVE Physical Disk Dashboard on http://{args.host}:{args.port}")
    scan_disks()

    server = HTTPServer((args.host, args.port), RequestHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Shutting down...")
        server.server_close()

if __name__ == "__main__":
    main()
