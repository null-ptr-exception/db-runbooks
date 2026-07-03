# MongoDB Reconfig 安全閘道 — 設計 v2(已定案並實作)

v1(原始草案)是以獨立 REST 微服務的世界觀寫的;v2 把它落到本 repo 的實際
架構(aqsh 無狀態 bash task + tasks-mongodb.yaml),並修正 v1 的幾個設計
問題。實作見 `aqsh-tasks/lib/mongodb-reconfig.sh` 與
`aqsh-tasks/scripts/mongodb/reconfig/`;使用文件見
`docs/mongodb/reconfig.md`;e2e 見 `tests/mongodb/reconfig.bats`。

## 相對 v1 的關鍵決策

| # | v1 | v2(定案) | 理由 |
|---|---|---|---|
| 1 | 呼叫者送完整 rs.conf JSON | **intent ops**(add_member / remove_member / set_votes / set_priority / set_hidden),server 讀現況自己組 config | gateway 要防的錯誤(version 錯、欄位漏抄、_id 撞號)大多來自手工組 config;改成意圖後這類錯誤在結構上不可能發生。configVersion 遞增檢查、_id 檢查整類消失 |
| 2 | approval_token + 10 分鐘 TTL,需儲存 | **plan_hash = hash(ns, sts, ops, configVersion, term)**,無狀態 CAS | TTL 是「世界可能變了」的代理指標;對 live version/term 做 CAS 是直接檢查。零儲存、零過期邏輯、保證更強(10 分鐘內被人動過 TTL 抓不到,CAS 抓得到) |
| 3 | 提醒使用者「一次改太多要拆步驟」(warn) | **一個 op 一次 rs.reconfig**,自動拆 | MongoDB 4.4+ safe reconfig 本來就限制單次一個投票變更;自動拆掉這個 warn 的存在必要 |
| 4 | 每個 pod 掛 sidecar/exporter 供 discovery | 沿用 kubectl exec(aqsh 所有 task 既有模式) | 對本架構是過度設計;exec RBAC 已存在 |
| 5 | 獨立 state API + NORMAL/MAINTENANCE/FREEZE/DR_ACTIVE 四態 | FREEZE = STS annotation(`reconfig/freeze` task);DR_ACTIVE 跟著動作走:force-dr confirm 設、成功的 gated apply 清 | MAINTENANCE 的唯一作用(放寬 warn)與 override_reason 重複;狀態跟動作綁定就不會有「宣告了 DR 沒人退出」的殭屍狀態 |
| 6 | 雙人核准、incident 系統驗證 | 誠實面對平台能力:incident_id 為必填 audit 欄位(不假裝驗證);4-eyes 交給上層(force-dr 可用獨立 allowed_groups 收窄) | aqsh 沒有 4-eyes primitive;在 bash task 裡自己搓是安全劇場 |
| 7 | 失聯 ≥ N 分鐘需查監控歷史 | 從存活成員 `rs.status().lastHeartbeatRecv` 現算失聯秒數 | 不需要外部 metrics store,純現查,符合「infra 從 k8s/mongo 反推」原則 |
| 8 | zone 從 **pod** labels 讀 | 從 `pod.spec.nodeName` join **node** 的 `topology.kubernetes.io/zone` | v1 的 jq 是錯的:topology labels 在 Node 上。查不到 zone → 模擬 skip(fail-soft,不猜) |
| 9 | 新成員連通性用 TCP handshake | k8s 層檢查:host 符合本 STS 命名 → pod 必須存在且 Ready(block);外部 host → warn(可能跨叢集) | headless DNS 在 pod 起來前必然不通,TCP 檢查會誤殺合法流程;同時新增 v1 沒有的 STS×member drift 檢查 |
| 10 | 偶數票建議「加仲裁湊 7 票」 | warn 訊息指向**第三站點 witness(2+2+1)** | 2-DC 加 arbiter 在任一 DC 只解一邊全滅,是假安全感 |

## 保留自 v1 的核心

- validate(→`plan`)/ apply 分離,plan 純唯讀
- force-dr 獨立 endpoint、獨立(更嚴)前置條件,永不與一般 reconfig 共用參數
- block 不可 override;warn 需 override_reason(入 audit)
- force-dr 三前置(全部現查、不用快取):P1 無 primary、P2 存活健康票 < 多數、P3 失聯投票成員靜默 ≥ 門檻
- 斷頭 config:失聯成員 votes:0 / priority:0,**不刪除**
- dry_run → 人工確認 → confirm(沿用 create-account 的 dry_run/confirm 契約)
- 事後恢復流程走正常 plan/apply(hidden → 追上 → 分批還票),成功後自動清 dr-active
- audit:pre/post config snapshot、who/why/incident,寫入 per-namespace ConfigMap ring buffer(audit 寫失敗回報 `audited:false`,不回滾已執行的 reconfig)

## API 面(對齊「API 不能有 infra 設定」)

```
reconfig/plan      namespace, ops_json
reconfig/apply     namespace, ops_json, plan_hash, override_reason?, requested_by?, request_id?
reconfig/force-dr  namespace, incident_id, dry_run/confirm, plan_hash?, requested_by?
reconfig/freeze    namespace, enabled, reason
```

sts_name / credential_* / audit CM 名稱 / DR 門檻等全部走
internal-config → auto-detect → fallback 三層(CLAUDE.md "Configuration
Layers"),與 recovery/* 相同,無任何 per-call 逃生口。

## 已知邊界(記錄,不假裝解決)

- `recovery/fix-no-primary` 的 reconfig/force-primary 層級仍是無 gate 的
  force reconfig 側門(針對「全員存活但選不出 primary」,force-dr 的
  失聯門檻在該情境永遠不成立)。本次依「不能動其他 API」約束保持原樣;
  長期應收斂到本閘道的 audit + 前置條件機制。
- incident_id 真偽、雙人核准由呼叫端平台負責。
- 跨叢集成員(host 非本地可驗證)只能 warn,不能 block。
