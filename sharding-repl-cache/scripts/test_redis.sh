#!/usr/bin/env bash
set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Параметры по умолчанию
URL="${1:-http://localhost:8080/helloDoc/users}"
COUNT="${2:-5}"
INTERVAL="${3:-5}"
VERBOSE="${VERBOSE:-false}"

# Функции логирования
log() { echo -e "${BLUE}[●]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1" >&2; }
debug() { [[ "$VERBOSE" == "true" ]] && echo -e "${MAGENTA}[DEBUG]${NC} $1"; }

# Экранирует строку для отображения
shell_escape() {
  printf '%q' "$1"
}

# Проверка зависимостей
if ! command -v curl &> /dev/null; then
  error "curl не установлен"
  exit 1
fi

# Показать справку
show_help() {
  cat << EOF
Использование: $0 [URL] [COUNT] [INTERVAL]

Параметры:
  URL       - эндпоинт API (по умолчанию: http://localhost:8080/helloDoc/users)
  COUNT     - количество запросов (по умолчанию: 5)
  INTERVAL  - интервал между запросами в секундах (по умолчанию: 5)

Переменные окружения:
  VERBOSE=true - включить подробный вывод

Примеры:
  $0                                    # тест с параметрами по умолчанию
  $0 http://localhost:8080/helloDoc 10  # 10 запросов к указанному URL
  $0 /api/users 20 2                    # 20 запросов с интервалом 2 сек
  VERBOSE=true $0 10                    # подробный вывод
EOF
  exit 0
}

# Проверка аргументов
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  show_help
fi

# Предварительная проверка доступности API
log "🔍 Проверка доступности API..."
if ! curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$URL" | grep -q "200\|404"; then
  warn "API может быть недоступен (проверка соединения)"
else
  success "API доступен"
fi

log "🚀 Тестирование API: ${CYAN}${URL}${NC}"
log "Запросов: ${COUNT} | Интервал: ${INTERVAL} сек"

# Массивы для хранения результатов
declare -a TIMES
declare -a STATUS_CODES
declare -a ERROR_MSGS

# Прогресс-бар функция
show_progress() {
  local current=$1
  local total=$2
  local width=40
  local percent=$((current * 100 / total))
  local filled=$((percent * width / 100))
  local empty=$((width - filled))

  printf "\r${BLUE}[${NC}"
  printf "%${filled}s" | tr ' ' '█'
  printf "%${empty}s" | tr ' ' '░'
  printf "${BLUE}]${NC} %3d%% (%d/%d)" "$percent" "$current" "$total"
}

for ((i=1; i<=COUNT; i++)); do

  # Выполняем запрос
  RESPONSE=$(curl -sS -w "\n%{http_code}\n%{time_total}" \
    --connect-timeout 5 \
    --max-time 10 \
    "$URL" 2>&1) || {
    ERROR_MSGS+=("Запрос $i: curl failed")
    continue
  }

  # Разбор ответа
  HTTP_BODY=$(echo "$RESPONSE" | sed '$d' | sed '$d')
  HTTP_CODE=$(echo "$RESPONSE" | tail -2 | head -1)
  TIME_SEC=$(echo "$RESPONSE" | tail -1)

  # Валидация времени
  if ! [[ "$TIME_SEC" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    warn "Некорректное значение времени: $TIME_SEC"
    TIME_SEC=0
  fi

  TIME_MS=$(awk -v t="$TIME_SEC" 'BEGIN { printf "%.0f", t*1000 }')

  STATUS_CODES+=("$HTTP_CODE")

  if [[ "$HTTP_CODE" -eq 200 ]]; then
    TIMES+=("$TIME_SEC")
    debug "Запрос $i: HTTP 200, время ${TIME_MS}мс"
  else
    ERROR_MSGS+=("Запрос $i: HTTP $HTTP_CODE, время ${TIME_MS}мс")
    if [[ -n "$HTTP_BODY" ]] && [[ "$HTTP_BODY" != "{}" ]] && [[ "$HTTP_BODY" != "[]" ]]; then
      debug "Тело ответа: $(echo "$HTTP_BODY" | tr '\n' ' ' | head -c 200)"
    fi
  fi

  # Ждём перед следующим запросом
  if [[ $i -lt $COUNT ]] && [[ $INTERVAL -gt 0 ]]; then
    sleep "$INTERVAL"
  fi
done

# Завершаем прогресс-бар
echo ""

# Статистика
echo
log "📊 Статистика тестирования:"

# Общая статистика
TOTAL_REQUESTS=$COUNT
SUCCESSFUL=${#TIMES[@]}
FAILED=$((TOTAL_REQUESTS - SUCCESSFUL))

printf "   Всего запросов:   %d\n" "$TOTAL_REQUESTS"
printf "   Успешных:         ${GREEN}%d${NC} (%.1f%%)\n" "$SUCCESSFUL" "$((SUCCESSFUL * 100 / TOTAL_REQUESTS))"
printf "   Неудачных:        ${RED}%d${NC} (%.1f%%)\n" "$FAILED" "$((FAILED * 100 / TOTAL_REQUESTS))"

# Статистика по HTTP кодам
if [[ ${#STATUS_CODES[@]} -gt 0 ]]; then
  echo -e "   Коды ответов:"
  printf "%s\n" "${STATUS_CODES[@]}" | sort | uniq -c | while read count code; do
    printf "     HTTP %s: %d\n" "$code" "$count"
  done
fi

# Статистика по времени
if [[ ${#TIMES[@]} -gt 0 ]]; then
  echo

  # Вычисляем статистику с помощью awk
  read -r MIN MAX AVG MEDIAN P95 P99 <<< $(printf "%s\n" "${TIMES[@]}" | awk '
    function ceil(x) { return int(x) + (x > int(x)) }
    {
      times[NR] = $1;
      sum += $1;
    }
    END {
      n = NR;
      if (n == 0) exit;

      # Сортировка
      asort(times);

      min = times[1];
      max = times[n];
      avg = sum / n;

      # Медиана
      if (n % 2 == 0)
        median = (times[n/2] + times[n/2+1]) / 2;
      else
        median = times[ceil(n/2)];

      # 95-й перцентиль
      p95_idx = ceil(n * 0.95);
      p95 = times[p95_idx];

      # 99-й перцентиль
      p99_idx = ceil(n * 0.99);
      p99 = times[p99_idx];

      printf "%.3f %.3f %.3f %.3f %.3f %.3f", min, max, avg, median, p95, p99
    }
  ')

  MIN_MS=$(awk -v t="$MIN" 'BEGIN { printf "%.0f", t*1000 }')
  MAX_MS=$(awk -v t="$MAX" 'BEGIN { printf "%.0f", t*1000 }')
  AVG_MS=$(awk -v t="$AVG" 'BEGIN { printf "%.0f", t*1000 }')
  MEDIAN_MS=$(awk -v t="$MEDIAN" 'BEGIN { printf "%.0f", t*1000 }')
  P95_MS=$(awk -v t="$P95" 'BEGIN { printf "%.0f", t*1000 }')
  P99_MS=$(awk -v t="$P99" 'BEGIN { printf "%.0f", t*1000 }')

  echo "   ⏱️  Временные характеристики (только успешные запросы):"
  printf "     Минимум:  %6s мс (%.3f с)\n" "$MIN_MS" "$MIN"
  printf "     Максимум: %6s мс (%.3f с)\n" "$MAX_MS" "$MAX"
  printf "     Среднее:  %6s мс (%.3f с)\n" "$AVG_MS" "$AVG"
  printf "     Медиана:  %6s мс (%.3f с)\n" "$MEDIAN_MS" "$MEDIAN"
  printf "     95-й п:   %6s мс (%.3f с)\n" "$P95_MS" "$P95"
  printf "     99-й п:   %6s мс (%.3f с)\n" "$P99_MS" "$P99"

  # Простой график распределения
  if [[ ${#TIMES[@]} -gt 5 ]]; then
    echo
    echo "   📈 Распределение времени ответа:"
    printf "%s\n" "${TIMES[@]}" | awk -v max_time="$MAX" '
      {
        # Нормализуем время от 0 до 50
        pos = int(($1 / max_time) * 50);
        if (pos > 50) pos = 50;
        hist[pos]++;
      }
      END {
        for (i = 0; i <= 50; i+=5) {
          printf "     %3d-%3d%% ", i, i+5;
          count = 0;
          for (j = i; j < i+5 && j <= 50; j++) count += hist[j];
          bar_len = count > 0 ? int(count / 2) + 1 : 0;
          printf "%s\n", bar_len > 0 ? sprintf("%*s", bar_len, "") : "";
          gsub(/ /, "█", $0);
        }
      }
    ' | sed 's/█/█/g'
  fi
fi

# Вывод ошибок
if [[ ${#ERROR_MSGS[@]} -gt 0 ]] && [[ "$VERBOSE" == "true" ]]; then
  echo
  log "❌ Детали ошибок:"
  for msg in "${ERROR_MSGS[@]}"; do
    echo "   $msg"
  done
fi

# Оценка производительности
echo
if [[ ${#TIMES[@]} -gt 0 ]]; then
  AVG_SEC=$(echo "$AVG" | awk '{printf "%.0f", $1}')
  if [[ $AVG_SEC -lt 1 ]]; then
    success "✨ Отличная производительность (среднее время < 1с)"
  elif [[ $AVG_SEC -lt 3 ]]; then
    success "✅ Хорошая производительность (среднее время < 3с)"
  elif [[ $AVG_SEC -lt 5 ]]; then
    warn "⚠️  Удовлетворительная производительность (среднее время < 5с)"
  else
    error "🐌 Низкая производительность (среднее время > 5с)"
  fi
fi

echo
success "✅ Тестирование завершено."

# Код возврата (0 если все запросы успешны)
if [[ $FAILED -eq 0 ]]; then
  exit 0
else
  exit 1
fi