# Akvorado Health Check Script - Complete Guide
## Script: /home/myomyinttun/akvorado-health.sh
## Version: Updated 2026-02-23

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Script Usage](#script-usage)
3. [Variables & Configuration](#variables--configuration)
4. [Section-by-Section Guide](#section-by-section-guide)
5. [Quick Reference Commands](#quick-reference-commands)
6. [Alert Thresholds Summary](#alert-thresholds-summary)
7. [FAQ](#faq)

---

## Architecture Overview

```
                    +-------------------+
  Routers/Switches  |   Orchestrator    |  (port 8080)
  (NetFlow/sFlow)   |  config.yaml      |  Central coordinator
        |           +-------------------+
        |                    |
        v                    v
  +-----------+      +-----------+      +------------+      +-------------+
  |   Inlet   |----->|   Kafka   |----->|   Outlet   |----->| ClickHouse  |
  | port 8081 |      | port 9092 |      | port 8082  |      | port 9000   |
  | port 2055 |      | topic:    |      |            |      | DB: akvorado|
  | port 6343 |      | netplan-  |      |            |      | table: flows|
  | port 10179|      | flows-v5  |      |            |      |             |
  +-----------+      +-----------+      +------------+      +-------------+
                                                                   |
                                                                   v
                                                            +-------------+
                                                            |   Console   |
                                                            | port 8083   |
                                                            | (Web UI)    |
                                                            +-------------+
```

**Data Flow:** Router -> Inlet (receive & enrich) -> Kafka (buffer) -> Outlet (consume) -> ClickHouse (store) -> Console (query & visualize)

**Component Summary:**

| Component    | Binary                      | Role                                           |
|--------------|-----------------------------|-------------------------------------------------|
| Orchestrator | `akvorado orchestrator`     | Reads config.yaml, distributes config to others |
| Inlet        | `akvorado inlet`            | Receives NetFlow/sFlow, enriches, sends to Kafka|
| Outlet       | `akvorado outlet`           | Consumes Kafka, writes to ClickHouse            |
| Console      | `akvorado console`          | Web UI for queries and visualization            |
| Kafka        | Apache Kafka 2.13-3.9.1     | Message buffer between Inlet and Outlet         |
| ClickHouse   | ClickHouse v26.x            | Columnar database for flow storage              |

---

## Script Usage

### Normal health check (read-only)
```bash
bash akvorado-health.sh
```

### Change ClickHouse data retention
```bash
bash akvorado-health.sh --set-clickhouse-ttl <days>
# Example: keep 7 days of data
bash akvorado-health.sh --set-clickhouse-ttl 7
```

**How it works (line 22-51):**
1. Validates input is a number
2. Queries current TTL from `SHOW CREATE TABLE akvorado.flows`
3. Shows current vs new TTL
4. Asks for confirmation (`yes/no`)
5. Runs `ALTER TABLE akvorado.flows MODIFY TTL TimeReceived + INTERVAL <N> DAY DELETE`
6. Verifies the change by querying again
7. This is a **permanent change** — data older than N days will be auto-deleted

### Change Kafka topic retention
```bash
bash akvorado-health.sh --set-kafka-retention <days>
# Example: keep 3 days in Kafka buffer
bash akvorado-health.sh --set-kafka-retention 3
```

**How it works (line 54-89):**
1. Validates input is a number
2. Converts days to milliseconds (`days * 86400000`)
3. Queries current topic-level `retention.ms` config
4. Shows current vs new retention
5. Asks for confirmation (`yes/no`)
6. Runs `kafka-configs.sh --alter --add-config retention.ms=<ms>`
7. This is a **dynamic change** — takes effect immediately, no Kafka restart needed

---

## Variables & Configuration

**Defined at top of script (line 13-15):**

```bash
CLICKHOUSE_PASS="netflow2026"                              # ClickHouse password
KAFKA_BIN="/opt/kafka_2.13-3.9.1/bin"                      # Kafka binary directory
KAFKA_CONF="/opt/kafka_2.13-3.9.1/config/server.properties" # Kafka config file
```

**Helper function (line 17-19):**

```bash
print_table() {
    column -t -s $'\t' | sed 's/^/  /'
}
```
- Takes tab-separated input and formats it as an aligned table
- Adds 2-space indent with `sed 's/^/  /'`
- Used by all sections that display tabular data

---

## Section-by-Section Guide

---

### 1. AKVORADO PROCESSES (line 97-106)

**What it does:** Checks if all 4 Akvorado components are running.

**Command:** `pgrep -af "/usr/local/bin/akvorado"`
- `-a` = show full command line
- `-f` = match against full command line (not just process name)

**Expected output:**
```
[OK] 23261 /usr/local/bin/akvorado orchestrator /etc/akvorado/config.yaml
[OK] 23349 /usr/local/bin/akvorado inlet http://172.16.3.101:8080
[OK] 23403 /usr/local/bin/akvorado outlet http://172.16.3.101:8080
[OK] 23457 /usr/local/bin/akvorado console http://172.16.3.101:8080
```

| Process      | Config Source                    | Role                                    |
|--------------|----------------------------------|-----------------------------------------|
| orchestrator | `/etc/akvorado/config.yaml`      | Reads config, serves to other components|
| inlet        | `http://172.16.3.101:8080` (orchestrator) | Receives flows, sends to Kafka |
| outlet       | `http://172.16.3.101:8080` (orchestrator) | Kafka to ClickHouse           |
| console      | `http://172.16.3.101:8080` (orchestrator) | Web dashboard                  |

**Troubleshooting:**
- If a process is missing: `akvorado <component> http://172.16.3.101:8080`
- Check logs: `journalctl -u akvorado-<component>` or process stdout
- Config file: `/etc/akvorado/config.yaml`
- All 4 must be running for the system to work

---

### 2. SERVICE PORTS (line 108-129)

**What it does:** Verifies all required ports are listening using `ss`.

**Commands:**
- `ss -tlnp` = show TCP listening sockets
- `ss -ulnp` = show UDP listening sockets
- `-t/-u` = TCP/UDP, `-l` = listening, `-n` = numeric, `-p` = show process

**Logic:** For each port, checks both TCP and UDP. If found in either, marks as `[UP]`.

| Port  | Protocol | Service              | Purpose                          |
|-------|----------|----------------------|----------------------------------|
| 8080  | TCP      | Orchestrator API     | Config distribution to components|
| 8081  | TCP      | Inlet HTTP API       | Inlet metrics & health endpoint  |
| 8082  | TCP      | Outlet HTTP API      | Outlet metrics & health endpoint |
| 8083  | TCP      | Console Web UI       | User-facing dashboard            |
| 2055  | UDP      | NetFlow receiver     | NetFlow v5/v9/IPFIX packets      |
| 6343  | UDP      | sFlow receiver       | sFlow packets                    |
| 10179 | TCP      | BMP                  | BGP Monitoring Protocol          |
| 9092  | TCP      | Kafka broker         | Message queue                    |
| 9000  | TCP      | ClickHouse           | Database HTTP interface          |

**Troubleshooting:**
- If a port is DOWN, check corresponding process first (Section 1)
- Check firewall: `iptables -L -n` or `ufw status`
- Verify binding address in config
- NetFlow/sFlow ports (2055/6343) are UDP — routers send flow data here

---

### 3. KAFKA TOPICS & RETENTION (line 131-201)

**What it does:** Lists Kafka topics and shows data retention at 3 levels.

**Part 1 - Topic List (line 133-136):**
```bash
kafka-topics.sh --bootstrap-server localhost:9092 --list
```
Expected topics:
- `__consumer_offsets` — Kafka internal (tracks consumer positions)
- `netplan-flows-v5` — Akvorado flow data (inlet writes, outlet reads)

**Part 2 - Broker-Level Retention (line 139-161):**

Reads directly from `server.properties` config file. Checks 3 possible settings (in priority order):
1. `log.retention.ms` — milliseconds (highest priority)
2. `log.retention.minutes` — minutes
3. `log.retention.hours` — hours (most common, default: 168 = 7 days)

Your current setting: `log.retention.hours=24` = **1 day**

This is a **static config** — changing it requires editing the file and restarting Kafka.

**Part 3 - Topic-Level Retention (line 164-175):**
```bash
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name netplan-flows-v5 --describe
```
Checks for dynamic `retention.ms` override on the specific topic.
- If set: **overrides** broker-level setting for this topic only
- If not set: uses broker-level setting

**Part 4 - Effective Retention (line 178-196):**

Shows which retention actually applies, with priority:
1. Topic-level override (if exists) — wins
2. Broker-level from server.properties — fallback
3. Kafka default (7 days) — if nothing configured

**Kafka Retention Priority:**
```
Topic-level retention.ms  >  Broker log.retention.ms  >  Broker log.retention.minutes  >  Broker log.retention.hours  >  Default 7 days
```

**Change options displayed (line 199-201):**
- Topic-level (no restart): `bash akvorado-health.sh --set-kafka-retention <days>`
- Broker-level (restart required): Edit `server.properties` then restart Kafka

---

### 4. KAFKA PARTITIONS (line 203-207)

**What it does:** Shows partition details for the flow topic.

**Command:**
```bash
kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic netplan-flows-v5
```
`| head -5` limits to first 5 lines (topic header + 4 partitions).

**Key fields:**

| Field             | Your Value | Meaning                                    |
|-------------------|------------|--------------------------------------------|
| PartitionCount    | 8          | Data split across 8 partitions for parallelism |
| ReplicationFactor | 1          | No replication (single broker)             |
| Leader            | 0          | Broker 0 handles all partitions            |
| Replicas          | 0          | Which brokers hold copies                  |
| Isr               | 0          | In-Sync Replicas (should = Replicas count) |

**Troubleshooting:**
- Leader = -1 means partition is offline
- Isr < Replicas means a replica is falling behind
- Only 4 of 8 partitions shown due to `head -5`

---

### 5. KAFKA CONSUMER LAG (line 209-213)

**What it does:** Shows how far behind the outlet consumer is from latest data.

**Command:**
```bash
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group akvorado-outlet
```

**Key fields explained:**

| Field           | Meaning                                          |
|-----------------|--------------------------------------------------|
| PARTITION       | Which of the 8 partitions                        |
| CURRENT-OFFSET  | Last message the outlet has processed            |
| LOG-END-OFFSET  | Latest message written by inlet                  |
| **LAG**         | = LOG-END-OFFSET - CURRENT-OFFSET = unprocessed  |
| CONSUMER-ID     | Outlet consumer thread ID                        |
| HOST            | IP of the consumer                               |

**Health thresholds:**

| LAG Range      | Status   | Meaning                                         |
|----------------|----------|-------------------------------------------------|
| 0 - 1,000      | Healthy  | Outlet keeping up with inlet                    |
| 1,000 - 10,000 | Warning  | Outlet falling behind, monitor closely          |
| 10,000+        | Critical | Outlet can't keep up, data delay growing        |

**Your typical values:** LAG 300-700 per partition = very healthy

**Troubleshooting:**
- High lag = outlet slow writing to ClickHouse
- Check ClickHouse disk I/O and performance
- Check outlet logs for errors
- Multiple CONSUMER-IDs = outlet uses multiple threads across partitions

---

### 6. CLICKHOUSE STATUS (line 215-223)

**What it does:** Verifies ClickHouse is running and responding.

**Command:**
```bash
clickhouse-client --password "$CLICKHOUSE_PASS" -q 'SELECT version()'
```

**Logic:** If version string is returned, ClickHouse is healthy. If empty, it's not responding.

**Troubleshooting:**
- Check service: `systemctl status clickhouse-server`
- Check logs: `/var/log/clickhouse-server/clickhouse-server.log`
- Check port: `ss -tlnp | grep 9000`

---

### 7. DATABASE TTL SETTINGS (line 225-300)

**What it does:** Shows ClickHouse TTL (Time-To-Live) rule that auto-deletes old flow data.

**Step 1 (line 228-235):** Queries `system.tables` for the TTL expression:
```sql
SELECT name, engine, extractAllGroups(engine_full, 'TTL ([^,]+)')[1]
FROM system.tables WHERE database = 'akvorado' AND name = 'flows'
```

**Step 2 (line 240-251):** Extracts the TTL rule using 3 fallback methods:
1. `grep -oP '^TTL .*'` from `SHOW CREATE TABLE` output
2. `grep -oP '\\nTTL \K[^\n]+'` if TTL is inline
3. `grep -oP 'TTL \K[^S]+'` from `system.tables.engine_full`

**Step 3 (line 257-293):** Parses TTL days from 4 possible formats:

| Format                  | Example                         | How it parses     |
|-------------------------|---------------------------------|-------------------|
| `toIntervalDay(N)`      | `toIntervalDay(7)`              | N = 7 days        |
| `INTERVAL N DAY`        | `INTERVAL 7 DAY`                | N = 7 days        |
| `toIntervalSecond(N)`   | `toIntervalSecond(1296000)`     | N / 86400 = days  |
| `toIntervalHour(N)`     | `toIntervalHour(168)`           | N / 24 = days     |

**Important:** The script only parses the TTL rule line, NOT the PARTITION BY line, to avoid confusion with `toIntervalSecond(25920)` (partition interval = 7.2 hours).

**Key table settings:**
- **Partitioning:** `toIntervalSecond(25920)` = 7.2-hour partitions
- **Sort order:** `(5-min bucket, ExporterAddress, InIfName, OutIfName)`
- **ttl_only_drop_parts = 1** — Drops entire partitions efficiently (not row-by-row)

**TTL change is permanent:**
- Survives ClickHouse restart
- Old data deleted in background during merges
- Already deleted data cannot be recovered

---

### 8. DATABASE SIZE (line 302-320)

**What it does:** Shows total storage used by the akvorado database.

**Query:**
```sql
SELECT database,
    formatReadableSize(sum(bytes_on_disk)),
    formatReadableSize(sum(data_compressed_bytes)),
    formatReadableSize(sum(data_uncompressed_bytes)),
    sum(rows)
FROM system.parts WHERE database = 'akvorado' AND active
GROUP BY database
```

**Fields explained:**

| Field        | Example      | Meaning                                                    |
|--------------|--------------|------------------------------------------------------------|
| TOTAL_SIZE   | 101.83 GiB   | Actual bytes on disk (what `df` sees)                      |
| COMPRESSED   | 101.72 GiB   | Compressed data size (slightly less than total due to metadata) |
| UNCOMPRESSED | 787.74 GiB   | Original data size before ClickHouse compression           |
| TOTAL_ROWS   | 4,998,678,286| Total flow records in all active parts                     |

**Compression ratio** = UNCOMPRESSED / COMPRESSED = 787.74 / 101.72 = **~7.7x**
- ClickHouse compresses flow data to 1/8th of original size
- This is typical for network flow data with LZ4/ZSTD codecs

**Note:** TOTAL_ROWS here may differ from "Total Flows" in Section 9 because:
- `system.parts` counts rows in all parts (including not-yet-merged and pending TTL cleanup)
- Section 9 counts queryable rows from `SELECT count(*) FROM flows`

---

### 9. FLOW COUNTS (line 322-337)

**What it does:** Counts flow records across different time windows using 4 separate queries.

**Commands:**
```sql
SELECT count(*) FROM akvorado.flows                                          -- Total
SELECT count(*) FROM akvorado.flows WHERE TimeReceived > now() - INTERVAL 5 MINUTE  -- Last 5 min
SELECT count(*) FROM akvorado.flows WHERE TimeReceived > now() - INTERVAL 1 HOUR    -- Last 1 hour
SELECT count(*) FROM akvorado.flows WHERE TimeReceived > now() - INTERVAL 24 HOUR   -- Last 24 hours
```

**How to read the output:**

| Metric        | Example Value   | What it tells you                              | Your rate           |
|---------------|-----------------|-------------------------------------------------|---------------------|
| Total Flows   | 4,688,881,934   | All queryable records in database               | ~4.7 billion        |
| Last 5 min    | 4,268,890       | Recent ingestion (divide by 5 = per-minute rate)| ~854K/min           |
| Last 1 hour   | 51,818,866      | Short-term trend (divide by 60)                 | ~864K/min           |
| Last 24 hours | 1,172,913,460   | Daily volume (divide by 1440)                   | ~814K/min           |

**What to watch for:**
- All rates should be similar (~850K/min) = healthy, stable ingestion
- "Last 5 min" = 0 or very low → inlet stopped receiving flows
- "Last 5 min" much lower than "Last 1 hour" → recent drop in flows
- "Last 24 hours" much lower than expected → possible extended outage

---

### 10. DATABASE STORAGE PER DAY (line 339-358)

**What it does:** Shows daily flow counts and estimated real network traffic.

**Query:**
```sql
SELECT toDate(TimeReceived) AS date,
    count() AS flows,
    round(count() / 1000000, 2) AS millions,
    formatReadableSize(sum(toUInt64(Bytes) * toUInt64(SamplingRate))) AS traffic_vol
FROM akvorado.flows
WHERE TimeReceived > now() - INTERVAL 3 DAY
GROUP BY date ORDER BY date DESC LIMIT 3
```

**Fields explained:**

| Field       | Example        | Meaning                                              |
|-------------|----------------|------------------------------------------------------|
| DATE        | 2026-02-23     | Calendar date                                        |
| FLOWS       | 636,326,339    | Sampled flow records stored                          |
| MILLIONS    | 636.33         | Same number in millions (easier to read)             |
| TRAFFIC_VOL | 4.44 EiB       | **Estimated real network traffic**                   |

**About TRAFFIC_VOL:**
- Formula: `SUM(Bytes * SamplingRate)`
- This extrapolates sampled flows back to estimated real traffic
- Example: If router samples 1:1000, each stored flow represents 1000 real flows
- Values in **EiB (exbibytes)** are normal for high sampling rates
- This is NOT bytes stored on disk — it's estimated network throughput
- A partial day (like today) will show lower values than a full day

---

### 11. DISK STORAGE PER PARTITION (line 360-382)

**What it does:** Shows how data is physically stored in ClickHouse partitions.

**Query:**
```sql
SELECT partition, count() AS parts, sum(rows), formatReadableSize(sum(bytes_on_disk)),
    formatReadableSize(sum(data_compressed_bytes)), min(min_time), max(max_time)
FROM system.parts
WHERE database = 'akvorado' AND table = 'flows' AND active
GROUP BY partition ORDER BY partition DESC LIMIT 30
```

**Fields explained:**

| Field     | Example          | Meaning                                            |
|-----------|------------------|----------------------------------------------------|
| PARTITION | 20260223085400   | Partition name = timestamp (YYYYMMDDhhmmss)        |
| PARTS     | 12               | Number of data parts (ClickHouse merges over time) |
| ROWS      | 217,098,505      | Flow records in this partition                     |
| DISK_SIZE | 4.62 GiB         | Actual disk usage for this partition               |
| COMPRESSED| 4.61 GiB         | Compressed data size                               |
| MIN_TIME  | 2026-02-23 08:54 | Earliest flow timestamp in partition               |
| MAX_TIME  | 2026-02-23 13:07 | Latest flow timestamp in partition                 |

**Partition size:** Each partition covers ~7.2 hours (from `toIntervalSecond(25920)` in table definition).

**What to look for:**
- **Uniform sizes** (6-8 GiB each) = healthy, stable ingestion
- **Very small partition** = possible data gap or brief outage
- **Many PARTS** (>20) = ClickHouse may be behind on background merges
- Partitions older than TTL will be automatically dropped

---

### 12. FLOWS PER MINUTE (line 384-401)

**What it does:** Shows per-minute ingestion rate for the last 10 minutes.

**Query:**
```sql
SELECT toStartOfMinute(TimeReceived) AS minute, count() AS flows,
    formatReadableSize(sum(toUInt64(Bytes) * toUInt64(SamplingRate))) AS traffic_bytes
FROM akvorado.flows
WHERE TimeReceived > now() - INTERVAL 10 MINUTE
GROUP BY minute ORDER BY minute DESC
```

**How to read it:**

| Observation                    | Meaning                                   |
|--------------------------------|-------------------------------------------|
| All minutes ~863K flows        | Stable ingestion — healthy                |
| First minute much lower        | Partial minute (script ran mid-minute)    |
| Last minute much lower         | Partial minute (start of 10-min window)   |
| One minute drops to ~29K       | Data gap — brief inlet interruption       |
| One minute drops to 0          | Complete flow loss for that minute        |
| Traffic ~850 GiB/min           | Estimated real network traffic per minute |

**Your normal rate:** ~860,000 flows/minute with ~830 GiB/min estimated traffic

---

### 13. INLET METRICS (line 403-432)

**What it does:** Pulls Prometheus-format metrics from the Inlet HTTP API.

**Logic:**
1. Tries `http://127.0.0.1:8081/api/v0/inlet/metrics` first
2. Falls back to `http://127.0.0.1:8081/metrics` if empty
3. Uses 3-second connect timeout
4. Searches for flow/kafka related metrics with flexible patterns
5. Falls back to showing any `akvorado` metrics if specific patterns don't match

**Key metrics to look for:**
- `akvorado_inlet_flows_received_total` — Total flows received
- `akvorado_inlet_flows_decoded_total` — Flows successfully decoded
- `akvorado_inlet_kafka_produced_total` — Messages sent to Kafka

**Troubleshooting if empty:**
```bash
# Check what metrics are available
curl -s http://127.0.0.1:8081/api/v0/inlet/metrics | head -30
curl -s http://127.0.0.1:8081/metrics | head -30
```

---

### 14. OUTLET METRICS (line 434-462)

**What it does:** Pulls Prometheus-format metrics from the Outlet HTTP API.

**Logic:** Same as Section 13 but for outlet (port 8082).

**Key metrics to look for:**
- `akvorado_outlet_kafka_consumed_total` — Messages consumed from Kafka
- `akvorado_outlet_clickhouse_inserted_rows_total` — Rows written to ClickHouse
- `akvorado_outlet_clickhouse_batch_total` — Batches written

**Troubleshooting if empty:**
```bash
curl -s http://127.0.0.1:8082/api/v0/outlet/metrics | head -30
curl -s http://127.0.0.1:8082/metrics | head -30
```

---

### 15. BMP STATUS (line 464-476)

**What it does:** Checks if BGP Monitoring Protocol sessions are active.

**Logic:** Searches outlet metrics for BMP/routing related metrics.

**Purpose:** BMP provides BGP table data for flow enrichment:
- `DstASPath` — AS path to destination
- `DstCommunities` — BGP communities
- `Dst1stAS`, `Dst2ndAS`, `Dst3rdAS` — First hops in AS path

**Status meanings:**
| Status               | Meaning                                          |
|----------------------|--------------------------------------------------|
| Active sessions      | Routers sending BGP table info via BMP           |
| No sessions (WARN)   | BGP enrichment not available (normal if not configured) |

**To configure BMP:** Point your router's BMP client to `172.16.3.101:10179`

---

### 16. DISK USAGE (line 478-486)

**What it does:** Shows filesystem usage for data directories.

**Commands:**
```bash
df -h /var/lib/clickhouse   # ClickHouse data directory
df -h /tmp/kafka-logs        # Kafka data directory (may be on same filesystem)
```

**Thresholds:**

| Usage   | Status   | Action                                        |
|---------|----------|-----------------------------------------------|
| < 70%   | Safe     | No action needed                              |
| 70-85%  | Warning  | Plan for cleanup or reduce TTL                |
| 85-95%  | Critical | Reduce TTL immediately                        |
| > 95%   | Danger   | ClickHouse may stop accepting writes          |

**Your setup:** 442G total disk, currently ~53% used

---

### 17. MEMORY USAGE (line 488-496)

**What it does:** Shows system RAM usage from `free -h`.

**Fields explained:**

| Column     | Meaning                                                    |
|------------|------------------------------------------------------------|
| TOTAL      | Total physical RAM assigned to the VM                      |
| USED       | RAM actively used by processes                             |
| FREE       | Completely unused RAM                                      |
| BUFF/CACHE | RAM used by Linux for disk caching (reclaimable)           |
| AVAILABLE  | RAM available for new processes = FREE + reclaimable cache |

**Important: AVAILABLE is the real "free" memory, not FREE.**

Linux aggressively caches disk data (especially ClickHouse files) in RAM. This makes queries faster. If a process needs more RAM, Linux automatically releases cache.

**ESXi vs Linux memory difference:**
```
ESXi sees:  31.89 GB "consumed" = total RAM allocated to VM (all of it)
Linux sees: 5.3 GiB "used"     = only process memory (not cache)

ESXi view:  [=========================== 31.89 GB ===========================]
Linux view: [USED 5.3G][=== BUFF/CACHE 25G ===][FREE 271M]
                        ^^ reclaimable ^^
```
Both are correct — they measure different things.

---

### 18. TOP EXPORTERS (line 498-516)

**What it does:** Lists routers/switches sending the most flow data today.

**Query:**
```sql
SELECT ExporterName, count() AS flows,
    formatReadableSize(sum(toUInt64(Bytes) * toUInt64(SamplingRate))) AS traffic
FROM akvorado.flows WHERE TimeReceived > today()
GROUP BY ExporterName ORDER BY flows DESC LIMIT 10
```

**Your setup:** Single exporter `JCR10-EQIX` (router at Equinix exchange point)

**Troubleshooting:**
- Missing exporter = device stopped sending flows (check NetFlow config on router)
- Unexpected exporter = investigate unknown flow source
- ExporterName comes from SNMP/config enrichment by inlet

---

### 19. DATA RETENTION (line 518-547)

**What it does:** Calculates actual data retention span and estimates daily storage.

**Query:** Uses 4 UNION ALL queries:
1. `min(TimeReceived)` — oldest record
2. `max(TimeReceived)` — newest record
3. `dateDiff('day', min, max)` — days of data stored
4. `sum(bytes_on_disk) / days` — estimated daily disk size

**Key metrics:**

| Metric              | Meaning                                            |
|---------------------|----------------------------------------------------|
| Data Span (days)    | Actual days of data currently in database           |
| Oldest Record       | Timestamp of earliest flow                         |
| Newest Record       | Timestamp of latest flow                           |
| Estimated Daily Size| Average disk usage per day (~24-25 GiB for your setup) |

**Note:** Data Span may be less than TTL if:
- System was recently deployed
- Data was manually cleaned
- TTL hasn't had time to accumulate to the full retention period

---

### 20. TTL RECOMMENDATION (line 549-580)

**What it does:** Projects storage needs at various retention periods.

**Logic:**
1. Gets current data days: `dateDiff('day', min(TimeReceived), max(TimeReceived))`
2. Gets current disk size: `sum(bytes_on_disk) FROM system.parts`
3. Calculates daily size: `current_size / current_days`
4. Projects: `daily_size * N` for 7, 14, 30, 60, 90 days

**Decision guide for your 442G disk:**

| Retention | Est. Size | Disk %  | Safe?         |
|-----------|-----------|---------|---------------|
| 7 days    | ~172 GiB  | 39%     | Yes           |
| 14 days   | ~343 GiB  | 78%     | Yes (limit)   |
| 15 days   | ~367 GiB  | 83%     | Tight         |
| 30 days   | ~734 GiB  | 166%    | Exceeds disk  |

**Recommendation:** Keep ClickHouse TTL at 7-14 days for safe disk usage (< 80%).

---

## Quick Reference Commands

```bash
# ==================== HEALTH CHECK ====================
# Run full health check
bash /home/myomyinttun/akvorado-health.sh

# ==================== RETENTION CHANGES ====================
# Change ClickHouse TTL (permanent, auto-deletes old data)
bash akvorado-health.sh --set-clickhouse-ttl 7

# Change Kafka retention (dynamic, no restart)
bash akvorado-health.sh --set-kafka-retention 3

# Manual ClickHouse TTL change
clickhouse-client --password 'netflow2026' --query \
  "ALTER TABLE akvorado.flows MODIFY TTL TimeReceived + INTERVAL 7 DAY DELETE"

# Manual Kafka retention change (topic-level)
/opt/kafka_2.13-3.9.1/bin/kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name netplan-flows-v5 \
  --alter --add-config retention.ms=259200000

# ==================== PROCESS MANAGEMENT ====================
# Check processes
pgrep -af akvorado

# Restart a component
akvorado orchestrator /etc/akvorado/config.yaml
akvorado inlet http://172.16.3.101:8080
akvorado outlet http://172.16.3.101:8080
akvorado console http://172.16.3.101:8080

# ==================== KAFKA COMMANDS ====================
# Check Kafka lag
/opt/kafka_2.13-3.9.1/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --describe --group akvorado-outlet

# Check Kafka topic retention
/opt/kafka_2.13-3.9.1/bin/kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name netplan-flows-v5 --describe

# Check Kafka broker default retention
grep "log.retention" /opt/kafka_2.13-3.9.1/config/server.properties

# ==================== CLICKHOUSE QUERIES ====================
# Check recent flow rate
clickhouse-client --password 'netflow2026' --query "
  SELECT toStartOfMinute(TimeReceived) AS minute, count() AS flows
  FROM akvorado.flows
  WHERE TimeReceived > now() - INTERVAL 10 MINUTE
  GROUP BY minute ORDER BY minute DESC"

# Check database size
clickhouse-client --password 'netflow2026' --query "
  SELECT formatReadableSize(sum(bytes_on_disk))
  FROM system.parts
  WHERE database = 'akvorado' AND active"

# Check current TTL
clickhouse-client --password 'netflow2026' --query "
  SELECT engine_full FROM system.tables
  WHERE database = 'akvorado' AND name = 'flows'" | grep -oP 'TTL.*'

# Check data time range
clickhouse-client --password 'netflow2026' --query "
  SELECT min(TimeReceived), max(TimeReceived),
  dateDiff('day', min(TimeReceived), max(TimeReceived)) AS days
  FROM akvorado.flows"

# ==================== WEB UI ====================
# Console Web UI
# http://172.16.3.101:8083

# ==================== DEBUG METRICS ====================
# Check inlet metrics
curl -s http://127.0.0.1:8081/metrics | head -30
curl -s http://127.0.0.1:8081/api/v0/inlet/metrics | head -30

# Check outlet metrics
curl -s http://127.0.0.1:8082/metrics | head -30
curl -s http://127.0.0.1:8082/api/v0/outlet/metrics | head -30
```

---

## Alert Thresholds Summary

| Check              | Healthy              | Warning              | Critical                 |
|--------------------|----------------------|----------------------|--------------------------|
| Processes          | All 4 running        | -                    | Any missing              |
| Ports              | All UP               | -                    | Any DOWN                 |
| Kafka Lag          | < 1,000              | 1,000 - 10,000       | > 10,000                 |
| Disk Usage         | < 70%                | 70 - 85%             | > 85%                    |
| Flows/min          | ~860K (stable)       | ±20% variation       | Drop to 0                |
| Memory Available   | > 4 GiB              | 2 - 4 GiB            | < 2 GiB                  |
| ClickHouse         | Responding           | -                    | Not responding           |
| Compression Ratio  | 6-10x                | 3-6x                 | < 3x                     |
| Partition Parts    | < 15 per partition   | 15-30                | > 30 (merge backlog)     |

---

## FAQ

### Q: Why is TOTAL_ROWS in Section 8 different from Total Flows in Section 9?
**A:** Section 8 queries `system.parts` which counts rows in ALL data parts (including not-yet-merged parts and parts pending TTL cleanup). Section 9 runs `SELECT count(*)` which counts only queryable, deduplicated rows. The difference is normal and small.

### Q: Why does ESXi show 31.89 GB memory used but Linux shows only 5.3 GiB?
**A:** ESXi measures total RAM **allocated** to the VM. Linux `free` shows RAM used by **processes only**. The remaining ~25 GiB is Linux disk cache (BUFF/CACHE) which holds ClickHouse data files in memory for fast queries. Both are correct.

### Q: What does TRAFFIC_VOL in EiB mean?
**A:** `TRAFFIC_VOL = SUM(Bytes * SamplingRate)`. Your router samples flows (e.g., 1:1000), so each stored flow represents many real flows. Multiplying back gives estimated total network traffic. EiB values are expected for large networks with high sampling rates. This is NOT disk usage.

### Q: Why are the first and last minutes in Section 12 lower?
**A:** The script runs mid-minute, so the current minute is incomplete. Similarly, the minute at the start of the 10-minute window may be partial. Only full minutes between them represent accurate per-minute rates.

### Q: Is changing ClickHouse TTL permanent?
**A:** Yes. `ALTER TABLE ... MODIFY TTL` permanently changes the table definition. It survives restarts. Old data is deleted in the background during merge operations. Already deleted data cannot be recovered. You can change the TTL again later, but deleted data is gone.

### Q: What happens if Kafka retention is shorter than ClickHouse TTL?
**A:** This is fine and expected. Kafka is just a temporary buffer between inlet and outlet. Once the outlet consumes messages and writes them to ClickHouse, Kafka's copy is no longer needed. Kafka retention only needs to be long enough for the outlet to consume (with your lag of 300-700, even 1 day is more than enough).

### Q: How do I add more disk space for longer retention?
**A:** Options:
1. Add/expand the VM disk in ESXi, then extend the filesystem
2. Mount additional storage and configure ClickHouse to use multiple disks
3. Use ClickHouse storage policies for tiered storage (hot/cold)

### Q: What is the partition interval (25920 seconds / 7.2 hours)?
**A:** ClickHouse divides the `flows` table into time-based partitions of 7.2 hours each. When TTL expires, entire partitions are dropped at once (because `ttl_only_drop_parts = 1`), which is much more efficient than deleting individual rows. The 7.2-hour partition size balances between too many small partitions and too few large ones.
