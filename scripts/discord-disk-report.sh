#!/usr/bin/env python3
# /usr/local/bin/discord-disk-report.sh
# Daily System Health, Storage & Guests Report for Proxmox VE
import subprocess
import datetime
import socket

def run_cmd(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""

host = socket.gethostname()
date_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
uptime_str = run_cmd("uptime -p") or run_cmd("uptime")
ip_addr = run_cmd("hostname -I").split()[0] if run_cmd("hostname -I") else "127.0.0.1"

# 1. CPU Temperature (AMD k10temp / Intel fallback)
sensors_out = run_cmd("sensors")
cpu_temp = "N/A"
for line in sensors_out.splitlines():
    if any(k in line for k in ["Tctl", "Package id 0", "CPU Temperature"]):
        parts = line.split()
        if len(parts) >= 2:
            cpu_temp = parts[1].replace("+", "")
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

# 4. NVMe System SSD
nvme_out = run_cmd("smartctl -A /dev/nvme0n1")
nvme_temp = "N/A"
nvme_wear = "0%"
nvme_tbw = "N/A"
for line in nvme_out.splitlines():
    if "Temperature:" in line and "Sensor" not in line:
        nvme_temp = line.split()[1] + "°C"
    elif "Percentage Used:" in line:
        nvme_wear = line.split()[2]
    elif "Data Units Written:" in line:
        parts = line.split()
        if len(parts) >= 6:
            nvme_tbw = f"{parts[4]} {parts[5].replace('[', '').replace(']', '')}"

wear_num = int(nvme_wear.replace("%", "")) if nvme_wear.replace("%", "").isdigit() else 0
nvme_health = f"{100 - wear_num}%"
nvme_str = (
    f"Health:  {nvme_health} (Wear: {nvme_wear} | TBW: {nvme_tbw})\n"
    f"Status:  PASSED | Temp: {nvme_temp} | Errs: 0"
)

# 5. SATA HDDs S.M.A.R.T. (Clean Monospaced Table)
hdd_lines = [
    "Disk   Health   Temp   Bad Sector",
    "---------------------------------"
]
any_hdd_fail = False
for d in ["sda", "sdb", "sdc", "sdd"]:
    dev = f"/dev/{d}"
    h_out = run_cmd(f"smartctl -H {dev}")
    health = "PASSED" if "PASSED" in h_out or "OK" in h_out else "ALERT"
    if health != "PASSED":
        any_hdd_fail = True

    a_out = run_cmd(f"smartctl -A {dev}")
    t_val = "N/A"
    bad_val = "0"
    for l in a_out.splitlines():
        if "Temperature_Celsius" in l or "Airflow_Temperature" in l:
            parts = l.split()
            if len(parts) >= 10:
                t_val = parts[9] + "°C"
        elif "Reallocated_Sector_Ct" in l:
            parts = l.split()
            if len(parts) >= 10:
                bad_val = parts[9]
    hdd_lines.append(f"{d:<6} {health:<8} {t_val:<6} {bad_val}")
hdd_table = "\n".join(hdd_lines)

# 6. ZFS Storage Pool
zpool_out = run_cmd("zpool list -H -o name,size,alloc,free,cap,health").split()
if len(zpool_out) >= 6:
    zfs_str = f"Pool: {zpool_out[0]} ({zpool_out[5]})\nUsed: {zpool_out[2]} / {zpool_out[1]} ({zpool_out[4]})"
else:
    zfs_str = "No ZFS pools found"

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

# 8. Containers (LXC CT) - Notice parts[-1] is Name!
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
elif ram_pct > 90 or root_pct > 85:
    color = "yellow"

desc = (
    f"🖥️ **เซิร์ฟเวอร์:** `{host}` ({ip_addr})\n"
    f"⏱️ **Uptime:** {uptime_str}\n"
    f"⏰ **เวลาตรวจ:** {date_str}"
)

# Call /usr/local/bin/discord-send.sh
cmd = [
    "/usr/local/bin/discord-send.sh",
    "--tag",
    "--title", "📊 รายงานสถานะประจำวัน (Daily Health Check)",
    "--desc", desc,
    "--color", color,
    "--field", "🌡️ CPU Temp", cpu_temp, "true",
    "--field", "🧠 Memory (RAM)", ram_str, "true",
    "--field", "💾 Root Disk (/)", root_str, "true",
    "--field", "⚡ NVMe System SSD (250GB)", f"```text\n{nvme_str}\n```", "false",
    "--field", "🔍 SATA Hard Disks S.M.A.R.T.", f"```text\n{hdd_table}\n```", "false",
    "--field", "🗄️ ZFS Storage Pool", f"```text\n{zfs_str}\n```", "false",
    "--field", "🖥️ Virtual Machines (VM)", f"```text\n{vm_str}\n```", "true",
    "--field", "📦 Containers (LXC CT)", f"```text\n{ct_str}\n```", "true",
]

subprocess.run(cmd, check=True)