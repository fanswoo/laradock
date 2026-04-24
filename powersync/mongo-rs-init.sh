#!/usr/bin/env bash
# PowerSync mongo replica set initializer
#
# PowerSync 的 MongoBucketBatch 用 multi-document transactions 更新 bucket storage,
# 這只有在 mongo 以 replica set 模式跑時才支援。單節點 RS 即可,但 mongo 啟動時
# 只宣告 --replSet 不會自動 initiate,必須執行一次 rs.initiate() 把 config 寫進去。
#
# 清掉 powersync_mongo_data volume 後也會遺失此 config,需要再 initiate 一次。
# 把這個腳本放成一次性 init container,compose up 時自動把缺失補上,避免手動 mongosh。
#
# 冪等:已經 initiate 過的 mongo 會從 rs.status() 取得 ok=1 直接返回,不重複 initiate。

set -euo pipefail

MONGO_HOST="${MONGO_HOST:-powersync_mongo:27017}"
RS_NAME="${RS_NAME:-rs0}"

echo "[mongo-rs-init] Waiting for mongo at ${MONGO_HOST}..."
until mongosh --host "${MONGO_HOST}" --quiet --eval 'db.adminCommand("ping").ok' >/dev/null 2>&1; do
  sleep 1
done
echo "[mongo-rs-init] Mongo is up."

mongosh --host "${MONGO_HOST}" --quiet --eval "
  try {
    const s = rs.status();
    print('[mongo-rs-init] Replica set already initialized: ' + s.set + ' (myState=' + s.myState + ')');
  } catch (e) {
    if (e.codeName === 'NotYetInitialized' || /no replset config/i.test(e.message)) {
      print('[mongo-rs-init] No RS config found, initiating ${RS_NAME}...');
      rs.initiate({ _id: '${RS_NAME}', members: [{ _id: 0, host: '${MONGO_HOST}' }] });
      print('[mongo-rs-init] rs.initiate() returned.');
    } else {
      print('[mongo-rs-init] Unexpected rs.status() error: ' + e.message);
      throw e;
    }
  }
"
