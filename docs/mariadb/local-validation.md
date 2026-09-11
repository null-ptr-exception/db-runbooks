# PR 99：低資源本機驗證與清理交接

## 使用者決定（2026-09-11）

這台主機同時跑多組舊 Kind 環境曾造成 Kubernetes／Istio setup 逾時。使用者確認舊測試 clusters 都未使用，可停止釋放資源；也同意完整流程太重時縮小本機測試，前提是保留可交接文件。

預設跑 **quick**，不再為了每次驗證啟動雙 cluster E2E。這是本機驗證範圍調整，不代表完整 E2E 已通過，也不是 CI／review／內部環境驗證的豁免。不要把 unit pass 寫成 replication runtime pass。

## 下一個 AI 的執行順序

1. 讀取本 repo 的 AGENTS.md、git status，保留現有修改。不要重置／清理其他 session 的變更。
2. 使用 work-journal `projects/db-runbooks/scripts/local-validation/verify.sh <checkout> quick`，需要 Git、Bash、Bats、jq、ShellCheck、yamllint、Python 3。缺少工具時先依 `.mise.toml` 準備；不得把未執行／skip 當成功。
3. quick 包含 diff check、ShellCheck、yamllint、WORKTREE review preflight，以及本次 PR 涉及的 public-input／transport／replication／backup／restore／operator-profile／storage-resolution／runner tests。精確清單在 work-journal 的 `focused-unit.sh`，下方也提供獨立命令。這些是 shell/mock tests，不建立 Kind。
4. 若沒有 work-journal checkout，可直接執行下方的 focused 命令並跑 repo 靜態檢查；review harness 不可用時要明確記錄，不能冒稱通過。
5. 改 AQSH YAML include/config 時另跑 `verify.sh <checkout> config`，在獨立 Docker daemon 執行 4 個真實 config-loading tests。`unit` 是完整遞迴 unit suite，也在獨立 daemon 執行。
6. `e2e`／`all` 是明確選用的重型驗證，不是預設。只有需要 runtime 證據且資源足夠時，才執行 standalone `tests/mariadb-legacy/replication_link.bats`。一次只跑一份，不與其他 suites 共享 daemon。
7. 檢查 exit code、TAP 的 fail／skip、artifacts、殘留容器；整理哪些證據完成、哪些仍待 CI／review／內部環境。符合使用者授權的本機驗證範圍後才 push，PR 中明示未跑完的 E2E。

## 自動停止與恢復

- runner 每次建立獨立 daemon，無 host Docker socket／kubeconfig mount、無 published host ports。結束、失敗、INT／TERM 都清除此輪容器與匿名 volumes，保留私有暫存日誌。
- 容器內 watchdog 預設 3600 秒後停止 PID 1，再給 15 秒終止緩衝；因此 host runner 被 SIGKILL／終端斷線後，也不會無限占用 CPU／RAM。可用 `LOCAL_E2E_MAX_SECONDS` 指定正整數秒數。
- 若 host runner 已死亡，停止的容器可能留下日誌／磁碟資料。下次 runner 啟動時呼叫 `cleanup-stopped.sh`：只移除 `db-runbooks.local-e2e=true` 且 exited/dead 的容器，使用不帶 force 的 rm，避免刪除被重新啟動的環境。也可手動呼叫該腳本。
- 不自動停止其他正在跑的驗證；不執行 system prune、volume prune、kind delete cluster。Docker daemon 完全不可用时無法完成清理，要記為阻塞並在恢復後執行 cleanup-stopped.sh。
- 舊測試 cluster 的容器／volumes 保留，重啟政策未改。已授權名單在 work-journal `stop-legacy-clusters.sh`；它不碰 registry、日常工具服務或未知容器。舊環境若之後被重新啟用，不可未確認用途就重複停止。

## Runtime 範圍與停止條件

雙 cluster v24 E2E 應驗證 attach assessment／rebuild、真實資料同步、standby Pod restart 與 server_id、重複 attach/detach、指定 physical backup 的 in-place restore、CR/PVC UID 保留。quick 無法證明上述 runtime 行為。

Helmfile setup 有 900 秒等待預算；僅特定 EOF／TLS／connection reset／HTTP2 transport 失敗最多嘗試 3 次。Bats／AQSH 操作不自動重跑。出現 control-plane crashloop、持續 API timeout 或高度主機負載時，保留日誌並停止本次環境；不得無限重建、延長 timeout 或放寬 assertions。

## 已有證據／仍缺

先前遞迴 unit run：577 pass、4 Docker skip、0 fail；4 個 config tests 已在隔離 daemon 補跑通過。runner 新增測試另有通過紀錄。非 strict preflight 為 0 BLOCK／21 REVIEW／0 WARN；REVIEW 不是已經人工批准。

完整 v24 E2E 尚未通過：曾遇 containerd 啟動、chart EOF、Istio readiness timeout；最後較長預算的一輪因 16 CPU 主機 load average 229／176／156、scheduler 續租失敗而主動停止（exit 137）。尚未到達 MariaDB assertions。後續需 CI／資源允許時的完整 E2E、maintainer review，以及使用者執行的內部 v24 驗證。不得操作公司環境來補此證據。

## 沒有 work-journal 時的 focused 命令

```bash
bats --jobs 1 \
  tests/unit/aqsh/mariadb_public_inputs.bats \
  tests/unit/aqsh/resolution_registry_drift.bats \
  tests/unit/mariadb/peer-transport.bats \
  tests/unit/mariadb/replication-assessment.bats \
  tests/unit/mariadb/replication-link.bats \
  tests/unit/mariadb/replication-rebuild.bats \
  tests/unit/mariadb/physical-backup.bats \
  tests/unit/mariadb/physical-backup-legacy.bats \
  tests/unit/mariadb/restore-in-place.bats \
  tests/unit/mariadb/restore-legacy.bats \
  tests/unit/mariadb/blue-green-gate.bats \
  tests/unit/mariadb/operator-profile.bats \
  tests/unit/mariadb/s3-resolver.bats \
  tests/unit/mariadb/switch-primary.bats \
  tests/unit/local-e2e/isolation.bats \
  tests/unit/local-e2e/cleanup.bats
```

## 本次縮小範圍後的結果

quick gate：197 tests pass、0 skip、exit 0；隔離 config profile：4 tests pass、exit 0。已實測容器內 2 秒 watchdog 自行停止，以及 host runner 收到 SIGTERM 回傳 143 並移除自有容器。舊測試環境 16 個 Kind 節點均已停止；保留容器／volumes／restart policies、registry 與日常服務。完整 v24 E2E 仍未通過，不得混用上述結果。
