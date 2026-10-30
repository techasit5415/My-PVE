# 🚀 Proxmox VE Automation, Security & Discord Notification System

ระบบตรวจวัดสถานะอัตโนมัติ (Automated Monitoring), เสริมความปลอดภัย (Security Hardening), จัดการพลังงาน (CPU Power Optimization) และระบบแจ้งเตือนผ่าน Discord Webhook สำหรับเครื่องแม่ข่าย **Proxmox VE (PVE)**

---

## 🖥️ ข้อมูลฮาร์ดแวร์และระบบ (Server Specifications)

* **Server Hostname:** `pve` (IP: `192.168.100.253`)
* **Processor (CPU):** AMD Ryzen 5 4600G with Radeon Graphics (6 Cores / 12 Threads)
* **Memory (RAM):** 32 GB DDR4
* **System Disk (OS):** 250 GB WD Blue SN580 NVMe SSD (LVM-Thin)
* **Storage Pool (ZFS):** 4x 2TB Seagate BarraCuda SATA HDD (ZFS Mirror Pool `data` ~ 3.6 TB)
* **OS / Hypervisor:** Proxmox VE 9.2 (Debian 13 Trixie, Linux Kernel 7.0)
* **Backup Destination:** Proxmox Backup Server (PBS: `A1` @ `192.168.100.176`, Datastore: `bornzi`)

---

## 📑 สรุประบบที่ติดตั้งและเปิดใช้งาน (Implemented Features)

### 1. หมวด Critical & Storage (การเฝ้าระวังฮาร์ดแวร์และ ZFS)
* **S.M.A.R.T. Real-time Alert (`smartd`):**
  * คอนฟิกใน `/etc/smartd.conf` แยกค่าเกณฑ์ตามประเภทดิสก์:
    * NVMe OS (`/dev/nvme0n1`): อุณหภูมิแจ้งเตือน 65°C / ฉุกเฉิน 75°C
    * 4x SATA HDDs (`/dev/sd[a-d]`): ตรวจจับ Bad Sector (`-R 5`), Pending Sector (`-C 197+`), Uncorrectable Sector (`-U 198+`) และอุณหภูมิเกิน 45°C / 55°C
  * สคริปต์ `/usr/local/bin/smartd-discord.sh` จะยิงการ์ดสีแดงแจ้งเตือนเข้า Discord ทันทีที่ฮาร์ดแวร์มีปัญหา ไม่ต้องรอรอบสรุป
* **ZFS Event Daemon (`zfs-zed`):**
  * คอนฟิกใน `/etc/zfs/zed.d/zed.rc` เปิด `ZED_NOTIFY_DATA=1` และ `ZED_NOTIFY_VERBOSE=1`
  * ฝังฟังก์ชัน `zed_notify_discord` ใน `/etc/zfs/zed.d/zed-functions.sh`
  * แจ้งเตือนฉุกเฉินทันทีเมื่อ ZFS Pool หลุดเป็น `DEGRADED`, มีดิสก์ `FAULTED/REMOVED` หรือค่า Checksum Error เริ่มขยับมากกว่า 0
* **ZFS Monthly Scrub Summary:**
  * ตั้งเวลา Scrub อัตโนมัติทุกวันอาทิตย์ที่ 2 ของเดือน (`/etc/cron.d/zfsutils-linux`)
  * เมื่อ Scrub เสร็จสิ้น ZED จะส่งผลสรุปเข้า Discord (ปริมาณข้อมูลที่ตรวจ, เวลาที่ใช้, มี Bit Rot หรือบล็อกข้อมูลถูกซ่อมแซมหรือไม่)

### 2. หมวด Backup & Data Protection (VZDump / PBS Hook)
* **VZDump Discord Hook Script (`/usr/local/bin/vzdump-discord.sh`):**
  * ผูกเข้ากับระบบ Proxmox ผ่าน `/etc/vzdump.conf` (`script: /usr/local/bin/vzdump-discord.sh`)
  * **กรณีสำเร็จ (Success):** ส่ง Embed สีเขียว รายงานชื่อ VM/Container, ID, ขนาดไฟล์แบ็กอัป, Storage ปลายทาง และระยะเวลาที่ใช้ (เช่น `1m 24s`)
  * **กรณีล้มเหลว (Failed / Aborted):** ส่ง Embed สีแดง วิเคราะห์สาเหตุความผิดพลาด (ตรวจจับพื้นที่เต็ม `No space left on device`, Storage Offline หรือ Timeout) พร้อมตัด Log แนบมาให้ทันที

### 3. หมวด System Health & Resource Alerts (กันระบบน็อค)
* **Daily Health Check (สรุปสุขภาพประจำวัน 08:00 น.):**
  * สคริปต์ `/usr/local/bin/discord-disk-report.sh` ทำงานผ่าน Cron `/etc/cron.d/pve-daily-health-check` ทุกวันเวลา 08:00 น.
  * รายงาน:
    * 🌡️ อุณหภูมิ CPU Package / AMD Tctl
    * 🧠 ปริมาณการใช้ RAM (Used / Total และ %)
    * 💾 พื้นที่จัดเก็บ Root Disk (`/`)
    * 🗄️ สถานะและพื้นที่ ZFS Pool (`data`)
    * 🔍 ตาราง S.M.A.R.T. สุขภาพ, อุณหภูมิ และ Bad Sector ของดิสก์ทั้ง 5 ลูก
    * ⚡ สรุปจำนวน VM และ Container ที่กำลังทำงาน
* **Resource Warning เกินขีดจำกัด (`/usr/local/bin/pve-resource-monitor.sh`):**
  * รันตรวจเช็กทุก 5 นาทีผ่าน `/etc/cron.d/pve-resource-monitor`
  * **RAM > 90% เป็นเวลานาน:** แจ้งเตือนเมื่อ RAM เกิน 90% ติดต่อกันมากกว่า 10 นาที พร้อมแนบ Top 5 Process ที่กิน RAM สูงสุด (Cooldown 2 ชม.)
  * **Storage > 85%:** ตรวจเช็กทั้ง Root Filesystem (`/`) และ ZFS Pool แจ้งเตือนเมื่อพื้นที่เกิน 85% และยกระดับเป็น Critical เมื่อแตะ 95%

### 4. หมวด Operational & Security (ความปลอดภัยและการทำงาน)
* **Host Boot / Reboot Notification:**
  * สคริปต์ `/usr/local/bin/discord-boot-notify.sh` ทำงานผ่าน Systemd `/etc/systemd/system/pve-boot-notify.service`
  * ยิงข้อความ `🚀 PVE Server Booted Up Successfully` ทันทีที่เน็ตเวิร์กพร้อม รายงานเวลาบูต, IP Addresses, Kernel, สถานะ ZFS และประวัติเหตุการณ์ก่อนหน้า (เช่น ไฟดับ หรือรีสตาร์ตปกติ)
* **SSH Root Login Alert:**
  * สคริปต์ `/usr/local/bin/discord-ssh-login.sh` ผูกผ่าน PAM `/etc/pam.d/sshd`
  * ยิงแจ้งเตือนทันทีที่มีคนล็อกอินเข้าผ่าน SSH ด้วยสิทธิ์ `root` พร้อมระบุ **IP ต้นทาง**, ประเภทเซสชัน (TTY) และจำนวนผู้ใช้ที่ออนไลน์อยู่ (รันแบบ Asynchronous ไม่หน่วงเวลาล็อกอิน)

### 5. หมวด ZFS Auto-Snapshot (Sanoid)
* ติดตั้งแพ็กเกจ `sanoid` พร้อมเปิดใช้งาน Systemd Timer `sanoid.timer` (ตรวจเช็กทุก 15 นาที)
* คอนฟิกใน `/etc/sanoid/sanoid.conf` กำหนดนโยบายแบบ Recursive บน Pool `data`:
  * **Hourly:** 24 ชั่วโมงล่าสุด
  * **Daily:** 30 วันล่าสุด
  * **Monthly:** 3 เดือนล่าสุด
* **Zero Overhead:** Snapshot ใน ZFS ใช้เทคนิค Copy-on-Write (CoW) ทำให้กินพื้นที่เริ่มต้น 0 Bytes ไม่มีการก๊อปปี้บล็อกข้อมูลซ้ำซ้อน ไม่กินอายุฮาร์ดดิสก์ และสามารถ Rollback ย้อนเวลาคอนเทนเนอร์/VM กลับได้ใน 2 วินาทีหากเผลอลบไฟล์หรือถูก Ransomware

### 6. หมวด SSH Brute-Force Defense (Fail2ban)
* ติดตั้ง `fail2ban` ควบคุมผ่าน Jail `/etc/fail2ban/jail.local`
* **Whitelist:** ยกเว้นวงเครือข่ายภายในบ้าน (`127.0.0.1/8`, `192.168.100.0/24`, `192.168.1.0/24`, `192.168.5.0/24`, `192.168.69.0/24`) ป้องกันแอดมินถูกแบน
* **Ban Rule:** กรอกรหัสผ่านผิดเกิน 5 ครั้ง ภายใน 10 นาที จะถูกแบนเป็นเวลา **24 ชั่วโมง** ผ่าน Firewall
* **Discord Integration:** `/etc/fail2ban/action.d/discord-notify.conf` ส่งการ์ดแจ้งเตือนเข้า Discord ทันทีที่มีการแบน IP พร้อมระบุ IP, จำนวนครั้งที่พยายาม และระยะเวลาแบน

### 7. หมวด CPU Power & Thermal Tuning (AMD Ryzen Dynamic Scaling)
* ตรวจพบไดรเวอร์เคอร์เนล `amd-pstate-epp` ถูกตั้งค่าเริ่มต้นเป็น `performance` (ล็อคความเร็วค้างที่ 3.8 GHz ตลอดเวลา)
* ปรับจูนเป็น:
  * **Scaling Governor:** `powersave`
  * **Energy Performance Preference (EPP):** `balance_performance`
* ลดความเร็วตอน Idle ลงเหลือ ~1.4 - 2.9 GHz อุณหภูมิ CPU ลดลงมาอยู่ที่ **~33.8°C - 38.0°C** พัดลมเงียบลง และประหยัดไฟ โดยยังคงบูสต์ความเร็วเต็มกำลังทันทีเมื่อมีโหลด
* คงทนข้ามการรีบูตผ่านสคริปต์ `/usr/local/bin/set-cpu-governor.sh` และเซอร์วิส `/etc/systemd/system/pve-cpu-governor.service`

---

## 📂 โครงสร้างไดเรกทอรีใน Repository นี้

```text
My-PVE/
├── README.md                              # เอกสารสรุประบบและวิธีใช้งาน
├── configs/
│   ├── discord-notify.conf                # Action สำหรับ Fail2ban ส่ง Discord
│   ├── jail.local                         # การตั้งค่า Fail2ban SSH jail & whitelist
│   ├── pve-discord.conf.example           # ไฟล์ต้นแบบ Webhook URL กลาง
│   ├── sanoid.conf                        # นโยบาย ZFS Auto-Snapshot
│   └── smartd.conf                        # การตั้งค่ามอนิเตอร์ฮาร์ดแวร์ดิสก์ทั้ง 5 ลูก
├── cron/
│   ├── pve-daily-health-check             # ตั้งเวลารายงานสรุปสุขภาพประจำวัน 08:00 น.
│   └── pve-resource-monitor               # ตั้งเวลาตรวจวัด RAM > 90% และ ดิสก์ > 85% ทุก 5 นาที
├── scripts/
│   ├── discord-boot-notify.sh             # สคริปต์แจ้งเตือนเมื่อเปิดเครื่องเสร็จ
│   ├── discord-disk-report.sh             # สคริปต์ Daily Health Check รายงานละเอียด
│   ├── discord-send.sh                    # สคริปต์ส่ง Discord Embed กลาง
│   ├── discord-ssh-login.sh               # สคริปต์ตรวจจับและแจ้งเตือน SSH Root Login
│   ├── pve-resource-monitor.sh            # สคริปต์มอนิเตอร์ Resource Over-limit
│   ├── set-cpu-governor.sh                # สคริปต์ตั้งค่า AMD CPU Governor
│   ├── smartd-discord.sh                  # สคริปต์ดักจับเหตุการณ์ smartd
│   └── vzdump-discord.sh                  # Hook สคริปต์แจ้งเตือนผลแบ็กอัป VM/CT
└── systemd/
    ├── pve-boot-notify.service            # เซอร์วิสเรียกแจ้งเตือนตอนบูตเครื่อง
    └── pve-cpu-governor.service           # เซอร์วิสปรับจูนพลังงาน CPU ตอนบูตเครื่อง
```

---

## 🛠️ วิธีการติดตั้งบนเครื่องใหม่ (Quick Setup Instructions)

1. คัดลอกไฟล์คอนฟิก Webhook:
   ```bash
   cp configs/pve-discord.conf.example /etc/pve-discord.conf
   chmod 600 /etc/pve-discord.conf
   nano /etc/pve-discord.conf # ใส่ Discord Webhook URL จริง
   ```

2. คัดลอกสคริปต์ทั้งหมดไปยัง `/usr/local/bin/` และกำหนดสิทธิ์:
   ```bash
   cp scripts/*.sh /usr/local/bin/
   chmod +x /usr/local/bin/*.sh
   ```

3. ติดตั้ง Systemd Services & Timers:
   ```bash
   cp systemd/*.service /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now pve-boot-notify.service
   systemctl enable --now pve-cpu-governor.service
   ```

4. ติดตั้ง Cron Jobs:
   ```bash
   cp cron/* /etc/cron.d/
   chmod 644 /etc/cron.d/*
   systemctl restart cron
   ```

5. เปิดใช้งาน VZDump Hook ใน `/etc/vzdump.conf`:
   ```text
   script: /usr/local/bin/vzdump-discord.sh
   ```

6. เปิดใช้งาน SSH Login Hook ใน `/etc/pam.d/sshd`:
   ```text
   session optional pam_exec.so seteuid /usr/local/bin/discord-ssh-login.sh
   ```

---
*บันทึกสถานะระบบ ณ วันที่ 30 ตุลาคม 2026 โดย Antigravity Assistant*
