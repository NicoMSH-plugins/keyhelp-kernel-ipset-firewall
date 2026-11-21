# KeyHelp Kernel Firewall & IPSet Ban (AbuseIPDB & FireHOL)

Fast kernel-level IP blocking via IPSet for KeyHelp servers, including a live status dashboard widget for blocked IPs, traffic volume, and intercepted packets.
> [!NOTE]
> If you do not want the status widget in the KeyHelp dashboard, complete **Step 1** and jump straight to **Step 4 (Fail2Ban & IPSet)**.

<img width="837" height="296" alt="Screenshot 2026-11-21 130655" src="https://github.com/user-attachments/assets/0bdddd5c-09d9-4cad-adbf-ef8d5e3abb2e" />

---
> [!IMPORTANT]
> **Important Notes from the Scripts**
> * **Requirements:**
>   * **OS & Memory:** Ubuntu or Debian with `systemd` and kernel `ipset` (`hash:net`) support, at least **1 GB RAM** recommended.
>   * **Tools & Access:** Root privileges, outbound internet access, and the `ipset`, `iptables`, and `wget` packages installed.
>   * **KeyHelp:** Optional – only needed for KeyHelp-specific integration and status files (see screenshot above).
> * **Blocklists & Filtering:** `loadlist.sh` fetches `abuseipdb-s100-3d.ipv4` (borestad) and `firehol_level1.netset` (FireHOL) and filters out loopback (`127.*`) and private (`172.16.0.0/12`) ranges.
> * **Kernel IPSet & 7-Day Timeout:** `loadlist.sh` creates `f2b-iplistblock` (`hash:net`) with `maxelem 1000000` and `timeout 604800` (7 days) directly in the kernel without needing Fail2Ban. If an `f2b-iplistblock` set without a timeout already exists, run `ipset destroy f2b-iplistblock` once beforehand.
> * **Firewall & DHCP:** The script automatically adds the `INPUT` `DROP` rule for `f2b-iplistblock` and allows DHCP traffic (UDP `67`/`68`) so lease renewals are not blocked.
> * **Persistent Stats:** `live_status.sh` stores cumulative and daily counters in `/root/banip/` (`.persistent_total`, `.daily_bytes_start`, `f2b_status.txt`) and copies `f2b_status.txt` to `/home/keyhelp/www/keyhelp/f2b_status.txt` with `chmod 644`.

## 1. Create Directory & Download Scripts

```bash
mkdir -p /root/banip
cd /root/banip

wget https://github.com/NicoMSH-plugins/keyhelp-kernel-ipset-firewall/releases/download/1.3.0/live_status.sh
wget https://github.com/NicoMSH-plugins/keyhelp-kernel-ipset-firewall/releases/download/1.3.0/loadlist.sh

chmod +x /root/banip/live_status.sh /root/banip/loadlist.sh
```

---

## 2. Set Up Systemd Service & Timer for Live Status

Create the service file (`/etc/systemd/system/f2b-status.service`):

```bash
nano /etc/systemd/system/f2b-status.service
```

Paste the following content and save the file (`Ctrl+O`, `Enter`, `Ctrl+X`):

```ini
[Unit]
Description=Updates the Fail2Ban IPSet status for monitoring
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash /root/banip/live_status.sh

[Install]
WantedBy=multi-user.target
```

Create the timer file (`/etc/systemd/system/f2b-status.timer`):

```bash
nano /etc/systemd/system/f2b-status.timer
```

Paste the following content and save the file (`Ctrl+O`, `Enter`, `Ctrl+X`):

```ini
[Unit]
Description=Runs the f2b-status script every 1 minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
Unit=f2b-status.service

[Install]
WantedBy=timers.target
```

Reload systemd and enable the timer:

```bash
systemctl daemon-reload
systemctl enable --now f2b-status.timer
systemctl start f2b-status.service
```

---

## 3. Add Dashboard Widget in KeyHelp

1. Log in to KeyHelp as an administrator.
2. Navigate to **Configuration → White Label** and click the **pencil icon** next to **All Languages**.
3. Locate the **Additional JavaScript** field, paste the following code, and save:

<details>
<summary><b>Show / Expand JavaScript for the Dashboard Box</b></summary>

```javascript
// ====================================================
// 🛡️ ABANDONED/LIVE ABUSEIPDB & KERNEL IPSET STATUS BOX
// ====================================================
if ('admin_dashboard' === getUrlQueryParameterValue('page')) {
    $(function() {
        let $portTable = $('table').filter(function() {
            let htmlText = $(this).text();
            return htmlText.includes('FTP') && htmlText.includes('SSH');
        }).first();

        if (!$portTable.length) {
            $portTable = $('table').filter(function() {
                return $(this).find('.fa-network-wired, .fa-server, .fa-desktop').length > 0;
            }).first();
        }
        let $portCard = $portTable.closest('.card, .box');

        // Language and loading detection via HTML header
        let htmlLang = $('html').attr('lang') || '';
        let isGerman = htmlLang.toLowerCase().startsWith('de');

        let txtLoading = isGerman ? 'Lade Live-Daten...' : 'Loading live data...';

        let $abuseBox = $(`
            <div class="card mt-5 mb-5" id="abuseipdb-status-card" style="margin-top: 1.5rem !important; margin-bottom: 1.5rem !important;">
                <header class="card-header">
                    <span class="card-header-icon">
                        <i class="fas fa-shield-alt" style="color: #3273dc;"></i>
                    </span>
                    <p class="card-header-title">AbuseIPDB & Kernel-Firewall (IPSet)</p>
                </header>
                <div class="card-content">
                    <div id="abuseipdb-status-content" class="columns is-multiline is-mobile">
                        <div class="column is-12 has-text-grey">${txtLoading}</div>
                    </div>
                </div>
            </div>
        `);

        if ($portCard.length) {
            $portCard.before($abuseBox);
        }

        let txt = isGerman ? {
            ips: "Gesperrte IPs",
            total: "Datenverkehr Gesamt",
            daily: "Datenverkehr Heute",
            packets: "Abgefangene / Blockierte Pakete",
            update: "Letztes Update"
        } : {
            ips: "Blocked IPs",
            total: "Total Traffic",
            daily: "Traffic Today",
            packets: "Intercepted / Blocked Packets",
            update: "Last Update"
        };

        function updateAbuseStatus() {
            $.get('f2b_status.txt', function(rawText) {
                let parts = rawText.split('|');

                let ips = '0';
                let total = '0 Bytes';
                let daily = '0 Bytes';
                let packets = '0';
                let upd = '-';

                try {
                    if (parts.length >= 4) {
                        ips = parts[0].replace(/[^0-9]/g, '');
                        total = parts[1].replace('Gesamt:', '').trim();
                        
                        let dailyPart = parts[2];
                        if (dailyPart && dailyPart.includes(':')) {
                            daily = dailyPart.split(':')[1].replace('(Pakete', '').trim();
                        }
                        
                        let packetMatch = rawText.match(/Pakete:\s*([0-9]+)/);
                        if (packetMatch) {
                            packets = packetMatch[1];
                        }

                        let updMatch = rawText.match(/Upd:\s*(.*)/);
                        if (updMatch) {
                            upd = updMatch[1].trim();
                        }
                    } else {
                        ips = rawText;
                    }
                } catch (e) {
                    console.error("Error parsing status:", e);
                }

                let html = `
                    <div class="column is-12-mobile is-4-tablet">
                        <div class="p-5" style="background: rgba(50, 115, 220, 0.05); border-radius: 6px; border-left: 4px solid #3273dc;">
                            <div class="is-size-7 has-text-grey text-uppercase"><i class="fas fa-ban mr-1"></i> ${txt.ips}</div>
                            <div class="is-size-4 has-text-weight-bold mt-2" style="color: #3273dc; padding-left: 15px !important;">${ips}</div>
                        </div>
                    </div>
                    <div class="column is-12-mobile is-4-tablet">
                        <div class="p-5" style="background: rgba(72, 199, 116, 0.05); border-radius: 6px; border-left: 4px solid #48c774;">
                            <div class="is-size-7 has-text-grey text-uppercase"><i class="fas fa-database mr-1"></i> ${txt.total}</div>
                            <div class="is-size-4 has-text-weight-bold mt-2" style="color: #48c774; padding-left: 15px !important;">${total}</div>
                        </div>
                    </div>
                    <div class="column is-12-mobile is-4-tablet">
                        <div class="p-5" style="background: rgba(255, 221, 87, 0.05); border-radius: 6px; border-left: 4px solid #ffdd57;">
                            <div class="is-size-7 has-text-grey text-uppercase"><i class="fas fa-chart-line mr-1"></i> ${txt.daily}</div>
                            <div class="is-size-4 has-text-weight-bold mt-2" style="color: #ffdd57; padding-left: 15px !important;">${daily}</div>
                        </div>
                    </div>
                    <div class="column is-12">
                        <div class="p-5" style="background: rgba(255, 56, 96, 0.05); border-radius: 6px; border-left: 4px solid #ff3860;">
                            <div class="is-size-7 has-text-grey text-uppercase"><i class="fas fa-box mr-1"></i> ${txt.packets}</div>
                            <div class="is-size-4 has-text-weight-bold mt-2" style="color: #ff3860; padding-left: 15px !important;">${packets}</div>
                        </div>
                    </div>
                    <div class="column is-12 has-text-right pt-0 pb-0">
                        <span class="is-size-7 has-text-grey"><i class="far fa-clock mr-1"></i> ${txt.update}: ${upd}</span>
                    </div>
                `;

                $('#abuseipdb-status-content').html(html);
            }).fail(function() {
                let errText = isGerman ? "Status-Datei konnte nicht geladen werden." : "Could not load status file.";
                $('#abuseipdb-status-content').html(`<div class="column is-12 has-text-danger">${errText}</div>`);
            });
        }

        updateAbuseStatus();
        setInterval(updateAbuseStatus, 60000);
    });
}
```

</details>

---

### 4. Set Up Boot Service (`loadlist-boot.service`)

Since `/root/banip/loadlist.sh` creates and manages the kernel IPSet `f2b-iplistblock` (`hash:net`, `maxelem 1000000`, `timeout 604800` = 7 days) as well as the `iptables` rules directly, no Fail2Ban filter or jail is required. To ensure the blocklist is loaded automatically after a server reboot, create a `systemd` oneshot service.

Create the service file:

```bash
nano /etc/systemd/system/loadlist-boot.service
```

Paste the following content and save the file (`Ctrl+O`, `Enter`, `Ctrl+X`):

```ini
[Unit]
Description=Load IP Blocklist at Boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash /root/banip/loadlist.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
```

Reload `systemd`, enable the service at boot, and verify its status:

```bash
systemctl daemon-reload
systemctl enable loadlist-boot.service
systemctl start loadlist-boot.service
systemctl status loadlist-boot.service --no-pager
```
> [!TIP]
> Optional check to verify that the kernel IPSet is active with `maxelem 1000000` and `timeout 604800`:
>
> ```bash
> ipset list f2b-iplistblock | head -n 10
> ```

## 5. Set Up Daily Cron Job in KeyHelp

1. Log in to KeyHelp as an administrator, go to **Configuration → Scheduled Tasks**, and click **Add Task**.
2. Fill in the fields as follows and click **Save**:
   * **Enabled:** Yes
   * **Description:** `IP Blocklist`
   * **Task Type:** Execute command
   * **Command:** `/root/banip/loadlist.sh`
   * **Schedule:** Daily (choose your preferred time)
   * **Owner:** `-- System (root) --`

---

## 6. Run Initial Test & Start

Either trigger the newly created scheduled task in KeyHelp by clicking the **blue play icon** on the right, or run it directly in your terminal:

```bash
bash /root/banip/loadlist.sh
```

Everything will now run automatically. Once the blocklists have been fetched and imported, the blocked IPs, packet counts, and traffic stats will appear on your KeyHelp dashboard. Enjoy!

## Changelog

### v1.3.0 (2026-11-21)
- **Removed Fail2Ban Requirement**: Replaced the Fail2Ban filter and jail setup (`[iplistblock]`) with direct kernel IPSet management via `loadlist.sh` (`hash:net`, `maxelem 1000000`, `timeout 604800` for automatic 7-day expiration).
- **Added Boot Service (`loadlist-boot.service`)**: Added documentation and setup instructions for the `systemd` oneshot service to automatically load the IP blocklist into the kernel on server reboot.
