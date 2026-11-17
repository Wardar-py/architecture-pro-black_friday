#!/usr/bin/env bash
set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
  echo -e "${BLUE}[●]${NC} $1"
}

success() {
  echo -e "${GREEN}[✓]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[⚠]${NC} $1"
}

error() {
  echo -e "${RED}[✗]${NC} $1" >&2
}

# Функция для выполнения mongosh-команды в контейнере
run_mongo() {
  local container="$1"
  local port="$2"
  local js_cmd="$3"
  docker compose exec -T "$container" mongosh --port "$port" --quiet --eval "$js_cmd" 2>/dev/null | tr -d '\r' | grep -v '^$'
}

log "1. Запрос общего количества документов через mongos_router..."
TOTAL=$(run_mongo "mongos_router" "27020" "db.getSiblingDB('somedb').helloDoc.countDocuments()")
if [[ -z "$TOTAL" ]]; then
  error "Не удалось получить количество документов"
  exit 1
fi
success "Общее количество документов в кластере: ${CYAN}${TOTAL}${NC}"

echo

# Данные на шарде 1
log "2. Проверка данных на шарде shard1 (replica set 'shard1')..."

declare -A SHARD1_COUNTS
# В replica set shard1 входят: shard1 (primary) и shard1_1 (secondary)
for container in shard1 shard1_1; do
  # Определяем порт для каждого контейнера
  case $container in
    shard1)
      port=27018
      ;;
    shard1_1)
      port=27021
      ;;
    *)
      continue
      ;;
  esac

  count=$(run_mongo "$container" "$port" "db.getSiblingDB('somedb').helloDoc.countDocuments()" || echo "-1")
  SHARD1_COUNTS[$container]=$count

  if [[ "$count" == "-1" ]]; then
    error "  $container: недоступен"
  elif [[ "$count" == "0" ]]; then
    warn "  $container: ${count} документов"
  else
    success "  $container: ${CYAN}${count}${NC} документов"
  fi
done

# Анализ: все ли реплики синхронизированы?
unique_counts1=($(printf '%s\n' "${SHARD1_COUNTS[@]}" | sort -u | grep -v -- "-1"))
if [[ ${#unique_counts1[@]} -eq 1 ]] && [[ -n "${unique_counts1[0]}" ]]; then
  success "→ Все реплики shard1 синхронизированы: ${unique_counts1[0]} документов"
elif [[ ${#unique_counts1[@]} -eq 0 ]]; then
  error "→ Все ноды shard1 недоступны"
else
  warn "→ Расхождение в данных на репликах shard1: (${unique_counts1[*]})"
fi

echo

# === 3. Данные на шарде 2 (shard2 replica set) ===
log "3. Проверка данных на шарде shard2 (replica set 'shard2')..."

declare -A SHARD2_COUNTS
# В replica set shard2 входят: shard2 (primary) и shard2_1 (secondary)
for container in shard2 shard2_1; do
  # Определяем порт для каждого контейнера
  case $container in
    shard2)
      port=27019
      ;;
    shard2_1)
      port=27022
      ;;
    *)
      continue
      ;;
  esac

  count=$(run_mongo "$container" "$port" "db.getSiblingDB('somedb').helloDoc.countDocuments()" || echo "-1")
  SHARD2_COUNTS[$container]=$count

  if [[ "$count" == "-1" ]]; then
    error "  $container: недоступен"
  elif [[ "$count" == "0" ]]; then
    warn "  $container: ${count} документов"
  else
    success "  $container: ${CYAN}${count}${NC} документов"
  fi
done

unique_counts2=($(printf '%s\n' "${SHARD2_COUNTS[@]}" | sort -u | grep -v -- "-1"))
if [[ ${#unique_counts2[@]} -eq 1 ]] && [[ -n "${unique_counts2[0]}" ]]; then
  success "→ Все реплики shard2 синхронизированы: ${unique_counts2[0]} документов"
elif [[ ${#unique_counts2[@]} -eq 0 ]]; then
  error "→ Все ноды shard2 недоступны"
else
  warn "→ Расхождение в данных на репликах shard2: (${unique_counts2[*]})"
fi

echo

# === 4. Проверка через API ===
log "4. Запрос количества документов через API (/helloDoc/count)..."
API_TOTAL=$(curl -s http://localhost:8080/helloDoc/count 2>/dev/null || echo "error")

if [[ "$API_TOTAL" == "error" ]]; then
  error "→ API недоступен (порт 8080). Проверьте, запущен ли pymongo_api контейнер."
elif [[ "$API_TOTAL" == "$TOTAL" ]]; then
  success "→ API вернул корректное значение: ${CYAN}${API_TOTAL}${NC}"
else
  warn "→ Расхождение: API=${API_TOTAL}, mongos=${TOTAL}"
fi

echo

# === 5. Итоговый анализ распределения ===
log "5. Анализ распределения данных по шардам..."

# Берем данные из primary реплик (shard1 и shard2)
shard1_docs=${SHARD1_COUNTS[shard1]:-0}
shard2_docs=${SHARD2_COUNTS[shard2]:-0}

# Приводим к числам (если -1, заменяем на 0)
[[ "$shard1_docs" == "-1" ]] && shard1_docs=0
[[ "$shard2_docs" == "-1" ]] && shard2_docs=0

sum_local=$((shard1_docs + shard2_docs))

echo -e "${BLUE}Статистика по primary шардам:${NC}"
echo "  shard1 (primary): ${CYAN}${shard1_docs}${NC} документов"
echo "  shard2 (primary): ${CYAN}${shard2_docs}${NC} документов"
echo "  Сумма:           ${GREEN}${sum_local}${NC} документов"
echo "  mongos:          ${CYAN}${TOTAL}${NC} документов"

if [[ "$sum_local" -eq "$TOTAL" ]] && [[ "$sum_local" -gt 0 ]]; then
  success "✅ Согласованность данных подтверждена!"
  echo ""
  echo -e "${GREEN}Распределение данных по шардам:${NC}"
  percent1=$((shard1_docs * 100 / TOTAL))
  percent2=$((shard2_docs * 100 / TOTAL))
  echo "  Шард 1: $shard1_docs документов ($percent1%)"
  echo "  Шард 2: $shard2_docs документов ($percent2%)"
elif [[ "$sum_local" -ne "$TOTAL" ]]; then
  warn "⚠️  Несоответствие: сумма по primary шардам ($sum_local) ≠ mongos ($TOTAL)"
  printf "   Возможные причины:\n"
  printf "   - Данные ещё реплицируются\n"
  printf "   - Некоторые документы находятся в состоянии миграции\n"
  printf "   - Шардинг не полностью инициализирован\n"
fi

echo
log "Проверка завершена."

# Дополнительная информация о статусе репликации
echo
log "Дополнительная информация:"

# Проверка статуса replica set для shard1
log "Статус replica set shard1:"
docker compose exec -T shard1 mongosh --port 27018 --quiet --eval "rs.status().members.forEach(m => print(m.name + ': ' + m.stateStr))" 2>/dev/null || error "Не удалось получить статус shard1"

echo

# Проверка статуса replica set для shard2
log "Статус replica set shard2:"
docker compose exec -T shard2 mongosh --port 27019 --quiet --eval "rs.status().members.forEach(m => print(m.name + ': ' + m.stateStr))" 2>/dev/null || error "Не удалось получить статус shard2"

echo

# Проверка балансировки чанков
log "Статус балансировки чанков:"
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval "sh.status()" 2>/dev/null | grep -A 5 "somedb.helloDoc" || warn "Информация о чанках не найдена"