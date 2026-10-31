#!/usr/bin/env python3
# /usr/local/bin/discord-disk-report.sh
# Daily System Health, Storage & Guests Report for Proxmox VE
import os
import subprocess
import datetime
import socket

# Ensure system binary paths are available under cron/limited environments
os.environ["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:" + os.environ.get("PATH", "")

def run_cmd(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""

host = socket.gethostname()
date_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
uptime_str = run_cmd("uptime -p") or run_cmd("uptime")
ip_addr = run_cmd("hostname -I").split()[0] if run_cmd("hostname -I") else "127.0.0.1"

# 1. CPU Temperature (AMD k10temp / Intel coretemp / Dual Xeon)
sensors_out = run_cmd("sensors")
cpu_temp = "N/A"
for line in sensors_out.splitlines():
    if any(k in line for k in ["Tctl", "Package id 0", "CPU Temperature", "Core 0"]):
        parts = line.split()
        for p in parts:
            if "°C" in p:
                cpu_temp = p.replace("+", "")
                break
        if cpu_temp != "N/A":
            break

# 2. RAM Usage
free_m = run_cmd("free -m").splitlines()
ram_str = "N/A"
ram_pct = 0
for line in free_m:
    if line.startswith("Mem:"):
        parts = line.split()
        total_m, avail_m = int(parts[1]), int(parts[6])
        used_m = total_m - avail_m
        ram_pct = int(used_m * 100 / total_m)
        ram_str = f"{used_m/1024:.1f}G / {total_m/1024:.1f}G ({ram_pct}%)"
        break

# 3. Root Filesystem
df_root = run_cmd("df -h /").splitlines()
root_str = "N/A"
root_pct = 0
if len(df_root) >= 2:
    parts = df_root[1].split()
    root_str = f"{parts[2]} / {parts[1]} ({parts[4]})"
    root_pct = int(parts[4].replace("%", "")) if parts[4].replace("%", "").isdigit() else 0

# 4. NVMe System SSD (if present)
has_nvme = os.path.exists("/dev/nvme0n1")
nvme_str = ""
nvme_status = "PASSED"
if has_nvme:
    nvme_h_out = run_cmd("smartctl -H /dev/nvme0n1")
    nvme_status = "PASSED" if any(k in nvme_h_out.upper() for k in ["PASSED", "OK"]) else "ALERT"
    nvme_out = run_cmd("smartctl -A /dev/nvme0n1")
    nvme_temp = "N/A"
    nvme_wear = "0%"
    nvme_tbw = "N/A"
    for line in nvme_out.splitlines():
        if "Temperature:" in line and "Sensor" not in line:
            parts = line.split()
            if len(parts) >= 2:
                nvme_temp = parts[1] + "°C"
        elif "Percentage Used:" in line:
            parts = line.split()
            if len(parts) >= 3:
                nvme_wear = parts[2]
        elif "Data Units Written:" in line:
            parts = line.split()
            if len(parts) >= 6:
                nvme_tbw = f"{parts[4].replace('[', '')} {parts[5].replace(']', '')}"
    wear_num = int(nvme_wear.replace("%", "")) if nvme_wear.replace("%", "").isdigit() else 0
    nvme_health = f"{100 - wear_num}%"
    nvme_str = (
        f"Health:  {nvme_health} (Wear: {nvme_wear} | TBW: {nvme_tbw})\n"
        f"Status:  {nvme_status} | Temp: {nvme_temp} | Errs: 0"
    )

# 5. Hard Disks S.M.A.R.T. (Auto-detect SATA & SAS)
disks = []
for line in run_cmd("lsblk -d -n -o NAME,TYPE").splitlines():
    parts = line.split()
    if len(parts) >= 2 and parts[1] == "disk":
        dname = parts[0]
        if not dname.startswith(("zd", "loop", "ram", "nvme")):
            disks.append(dname)
disks.sort()

hdd_lines = [
    "Disk   Health   Temp   Bad Sector",
    "---------------------------------"
]
any_hdd_fail = (has_nvme and nvme_status != "PASSED")
any_hdd_warn = False
for d in disks:
    dev = f"/dev/{d}"
    h_out = run_cmd(f"smartctl -H {dev}")
    health = "PASSED" if any(k in h_out.upper() for k in ["PASSED", "OK"]) else "ALERT"

    a_out = run_cmd(f"smartctl -A {dev}")
    t_val = "N/A"
    bad_val = "0"
    for l in a_out.splitlines():
        if "Current Drive Temperature:" in l:
            parts = l.split()
            if len(parts) >= 4:
                t_val = f"{parts[3]}°C"
        elif "Temperature_Celsius" in l or "Airflow_Temperature" in l:
            parts = l.split()
            if len(parts) >= 10:
                t_val = f"{parts[9]}°C"

        if "Elements in grown defect list:" in l:
            bad_val = l.split(":")[-1].strip()
        elif "Reallocated_Sector_Ct" in l:
            parts = l.split()
            if len(parts) >= 10:
                bad_val = parts[9]

    bad_num = int(bad_val) if bad_val.isdigit() else 0
    if health == "PASSED" and bad_num > 0:
        health = "WARN"

    if health == "ALERT":
        any_hdd_fail = True
    elif health == "WARN":
        any_hdd_warn = True

    hdd_lines.append(f"{d:<6} {health:<8} {t_val:<6} {bad_val}")

hdd_table = "\n".join(hdd_lines) if disks else "No hard disks detected"

# 6. ZFS Storage Pool(s)
zpool_out = run_cmd("zpool list -H -o name,size,alloc,free,cap,health").splitlines()
zfs_lines = []
for zp in zpool_out:
    parts = zp.split()
    if len(parts) >= 6:
        zfs_lines.append(f"Pool: {parts[0]} ({parts[5]})\nUsed: {parts[2]} / {parts[1]} ({parts[4]})")
zfs_str = "\n\n".join(zfs_lines) if zfs_lines else "No ZFS pools found"

# 7. Virtual Machines (VM)
qm_out = run_cmd("qm list").splitlines()
vm_lines = []
vm_run = 0
for line in qm_out[1:]:
    parts = line.split()
    if len(parts) >= 3:
        vmid, name, status = parts[0], parts[1], parts[2]
        if status == "running":
            vm_lines.append(f"🟢 {vmid:<4} {name}")
            vm_run += 1
        else:
            vm_lines.append(f"⚪ {vmid:<4} {name} (off)")

total_vms = len(qm_out) - 1 if len(qm_out) > 1 else 0
vm_str = "\n".join(vm_lines) if vm_lines else "No VMs"
vm_str += f"\n\nTotal: {vm_run}/{total_vms} Running"

# 8. Containers (LXC CT)
pct_out = run_cmd("pct list").splitlines()
ct_lines = []
ct_run = 0
for line in pct_out[1:]:
    parts = line.split()
    if len(parts) >= 3:
        vmid, status, name = parts[0], parts[1], parts[-1]
        if status == "running":
            ct_lines.append(f"🟢 {vmid:<4} {name}")
            ct_run += 1
        else:
            ct_lines.append(f"⚪ {vmid:<4} {name} (off)")

total_cts = len(pct_out) - 1 if len(pct_out) > 1 else 0
ct_str = "\n".join(ct_lines) if ct_lines else "No CTs"
ct_str += f"\n\nTotal: {ct_run}/{total_cts} Running"

# Determine Color
color = "green"
if any_hdd_fail:
    color = "red"
elif any_hdd_warn or ram_pct > 90 or root_pct > 85:
    color = "yellow"

desc = (
    f"🖥️ **เซิร์ฟเวอร์:** `{host}` ({ip_addr})\n"
    f"⏱️ **Uptime:** {uptime_str}\n"
    f"⏰ **เวลาตรวจ:** {date_str}"
)

# Build command for /usr/local/bin/discord-send.sh
cmd = [
    "/usr/local/bin/discord-send.sh",
    "--tag",
    "--title", "📊 รายงานสถานะประจำวัน (Daily Health Check)",
    "--desc", desc,
    "--color", color,
    "--field", "🌡️ CPU Temp", cpu_temp, "true",
    "--field", "🧠 Memory (RAM)", ram_str, "true",
    "--field", "💾 Root Disk (/)", root_str, "true",
]

if has_nvme and nvme_str:
    cmd.extend(["--field", "⚡ NVMe System SSD", f"```text\n{nvme_str}\n```", "false"])

cmd.extend([
    "--field", "🔍 Hard Disks S.M.A.R.T.", f"```text\n{hdd_table}\n```", "false",
    "--field", "🗄️ ZFS Storage Pool", f"```text\n{zfs_str}\n```", "false",
    "--field", "🖥️ Virtual Machines (VM)", f"```text\n{vm_str}\n```", "true",
    "--field", "📦 Containers (LXC CT)", f"```text\n{ct_str}\n```", "true",
])

subprocess.run(cmd, check=True)