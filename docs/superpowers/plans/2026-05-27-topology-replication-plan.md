# Plan: Topology-Aware DB Replication & Test Framework

**Date**: 2026-05-27  
**Branch**: feat/dual-cluster-multi-mode (follow-up work)  
**Context**: 延伸現有 dual-cluster 基礎設施，實作真正的 MongoDB Replica Set 與 MariaDB 複寫，並重構測試框架使其可宣告所需 infra topology。

---

## 背景：現有 CI 問題分析

### 症狀

CI 測試每次失敗的位置不同，主要兩種錯誤：

**Failure 1 — `setup_file failed`（deploy_mongodb_dual 失敗）**
```
statefulset.apps/mongodb created
Waiting for MongoDB in mongo-1 to be ready...
Waiting for statefulset spec update to be observed...
Rollout status timed out, falling back to wait pod...
error: no matching resources found
No resources found in mongo-1 namespace.
```

**Failure 2 — `restart task completes on cluster-a` 失敗**
```json
{"last_error":"script exited with code 1","status":"failed"}
```

### 根本原因

環境：自架 GitHub Actions Runner，**2 CPU cores，64 GB RAM**。  
記憶體充足，問題在 CPU。

**Dual mode 下同時運行 4 個 Kind cluster：**
- `cluster-auth`, `cluster-dbs-a`, `cluster-dbs-b`, `cluster-apps`  
- 每個 cluster ≈ 8–10 個 system processes（apiserver、etcd、controller-manager、scheduler、coredns…）  
- 加上 app pods（aqsh、kube-auth-proxy、test-client…）  
- 總計 **~50+ processes 競爭 2 CPU cores**

**Failure 1 機制**：
1. `kube-controller-manager` on cluster-dbs-b 被 cluster-dbs-a 的大量部署工作搶走 CPU
2. `kubectl rollout status` 一直印 `Waiting for statefulset spec update to be observed...`（代表 controller 從未處理新 StatefulSet，`observedGeneration` 停在 0）
3. 240s 後 timeout → fallback `kubectl wait pod -l app=mongodb`
4. **Pod 根本不存在**（controller 還沒建立），`kubectl wait` 遇到空 selector → 立即 return `error: no matching resources found`

**Failure 2 機制**：  
`k8s_sts_restart` 執行 `kubectl rollout status --timeout=300s`，MongoDB pod 在 2-core 環境下重啟加初始化超過 300s → 返回 code 1 → task 標記失敗。

**次要問題**：
- `rollout status ... 2>/dev/null` 吞掉所有錯誤訊息，CI log 完全看不出真正原因
- `_wait_for_ns_deleted` 只等 60s，namespace Terminating 清理太慢時提早放棄
- **Namespace Terminating Race**：`teardown_file` 刪除 namespace（非同步，進入 Terminating），下一個 test file 的 `setup_file` 立刻嘗試在同 namespace 建立新資源，競爭

### 現有測試的問題結構

```
setup_suite   → 每個 test file setup_file → @test → teardown_file
（穩定）          （flaky：每次 deploy DB）   （正常）  （觸發 Terminating race）

mongo-1 被建立、刪除、建立、刪除了 3 次：
  replication.bats setup_file: deploy mongo-1  ← FLAKY
  replication.bats teardown_file: delete mongo-1 → Terminating...
  restart.bats     setup_file: deploy mongo-1  ← FLAKY（Terminating race）
  restart.bats     teardown_file: delete mongo-1 → Terminating...
  sanity_check.bats setup_file: deploy mongo-1 ← FLAKY（Terminating race）
```

### 現有測試實際在測什麼

`replication.bats`（名稱具誤導性）實際測的是**基礎設施連線**，不是資料複寫：

| Test | 測試內容 |
|---|---|
| aqsh on cluster-a/b is reachable | HTTP 202 |
| peer-db-proxy TCP tunnel | `nc -zv peer-db-proxy 27017` |
| restart task completes | 呼叫 aqsh restart 任務並等完成 |
| ❌ 缺失 | 實際 MongoDB RS 建立、寫入、跨 cluster 同步 |

目前 `mongo-1` 是 **standalone 單節點**（`replicas: 1`，無 `--replSet` 參數），並無真正複寫功能。

---

## 目標架構

### MongoDB Replica Set（3 成員）

```
cluster-dbs-a                          cluster-dbs-b
┌──────────────────────────────┐       ┌──────────────────────────────┐
│  namespace: mongo-1          │       │  namespace: mongo-1          │
│                              │       │                              │
│  mongodb-0  ─── PRIMARY      │       │  mongodb-0  ─── SECONDARY    │
│  NodePort: 30090             │       │  NodePort: 30090             │
│                              │       │                              │
│  mongodb-1  ─── SECONDARY    │       └──────────────────────────────┘
│  NodePort: 30094 (NEW)       │
└──────────────────────────────┘

RS 成員地址（使用 Docker bridge IP，所有 pod 可互達）：
  Member 0: CLUSTER_DBS_A_IP:30090  (priority: 2 → 優先當 primary)
  Member 1: CLUSTER_DBS_A_IP:30094  (priority: 1)
  Member 2: CLUSTER_DBS_B_IP:30090  (priority: 1)
```

### MariaDB Replication（3 節點，GTID-based）

```
cluster-dbs-a                          cluster-dbs-b
┌──────────────────────────────┐       ┌──────────────────────────────┐
│  namespace: mariadb-1        │       │  namespace: mariadb-1        │
│                              │       │                              │
│  mariadb-0  ─── PRIMARY      │       │  mariadb-0  ─── REPLICA      │
│  NodePort: 30091             │       │  NodePort: 30091             │
│  server-id: 1                │       │  server-id: 3                │
│                              │       │                              │
│  mariadb-1  ─── REPLICA      │       └──────────────────────────────┘
│  NodePort: 30095 (NEW)       │
│  server-id: 2                │
└──────────────────────────────┘

複寫方向：
  mariadb-0 (cluster-a) → PRIMARY（啟用 binlog）
  mariadb-1 (cluster-a) → CHANGE MASTER TO mariadb-0.mariadb.mariadb-1.svc（內部 DNS）
  mariadb-0 (cluster-b) → CHANGE MASTER TO CLUSTER_DBS_A_IP:30091（跨 cluster NodePort）
```

### Topology 宣告系統

```
環境變數（寫入 .env）
  MONGO_TOPOLOGY="2+1"       ← A+B: cluster-a 幾個 + cluster-b 幾個
  MARIADB_TOPOLOGY="2+1"

支援的值：
  "standalone"  ─ 1 pod，無 RS / 無複寫（DB_MODE=single）
  "3+0"         ─ 3 pods 全在 cluster-a，組成 RS（DB_MODE=single）
  "2+1"         ─ cluster-a: 2，cluster-b: 1（DB_MODE=dual）
  "1+2"         ─ cluster-a: 1，cluster-b: 2（DB_MODE=dual）

規則：
  - cluster-a 的 pod-0 永遠是 PRIMARY（MongoDB priority 最高 / MariaDB 設為 primary）
  - 最多 3 個成員
  - B > 0 時必須 DB_MODE=dual
```

### 新測試執行流程（解決 CPU 競爭）

```
setup_suite.bash（全局執行一次）
  ├── create clusters（setup-clusters.sh）
  ├── deploy infra（deploy-infra.sh）
  ├── kind load docker-image mongo:7（兩個 cluster）  ← 預載，避免 pull 競爭
  ├── kind load docker-image mariadb:10.6（兩個 cluster）
  ├── deploy_mongodb_with_topology "mongo-1" "$MONGO_TOPOLOGY"
  │     ├── 部署 StatefulSet（依 topology 決定 replicas 數）
  │     ├── 等 all pods Ready（timeout 可給 900s，不影響測試速度）
  │     └── 呼叫 rs-init aqsh task（若 topology != standalone）
  └── deploy_mariadb_with_topology "mariadb-1" "$MARIADB_TOPOLOGY"
        ├── 部署 StatefulSet
        ├── 等 all pods Ready
        └── 呼叫 setup-replication aqsh task（若 topology != standalone）

各 .bats 的 setup_file（輕量，毫秒級）
  └── skip_unless_mongo_topology "$REQUIRED_MONGO_TOPOLOGY"
  └── assert_mongodb_ready "mongo-1"（kubectl get，快速確認）

各 .bats 無 teardown_file  ← 不刪 namespace，避免 Terminating race

teardown_suite（全局清理一次）
  └── teardown.sh（刪掉所有 cluster）
```

---

## Port 對照表（完整）

| Service | Cluster | Port | Mode | 狀態 |
|---|---|---|---|---|
| kube-federated-auth | cluster-auth | 30080 | All | 現有 |
| aqsh-mariadb | cluster-dbs / cluster-dbs-a/b | 30081 | All | 現有 |
| aqsh-mongodb | cluster-dbs / cluster-dbs-a/b | 30082 | All | 現有 |
| nginx HTTP gateway | cluster-dbs | 30083 | ENABLE_MINIO=true | 現有 |
| **mongodb-0-nodeport** | **cluster-dbs-a/b 或 cluster-dbs** | **30090** | **All** | **現有（改為 per-pod selector）** |
| **mariadb-0-nodeport** | **cluster-dbs-a/b 或 cluster-dbs** | **30091** | **All** | **現有（改為 per-pod selector）** |
| MinIO API | cluster-minio | 30092 | ENABLE_MINIO=true | 現有 |
| MinIO Console | cluster-minio | 30093 | ENABLE_MINIO=true | 現有 |
| **mongodb-1-nodeport** | **cluster-dbs-a 或 cluster-dbs** | **30094** | **topology 需要 pod-1** | **NEW** |
| **mariadb-1-nodeport** | **cluster-dbs-a 或 cluster-dbs** | **30095** | **topology 需要 pod-1** | **NEW** |
| **mongodb-2-nodeport** | **cluster-dbs** | **30096** | **topology=3+0** | **NEW** |
| **mariadb-2-nodeport** | **cluster-dbs** | **30097** | **topology=3+0** | **NEW** |

---

## 實作計畫（分 Phase）

### Phase 1：修復現有 CI 不穩定（立即）

目標：讓現有 PR 8 的測試通過，不引入新功能。

**1.1 修 `deploy_mongodb` fallback 邏輯**
- 檔案：`tests/test_helper/common_setup.bash`
- 問題：rollout timeout 後，`kubectl wait pod` 遇到空 selector 立即 fail
- 修法：先等 pod 存在（loop 確認），再等 pod ready
- 同時拿掉 `2>/dev/null`，保留錯誤訊息到 CI log

```bash
# 舊（壞）
kubectl wait pod -l app=mongodb --for=condition=Ready --timeout=60s

# 新（先等 pod 存在）
local wait_elapsed=0
while (( wait_elapsed < 120 )); do
  if kubectl --context "$ctx" -n "$namespace" get pod \
      -l app=mongodb --no-headers 2>/dev/null | grep -q .; then
    break
  fi
  sleep 5; wait_elapsed=$((wait_elapsed + 5))
done
kubectl --context "$ctx" -n "$namespace" wait pod \
  -l app=mongodb --for=condition=Ready --timeout=120s
```

**1.2 增加 `_wait_for_ns_deleted` timeout**
- 60s → 180s（2-core 機器 namespace 清理較慢）

**1.3 增加 rollout status timeout**
- `--timeout=240s` → `--timeout=480s`（controller-manager 在 2-core 下可能很慢）

**1.4 預載 Docker image**
- 在 `scripts/deploy-infra.sh` 或 `scripts/setup-clusters.sh` 加入 `kind load docker-image`
- 目標 images：`mongo:7`、`mariadb:10.6`（雙 cluster 各一次）
- 消除 image pull 在 2-core 下競爭 CPU/網路的問題

---

### Phase 2：重構測試框架（中期）

目標：實作 topology 宣告系統，讓 setup_suite 統一部署、test file 輕量確認。

**2.1 setup_suite.bash 擴充**
- 加入 `deploy_mongodb_with_topology` 和 `deploy_mariadb_with_topology` 呼叫
- 讀取 `MONGO_TOPOLOGY`（預設 `standalone`）和 `MARIADB_TOPOLOGY`

**2.2 common_setup.bash 新增 helpers**

```bash
# 確認 DB ready（快速，不重建）
assert_mongodb_ready() {
  local namespace="$1"
  local ctx="${2:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  kubectl --context "$ctx" -n "$namespace" wait pod \
    -l app=mongodb --for=condition=Ready --timeout=30s
}

# Topology guard（不符合就 skip）
skip_unless_mongo_topology() {
  local required="$1"
  local current="${MONGO_TOPOLOGY:-standalone}"
  if [[ "$required" != "any" && "$current" != "$required" ]]; then
    skip "Requires MONGO_TOPOLOGY=${required}, current=${current}"
  fi
}

# deploy_mongodb_with_topology（取代 deploy_mongodb / deploy_mongodb_dual）
deploy_mongodb_with_topology() {
  local namespace="$1" topology="${2:-standalone}"
  # 解析 A+B
  local members_a members_b
  members_a="${topology%%+*}"
  members_b="${topology##*+}"
  # 依 topology 部署，呼叫 rs-init task
  ...
}
```

**2.3 各 .bats 改為宣告式**

```bash
# tests/mongodb/replication.bats（改後）
REQUIRED_MONGO_TOPOLOGY="2+1"

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  skip_unless_mongo_topology "$REQUIRED_MONGO_TOPOLOGY"
  assert_mongodb_ready "mongo-1"   # 快速確認，不重建
}

# 無 teardown_file
```

**2.4 setup-clusters.sh 寫入 topology 到 .env**

```bash
# 在 .env 生成時加入（依 DB_MODE 給預設值）
MONGO_TOPOLOGY="${MONGO_TOPOLOGY:-$(  [[ "$DB_MODE" == "dual" ]] && echo "2+1" || echo "standalone" )}"
MARIADB_TOPOLOGY="${MARIADB_TOPOLOGY:-$(  [[ "$DB_MODE" == "dual" ]] && echo "2+1" || echo "standalone" )}"
```

---

### Phase 3：真正的 MongoDB RS 實作（主要功能）

**3.1 Per-pod NodePort Services**

現有 `nodeport-service.yaml` 使用 `selector: app: mongodb`，會 load-balance 到所有 pods。  
需改為每個 pod 各自的 Service：

```yaml
# k8s/cluster-dbs/mongodb/nodeport-pod0.yaml
apiVersion: v1
kind: Service
metadata:
  name: mongodb-0-nodeport
spec:
  type: NodePort
  selector:
    statefulset.kubernetes.io/pod-name: mongodb-0  # K8s 自動加在 StatefulSet pods 上
  ports:
    - port: 27017
      targetPort: 27017
      nodePort: 30090

---
# k8s/cluster-dbs/mongodb/nodeport-pod1.yaml
# nodePort: 30094（只在 topology 需要 pod-1 時部署）

---
# k8s/cluster-dbs/mongodb/nodeport-pod2.yaml
# nodePort: 30096（只在 topology=3+0 時部署）
```

**3.2 MongoDB StatefulSet 支援 RS 模式**

新增 `--replSet rs0 --bind_ip_all` 啟動參數。由於 `standalone` 模式不需要 RS，  
使用兩個 YAML 版本（或 template）：

```yaml
# mongo-1-rs.yaml（RS 模式）
spec:
  replicas: MONGO_REPLICAS  # 由 deploy 時 envsubst 填入
  template:
    spec:
      containers:
        - name: mongodb
          args: ["--replSet", "rs0", "--bind_ip_all"]
```

- cluster-a（topology `2+1`）：`replicas: 2`
- cluster-b（topology `2+1`）：`replicas: 1`
- cluster-dbs（topology `3+0`）：`replicas: 3`
- cluster-dbs（topology `standalone`）：`replicas: 1`，無 args

**3.3 新增 aqsh task：`mongodb/rs-init.sh`**

```yaml
# tasks-mongodb.yaml 新增
rs-init:
  script: mongodb/rs-init.sh
  description: "Initialize MongoDB Replica Set across clusters"
  timeout: 10m
  input:
    - name: namespace
      env: DB_NAMESPACE
      pattern: '^mongo-[0-9]+$'
    - name: topology
      env: RS_TOPOLOGY       # "2+1", "1+2", "3+0"
    - name: cluster_a_ip
      env: CLUSTER_A_IP
    - name: cluster_b_ip
      env: CLUSTER_B_IP
      required: false        # standalone / 3+0 時不需要
```

**`aqsh-tasks/scripts/mongodb/rs-init.sh` 邏輯：**

```
1. 依 topology 計算 member 地址：
   topology "2+1"：
     members[0] = CLUSTER_A_IP:30090  (priority 2)
     members[1] = CLUSTER_A_IP:30094  (priority 1)
     members[2] = CLUSTER_B_IP:30090  (priority 1)
   topology "3+0"：
     members[0] = CLUSTER_A_IP:30090  (priority 2)
     members[1] = CLUSTER_A_IP:30094  (priority 1)
     members[2] = CLUSTER_A_IP:30096  (priority 1)

2. 連接 mongodb-0.mongodb.{namespace}.svc（in-cluster DNS）

3. 執行 rs.initiate({ _id: "rs0", members: [...] })

4. 等待 primary 選出（polling rs.status().ok == 1，timeout 120s）

5. 驗證：rs.status().members 全部 health=1

6. 輸出 JSON：{rs_name, primary, members_count, topology}
```

**幂等性**：若 RS 已初始化（`rs.status()` 回傳 ok），跳過 initiate 直接確認狀態。

---

### Phase 4：真正的 MariaDB Replication 實作（主要功能）

**4.1 MariaDB Native StatefulSet（棄用 operator 路徑）**

跨 cluster 複寫需要精確控制 server-id 和 binlog 設定，Operator 不適合此場景。  
固定使用 `USE_MARIADB_OPERATOR=false` 路徑。

**server-id 動態設定**（每個 pod 不同）：

```yaml
# statefulset.yaml
containers:
  - name: mariadb
    command: ["/bin/bash", "-c"]
    args:
      - |
        POD_ORDINAL="${HOSTNAME##*-}"
        SERVER_ID=$(( BASE_SERVER_ID + POD_ORDINAL ))
        exec mariadbd \
          --server-id="${SERVER_ID}" \
          --log-bin=mysql-bin \
          --binlog-format=ROW \
          --gtid-strict-mode=ON \
          --log-slave-updates=ON \
          "$@"
    env:
      - name: BASE_SERVER_ID  # cluster-a: 1, cluster-b: 10
        value: "1"
```

- cluster-a pod-0：server-id = 1（PRIMARY）
- cluster-a pod-1：server-id = 2（REPLICA）
- cluster-b pod-0：server-id = 10（REPLICA，避免與 cluster-a 衝突）

**4.2 Per-pod NodePort Services**

同 MongoDB，使用 `statefulset.kubernetes.io/pod-name` selector：
- NodePort 30091（mariadb-0，所有 cluster）
- NodePort 30095（mariadb-1，cluster-a 或 cluster-dbs）
- NodePort 30097（mariadb-2，cluster-dbs，topology=3+0）

**4.3 新增 aqsh task：`mariadb/setup-replication.sh`**

```yaml
# tasks-mariadb.yaml 新增
setup-replication:
  script: mariadb/setup-replication.sh
  description: "Configure GTID-based MariaDB replication"
  timeout: 10m
  input:
    - name: namespace
      env: DB_NAMESPACE
      pattern: '^mariadb-[0-9]+$'
    - name: topology
      env: REPL_TOPOLOGY
    - name: cluster_a_ip
      env: CLUSTER_A_IP
    - name: cluster_b_ip
      env: CLUSTER_B_IP
      required: false
```

**`aqsh-tasks/scripts/mariadb/setup-replication.sh` 邏輯：**

```
1. 確認 primary（mariadb-0 on cluster-a）已啟動並啟用 GTID

2. 在 primary 建立複寫用帳號：
   CREATE USER 'repl'@'%' IDENTIFIED BY '...';
   GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';

3. 對每個 REPLICA 執行（依 topology 決定幾個）：
   CHANGE MASTER TO
     MASTER_HOST = <primary_host>,  # 內部 DNS 或 NodePort IP
     MASTER_PORT = <port>,
     MASTER_USER = 'repl',
     MASTER_PASSWORD = '...',
     MASTER_USE_GTID = slave_pos;
   START SLAVE;

4. 驗證：SHOW SLAVE STATUS → Slave_IO_Running=Yes, Slave_SQL_Running=Yes

5. 輸出 JSON：{primary, replicas, topology, gtid_mode}
```

**幂等性**：若 `SHOW SLAVE STATUS` 已有正在運行的複寫，跳過設定。

---

### Phase 5：測試擴充

**5.1 replication.bats（真正的資料複寫測試）**

```bash
REQUIRED_MONGO_TOPOLOGY="2+1"

@test "data written on primary is readable on secondary" {
  # 透過 aqsh task 在 mongo-1 primary 寫入資料
  # 等待複寫（最多 30s）
  # 在 cluster-b secondary 讀取確認
}

@test "rs status shows all members healthy" {
  # 呼叫 sanity-check task
  # 驗證 TASK_RESPONSE.result.members_healthy == 3
}
```

**5.2 新增 rs_init.bats**

```bash
REQUIRED_MONGO_TOPOLOGY="any-rs"  # 任何 RS topology（非 standalone）

@test "rs-init task initializes replica set" { ... }
@test "rs-init is idempotent" { ... }  # 呼叫兩次，第二次應成功不出錯
```

**5.3 新增 mariadb/replication.bats**

```bash
REQUIRED_MARIADB_TOPOLOGY="2+1"

@test "data written on primary is readable on replica" { ... }
@test "replica lag is within acceptable bounds" { ... }
```

---

## 受影響檔案清單

### 修改（Modify）

| 檔案 | 改動內容 |
|---|---|
| `tests/test_helper/common_setup.bash` | 新增 3 helpers；修 fallback；增加 timeout；拿掉 `2>/dev/null` |
| `tests/setup_suite.bash` | 加 image preload + deploy_with_topology 呼叫 |
| `tests/mongodb/replication.bats` | 改宣告式，加真實複寫測試，刪 teardown_file |
| `tests/mongodb/restart.bats` | 改宣告式，刪 teardown_file |
| `tests/mongodb/sanity_check.bats` | 改宣告式，刪 teardown_file |
| `tests/mariadb/replication.bats` | 改宣告式，加真實複寫測試，刪 teardown_file |
| `scripts/setup-clusters.sh` | 寫 MONGO_TOPOLOGY / MARIADB_TOPOLOGY 到 .env |
| `scripts/deploy.sh` | 依 topology 決定 test 執行範圍 |
| `k8s/cluster-dbs/mongodb/nodeport-service.yaml` | 改為 per-pod（pod-0 用）|
| `k8s/cluster-dbs/mariadb/nodeport-service.yaml` | 改為 per-pod（pod-0 用）|
| `k8s/cluster-dbs/mariadb/statefulset.yaml` | 加 server-id 動態設定、binlog、GTID |
| `aqsh-tasks/tasks-mongodb.yaml` | 新增 rs-init task 定義 |
| `aqsh-tasks/tasks-mariadb.yaml` | 新增 setup-replication task 定義 |
| `CLAUDE.md` | 新增 port 30094-30097 說明 |

### 新增（Create）

| 檔案 | 說明 |
|---|---|
| `k8s/cluster-dbs/mongodb/nodeport-pod1.yaml` | mongodb-1 per-pod NodePort 30094 |
| `k8s/cluster-dbs/mongodb/nodeport-pod2.yaml` | mongodb-2 per-pod NodePort 30096 |
| `k8s/cluster-dbs/mongodb/mongo-1-rs.yaml` | RS 模式 StatefulSet template（含 `--replSet rs0`）|
| `k8s/cluster-dbs/mariadb/nodeport-pod1.yaml` | mariadb-1 per-pod NodePort 30095 |
| `k8s/cluster-dbs/mariadb/nodeport-pod2.yaml` | mariadb-2 per-pod NodePort 30097 |
| `aqsh-tasks/scripts/mongodb/rs-init.sh` | RS 初始化 aqsh 腳本 |
| `aqsh-tasks/scripts/mariadb/setup-replication.sh` | MariaDB 複寫設定 aqsh 腳本 |
| `tests/mongodb/rs_init.bats` | rs-init task 測試 |
| `tests/mariadb/replication.bats` | MariaDB 複寫測試（現有為空）|

---

## 資源競爭影響評估

| 面向 | Phase 1（修 fallback）| Phase 2（setup_suite 統一部署）| Phase 3-4（RS + Replication）|
|---|---|---|---|
| deploy 次數 | 3 次（不變）| **1 次** | 1 次 |
| 單次 timeout 預算 | 240s → 480s | **可給 900s** | 900s |
| Terminating race | 仍存在 | **完全消失** | 完全消失 |
| 同時運行 pods 數 | 1 MongoDB | 1 MongoDB | **3 MongoDB + 3 MariaDB** |
| 測試執行時 CPU 壓力 | 低 | 低 | 低（idle pods 幾乎不耗 CPU）|
| 主要風險 | 同上問題 | setup_suite 可能慢 | RS election + replication setup 可能慢 |
| 緩解方式 | 增加 timeout | `kind load docker-image` 預載 | 序列部署（MongoDB → rs-init → MariaDB → setup-replication）|

---

## 執行優先順序

```
第一步（本 PR 8 合併前）
  └── Phase 1：修 fallback + 增加 timeout + 預載 image → CI 穩定

第二步（新 PR）
  └── Phase 2：setup_suite 統一部署 + declarative topology → 測試架構改善

第三步（新 PR）
  ├── Phase 3：MongoDB RS（rs-init task + per-pod NodePort + RS StatefulSet）
  └── Phase 4：MariaDB replication（setup-replication task + GTID StatefulSet）

第四步（持續迭代）
  └── Phase 5：真實複寫測試 + sanity-check 驗 RS 健康
```

---

## 開放問題

1. **rs-init 執行方式**：透過 aqsh task API（需要 auth token，與其他任務一致）還是直接 `kubectl exec mongosh`（更簡單，繞過 aqsh 框架）？建議前者，保持一致性。

2. **MariaDB topology `3+0` 的 BASE_SERVER_ID**：同一 cluster 內 server-id 用 1/2/3，cross-cluster 用 1-10 段位避免衝突。

3. **MongoDB `standalone` 模式的 `mongo-1.yaml`**：繼續不加 `--replSet`，sanity-check 中 `STANDALONE_OK=1` 跳過 RS 相關檢查。
