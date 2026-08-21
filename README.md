# disk_health_check.sh + push_health_to_proxmox.sh

Health-scores physical disks sitting behind an **Adaptec 6805T** (or other
`aacraid`-based) RAID controller, combining two independent data sources:

1. **`smartctl`** — drive-level media/wear health (reallocated sectors,
   uncorrectable errors, wear leveling, etc.)
2. **`arcconf`** — controller and array status, including whether the
   controller itself considers a disk `Online`/`Ready` or has failed it
   out of the array

Neither source alone is enough: `arcconf`'s own SMART reporting is
unreliable for SATA SSDs behind a SAS controller (it will often show
`S.M.A.R.T.: No` even on a healthy drive), while `smartctl` has no idea
whether the controller has actually pulled a disk from service. This
script pulls both together into one 0–100 score per drive.

## Requirements

- `smartctl` ≥ 7.x (needs `aacraid,H,L,ID` device-type support)
- `arcconf`, either:
  - installed natively, or
  - available via Docker as `akit042/docker-arccheck` (auto-detected —
    no config needed)
- Run as root (both tools need raw device access)

## Usage

```bash
chmod +x disk_health_check.sh
sudo ./disk_health_check.sh          # normal output
sudo ./disk_health_check.sh -v       # verbose: explains every note in plain English
sudo ./disk_health_check.sh -m       # markdown output, no ANSI colors (for Proxmox Notes, wikis, etc.)
sudo ./disk_health_check.sh -h       # help
```

## Configuring your drives

Edit the `DRIVES` array near the top of the script. Each entry is:

```
"label|device_node|host,lun,id"
```

- `device_node` — the block device the controller exposes to Linux
  (e.g. `/dev/sda`, `/dev/sdb`) — find these with `smartctl --scan`
- `host,lun,id` — the aacraid addressing triple; the `id` (last number)
  should match the drive's target ID from `arcconf GETCONFIG 1 PD`'s
  `Reported Channel,Device(T:L)` field, e.g. `0,4(4:0)` → id `4`

Example:
```bash
DRIVES=(
  "Disk0-Samsung870EVO|/dev/sda|0,0,0"
  "Disk4-MZ7L3960-A|/dev/sdb|0,0,4"
)
```

## What gets checked

**From `smartctl` (per drive):**
| Signal | What it means |
|---|---|
| Overall SMART self-assessment | Drive's own pass/fail verdict |
| Reallocated sectors | Worn sectors swapped for spares |
| Uncorrectable errors | Data errors the drive couldn't fix — serious |
| Runtime bad blocks | Blocks failing during active use |
| Program/erase fail counts | Flash cells failing to write/erase |
| CRC/interface errors | Usually a cabling/backplane issue, not the drive itself |
| Retired flash blocks | Normal SSD wear in small numbers |
| Wear leveling / life remaining | % of rated write endurance left |
| Reserved block capacity | Spare-block pool still available |

**From `arcconf` (once per run, plus per drive):**
- Controller status (`Optimal`/`Degraded`)
- Logical device (RAID array) status per array
- Defunct disk count
- Each physical disk's controller-reported `State` — if this isn't
  `Online`/`Ready`, it's treated as more urgent than any SMART reading,
  since it reflects whether the disk is actually in service right now

## Proxmox integration

`push_health_to_proxmox.sh` runs `disk_health_check.sh --markdown` and
pushes the result straight into the node's **Notes** field via `pvesh`
(Proxmox's built-in API CLI). That field renders as markdown right on
the node's **Summary** page in the web UI — no extra services, ports,
or Grafana/InfluxDB stack required.

```bash
mkdir -p /opt/scripts
cp disk_health_check.sh push_health_to_proxmox.sh /opt/scripts/
chmod +x /opt/scripts/*.sh

# test it once
/opt/scripts/push_health_to_proxmox.sh
```

Then check **Datacenter → your node → Summary** in the web UI.

Schedule it to refresh automatically:
```bash
crontab -e
```
```
0 6 * * * /opt/scripts/push_health_to_proxmox.sh >> /var/log/disk_health_push.log 2>&1
```

**Under the hood:** `pvesh set /nodes/<node>/config --description "..."`
writes directly to the same REST API endpoint the web UI itself uses
(`/nodes/{node}/config`) — the `description` field there is exactly
what the Notes widget displays. You can inspect it any time with
`pvesh get /nodes/$(hostname)/config`.

**Heads up:** each run *overwrites* the node's existing Notes field.
If you use Notes for other info, either move it elsewhere or ask for
an append-below-a-marker version instead of a full overwrite.

## Score bands and recommended action

| Score | Label | What to do |
|---|---|---|
| 90–100 | Excellent | No action. Keep running weekly. |
| 75–89 | Good | No action now. Recheck monthly, watch the trend. |
| 50–74 | Watch | Check weekly. Confirm backups are current, keep a spare on hand. |
| 1–49 | Poor | Schedule replacement soon. Confirm RAID redundancy covers it, back up anything not redundant. Check daily. |
| 0 | Critical | Replace ASAP. Back up now if the array can't tolerate losing it. |

## Notes and limitations

- The scoring weights are a practical heuristic, not an industry
  standard — treat the score as a triage signal. A score dropping over
  time matters more than any single static number.
- If `arcconf` isn't found (no native binary, no Docker), the script
  skips the controller/array section and falls back to SMART-only
  scoring, with a warning printed at the top.
- Consider running this on a cron schedule (e.g. weekly) and comparing
  output over time — a steady decline is a stronger signal than any
  one-off reading.

## Example output

**Normal (`-v` for verbose explanations):**
```
Controller / Array Status (arcconf)
  Controller Status:    Optimal
  Logical Devs/Fail/Deg: 2/0/0
  Defunct disk count:   0
  LD 0: Optimal
  LD 1: Optimal

Disk0-Samsung870EVO  (/dev/sda aacraid,0,0,0)
  Model:        Samsung SSD 870 EVO 500GB
  Power-on hrs: 1300
  Ctrl State:   Online
  Score:        96/100  Excellent  [###################-]
  What to do:   No action needed. Keep running this check on a regular schedule (e.g. weekly).
  Notes:
    - Retired flash blocks: 4
    - Wear leveling / life remaining: 99
```

**Markdown (`-m`), as it renders on the Proxmox node Summary page:**
```
### Disk0-Samsung870EVO
_(/dev/sda aacraid,0,0,0)_

| Field | Value |
|---|---|
| Model | Samsung SSD 870 EVO 500GB |
| Power-on hours | 1300 |
| Controller State | Online |
| **Score** | 🟢 **96/100 — Excellent** |
| What to do | No action needed. Keep running this check on a regular schedule (e.g. weekly). |

**Notes:**
- Retired flash blocks: 4
- Wear leveling / life remaining: 99
```
