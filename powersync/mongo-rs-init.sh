#!/usr/bin/env bash
# PowerSync mongo replica set initializer (從 host 手動執行)
#
# 何時要跑:
#   - 第一次 `docker compose up powersync_mongo` 後
#   - 清掉 powersync_mongo_data volume 後
#   - powersync service 啟動報 "not running with --replSet" / "no replset config" 時
#
# 用法 (在 laradock 根目錄):
#   bash ./powersync/mongo-rs-init.sh
#
# 為什麼需要這步:
#   PowerSync 的 MongoBucketBatch 用 multi-document transactions 更新 bucket storage,
#   這只有在 mongo 以 replica set 模式跑時才支援。單節點 RS 即可,但 mongo 啟動時
#   只宣告 --replSet 不會自動 initiate,必須執行一次 rs.initiate() 把 config 寫進去。
#
# 冪等: 已經 initiate 過的 mongo 會從 rs.status() 取得 ok=1 直接返回,不重複 initiate。

set -euo pipefail

cd "$(dirname "$0")/.."

SERVICE="${SERVICE:-powersync_mongo}"
RS_NAME="${RS_NAME:-rs0}"

# compose v2 可能裝成 docker plugin (docker compose) 或獨立執行檔 (docker-compose)
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "[mongo-rs-init] 找不到 docker compose / docker-compose" >&2
  exit 1
fi

echo "[mongo-rs-init] Waiting for ${SERVICE} mongo to accept connections..."
for i in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T "${SERVICE}" mongosh --quiet --eval 'db.adminCommand("ping").ok' >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "[mongo-rs-init] 等了 60 秒還連不上，最後一次錯誤:" >&2
    "${COMPOSE[@]}" exec -T "${SERVICE}" mongosh --quiet --eval 'db.adminCommand("ping").ok' >&2 || true
    exit 1
  fi
  sleep 1
done
echo "[mongo-rs-init] Mongo is up."

"${COMPOSE[@]}" exec -T "${SERVICE}" mongosh --quiet --eval "
  try {
    const s = rs.status();
    print('[mongo-rs-init] Replica set already initialized: ' + s.set + ' (myState=' + s.myState + ')');
  } catch (e) {
    if (e.codeName === 'NotYetInitialized' || /no replset config/i.test(e.message)) {
      print('[mongo-rs-init] No RS config found, initiating ${RS_NAME}...');
      rs.initiate({ _id: '${RS_NAME}', members: [{ _id: 0, host: '${SERVICE}:27017' }] });
      print('[mongo-rs-init] rs.initiate() returned.');
    } else {
      print('[mongo-rs-init] Unexpected rs.status() error: ' + e.message);
      throw e;
    }
  }
"
