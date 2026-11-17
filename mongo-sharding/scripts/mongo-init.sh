#!/bin/bash
set -euo pipefail  # Прерываем выполнение при любой ошибке

# Цвета ANSI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции логирования
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') - $1"
}

log_ok() {
    echo -e "${GREEN}[OK]${NC} $(date '+%H:%M:%S') - $1"
}

log_wait() {
    echo -e "${YELLOW}[WAIT]${NC} $(date '+%H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') - $1"
}

# Функция инициализации replica set с проверкой
init_replica_set() {
    local service=$1
    local port=$2
    local rs_name=$3
    local rs_config=$4
    local max_attempts=3
    local attempt=1

    log_info "Инициализация replica set для $rs_name (порт $port)..."

    while [ $attempt -le $max_attempts ]; do
        if docker compose exec -T "$service" mongosh --port "$port" --quiet --eval "$rs_config" 2>/dev/null; then
            log_ok "$rs_name replica set инициализирован"
            return 0
        else
            log_wait "Попытка $attempt из $max_attempts не удалась. Повтор через 5 секунд..."
            sleep 5
            ((attempt++))
        fi
    done

    log_error "Не удалось инициализировать $rs_name после $max_attempts попыток"
    return 1
}

# Функция ожидания готовности сервиса
wait_for_mongos() {
    local max_attempts=20
    local attempt=1
    local wait_time=5

    log_info "Ожидание готовности mongos_router (порт 27020)..."

    while [ $attempt -le $max_attempts ]; do
        if docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval 'db.runCommand({ping: 1})' >/dev/null 2>&1; then
            log_ok "mongos_router доступен"
            return 0
        else
            log_wait "mongos_router ещё не готов. Попытка $attempt из $max_attempts. Повтор через $wait_time секунд..."
            sleep $wait_time
            ((attempt++))
        fi
    done

    log_error "mongos_router не стал доступен после $max_attempts попыток"
    return 1
}

# Функция выполнения команд в mongos
exec_mongos() {
    local command=$1
    docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval "$command"
}


# Проверка запущенных контейнеров
log_info "Проверка запущенных контейнеров..."
if ! docker compose ps --services --filter "status=running" 2>/dev/null | grep -q .; then
    log_error "Нет запущенных контейнеров. Запустите: docker compose up -d"
    exit 1
fi


# Инициализация config-сервера
init_replica_set "configSrv" "27017" "Config server" '
rs.initiate({
    _id: "config_server",
    configsvr: true,
    members: [{ _id: 0, host: "configSrv:27017" }]
})
' || exit 1

# Инициализация shard1
init_replica_set "shard1" "27018" "Shard1" '
rs.initiate({
    _id: "shard1",
    members: [{ _id: 0, host: "shard1:27018" }]
})
' || exit 1

# Инициализация shard2
init_replica_set "shard2" "27019" "Shard2" '
rs.initiate({
    _id: "shard2",
    members: [{ _id: 0, host: "shard2:27019" }]
})
' || exit 1

# Ожидание готовности маршрутизатора
wait_for_mongos || exit 1

# Подключение шардов к кластеру
log_info "Подключение шардов к кластеру через mongos..."
if exec_mongos '
    try {
        sh.addShard("shard1/shard1:27018");
        sh.addShard("shard2/shard2:27019");
        print("OK");
    } catch(e) {
        print("ERROR: " + e);
        quit(1);
    }
' | grep -q "OK"; then
    log_ok "Шарды успешно добавлены"
else
    log_error "Не удалось добавить шарды"
    exit 1
fi

# Настройка шардинга
log_info "Включение шардинга для БД 'somedb' и коллекции 'helloDoc'..."
if exec_mongos '
    try {
        sh.enableSharding("somedb");
        sh.shardCollection("somedb.helloDoc", { "name": "hashed" });
        print("OK");
    } catch(e) {
        print("ERROR: " + e);
        quit(1);
    }
' | grep -q "OK"; then
    log_ok "Шардинг включён для somedb.helloDoc"
else
    log_error "Не удалось настроить шардинг"
    exit 1
fi

# Вставка тестовых данных
log_info "Вставка 1000 тестовых документов в коллекцию somedb.helloDoc..."
BATCH_SIZE=100
TOTAL_DOCS=1000

exec_mongos "
use somedb
print('Начало вставки $TOTAL_DOCS документов...')
for(var i = 0; i < $TOTAL_DOCS; i++) {
    db.helloDoc.insertOne({age: i, name: 'ly' + i});
    if ((i + 1) % $BATCH_SIZE === 0) {
        print('Вставлено ' + (i + 1) + ' документов');
    }
}
print('Готово: вставлено ' + db.helloDoc.countDocuments() + ' документов');
"

if [ $? -eq 0 ]; then
    log_ok "1000 документов успешно вставлены"
else
    log_error "Ошибка при вставке документов"
    exit 1
fi

# Вывод статистики распределения
log_info "Статистика распределения данных по шардам:"
exec_mongos "
use somedb
print('=== Распределение данных ===')
db.helloDoc.getShardDistribution()
"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Настройка шардированного кластера завершена!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${BLUE}Подключение:${NC} mongodb://localhost:27020"
echo -e "${BLUE}База данных:${NC} somedb"
echo -e "${BLUE}Коллекция:${NC} helloDoc"
echo -e "${BLUE}Количество документов:${NC} 1000"
echo -e "${GREEN}========================================${NC}"