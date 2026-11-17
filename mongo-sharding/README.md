# Как запустить и проверить

## 1. Запустите приложение
```shell
docker compose up -d
```

## 2. Инициализация
```shell
bash scripts/mongo-init.sh
```

## 3. Опрашиваем данные

1. Сколько всего записей в коллекции `helloDoc`.
```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

2. Команда для просмотра данных первого шарда.

```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

3. Команда для просмотра данных второго шарда.

```shell
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

4. Получение количества записей через API
```shell
curl http://localhost:8080/helloDoc/count
```

---
