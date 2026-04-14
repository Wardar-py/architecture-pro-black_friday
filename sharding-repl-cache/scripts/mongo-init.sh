#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}


check_command() {
    if [ $? -eq 0 ]; then
        log_success "$1"
    else
        log_error "$2"
        exit 1
    fi
}


init_replica_set() {
    local service=$1
    local port=$2
    local config=$3
    local name=$4
    local max_attempts=5
    local attempt=1

    log_info "Инициализация replica set для $name (порт $port)..."

    while [ $attempt -le $max_attempts ]; do
        if docker compose exec -T "$service" mongosh --port "$port" --eval "$config" >/dev/null 2>&1; then
            log_success "$name replica set инициализирован"
            return 0
        else
            log_warning "Попытка $attempt из $max_attempts не удалась. Повтор через 10 секунд..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "Не удалось инициализировать $name replica set после $max_attempts попыток"
    exit 1
}

wait_for_service() {
    local service=$1
    local port=$2
    local max_attempts=12
    local attempt=1

    log_info "Ожидание готовности $service (порт $port)..."

    while [ $attempt -le $max_attempts ]; do
        if docker compose exec -T "$service" mongosh --port "$port" --eval 'db.runCommand({ping: 1})' >/dev/null 2>&1; then
            log_success "$service доступен"
            return 0
        else
            log_warning "Попытка $attempt из $max_attempts. Повтор через 10 секунд..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "$service не стал доступен после $max_attempts попыток"
    exit 1
}


log_info "Проверка запущенных контейнеров..."
if ! docker compose ps --services --filter "status=running" | grep -q .; then
    log_error "Нет запущенных контейнеров. Запустите контейнеры командой: docker compose up -d"
    exit 1
fi

# Инициализация config-сервера
init_replica_set "configSrv" "27017" '
rs.initiate({
    _id: "config_server",
    configsvr: true,
    members: [{ _id: 0, host: "configSrv:27017" }]
})' "Config server"

# Инициализация shard1
init_replica_set "shard1" "27018" '
rs.initiate({
    _id: "shard1",
    members: [
        { _id: 0, host: "shard1:27018" },
        { _id: 1, host: "shard1_1:27021" }
    ]
})' "Shard1"

# Инициализация shard2
init_replica_set "shard2" "27019" '
rs.initiate({
    _id: "shard2",
    members: [
        { _id: 0, host: "shard2:27019" },
        { _id: 1, host: "shard2_1:27022" }
    ]
})' "Shard2"

# Ожидание готовности mongos_router
wait_for_service "mongos_router" "27020"

# Добавление шардов в кластер
log_info "Подключение шардов к кластеру через mongos..."
docker compose exec -T mongos_router mongosh --port 27020 <<EOF
try {
    sh.addShard("shard1/shard1:27018");
    sh.addShard("shard2/shard2:27019");
    print("Шарды успешно добавлены");
} catch(e) {
    print("Ошибка при добавлении шардов: " + e);
    quit(1);
}
EOF
check_command "Шарды добавлены" "Не удалось добавить шарды"

# Настройка шардинга
log_info "Настройка шардинга для БД 'somedb' и коллекции 'helloDoc'..."
docker compose exec -T mongos_router mongosh --port 27020 <<EOF
try {
    sh.enableSharding("somedb");
    sh.shardCollection("somedb.helloDoc", { "name": "hashed" });
    print("Шардинг успешно настроен");
} catch(e) {
    print("Ошибка при настройке шардинга: " + e);
    quit(1);
}
EOF
check_command "Шардинг настроен" "Не удалось настроить шардинг"

# Вставка тестовых данных с прогрессом
log_info "Вставка 1000 тестовых документов..."
docker compose exec -T mongos_router mongosh --port 27020 <<EOF
use somedb;
print("Начинаю вставку 1000 документов...");
for(var i = 0; i < 1000; i++) {
    db.helloDoc.insertOne({age: i, name: "ly" + i});
    if ((i + 1) % 100 === 0) {
        print("Вставлено " + (i + 1) + " документов");
    }
}
print("Все 1000 документов успешно вставлены");
EOF
check_command "1000 документов вставлены" "Ошибка при вставке документов"

# Проверка распределения данных по шардам
log_info "Проверка распределения данных по шардам..."
docker compose exec -T mongos_router mongosh --port 27020 <<EOF
use somedb;
print("Статистика по шардам:");
db.helloDoc.getShardDistribution();
EOF

log_success "Настройка шардированного кластера успешно завершена!"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Кластер готов к использованию!${NC}"
echo -e "${GREEN}Подключение: mongodb://localhost:27020${NC}"
echo -e "${GREEN}========================================${NC}"