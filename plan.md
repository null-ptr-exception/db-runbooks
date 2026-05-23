# db-runbooks 開發計畫

## 目前狀態（2026-05-20）

### 已完成

- **架構重構**（commit `b91f828`）：改為 `cluster-region-a` + `cluster-region-b` + `cluster-apps-minio` 三叢集架構
- **Bug 修正**（commits `7dd1a8e` → `6dd498a`）：共修復 14 個部署阻斷問題：
  1. MinIO namespace 缺少定義
  2. kube-federated-auth configmap/secret 路徑錯誤
  3. test.sh context 名稱舊格式
  4. MongoDB keyFile 缺少 initContainer
  5. keyFile 含非法字元（連字號）
  6. MongoDB RS init 使用 NodePort（pod IP 不符）→ 改用 internal DNS
  7. nginx 啟動時 DNS 解析失敗 → aqsh Service 須先建立
  8. nginx port 名稱超過 15 字元
  9. nginx `rewrite` 將 `%2F` decode 成 `/`，aqsh 路由失敗 → 改用 `map $request_uri`
  10. `scripts/test.sh` 缺少 `CLUSTER_DBS_IP` 變數
  11. `tests/common/test.sh` in-pod NodePort 錯誤（30081/30082 → 30082/30083）

### 測試結果

| 執行方式 | 結果 |
|---------|------|
| 手動部署後首次執行（修正前） | 13/18 PASS（5 FAIL） |
| 套用所有修正後手動執行 | **19/19 PASS** ✅ |
| `make single` 全新部署後手動執行 | **19/19 PASS** ✅ |

### 已知問題

#### `make single` 在 Phase 3 (test.sh) 偶爾失敗

- **現象**：deployment 完全成功，但 setup.sh 隨即呼叫 test.sh 時部分 test 失敗（exit 1）
- **根因**：aqsh deployment 報告 `rollout status` 完成後，pod 實際上還需要幾秒鐘才能穩定接受流量；test.sh 在此空窗期送出請求而失敗
- **影響**：不影響功能正確性，手動補跑 `scripts/test.sh` 均 19/19 PASS
- **建議修正**：在 setup.sh 的 Phase 3 前加入短暫等待，或在 test.sh 對第一個請求加入 retry

---

## 下一步計畫

### P0 — 修正 `make single` 偶發 timing 失敗

- [x] `scripts/setup.sh` 在 Phase 3 前改為 `http://${REGION_A_IP}:30080/healthz` retry loop（30 次、每次 2 秒）
- [x] 移除固定 sleep 依賴，改為 readiness-driven 進入 test phase

### P1 — `make multi` 複寫架構補完

- [x] MariaDB 改為 operator 管理 replication：
  - region-a `mariadb-{1,2,3}.yaml` 啟用 `spec.replication.primary`
  - region-b `mariadb-{1,2,3}.yaml.tpl` 啟用 `spec.replication.replica.externalPrimary`
  - `scripts/setup-replication.sh` 移除手動建立 replication user / binlog position 查詢
  - 若 operator 不支援 `externalPrimary`，自動 fallback：`kubectl patch` 啟用 operator replication 管理，再以 script 僅做 `CHANGE MASTER TO`
- [x] MongoDB 跨 region RS 修正：
  - `rs.reconfig({force:true})` 將 primary member host 改為 region-a NodePort
  - 再 `rs.add` region-b secondary
- [x] 新增 `MONGO_REPLICATION_MODE`（預設 `3+3`）：
  - `3+3`：mongo-1/2/3 全部加入 region-b secondary
  - `3+1`：只有 mongo-1 加入 region-b secondary

### P2 — 跨 region 驗證測試補完

- [x] 新增 `tests/integration/replication/` BATS 測試：
  - `01-mariadb-replication.bats`
  - `02-mongodb-replication.bats`
  - `03-cross-region-auth.bats`
  - `helpers.bash`
- [x] `make test-multi` 對應執行 replication 測試路徑

### P3 — 文件同步

- [x] `CLAUDE.md` Quick Start / Environment Variables 新增 `MONGO_REPLICATION_MODE`
- [x] 補充 MariaDB operator-native replication 與 MongoDB `3+3` / `3+1` 行為說明

---

## 關鍵技術說明

### 元件對應

| 元件 | Image | NodePort |
|------|-------|----------|
| nginx (proxy) | `nginx:alpine` | 30080 |
| kube-federated-auth | `ghcr.io/rophy/kube-federated-auth:3.2.0` | 30081 |
| aqsh-mariadb | `aqsh-mariadb:latest`（本機 build） | 30082 |
| aqsh-mongodb | `aqsh-mongodb:latest`（本機 build） | 30083 |
| MinIO API | `minio/minio:latest` | 30090 |
| MinIO Console | `minio/minio:latest` | 30091 |
| MongoDB stream | TCP stream via nginx | 30092–30097 |

### 重要 URL 格式

- aqsh task 提交：`POST /tasks/common%2Fhello`（`%2F` 不可 decode，aqsh 路由為單一 segment）
- nginx 透過 `map $request_uri` 保留原始編碼後轉發

### Git Branch

`feature/multi-region-arch`（最新 commit：`6dd498a`）
