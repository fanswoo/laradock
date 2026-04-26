# PowerSync Production 設定

本文件記錄 production 環境（Google Cloud SQL + GCP）部署 PowerSync 所需的設定。

本地開發環境的設定請見：
- [`config.yaml`](./config.yaml) — PowerSync service 主設定
- [`sync-streams.yaml`](./sync-streams.yaml) — 同步規則（與環境無關，production 共用）
- [`/var/laradock/mysql/my.cnf`](../mysql/my.cnf) — 本地 MySQL binlog 設定

---

## 1. Cloud SQL (MySQL) 設定

Cloud SQL 不能改 `my.cnf`，必須透過 Console / `gcloud` 設定。

### 1-1. 前置確認

執行任何變更前先確認：

- 已有完整 backup 並驗證可還原
- 已安排 maintenance window（會 restart 實例約 1–2 分鐘）

> Cloud SQL MySQL 8 的 `gtid_mode` 預設就是 `ON`（且不開放修改），所以「啟用 GTID 對 Read Replica 的衝擊」這類顧慮在 Cloud SQL 不存在——本文件不需要 GTID rolling upgrade 流程。

### 1-2. 啟用 Point-in-time Recovery (PITR)

Cloud SQL 的 binary log 由 PITR 開關控制，**不是**「Automated backups」開關。PowerSync 透過 binlog 追蹤資料變更，必須開 PITR。

**Console 路徑**：實例 → Edit → Data Protection

| 設定 | 值 |
|---|---|
| Automated backups | ✅ 勾選 |
| Enable point-in-time recovery | ✅ 勾選 |
| Backup retention | 7 天以上 |
| Transaction log retention | **7 天** |

> **Transaction log retention 的意義**：這控制 binlog 在 Cloud SQL 端保留多久。**只影響 PowerSync service 的 downtime tolerance**，不影響 client 離線時間（client 離線後重連時是從 PowerSync 自己的 MongoDB bucket 抓資料，不直接讀 binlog）。7 天是業界 default。

### 1-3. 加 Database Flags

**Console 路徑**：實例 → Edit → Flags and parameters → ADD FLAG

只需要設 **1 個** flag：

| Flag name | Value | 說明 |
|---|---|---|
| `binlog_row_image` | `FULL` | PowerSync 需完整 row image 才能正確 replicate UPDATE |

**不需要設的 flag**（在 Cloud SQL 上 dropdown 找不到 / 不開放修改是正常的，**不是 bug**）：

- ❌ `gtid_mode`：Cloud SQL MySQL 8 **預設就是 `ON`**，reserved 不開放修改 → 用步驟 1-5 驗證
- ❌ `enforce_gtid_consistency`：Cloud SQL MySQL 8 **預設就是 `ON`**，reserved 不開放修改 → 用步驟 1-5 驗證
- ❌ `binlog_expire_logs_seconds`：由步驟 1-2 的 Transaction log retention 控制
- ❌ `binlog_format`：Cloud SQL MySQL 8 預設 `ROW`，reserved
- ❌ `log_bin`：由步驟 1-2 的 PITR 開關控制
- ❌ `server-id`：Cloud SQL 自動管理

### 1-4. Save & Restart

頁面底部 **SAVE AND RESTART**。約 1–2 分鐘 downtime。

### 1-5. 驗證

Cloud SQL Studio 或 mysql client 執行：

```sql
SHOW VARIABLES LIKE 'log_bin';                     -- ON   (由 PITR 控制)
SHOW VARIABLES LIKE 'binlog_format';               -- ROW  (Cloud SQL 預設)
SHOW VARIABLES LIKE 'binlog_row_image';            -- FULL (步驟 1-3 設的)
SHOW VARIABLES LIKE 'gtid_mode';                   -- ON   (Cloud SQL 預設)
SHOW VARIABLES LIKE 'enforce_gtid_consistency';    -- ON   (Cloud SQL 預設)
```

5 項全部符合 → 通過。

> 如果 `gtid_mode` 或 `enforce_gtid_consistency` 不是 ON（極少見），請聯絡 Google Cloud Support，可能是某些舊建立的實例例外狀況。

### 1-6. 建立 PowerSync 專用 MySQL 使用者

用 `cloudsqlsuperuser` 角色（Cloud SQL admin user）連入後執行：

```sql
CREATE USER 'powersync_user'@'%' IDENTIFIED BY '<從 Secret Manager 取得>' REQUIRE SSL;
GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'powersync_user'@'%';
FLUSH PRIVILEGES;
```

驗證：
```sql
SHOW GRANTS FOR 'powersync_user'@'%';
```

> 密碼**不要**寫進 git；存 Google Secret Manager，PowerSync service 啟動時注入。

### 1-8. 副作用提醒

- 舊 mysqldump 備份還原時需加 `--set-gtid-purged=OFF`，否則 GTID set 衝突會被拒絕匯入。Console 的「還原」按鈕走 internal snapshot，不受影響（Cloud SQL 預設 GTID ON，本來就要注意這點，不是 PowerSync 帶來的新問題）
- 開啟 PITR 後 binlog 會持續累積，**Cloud SQL 儲存成本會增加**（依寫入量，通常每天數百 MB 到數 GB）

---

## 2. PowerSync Service 部署（待補）

> 待規劃確認後補上。候選方案：
> - GCE VM + docker-compose（最接近本地 laradock 操作）
> - GKE Autopilot（後續擴展彈性大）
>
> 兩者都需要：
> - Cloud SQL Auth Proxy（連 MySQL 用 Private IP）
> - MongoDB Atlas（建議；自管 RS 維運成本高）
> - GCLB + Managed SSL（對外 HTTPS endpoint）
> - Secret Manager（注入 `PS_MYSQL_URI` / `PS_MONGO_URI` / JWT key）

---

## 3. PowerSync `config.yaml` Production 差異

對照 [`config.yaml`](./config.yaml)，production 主要改 3 處：

```yaml
replication:
  connections:
    - type: mysql
      uri: !env PS_MYSQL_URI
      # production: mysql://powersync_user:<pwd>@cloudsql-proxy:3306/<db>?ssl=true

storage:
  type: mongodb
  uri: !env PS_MONGO_URI
  # production: Atlas mongodb+srv URI；不要再寫死 ?replicaSet=rs0
  # （Atlas 的 SRV record 自動帶 replica set 名稱）

client_auth:
  jwks_uri: "https://<production-domain>/api/message/powersync/.well-known/jwks.json"
  audience:
    - "https://<production-domain>"
```

`sync-streams.yaml` **不需要改** — sync rules 是純資料層邏輯，跟環境無關。
