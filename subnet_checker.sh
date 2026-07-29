#!/bin/bash
# check_subnet.sh -- проверяет IP-адрес на присутствие в antifilter.network
# списках по произвольному набору масок, считает количество адресов в
# каждой найденной записи и расстояние до ближайшего заблокированного
# соседа. Подробный список найденных адресов выводится только с флагом -v.
#
# Использование:
#   ./check_subnet.sh <IP> [маски через запятую] [-v]
#
# Примеры:
#   ./check_subnet.sh 141.0.188.44
#       -> проверка по умолчанию: /24, /20, /16
#
#   ./check_subnet.sh 141.0.188.44 24,22,20,18,16,12,8
#       -> проверка по указанному набору масок
#
#   ./check_subnet.sh 141.0.188.44 24,16 -v
#       -> с подробным списком всех найденных адресов/подсетей

set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Использование: $0 <IP-адрес> [маски через запятую] [-v]"
    echo "Пример: $0 141.0.188.44 24,20,16,12 -v"
    exit 1
fi

IP="$1"
shift

VERBOSE=0
MASK_LIST="24,20,16"   # по умолчанию

for arg in "$@"; do
    if [ "$arg" = "-v" ]; then
        VERBOSE=1
    elif [[ "$arg" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        MASK_LIST="$arg"
    fi
done

if ! [[ "$IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Ошибка: '$IP' не похож на IPv4-адрес (ожидается формат A.B.C.D)"
    exit 1
fi

IFS='.' read -r A B C D <<< "$IP"

# --- IP -> число ---
ip_to_int() {
    local ip="$1"
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
}

# --- число -> IP (для вывода префикса по маске) ---
int_to_ip() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# --- диапазон [начало, конец] для записи CIDR или одиночного IP ---
cidr_range() {
    local cidr="$1"
    local ip="${cidr%/*}"
    local mask="${cidr#*/}"
    if [ "$ip" = "$cidr" ]; then
        mask=32
    fi
    local ip_int
    ip_int=$(ip_to_int "$ip")
    local size=$(( 2 ** (32 - mask) ))
    local start=$ip_int
    local end=$(( ip_int + size - 1 ))
    echo "$start $end"
}

count_ips() {
    local mask="$1"
    echo $(( 2 ** (32 - mask) ))
}

TARGET_INT=$(ip_to_int "$IP")

echo "Проверяем адрес: $IP"
echo "Маски для проверки: $MASK_LIST"
echo ""

echo "Загружаю базы antifilter.network..."
curl --max-time 20 -sS https://antifilter.network/download/ip.lst -o /tmp/ip.lst \
    && echo "  ip.lst загружен ($(wc -l < /tmp/ip.lst) строк)" \
    || echo "  ОШИБКА загрузки ip.lst"

curl --max-time 20 -sS https://antifilter.network/download/ipsum.lst -o /tmp/ipsum.lst \
    && echo "  ipsum.lst загружен ($(wc -l < /tmp/ipsum.lst) строк)" \
    || echo "  ОШИБКА загрузки ipsum.lst"

echo ""

IFS=',' read -ra MASKS <<< "$MASK_LIST"

# Сортируем маски по убыванию (от /24 к /8) -- от узкого к широкому
IFS=$'\n' SORTED_MASKS=($(sort -rn <<< "${MASKS[*]}"))
unset IFS

for mask in "${SORTED_MASKS[@]}"; do
    # Вычисляем базовый префикс сети для данной маски
    TARGET_BASE_INT=$(( (TARGET_INT >> (32 - mask)) << (32 - mask) ))
    BASE_IP=$(int_to_ip "$TARGET_BASE_INT")
    RANGE_END=$(( TARGET_BASE_INT + (2 ** (32 - mask)) - 1 ))

    echo "=== /$mask (${BASE_IP}/$mask) ==="

    # Предварительный grep-фильтр адаптируется под ширину маски: чем шире
    # диапазон (меньше mask), тем меньше октетов можно зафиксировать при
    # первичном отборе, иначе можно упустить реальные совпадения.
    if [ "$mask" -ge 24 ]; then
        PREGREP="^${A}\.${B}\.${C}\."
    elif [ "$mask" -ge 16 ]; then
        PREGREP="^${A}\.${B}\."
    elif [ "$mask" -ge 8 ]; then
        PREGREP="^${A}\."
    else
        PREGREP="^"
    fi
    CANDIDATES=$(grep -hE "$PREGREP" /tmp/ip.lst /tmp/ipsum.lst 2>/dev/null || true)

    MATCH_COUNT=0
    MATCH_IPS=0
    MIN_DIST=999999999
    CLOSEST=""
    MATCH_LINES=""

    if [ -n "$CANDIDATES" ]; then
        while read -r entry; do
            [ -z "$entry" ] && continue
            range=$(cidr_range "$entry")
            e_start=$(echo "$range" | cut -d' ' -f1)
            e_end=$(echo "$range" | cut -d' ' -f2)
            e_mask="${entry##*/}"
            [ "$entry" = "${entry%%/*}" ] && e_mask=32
            n=$(count_ips "$e_mask")

            # Пересечение записи с целевым диапазоном /$mask?
            if [ "$e_start" -le "$RANGE_END" ] && [ "$e_end" -ge "$TARGET_BASE_INT" ]; then
                MATCH_COUNT=$((MATCH_COUNT + 1))
                MATCH_IPS=$((MATCH_IPS + n))
                MATCH_LINES="${MATCH_LINES}${entry} (адресов: ${n})"$'\n'
            fi

            # Расстояние от target (не от границы диапазона /$mask) до записи
            if [ "$TARGET_INT" -ge "$e_start" ] && [ "$TARGET_INT" -le "$e_end" ]; then
                dist=0
            elif [ "$TARGET_INT" -lt "$e_start" ]; then
                dist=$((e_start - TARGET_INT))
            else
                dist=$((TARGET_INT - e_end))
            fi
            if [ "$dist" -lt "$MIN_DIST" ]; then
                MIN_DIST=$dist
                CLOSEST=$entry
            fi
        done <<< "$CANDIDATES"
    fi

    echo "  Записей внутри /$mask: $MATCH_COUNT"
    echo "  Заблокированных адресов внутри /$mask: $MATCH_IPS"
    if [ -n "$CLOSEST" ]; then
        echo "  Ближайший сосед (не обязательно внутри /$mask): $CLOSEST (расстояние: $MIN_DIST)"
    fi

    if [ "$VERBOSE" -eq 1 ] && [ "$MATCH_COUNT" -gt 0 ]; then
        echo "  --- Подробный список ---"
        echo "$MATCH_LINES" | sed '/^$/d' | sed 's/^/    /'
    fi

    echo ""
done
