#!/bin/sh

# ==================== OUM v7.3 — OpenWrt Ultimate Manager ====================
OUM_VERSION="7.3"
OUM_REPO_URL="https://raw.githubusercontent.com/ShockioOcki/oum/main/oum.sh"
GREEN='\033[1;32m'; RED='\033[1;31m'; CYAN='\033[1;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

header() {
    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${GREEN}       OUM v7.3 — OpenWrt Ultimate Manager        ${NC}"
    echo -e "${CYAN}==================================================${NC}"
}

pause() {
    echo -e "\n${YELLOW}Нажмите [Enter] для продолжения...${NC}"
    read -r _
}

read_choice() {
    read -p "Выбор: " choice
    echo "$choice"
}

check_root() {
    [ "$(id -u)" -ne 0 ] && { echo -e "${RED}❌ Запускайте от root!${NC}"; exit 1; }
}

# Бэкапы храним в /etc/oum/backups (overlay — переживает перезагрузку),
# а НЕ в /tmp (tmpfs — стирается при ребуте). Ротация: последние 5 шт.
BACKUP_DIR="/etc/oum/backups"
BACKUP_KEEP=5

make_backup() {
    echo -e "${YELLOW}Создаём бэкап конфигурации...${NC}"
    mkdir -p "$BACKUP_DIR"
    FREE_KB=$(df -Pk /etc 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 2048 ]; then
        echo -e "${YELLOW}⚠️  Мало места в постоянной памяти (overlay): ${FREE_KB} KB — старые бэкапы лучше удалить (Обслуживание → 4).${NC}"
    fi
    BACKUP_FILE="$BACKUP_DIR/oum_backup_$(date +%Y%m%d_%H%M).tar.gz"
    sysupgrade -b "$BACKUP_FILE" 2>/dev/null || tar -czf "$BACKUP_FILE" /etc/config /etc/rc.local /etc/init.d 2>/dev/null
    if [ -s "$BACKUP_FILE" ]; then
        echo -e "${GREEN}✅ Бэкап сохранён: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1)) — переживает перезагрузку.${NC}"
        ls -1t "$BACKUP_DIR"/oum_backup_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while IFS= read -r old; do
            rm -f "$old"
        done
        log_msg "OK backup $(basename "$BACKUP_FILE")"
    else
        echo -e "${RED}❌ Не удалось создать бэкап.${NC}"
        log_msg "FAIL backup creation"
    fi
}

# Лог тоже в /etc (overlay), не в /var/log (tmpfs). С лимитом размера,
# чтобы не изнашивать flash и не забить overlay.
log_msg() {
    # $1 = message
    mkdir -p /etc/oum
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> /etc/oum/oum.log
    if [ -f /etc/oum/oum.log ] && [ "$(wc -c < /etc/oum/oum.log)" -gt 65536 ]; then
        tail -n 500 /etc/oum/oum.log > /etc/oum/oum.log.tmp && mv /etc/oum/oum.log.tmp /etc/oum/oum.log
    fi
}

# ====================== Пакетный менеджер (opkg / apk) ======================
# Определяется ОДИН раз при старте скрипта и переиспользуется везде через
# pkg_update/pkg_install/pkg_is_installed — вместо повторного if/else
# command -v opkg... в каждой функции, которая ставит пакеты.
detect_pkg_manager() {
    if command -v opkg >/dev/null 2>&1; then
        echo "opkg"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo ""
    fi
}
PKG_MANAGER="$(detect_pkg_manager)"

pkg_update() {
    case "$PKG_MANAGER" in
        opkg) opkg update ;;
        apk)  apk update ;;
        *) echo -e "${RED}❌ Неизвестный пакетный менеджер (ни opkg, ни apk не найдены).${NC}"; return 1 ;;
    esac
}

pkg_install() {
    # $@ = список пакетов
    case "$PKG_MANAGER" in
        opkg) opkg install "$@" ;;
        apk)  apk add --no-cache "$@" ;;
        *) echo -e "${RED}❌ Неизвестный пакетный менеджер (ни opkg, ни apk не найдены).${NC}"; return 1 ;;
    esac
}

pkg_install_force() {
    # Форс-переустановка одного пакета (нужна watchdog'у для sing-box)
    # $1 = имя пакета
    case "$PKG_MANAGER" in
        opkg) opkg install "$1" --force-reinstall ;;
        apk)  apk add --no-cache --force-reinstall "$1" ;;
        *) return 1 ;;
    esac
}

pkg_is_installed() {
    # $1 = имя пакета
    case "$PKG_MANAGER" in
        opkg) opkg list-installed 2>/dev/null | grep -q "^$1 " ;;
        apk)  apk info -e "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

pkg_install_local() {
    # $1 = путь до локального .ipk/.apk файла (темы и пр. из GitHub)
    case "$PKG_MANAGER" in
        opkg) opkg install "$1" ;;
        apk)  apk add --allow-untrusted "$1" ;;
        *) echo -e "${RED}❌ Неизвестный пакетный менеджер.${NC}"; return 1 ;;
    esac
}

pkg_remove() {
    # $@ = список пакетов
    case "$PKG_MANAGER" in
        opkg) opkg remove "$@" ;;
        apk)  apk del "$@" ;;
        *) return 1 ;;
    esac
}

# ====================== GitHub hosts-fix ======================
# Если GitHub заблокирован/не резолвится, прописываем его IP прямо в
# /etc/hosts (решение из Zapret-Manager by StressOzz). IP периодически
# меняются — при полной неработоспособности обновите их или снимите фикс.
GITHUB_HOSTS_MARKER="#OUM-github-fix"

github_hosts_fix_applied() {
    grep -q "$GITHUB_HOSTS_MARKER" /etc/hosts 2>/dev/null
}

github_hosts_fix_apply() {
    github_hosts_fix_applied && return 0
    cat << EOF >> /etc/hosts

$GITHUB_HOSTS_MARKER
140.82.114.3 github.com
185.199.110.154 github.githubassets.com
185.199.110.133 camo.githubassets.com
185.199.109.133 raw.githubusercontent.com release-assets.githubusercontent.com
185.199.108.133 private-user-images.githubusercontent.com gist.githubusercontent.com avatars.githubusercontent.com
EOF
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    github_hosts_fix_applied
}

github_hosts_fix_revert() {
    github_hosts_fix_applied || return 0
    sed -i "/$GITHUB_HOSTS_MARKER/,+5d" /etc/hosts
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    log_msg "github hosts-fix reverted"
}

# ====================== Загрузка файлов с фолбэками ======================
# wget → (для GitHub: hosts-fix + повтор) → curl. Единая точка для всех
# загрузок OUM, чтобы блокировка GitHub не ломала установки целиком.
fetch_file() {
    # $1 = URL, $2 = файл назначения
    furl="$1"
    fdest="$2"
    wget -qO "$fdest" "$furl" && return 0
    case "$furl" in
        *github*)
            if ! github_hosts_fix_applied; then
                echo -e "${YELLOW}GitHub не отвечает — применяем hosts-fix и повторяем...${NC}"
                github_hosts_fix_apply && log_msg "github hosts-fix auto-applied"
                wget -qO "$fdest" "$furl" && return 0
            fi
            ;;
    esac
    command -v curl >/dev/null 2>&1 && curl -fsSL -o "$fdest" "$furl" && return 0
    return 1
}

# ====================== Безопасная загрузка+установка ======================
# Скачивает скрипт во временный файл, проверяет что скачивание удалось
# и файл не пустой, ТОЛЬКО ПОТОМ выполняет его. Возвращает 0/1 явно,
# вместо "молча выполнить что попало из wget -O -".
safe_run_remote() {
    # $1 = URL, $2 = отображаемое имя (для логов/сообщений), $3 = heredoc-ответы (опционально, через printf)
    url="$1"
    name="$2"
    answers="$3"
    tmpf="/tmp/oum_dl_$$.sh"

    if ! fetch_file "$url" "$tmpf"; then
        echo -e "${RED}❌ Не удалось скачать $name (проверьте интернет).${NC}"
        log_msg "FAIL download $name from $url"
        rm -f "$tmpf"
        return 1
    fi

    if [ ! -s "$tmpf" ]; then
        echo -e "${RED}❌ $name скачался пустым — прерываю установку.${NC}"
        log_msg "FAIL empty file $name from $url"
        rm -f "$tmpf"
        return 1
    fi

    # Грубая проверка, что это не HTML-страница ошибки вместо скрипта
    if head -c 200 "$tmpf" | grep -qi "<html"; then
        echo -e "${RED}❌ $name вернул HTML вместо скрипта (вероятно 404) — прерываю.${NC}"
        log_msg "FAIL html-instead-of-script $name from $url"
        rm -f "$tmpf"
        return 1
    fi

    if [ -n "$answers" ]; then
        printf '%b\n' "$answers" | sh "$tmpf"
    else
        sh "$tmpf"
    fi
    rc=$?

    rm -f "$tmpf"

    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}✅ $name установлен.${NC}"
        log_msg "OK install $name"
        return 0
    else
        echo -e "${RED}❌ $name завершился с ошибкой (код $rc).${NC}"
        log_msg "FAIL install $name rc=$rc"
        return 1
    fi
}

# ====================== Установка пакетов ======================
install_packages() {
    header
    if [ -z "$PKG_MANAGER" ]; then
        echo -e "${RED}❌ Неизвестный пакетный менеджер.${NC}"; pause; return
    fi
    echo -e "${GREEN}Обнаружен $PKG_MANAGER${NC}"
    pkg_update
    echo -e "${YELLOW}Устанавливаем пакеты...${NC}"
    if pkg_install nano luci-i18n-base-ru procps-ng-watch curl ca-bundle unzip tar ip-full luci-app-firewall luci-i18n-firewall-ru; then
        echo -e "${GREEN}✅ Пакеты установлены.${NC}"
        log_msg "OK install_packages"
    else
        echo -e "${RED}❌ Ошибка установки одного или нескольких пакетов, проверьте вывод выше.${NC}"
        log_msg "FAIL install_packages"
    fi
    pause
}

# ====================== Podkop: общие проверки ======================
# ВАЖНО: pgrep -f podkop нельзя использовать — он матчит сам watchdog
# (podkop-watchdog.sh) и любые процессы со словом podkop в cmdline.
# Живость = статус init-скрипта ИЛИ процесс sing-box (ядро podkop).
podkop_alive() {
    /etc/init.d/podkop status >/dev/null 2>&1 && return 0
    pgrep -x sing-box >/dev/null 2>&1
}

net_ok() {
    ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1
}

podkop_check() {
    A=0; B=0
    podkop_alive && A=1
    net_ok && B=1
    if [ "$A" = "1" ] && [ "$B" = "1" ]; then
        echo -e "${GREEN}✅ Podkop работает, интернет есть.${NC}"
        return 0
    elif [ "$A" = "1" ]; then
        echo -e "${RED}❌ Процесс podkop жив, но внешняя сеть не отвечает — возможно, завис sing-box или зависли правила.${NC}"
        return 1
    else
        echo -e "${RED}❌ Podkop не запущен.${NC}"
        return 1
    fi
}

# ====================== Podkop: каскад восстановления (ручной запуск) ======================
podkop_recover() {
    header
    if [ ! -f /etc/init.d/podkop ]; then
        echo -e "${RED}❌ Podkop не найден на этой системе.${NC}"; pause; return
    fi

    echo -e "${CYAN}Каскад восстановления podkop:${NC}"
    echo "1) Рестарт службы"
    echo "2) Стоп → обновление sing-box и podkop → старт → проверка"
    echo "3) Приостановить podkop до физической перезагрузки (интернет без прокси)"
    echo "4) Выполнить весь каскад по порядку"
    echo ""
    echo -e "${YELLOW}Enter — Назад${NC}"
    choice=$(read_choice)

    case "$choice" in
        "") return ;;
        1) _podkop_restart && podkop_check ;;
        2) _podkop_stop_update_start ;;
        3) _podkop_pause ;;
        4) _podkop_full_cascade ;;
        *) echo -e "${RED}Неверный выбор.${NC}" ;;
    esac
    pause
}

_podkop_restart() {
    echo -e "${YELLOW}Перезапуск podkop...${NC}"
    /etc/init.d/podkop restart
    sleep 5
}

_podkop_stop_update_start() {
    echo -e "${YELLOW}Останавливаем podkop...${NC}"
    /etc/init.d/podkop stop
    sleep 1

    echo -e "${YELLOW}Обновляем sing-box...${NC}"
    pkg_update && pkg_install_force sing-box

    echo -e "${YELLOW}Обновляем podkop...${NC}"
    safe_run_remote "https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh" "Podkop (обновление)" "y"

    echo -e "${YELLOW}Запускаем podkop...${NC}"
    /etc/init.d/podkop start
    sleep 5

    if podkop_check; then
        return 0
    else
        echo -e "${RED}Обновление не помогло.${NC}"
        return 1
    fi
}

# Приостановка: ТОЛЬКО stop, БЕЗ disable — служба остаётся в автозагрузке
# и после физической перезагрузки podkop стартует сам. Флаг нужен, чтобы
# установленный watchdog не пытался «оживить» то, что человек выключил.
_podkop_pause() {
    echo -e "${YELLOW}Приостанавливаем podkop (до физической перезагрузки роутера)...${NC}"
    /etc/init.d/podkop stop
    mkdir -p /tmp/podkop_watchdog
    touch /tmp/podkop_watchdog/stopped
    log_msg "podkop paused until physical reboot"
    echo -e "${GREEN}✅ Podkop остановлен. Базовый интернет (без прокси) должен работать.${NC}"
    echo -e "${YELLOW}После перезагрузки роутера podkop запустится сам. Запустить сразу: пункт «Сброс» в меню отказоустойчивости.${NC}"
}

_podkop_full_cascade() {
    echo -e "${CYAN}Шаг 1: рестарт${NC}"
    _podkop_restart
    if podkop_check; then return 0; fi

    echo -e "${CYAN}Шаг 2: стоп + обновление + старт${NC}"
    if _podkop_stop_update_start; then return 0; fi

    echo -e "${CYAN}Шаг 3: приостановка до физической перезагрузки${NC}"
    _podkop_pause
}

# ====================== Автоматический watchdog Podkop v2 (cron) ======================
# Принципы v2 (переработан после инцидентов с v1):
#  - одновременный запуск исключён lock-каталогом с проверкой живости PID
#    (v1 мог запуститься дважды, когда шаг «обновление» длился > 5 минут,
#    и за пару циклов сам себя эскалировал до отключения);
#  - «WAN жив» проверяется пингом ШЛЮЗА провайдера, а не внешних IP
#    (если правила podkop глушат трафик, внешние пинги тоже мертвы —
#    v1 в этом случае молчал, хотя это его сценарий);
#  - живость = init-статус или процесс sing-box (pgrep -f врал: матчил
#    сам watchdog);
#  - НИКАКИХ скачиваний/переустановок: в аварийном состоянии сеть может
#    быть сломана, а слепой `install.sh | sh` делает только хуже;
#  - финальный шаг: stop (НЕ disable) + флаг в /tmp — после физической
#    перезагрузки podkop стартует сам, watchdog сбрасывается.
install_podkop_watchdog() {
    header
    [ -f /etc/init.d/podkop ] || { echo -e "${RED}❌ Сначала установите Podkop.${NC}"; pause; return; }
    make_backup

    cat << 'WDEOF' > /usr/bin/podkop-watchdog.sh
#!/bin/sh
# ==================== podkop-watchdog.sh v2 (OUM) ====================
STATE_DIR="/tmp/podkop_watchdog"
FAIL_FILE="$STATE_DIR/fail_count"
STOPPED_FILE="$STATE_DIR/stopped"
LOCK_DIR="$STATE_DIR/lock"
LOG_FILE="/etc/oum/oum.log"
mkdir -p "$STATE_DIR" 2>/dev/null
mkdir -p /etc/oum 2>/dev/null
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $1" >> "$LOG_FILE"
}

# Podkop сознательно остановлен (watchdog'ом или человеком) — не вмешиваемся
[ -f "$STOPPED_FILE" ] && exit 0

# --- Исключаем одновременный запуск ---
if [ -d "$LOCK_DIR" ]; then
    LP=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$LP" ] && kill -0 "$LP" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$LOCK_DIR"
fi
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

# --- WAN вообще жив? Пинг шлюза провайдера (podkop его не перехватывает) ---
GW=$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $2; exit}')
if [ -z "$GW" ]; then
    log "нет default route — WAN не поднят, пропускаю"
    exit 0
fi
if ! ping -c 1 -W 2 "$GW" >/dev/null 2>&1; then
    log "шлюз $GW не отвечает — проблема линка/провайдера, пропускаю"
    exit 0
fi

# --- Живость podkop: init-статус ИЛИ процесс sing-box ---
podkop_alive() {
    /etc/init.d/podkop status >/dev/null 2>&1 && return 0
    pgrep -x sing-box >/dev/null 2>&1
}
# --- Внешняя сеть доступна? ---
net_ok() {
    ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1
}

if podkop_alive && net_ok; then
    rm -f "$FAIL_FILE"
    exit 0
fi

A=0; B=0
podkop_alive && A=1
net_ok && B=1

FAIL=0
[ -f "$FAIL_FILE" ] && FAIL=$(cat "$FAIL_FILE")
FAIL=$((FAIL + 1))
echo "$FAIL" > "$FAIL_FILE"
log "проверка не прошла (podkop=$A, внешняя сеть=$B), неудача №$FAIL подряд"

if [ "$FAIL" -eq 1 ]; then
    log "шаг 1: рестарт podkop"
    /etc/init.d/podkop restart
    sleep 20
    if podkop_alive && net_ok; then
        log "шаг 1 помог — podkop восстановлен"
        rm -f "$FAIL_FILE"
    else
        log "шаг 1 не помог"
    fi
    exit 0
fi

if [ "$FAIL" -eq 2 ]; then
    log "шаг 2: рестарт firewall + podkop (чистка зависших правил)"
    /etc/init.d/podkop stop
    /etc/init.d/firewall restart
    sleep 3
    /etc/init.d/podkop start
    sleep 30
    if podkop_alive && net_ok; then
        log "шаг 2 помог — podkop восстановлен"
        rm -f "$FAIL_FILE"
    else
        log "шаг 2 не помог"
    fi
    exit 0
fi

log "шаг 3: podkop не восстановился за 3 попытки — останавливаю его (базовый интернет), до перезагрузки/сброса"
/etc/init.d/podkop stop
touch "$STOPPED_FILE"
log "podkop остановлен watchdog'ом. После перезагрузки роутера запустится сам. Лог: $LOG_FILE"
WDEOF
    chmod +x /usr/bin/podkop-watchdog.sh

    read -p "Интервал проверки watchdog, минут [5]: " wdint
    wdint=${wdint:-5}
    case "$wdint" in
        ''|*[!0-9]*) wdint=5 ;;
    esac
    [ "$wdint" -lt 1 ] && wdint=1
    [ "$wdint" -gt 59 ] && wdint=59

    ( crontab -l 2>/dev/null | grep -v podkop-watchdog.sh ; echo "*/$wdint * * * * /usr/bin/podkop-watchdog.sh" ) | crontab -
    /etc/init.d/cron restart

    log_msg "podkop watchdog v2 installed (cron */$wdint)"
    echo -e "${GREEN}✅ Watchdog v2 установлен (крон: каждые $wdint мин).${NC}"
    echo -e "${CYAN}Каскад: рестарт → firewall+рестарт → стоп до перезагрузки. Без автообновлений.${NC}"
    echo -e "${YELLOW}Проверьте работу: меню отказоустойчивости → «ТЕСТ watchdog» (уронит и оживит podkop).${NC}"
    echo -e "${YELLOW}Лог: /etc/oum/oum.log (строки [watchdog]).${NC}"
    pause
}

uninstall_podkop_watchdog() {
    header
    crontab -l 2>/dev/null | grep -v podkop-watchdog.sh | crontab -
    /etc/init.d/cron restart
    rm -f /usr/bin/podkop-watchdog.sh
    rm -rf /tmp/podkop_watchdog
    log_msg "podkop watchdog uninstalled"
    echo -e "${GREEN}✅ Watchdog удалён из cron и с роутера.${NC}"
    pause
}

# --- Служебные операции watchdog'а для меню ---
watchdog_resume() {
    header
    if [ ! -f /etc/init.d/podkop ]; then
        echo -e "${RED}❌ Podkop не установлен.${NC}"; pause; return
    fi
    echo -e "${YELLOW}Сбрасываем состояние watchdog и запускаем podkop...${NC}"
    rm -f /tmp/podkop_watchdog/fail_count /tmp/podkop_watchdog/stopped
    /etc/init.d/podkop enable 2>/dev/null
    /etc/init.d/podkop start
    sleep 5
    if podkop_check; then
        log_msg "OK watchdog_resume"
    else
        echo -e "${YELLOW}Podkop не поднялся — запустите каскад восстановления.${NC}"
    fi
    pause
}

watchdog_test() {
    header
    echo -e "${CYAN}=== ТЕСТ watchdog: уронить podkop → watchdog должен оживить ===${NC}"
    if [ ! -x /usr/bin/podkop-watchdog.sh ]; then
        echo -e "${RED}❌ Watchdog не установлен (пункт 1).${NC}"; pause; return
    fi
    if [ -f /tmp/podkop_watchdog/stopped ]; then
        echo -e "${RED}❌ Podkop остановлен watchdog'ом — сначала сброс (пункт 6).${NC}"; pause; return
    fi
    if ! podkop_alive; then
        echo -e "${RED}❌ Podkop сейчас и так не запущен — тест не показателен. Сначала пункт 6 (сброс).${NC}"; pause; return
    fi
    GW=$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $2; exit}')
    if [ -z "$GW" ] || ! ping -c 1 -W 2 "$GW" >/dev/null 2>&1; then
        echo -e "${RED}❌ Шлюз провайдера недоступен — watchdog в тесте корректно ничего не сделает. Тест отменён.${NC}"; pause; return
    fi

    echo "1/4: Уроним podkop (stop + kill sing-box, как при реальном падении)..."
    /etc/init.d/podkop stop >/dev/null 2>&1
    pkill -x sing-box 2>/dev/null
    sleep 1
    if podkop_alive; then
        echo -e "${RED}❌ Не удалось уронить podkop — тест прерван, запускаю обратно.${NC}"
        /etc/init.d/podkop start
        pause; return
    fi
    echo -e "  ${YELLOW}podkop мёртв ✔${NC}"

    echo "2/4: Запускаем watchdog (один прогон, ~30 секунд, ждите)..."
    rm -f /tmp/podkop_watchdog/fail_count
    LOG_BEFORE=$(wc -l < /etc/oum/oum.log 2>/dev/null || echo 0)
    /usr/bin/podkop-watchdog.sh
    echo -e "  ${YELLOW}watchdog отработал ✔${NC}"

    echo "3/4: Что записал watchdog в лог:"
    tail -n +$((LOG_BEFORE + 1)) /etc/oum/oum.log 2>/dev/null | sed 's/^/  /'

    echo "4/4: Итог:"
    rm -f /tmp/podkop_watchdog/fail_count
    if podkop_alive && net_ok; then
        echo -e "${GREEN}✅ ТЕСТ ПРОЙДЕН: watchdog обнаружил падение и оживил podkop.${NC}"
        log_msg "OK watchdog_test passed"
    else
        echo -e "${RED}❌ ТЕСТ ПРОВАЛЕН: podkop не поднялся. Смотрим лог выше и каскад вручную.${NC}"
        echo -e "${YELLOW}Поднимаю podkop принудительно...${NC}"
        /etc/init.d/podkop start
        sleep 5
        podkop_check
        log_msg "FAIL watchdog_test"
    fi
    pause
}

# ====================== Первичная настройка ======================
menu_primary() {
    while true; do
        header
        echo "1) Установка необходимого ПО (база)"
        echo "2) Установка AmneziaWG"
        echo "3) Установка Podkop"
        echo "4) Установка Zapret"
        echo "5) Установить ВСЁ сразу (база + AWG + Podkop + Zapret v1)"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) install_packages ;;
            2) make_backup
                safe_run_remote "https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh" "AmneziaWG" "y
n"
                pause ;;
            3) make_backup
                safe_run_remote "https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh" "Podkop" "y"
                pause ;;
            4)
                echo "1) Zapret v1 (remittor)"
                echo "2) Zapret v2 (remittor)"
                echo "3) Zapret Manager (StressOzz) — всегда свежая версия с GitHub"
                [ -x /usr/bin/zms ] && echo -e "   ${CYAN}(уже установлен: команда zms запускает его в любой момент)${NC}"
                z=$(read_choice)
                case "$z" in
                    1) if fetch_file "https://raw.githubusercontent.com/remittor/zapret-openwrt/zap1/zapret/update-pkg.sh" /tmp/zap.sh && [ -s /tmp/zap.sh ]; then
                           sh /tmp/zap.sh -u 1
                       else
                           echo -e "${RED}❌ Не удалось скачать установщик Zapret.${NC}"
                           log_msg "FAIL download zapret v1"
                       fi ;;
                    2) if fetch_file "https://raw.githubusercontent.com/remittor/zapret-openwrt/zap1/zapret/update-pkg.sh" /tmp/zap.sh && [ -s /tmp/zap.sh ]; then
                           sh /tmp/zap.sh -u 2
                       else
                           echo -e "${RED}❌ Не удалось скачать установщик Zapret.${NC}"
                           log_msg "FAIL download zapret v2"
                       fi ;;
                    3) safe_run_remote "https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/Zapret-Manager.sh" "Zapret Manager" ;;
                esac
                pause ;;
            5)
                make_backup
                install_packages
                safe_run_remote "https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh" "AmneziaWG" "y
n"
                safe_run_remote "https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh" "Podkop" "y"
                fetch_file "https://raw.githubusercontent.com/remittor/zapret-openwrt/zap1/zapret/update-pkg.sh" /tmp/zap.sh && [ -s /tmp/zap.sh ] && sh /tmp/zap.sh -u 1
                echo -e "${GREEN}✅ Всё установлено (см. сообщения выше по каждому компоненту).${NC}"
                pause ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== GearUP ======================
menu_gearup() {
    while true; do
        header
        echo "=== GearUP Booster ==="
        echo "1) Установка GearUP"
        echo "2) Монитор (procd-сервис) + Firewall"
        echo "3) Сохранить привязку + сервис восстановления"
        echo "4) Выполнить ВСЕ шаги по порядку"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1)
                make_backup
                echo -e "${YELLOW}Проверяем модуль kmod-tun...${NC}"
                if ! pkg_is_installed kmod-tun; then
                    echo -e "${YELLOW}kmod-tun не найден, устанавливаем...${NC}"
                    pkg_update && pkg_install kmod-tun
                fi
                if [ ! -e /dev/net/tun ]; then
                    echo -e "${RED}❌ /dev/net/tun недоступен — GearUP не будет работать на этой прошивке/ядре.${NC}"
                    pause; continue
                fi
                echo -e "${YELLOW}Устанавливаем GearUP (официальный метод: curl sdp.gg/op)...${NC}"
                if command -v curl >/dev/null 2>&1; then
                    curl sdp.gg/op | sh
                else
                    wget -qO- sdp.gg/op | sh
                fi
                echo -e "${YELLOW}Если в выводе выше есть 'sn=' — установка прошла успешно.${NC}"
                pause ;;
            2)
                make_backup
                cat << 'EOF' > /usr/bin/gearup-monitor.sh
#!/bin/sh
while true; do
    if ip rule show | grep -q "lookup 135"; then
        if ! ip rule show | grep -q "priority 51:"; then
            TARGET_IP=$(ip rule show | grep "lookup 135" | awk '{print $3}' | head -n 1)
            [ -n "$TARGET_IP" ] && [ "$TARGET_IP" != "all" ] && ip rule add from "$TARGET_IP" lookup 119 priority 51 2>/dev/null
        fi
    else
        ip rule del priority 51 2>/dev/null
    fi
    if ip rule show | grep -q "lookup 136"; then
        if ! ip rule show | grep -q "priority 52:"; then
            TARGET_IP=$(ip rule show | grep "lookup 136" | awk '{print $3}' | head -n 1)
            [ -n "$TARGET_IP" ] && [ "$TARGET_IP" != "all" ] && ip rule add from "$TARGET_IP" lookup 120 priority 52 2>/dev/null
        fi
    else
        ip rule del priority 52 2>/dev/null
    fi
    sleep 4
done
EOF
                chmod +x /usr/bin/gearup-monitor.sh

                # procd-сервис вместо rc.local-хака: OpenWrt сам перезапустит
                # процесс при падении и будет вести respawn-лог.
                cat << 'EOF' > /etc/init.d/gearup-monitor
#!/bin/sh /etc/rc.common
START=95
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/gearup-monitor.sh
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
                chmod +x /etc/init.d/gearup-monitor
                /etc/init.d/gearup-monitor enable
                /etc/init.d/gearup-monitor start

                # Статическое правило маршрутизации всё ещё нужно один раз при загрузке
                uci -q delete network.gearup_rule
                uci set network.gearup_rule='rule'
                uci set network.gearup_rule.priority='50'
                uci set network.gearup_rule.src='192.168.255.255/32'
                uci set network.gearup_rule.lookup='121'
                uci commit network

                uci set firewall.@defaults[0].input='ACCEPT'
                uci set firewall.@defaults[0].output='ACCEPT'
                uci set firewall.@defaults[0].forward='ACCEPT'
                uci commit firewall
                /etc/init.d/firewall restart
                echo -e "${GREEN}✅ Монитор запущен как procd-сервис (автоперезапуск при падении) + Firewall настроен.${NC}"
                pause ;;
            3)
                echo -e "${YELLOW}Вы уже привязали роутер в приложении GearUP? (y/n)${NC}"
                read -p "Ответ: " bound
                if [ "$bound" != "y" ] && [ "$bound" != "Y" ]; then
                    echo -e "${RED}Сначала привяжите роутер в приложении!${NC}"
                    pause; continue
                fi
                mkdir -p /etc/gearup_persist
                if [ -d "/tmp/gu" ]; then
                    cp -r /tmp/gu /etc/gearup_persist/
                    echo -e "${GREEN}✅ Привязка сохранена.${NC}"
                else
                    echo -e "${RED}❌ /tmp/gu не найдена.${NC}"
                fi
                cat << 'EOF' > /etc/init.d/gearup_restore
#!/bin/sh /etc/rc.common
START=50
start() {
    sleep 10
    if [ -d "/etc/gearup_persist/gu" ]; then
        killall guplugin 2>/dev/null
        sleep 3
        rm -rf /tmp/gu
        cp -r /etc/gearup_persist/gu /tmp/
        chown -R 2969:2969 /tmp/gu 2>/dev/null
        chmod +x /tmp/gu/guplugin 2>/dev/null
    fi
}
stop() { return 0; }
EOF
                chmod +x /etc/init.d/gearup_restore
                /etc/init.d/gearup_restore enable
                echo -e "${GREEN}✅ Сервис восстановления создан.${NC}"
                pause ;;
            4)
                echo -e "${YELLOW}Выполняем все шаги GearUP...${NC}"
                make_backup
                if ! pkg_is_installed kmod-tun; then
                    pkg_update && pkg_install kmod-tun
                fi
                if [ ! -e /dev/net/tun ]; then
                    echo -e "${RED}❌ /dev/net/tun недоступен — GearUP не будет работать на этой прошивке/ядре.${NC}"
                    pause; continue
                fi
                if command -v curl >/dev/null 2>&1; then
                    curl sdp.gg/op | sh
                else
                    wget -qO- sdp.gg/op | sh
                fi
                pause
                echo -e "${GREEN}Шаг 2: используйте пункт 2 меню для монитора.${NC}"
                pause
                echo -e "${YELLOW}Шаг 3: Убедитесь, что роутер привязан в приложении, затем используйте пункт 3.${NC}"
                pause
                ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== Аппаратное ускорение (flow offloading) ======================
hw_accel_supported() {
    # Признаки поддержки аппаратного offload: загруженный модуль HNAT
    # (MediaTek MT7621/MT798x и др.) либо упоминания в dmesg.
    [ -d /sys/module/mtk_hnat ] && return 0
    dmesg 2>/dev/null | grep -qi "hnat\|flow.*offload" && return 0
    return 1
}

hw_accel_apply() {
    # $1 = software offloading (0/1), $2 = hardware offloading (0/1)
    # Программный offload работает почти везде; аппаратный — только на
    # поддерживаемых чипах, но ядро само игнорирует опцию, если чип
    # не поддерживает — поэтому применяем и проверяем по dmesg.
    uci set firewall.@defaults[0].flow_offloading="$1"
    uci set firewall.@defaults[0].flow_offloading_hw="$2"
    uci commit firewall
    /etc/init.d/firewall restart
    sleep 2
}

hw_accel_verify() {
    if dmesg 2>/dev/null | tail -n 50 | grep -qi "flow.*offload\|hnat"; then
        echo -e "${GREEN}✅ Аппаратное ускорение включено, есть признаки активности в dmesg.${NC}"
    else
        echo -e "${YELLOW}⚠️  Опции применены, но явного подтверждения в dmesg не найдено.${NC}"
        echo -e "${YELLOW}   Возможно ваш чипсет не поддерживает hardware offloading — тогда работает только software flow offloading (тоже полезно, но не так сильно разгружает CPU).${NC}"
    fi
}

# --- FIX совместимости flow offloading с DPI-обходом (Zapret) ---
# Патч из Zapret-Manager (StressOzz): offload соединения только после
# 30 пакетов в оригинальном направлении. Вся работа DPI-обхода zapret
# (fake/desync через NFQUEUE) происходит в первых пакетах соединения —
# они продолжат идти через обычный netfilter-путь, а долгие передачи
# всё равно ускоряются. Шаблон принадлежит пакету firewall4 и вернётся
# к стоковому виду при его обновлении — FIX нужно применить снова.
FW4_TEMPLATE="/usr/share/firewall4/templates/ruleset.uc"

hw_offload_fix_applied() {
    grep -q 'ct original packets ge 30 flow offload @ft;' "$FW4_TEMPLATE" 2>/dev/null
}

hw_offload_fix_available() {
    [ -f "$FW4_TEMPLATE" ] && grep -q 'meta l4proto { tcp, udp } flow offload @ft;' "$FW4_TEMPLATE" 2>/dev/null
}

hw_offload_fix_apply() {
    hw_offload_fix_applied && return 0
    hw_offload_fix_available || return 1
    sed -i 's/meta l4proto { tcp, udp } flow offload @ft;/meta l4proto { tcp, udp } ct original packets ge 30 flow offload @ft;/' "$FW4_TEMPLATE" \
        && /etc/init.d/firewall restart >/dev/null 2>&1
    hw_offload_fix_applied
}

hw_offload_fix_revert() {
    hw_offload_fix_applied || return 0
    sed -i 's/meta l4proto { tcp, udp } ct original packets ge 30 flow offload @ft;/meta l4proto { tcp, udp } flow offload @ft;/' "$FW4_TEMPLATE"
    /etc/init.d/firewall restart >/dev/null 2>&1
}

_hw_offer_fix() {
    # После включения offloading: если стоит Zapret — предложить FIX
    [ -f /etc/init.d/zapret ] || return 0
    hw_offload_fix_applied && return 0
    hw_offload_fix_available || return 0
    echo -e "${YELLOW}Обнаружен Zapret: offloading может ломать его работу (первые пакеты соединения уходят в offload мимо NFQUEUE).${NC}"
    read -p "Применить FIX (offload только после 30 пакетов соединения)? (Y/n): " fixans
    case "$fixans" in
        n|N) return 0 ;;
    esac
    if hw_offload_fix_apply; then
        echo -e "${GREEN}✅ FIX применён.${NC}"
        log_msg "OK hw_offload_fix applied"
    else
        echo -e "${RED}❌ Не удалось применить FIX (шаблон firewall4 не совпал).${NC}"
        log_msg "FAIL hw_offload_fix apply"
    fi
}

menu_hw_accel() {
    while true; do
        header
        echo -e "${CYAN}=== Аппаратное ускорение (flow offloading) ===${NC}"
        if [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = "1" ]; then
            echo "Software offloading: ${GREEN}включён${NC}"
        else
            echo "Software offloading: ${YELLOW}выключен${NC}"
        fi
        if [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = "1" ]; then
            echo "Hardware offloading: ${GREEN}включён${NC}"
        else
            echo "Hardware offloading: ${YELLOW}выключен${NC}"
        fi
        if hw_accel_supported; then
            echo "Чипсет: ${GREEN}похоже, поддерживает hardware offload${NC}"
        else
            echo "Чипсет: ${YELLOW}признаков hardware offload не найдено (доступен только software)${NC}"
        fi
        if hw_offload_fix_applied; then
            echo "FIX для DPI-обхода (Zapret): ${GREEN}применён${NC}"
        elif hw_offload_fix_available; then
            echo "FIX для DPI-обхода (Zapret): ${YELLOW}не применён${NC}"
        elif [ -f "$FW4_TEMPLATE" ]; then
            echo "FIX для DPI-обхода (Zapret): ${YELLOW}неприменим (шаблон firewall4 отличается)${NC}"
        fi
        FO_ON=0
        [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = "1" ] && FO_ON=1
        [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = "1" ] && FO_ON=1
        if [ "$FO_ON" = "1" ] && [ -f /etc/init.d/zapret ] && ! hw_offload_fix_applied; then
            echo -e "${RED}⚠️  Включён offloading + Zapret без FIX — обход может работать некорректно. Примените FIX (пункт 4).${NC}"
        fi
        echo ""
        echo "1) Включить HW + SW offloading (максимальная разгрузка CPU)"
        echo "2) Включить только SW offloading (работает на любом чипсете)"
        echo "3) Выключить offloading"
        if hw_offload_fix_applied || hw_offload_fix_available; then
            if hw_offload_fix_applied; then
                echo "4) Отключить FIX для DPI-обхода (Zapret)"
            else
                echo "4) Применить FIX для DPI-обхода (Zapret)"
            fi
        fi
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1)
                echo -e "${YELLOW}Включаем hardware + software flow offloading...${NC}"
                make_backup
                hw_accel_apply 1 1
                hw_accel_verify
                _hw_offer_fix
                log_msg "hw_acceleration enabled (hw+sw)"
                pause ;;
            2)
                echo -e "${YELLOW}Включаем software flow offloading...${NC}"
                make_backup
                hw_accel_apply 1 0
                echo -e "${GREEN}✅ Software offloading включён.${NC}"
                _hw_offer_fix
                log_msg "hw_acceleration enabled (sw only)"
                pause ;;
            3)
                echo -e "${YELLOW}Выключаем flow offloading...${NC}"
                make_backup
                hw_accel_apply 0 0
                echo -e "${GREEN}✅ Offloading выключен.${NC}"
                log_msg "hw_acceleration disabled"
                pause ;;
            4)
                if hw_offload_fix_applied; then
                    echo -e "${YELLOW}Отключаем FIX...${NC}"
                    hw_offload_fix_revert
                    echo -e "${GREEN}✅ FIX отключён.${NC}"
                    log_msg "hw_offload_fix reverted"
                elif hw_offload_fix_apply; then
                    echo -e "${GREEN}✅ FIX применён: первые ~30 пакетов соединения идут через CPU (DPI-обход работает), дальше — offload.${NC}"
                    echo -e "${YELLOW}Обновление пакета firewall4 сбрасывает шаблон — примените FIX снова.${NC}"
                    log_msg "OK hw_offload_fix applied"
                else
                    echo -e "${RED}❌ Не удалось применить FIX (шаблон firewall4 не совпал).${NC}"
                    log_msg "FAIL hw_offload_fix apply"
                fi
                pause ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== Wi-Fi ======================
wifi_setup() {
    header
    echo -e "${CYAN}Настройка Wi-Fi${NC}"
    echo -e "${YELLOW}Один SSID будет установлен на оба диапазона (2.4 и 5 ГГц).${NC}"
    read -p "Имя сети (SSID): " ssid
    if [ -z "$ssid" ]; then
        echo -e "${RED}❌ SSID не может быть пустым.${NC}"; pause; return
    fi
    read -p "Пароль (Enter — оставить сеть ОТКРЫТОЙ, без пароля): " wifi_pass

    if [ -n "$wifi_pass" ] && [ "${#wifi_pass}" -lt 8 ]; then
        echo -e "${RED}❌ Пароль слишком короткий (WPA2 требует минимум 8 символов). Либо ≥8 символов, либо пусто для открытой сети.${NC}"
        pause; return
    fi

    make_backup
    for dev in $(uci show wireless | grep '=wifi-iface' | cut -d. -f2 | cut -d= -f1); do
        uci set wireless."$dev".disabled='0'
        uci set wireless."$dev".ssid="$ssid"
        if [ -n "$wifi_pass" ]; then
            uci set wireless."$dev".encryption='psk2'
            uci set wireless."$dev".key="$wifi_pass"
        else
            uci set wireless."$dev".encryption='none'
            uci -q delete wireless."$dev".key
        fi
    done
    for radio in $(uci show wireless | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
        uci set wireless."$radio".disabled='0'
        uci set wireless."$radio".country='PA'
    done
    if uci commit wireless && wifi reload; then
        if [ -n "$wifi_pass" ]; then
            echo -e "${GREEN}✅ Wi-Fi настроен: SSID \"$ssid\" (WPA2), страна PA.${NC}"
        else
            echo -e "${YELLOW}⚠️  Wi-Fi настроен БЕЗ пароля (открытая сеть): SSID \"$ssid\", страна PA.${NC}"
        fi
        log_msg "OK wifi_setup ssid=$ssid open=$( [ -z "$wifi_pass" ] && echo yes || echo no )"
    else
        echo -e "${RED}❌ Не удалось применить настройки Wi-Fi.${NC}"
        log_msg "FAIL wifi_setup"
    fi
    pause
}

# ====================== Wi-Fi powersave fix ======================
# Отключает powersave на ВСЕХ обнаруженных радиомодулях (не хардкодит
# radio0/radio1 — на роутерах с другой нумерацией/количеством радио
# старая версия просто ничего не делала бы молча). Лечит обрывы Wi-Fi
# при устойчивой нагрузке (характерно для RAX3000M и похожих чипов
# под нагрузкой NAS/USB), но полезно как отдельный пункт меню сам по
# себе, не только внутри установки NAS.
_wifi_powersave_fix_apply() {
    applied=0
    for radio in $(uci show wireless 2>/dev/null | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
        uci set wireless."$radio".powersave='0'
        applied=1
    done
    if [ "$applied" -eq 0 ]; then
        echo -e "${RED}❌ Не найдено ни одного радиомодуля в wireless-конфиге.${NC}"
        log_msg "FAIL wifi_powersave_fix: no radios found"
        return 1
    fi
    if uci commit wireless && { wifi reload 2>/dev/null || wifi; }; then
        echo -e "${GREEN}✅ Wi-Fi powersave отключён на всех радиомодулях.${NC}"
        log_msg "OK wifi_powersave_fix"
        return 0
    else
        echo -e "${RED}❌ Не удалось применить настройки Wi-Fi.${NC}"
        log_msg "FAIL wifi_powersave_fix: apply failed"
        return 1
    fi
}

wifi_powersave_fix() {
    header
    echo -e "${CYAN}Отключение Wi-Fi powersave${NC}"
    echo -e "${YELLOW}Лечит обрывы/просадки Wi-Fi при устойчивой нагрузке на роутер${NC}"
    echo -e "${YELLOW}(например, активный NAS/USB-накопитель) — известная особенность${NC}"
    echo -e "${YELLOW}RAX3000M и ряда похожих чипов.${NC}"
    make_backup
    _wifi_powersave_fix_apply
    pause
}

# ====================== Медиа-сортировщик (TV/Movies + TMDB) ======================
# Конфиг (пути) и ключ TMDB хранятся ОТДЕЛЬНО от самого media-organizer.py
# (/etc/oum/media-organizer.conf и /etc/oum/tmdb_api_key) — переустановка
# или обновление скрипта не требует повторного ввода ключа. Один и тот же
# /usr/bin/media-organizer.py одинаков у всех, различаются только конфиги.
# У каждого пользователя должен быть СВОЙ TMDB-ключ (бесплатный).

_tmdb_key_instructions() {
    echo -e "${CYAN}Как получить бесплатный TMDB API-ключ (у каждого — свой):${NC}"
    echo "1. Зайдите на https://www.themoviedb.org и зарегистрируйтесь (или войдите)."
    echo "2. Перейдите в Settings -> API (в левом меню)."
    echo "3. Нажмите Create -> выберите Developer."
    echo "4. Примите условия использования, заполните анкету произвольными данными"
    echo "   (в названии приложения можно указать 'Home NAS', в URL — 'http://localhost')."
    echo "5. Скопируйте значение поля 'API Key (v3 auth)' — это и есть ваш ключ."
    echo ""
    echo -e "${YELLOW}Ключ бесплатный. Не используйте один и тот же ключ на нескольких роутерах —${NC}"
    echo -e "${YELLOW}у TMDB есть лимит запросов в секунду на ключ.${NC}"
}

media_organizer_set_key() {
    _tmdb_key_instructions
    echo ""
    current=""
    [ -f /etc/oum/tmdb_api_key ] && current=$(cat /etc/oum/tmdb_api_key)
    if [ -n "$current" ]; then
        echo -e "${CYAN}Текущий сохранённый ключ: ${current}${NC}"
    fi
    read -p "Вставьте ваш TMDB API-ключ (Enter — оставить как есть): " key
    if [ -z "$key" ]; then
        if [ -z "$current" ]; then
            echo -e "${RED}❌ Ключ не задан. Без него сортировка будет работать, но без русских названий.${NC}"
        else
            echo -e "${YELLOW}Ключ не изменён.${NC}"
        fi
        return
    fi
    if ! echo "$key" | grep -qE '^[a-f0-9]{32}$'; then
        echo -e "${YELLOW}⚠️  Ключ не похож на стандартный TMDB v3 ключ (32 hex-символа), но сохраняю как есть.${NC}"
        echo -e "${YELLOW}   Если TMDB не ответит — перепроверьте ключ через это же меню.${NC}"
    fi
    mkdir -p /etc/oum
    echo "$key" > /etc/oum/tmdb_api_key
    chmod 600 /etc/oum/tmdb_api_key
    echo -e "${GREEN}✅ Ключ сохранён в /etc/oum/tmdb_api_key.${NC}"
    log_msg "OK media_organizer_set_key"
}

_media_organizer_deploy_files() {
    # Сам код НЕ содержит ни путей, ни ключа — оба читаются из /etc/oum/ при
    # каждом запуске. Тело функции неизменно между установками/обновлениями.
    cat << 'PYEOF' > /usr/bin/media-organizer.py
#!/usr/bin/env python3
import os
import re
import shutil
import sys
import json
import ssl
import socket
import subprocess
import urllib.parse
import urllib.request

CONFIG_FILE = "/etc/oum/media-organizer.conf"
KEY_FILE = "/etc/oum/tmdb_api_key"

DEFAULTS = {
    "SOURCE_DIR": "/mnt/hdd/NAS/downloads",
    "MOVIES_DIR": "/mnt/hdd/NAS/Movies",
    "TV_DIR": "/mnt/hdd/NAS/TV",
    "LANGUAGE": "ru-RU",
}

def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return cfg

def load_api_key():
    try:
        with open(KEY_FILE) as f:
            key = f.read().strip()
            return key if key else None
    except FileNotFoundError:
        return None

CFG = load_config()
SOURCE_DIR = CFG["SOURCE_DIR"]
MOVIES_DIR = CFG["MOVIES_DIR"]
TV_DIR = CFG["TV_DIR"]
LANGUAGE = CFG["LANGUAGE"]
TMDB_API_KEY = load_api_key()

VIDEO_EXTS = {'.mkv', '.mp4', '.avi', '.m4v', '.mov', '.ts'}
CLEAN_EXTS = {'.torrent', '.aria2'}

TV_EPISODE_PATTERNS = [
    re.compile(r'^(.*?)[. ]+[sS](\d{1,2})[eE](\d{1,2})', re.IGNORECASE),
    re.compile(r'^(.*?)[. ]+(\d{1,2})x(\d{1,2})', re.IGNORECASE),
    re.compile(r'^[sS](\d{1,2})[eE](\d{1,2})', re.IGNORECASE),
]

def sanitize_filename(name):
    """Убирает символы, недопустимые в именах файлов на Windows/NTFS/SMB,
    чтобы файлы были видны и открывались через сетевой проводник и ТВ-плееры."""
    name = name.replace(':', ' -')
    name = re.sub(r'[\\/*?"<>|]', '', name)
    name = re.sub(r'\s+', ' ', name).strip()
    return name


def safe_move(src, dest_path):
    """Переносит файл, не перезаписывая существующий: при конфликте имени
    добавляет суффикс (2), (3) и т.д. к имени файла."""
    if not os.path.exists(dest_path):
        shutil.move(src, dest_path)
        return dest_path

    base, ext = os.path.splitext(dest_path)
    counter = 2
    while True:
        candidate = f"{base} ({counter}){ext}"
        if not os.path.exists(candidate):
            shutil.move(src, candidate)
            return candidate
        counter += 1


def clean_search_term(name):
    name = re.sub(r'-\s*\[\d+x\d+\]', '', name)
    name = re.sub(r'[\. \[\(]?(?:19|20)\d{2}.*$', '', name, flags=re.IGNORECASE)
    junk_pattern = r'(?i)\b(1080p|720p|2160p|4k|uhd|imax|dv|hdr|web-dl|web-dlrip|bdrip|hdrip|remux|bluray|x264|x265|hevc|h265|h264|aac|ac3|dub[^\s]*|5xrus|eng|hdclub)\b'
    name = re.sub(junk_pattern, '', name)
    return name.replace('.', ' ').strip(' -_')

# TMDB иногда возвращает generic-заглушку вместо реального названия серии
# ("Episode 5" по-английски, "Эпизод 5" на русском при language=ru-RU) —
# такую заглушку добавлять к имени файла бессмысленно, лучше её просто
# отбросить и оставить только номер сезона/серии.
GENERIC_EP_TITLE_RE = re.compile(r'(?i)^(episode|эпизод)\s*\d+$')

# Папка "Season N"/"Сезон N" сама по себе не название сериала — если файл
# лежит в такой подпапке (downloads/Шоу/Season 2/файл.mkv), нужно название
# из папки НАД ней, а не из "Season 2".
SEASON_FOLDER_RE = re.compile(r'(?i)^(s|season|сезон)\s*\.?\s*\d{1,2}$')

def resolve_show_name_from_path(filepath, matched_group1, source_dir):
    """Возвращает название сериала: из имени файла (если regex его выделил),
    иначе поднимается по дереву папок мимо "Season N"-подпапок до первой
    осмысленной директории, но не выше source_dir."""
    if matched_group1 and matched_group1.strip():
        return matched_group1.strip()

    d = os.path.dirname(filepath)
    source_dir_norm = os.path.normpath(source_dir)
    for _ in range(4):
        d_norm = os.path.normpath(d)
        if d_norm == source_dir_norm or len(d_norm) <= len(source_dir_norm):
            break
        name = os.path.basename(d)
        if name and not SEASON_FOLDER_RE.match(name.strip()):
            return name
        d = os.path.dirname(d)
    # ничего осмысленного не нашли — возвращаем то, что было изначально
    return os.path.basename(os.path.dirname(filepath))


def cleanup_empty_dirs(base_dir):
    """Удаляет опустевшие после переноса файлов папки внутри base_dir
    (саму base_dir не трогает)."""
    for root, dirs, files in os.walk(base_dir, topdown=False):
        if os.path.normpath(root) == os.path.normpath(base_dir):
            continue
        try:
            if not os.listdir(root):
                os.rmdir(root)
        except OSError:
            pass

TMDB_HOST = "api.themoviedb.org"
_TMDB_IP_CACHE = None

def resolve_tmdb_ip():
    """Резолвим TMDB через публичный DNS (1.1.1.1), в обход возможного
    fake-ip локального резолвера (например, если стоит podkop/AdGuard и т.п.)."""
    global _TMDB_IP_CACHE
    if _TMDB_IP_CACHE:
        return _TMDB_IP_CACHE
    try:
        out = subprocess.run(
            ["nslookup", TMDB_HOST, "1.1.1.1"],
            capture_output=True, text=True, timeout=5
        ).stdout
        ips = re.findall(r'Address:\s*(\d+\.\d+\.\d+\.\d+)\s*$', out, re.MULTILINE)
        if ips:
            _TMDB_IP_CACHE = ips[0]
            return _TMDB_IP_CACHE
    except Exception:
        pass
    return None

_orig_getaddrinfo = socket.getaddrinfo
def _patched_getaddrinfo(host, *args, **kwargs):
    if host == TMDB_HOST:
        ip = resolve_tmdb_ip()
        if ip:
            return _orig_getaddrinfo(ip, *args, **kwargs)
    return _orig_getaddrinfo(host, *args, **kwargs)
socket.getaddrinfo = _patched_getaddrinfo

def fetch_tmdb(endpoint, params):
    if not TMDB_API_KEY:
        return None
    params['api_key'] = TMDB_API_KEY
    params['language'] = LANGUAGE
    url = f"https://{TMDB_HOST}/3/{endpoint}?" + urllib.parse.urlencode(params)
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=8) as response:
            if response.status == 200:
                return json.loads(response.read().decode('utf-8'))
    except Exception:
        pass
    return None

def get_ru_movie_title(query_name):
    data = fetch_tmdb("search/movie", {"query": query_name})
    if data and data.get('results'):
        title = data['results'][0].get('title')
        if title:
            return title
    return None

def get_ru_tv_info(query_name, season, episode):
    search_data = fetch_tmdb("search/tv", {"query": query_name})
    if search_data and search_data.get('results'):
        show = search_data['results'][0]
        tv_id = show['id']
        official_show_title = show.get('name') or query_name

        ep_data = fetch_tmdb(f"tv/{tv_id}/season/{season}/episode/{episode}", {})
        ep_title = ep_data.get('name') if ep_data else None

        return official_show_title, ep_title
    return query_name, None

def process_file(filepath):
    if not os.path.exists(filepath):
        return

    filename = os.path.basename(filepath)
    ext = os.path.splitext(filename)[1].lower()

    if ext in CLEAN_EXTS:
        try:
            os.remove(filepath)
            print(f"[CLEAN] Удален служебный файл: {filename}")
        except Exception:
            pass
        return

    if ext not in VIDEO_EXTS:
        return

    parent_dir_name = os.path.basename(os.path.dirname(filepath))
    raw_name = os.path.splitext(filename)[0]

    for pattern in TV_EPISODE_PATTERNS:
        match = pattern.search(raw_name)
        if match:
            has_name_group = len(match.groups()) == 3
            matched_group1 = match.group(1) if has_name_group else None
            season = int(match.group(2 if has_name_group else 1))
            episode = int(match.group(3 if has_name_group else 2))

            raw_show_name = resolve_show_name_from_path(filepath, matched_group1, SOURCE_DIR)
            search_term = clean_search_term(raw_show_name)
            show_title, ep_title = get_ru_tv_info(search_term, season, episode)
            show_title = sanitize_filename(show_title)

            dest_dir = os.path.join(TV_DIR, show_title, f"Season {season:02d}")
            os.makedirs(dest_dir, exist_ok=True)

            if ep_title and not GENERIC_EP_TITLE_RE.match(ep_title.strip()):
                ep_title_clean = sanitize_filename(ep_title)
                new_filename = f"{show_title} - S{season:02d}E{episode:02d} - {ep_title_clean}{ext}"
            else:
                new_filename = f"{show_title} - S{season:02d}E{episode:02d}{ext}"

            dest_path = os.path.join(dest_dir, new_filename)
            final_path = safe_move(filepath, dest_path)
            print(f"[TV] {filename} -> {final_path}")
            return

    search_term = clean_search_term(raw_name)
    if not search_term and parent_dir_name != "downloads":
        search_term = clean_search_term(parent_dir_name)

    ru_title = get_ru_movie_title(search_term)
    final_title = sanitize_filename(ru_title if ru_title else search_term)

    new_filename = f"{final_title}{ext}"
    os.makedirs(MOVIES_DIR, exist_ok=True)
    dest_path = os.path.join(MOVIES_DIR, new_filename)

    final_path = safe_move(filepath, dest_path)
    print(f"[MOVIE] {filename} -> {final_path}")

def scan_and_organize(target_dir):
    for root, dirs, files in os.walk(target_dir):
        if root.startswith(TV_DIR) or root.startswith(MOVIES_DIR):
            continue
        for file in files:
            process_file(os.path.join(root, file))

if __name__ == "__main__":
    if not TMDB_API_KEY:
        print("[WARN] TMDB-ключ не задан (/etc/oum/tmdb_api_key) — работаю без русских названий.")
    target = sys.argv[1] if len(sys.argv) > 1 else SOURCE_DIR
    print(f"Сканирование: {target}")
    scan_and_organize(target)
    cleanup_empty_dirs(target)
PYEOF
    chmod +x /usr/bin/media-organizer.py

    cat << 'WATCHEOF' > /usr/bin/media-organizer-watch.sh
#!/bin/sh
# Читает пути из общего конфига — тот же файл, что использует media-organizer.py
CONF="/etc/oum/media-organizer.conf"
[ -f "$CONF" ] && . "$CONF"
SOURCE_DIR="${SOURCE_DIR:-/mnt/hdd/NAS/downloads}"

LOCKFILE="/tmp/media-organizer.lock"
if [ -f "$LOCKFILE" ]; then
    pid=$(cat "$LOCKFILE")
    if kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"

if ! find "$SOURCE_DIR" -mindepth 1 -maxdepth 3 -name "*.aria2" 2>/dev/null | grep -q .; then
    python3 /usr/bin/media-organizer.py >> /var/log/media-organizer.log 2>&1
fi

rm -f "$LOCKFILE"
WATCHEOF
    chmod +x /usr/bin/media-organizer-watch.sh
}

media_organizer_install() {
    header
    echo -e "${CYAN}=== Установка медиа-сортировщика (TV/Movies + TMDB) ===${NC}"
    mkdir -p /etc/oum

    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${YELLOW}Python3 не найден, устанавливаем...${NC}"
        pkg_update
        if ! pkg_install python3; then
            echo -e "${RED}❌ Не удалось установить python3 — без него скрипт работать не будет.${NC}"
            log_msg "FAIL media_organizer_install: python3 install failed"
            pause; return
        fi
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}❌ python3 всё ещё не найден после установки — прерываю.${NC}"
        pause; return
    fi

    default_source="/mnt/hdd/NAS/downloads"
    default_movies="/mnt/hdd/NAS/Movies"
    default_tv="/mnt/hdd/NAS/TV"
    [ -f /etc/oum/media-organizer.conf ] && . /etc/oum/media-organizer.conf

    read -p "Папка загрузок [${SOURCE_DIR:-$default_source}]: " in_source
    read -p "Папка фильмов [${MOVIES_DIR:-$default_movies}]: " in_movies
    read -p "Папка сериалов [${TV_DIR:-$default_tv}]: " in_tv
    SOURCE_DIR=${in_source:-${SOURCE_DIR:-$default_source}}
    MOVIES_DIR=${in_movies:-${MOVIES_DIR:-$default_movies}}
    TV_DIR=${in_tv:-${TV_DIR:-$default_tv}}

    cat > /etc/oum/media-organizer.conf << CONFEOF
SOURCE_DIR=$SOURCE_DIR
MOVIES_DIR=$MOVIES_DIR
TV_DIR=$TV_DIR
LANGUAGE=ru-RU
CONFEOF
    chmod 644 /etc/oum/media-organizer.conf

    echo ""
    if [ ! -s /etc/oum/tmdb_api_key ]; then
        echo -e "${YELLOW}TMDB-ключ ещё не задан — без него сортировка будет работать,${NC}"
        echo -e "${YELLOW}но БЕЗ русских названий (только очистка релизного мусора и раскладка по папкам).${NC}"
        echo ""
        media_organizer_set_key
    else
        echo -e "${GREEN}TMDB-ключ уже задан.${NC}"
        read -p "Изменить ключ? (y/N): " chg
        case "$chg" in y|Y) media_organizer_set_key ;; esac
    fi

    echo ""
    echo -e "${YELLOW}Разворачиваем скрипты...${NC}"
    _media_organizer_deploy_files

    read -p "Периодичность проверки cron, минут [5]: " interval
    interval=${interval:-5}
    if ! echo "$interval" | grep -qE '^[0-9]+$' || [ "$interval" -lt 1 ]; then
        interval=5
    fi
    ( crontab -l 2>/dev/null | grep -v media-organizer-watch.sh ; echo "*/$interval * * * * /usr/bin/media-organizer-watch.sh" ) | crontab -
    /etc/init.d/cron restart

    log_msg "OK media_organizer_install source=$SOURCE_DIR movies=$MOVIES_DIR tv=$TV_DIR interval=$interval"
    echo -e "${GREEN}✅ Медиа-сортировщик установлен, проверка каждые $interval мин.${NC}"
    echo -e "${YELLOW}Лог: /var/log/media-organizer.log${NC}"
    pause
}

media_organizer_uninstall() {
    header
    echo -e "${YELLOW}Удалить медиа-сортировщик? Конфиг и TMDB-ключ тоже будут удалены. (y/N)${NC}"
    read -p "Ответ: " ans
    case "$ans" in
        y|Y)
            crontab -l 2>/dev/null | grep -v media-organizer-watch.sh | crontab -
            /etc/init.d/cron restart
            rm -f /usr/bin/media-organizer.py /usr/bin/media-organizer-watch.sh
            rm -f /etc/oum/media-organizer.conf /etc/oum/tmdb_api_key
            log_msg "OK media_organizer_uninstall"
            echo -e "${GREEN}✅ Удалено.${NC}"
            ;;
        *) echo -e "${YELLOW}Отменено.${NC}" ;;
    esac
    pause
}

menu_media_organizer() {
    while true; do
        header
        echo -e "${CYAN}=== Медиа-сортировщик (TV/Movies + TMDB) ===${NC}"
        if [ -f /usr/bin/media-organizer.py ]; then
            echo -e "Статус: ${GREEN}установлен${NC}"
        else
            echo -e "Статус: ${YELLOW}не установлен${NC}"
        fi
        if command -v python3 >/dev/null 2>&1; then
            echo -e "Python3: ${GREEN}есть${NC}"
        else
            echo -e "Python3: ${RED}НЕ найден (сортировка работать не будет)${NC}"
        fi
        if [ -s /etc/oum/tmdb_api_key ]; then
            echo -e "TMDB-ключ: ${GREEN}задан${NC}"
        else
            echo -e "TMDB-ключ: ${YELLOW}не задан${NC}"
        fi
        echo ""
        echo "1) Установить / перенастроить (пути, ключ, cron)"
        echo "2) Изменить только TMDB-ключ"
        echo "3) Запустить сейчас вручную"
        echo "4) Показать лог"
        echo "5) Удалить"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) media_organizer_install ;;
            2) header; media_organizer_set_key; pause ;;
            3)
                header
                if [ ! -f /usr/bin/media-organizer.py ]; then
                    echo -e "${RED}❌ Сначала установите (пункт 1).${NC}"
                else
                    /usr/bin/media-organizer.py 2>&1 | tee -a /var/log/media-organizer.log
                fi
                pause ;;
            4)
                header
                if [ -f /var/log/media-organizer.log ]; then
                    tail -n 40 /var/log/media-organizer.log
                else
                    echo -e "${YELLOW}Лог пуст или ещё не создан.${NC}"
                fi
                pause ;;
            5) media_organizer_uninstall ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== NAS / Медиасервер (SMB + aria2 + AriaNg) ======================
# Torrent/download/SMB стек на внешнем USB HDD, без Docker (расчитано на
# слабое железо вроде RAX3000M). miniDLNA сознательно не используется.
nas_setup() {
    header
    echo -e "${CYAN}=== NAS / Медиасервер (SMB + aria2 + AriaNg) ===${NC}"

    read -p "Раздел диска [/dev/sda1]: " NAS_DISK_DEV
    NAS_DISK_DEV=${NAS_DISK_DEV:-/dev/sda1}
    NAS_DISK_BASE=$(echo "$NAS_DISK_DEV" | sed -E 's/[0-9]+$//')

    read -p "Точка монтирования [/mnt/hdd]: " NAS_MOUNT
    NAS_MOUNT=${NAS_MOUNT:-/mnt/hdd}

    echo -e "${YELLOW}Форматировать $NAS_DISK_BASE в ext4? ВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ! (y/N)${NC}"
    read -p "Ответ: " fmt_ans
    case "$fmt_ans" in
        y|Y|yes|YES) NAS_FORMAT="yes" ;;
        *) NAS_FORMAT="no" ;;
    esac

    read -p "Пользователь SMB [root]: " SMB_USER
    SMB_USER=${SMB_USER:-root}
    read -p "Пароль SMB [123456]: " SMB_PASS
    SMB_PASS=${SMB_PASS:-123456}
    ARIA2_SECRET=${SMB_PASS}

    make_backup

    echo -e "${YELLOW}Устанавливаем пакеты (USB, ФС, SMB, aria2)...${NC}"
    pkg_update
    pkg_install kmod-usb-core kmod-usb2 kmod-usb3 kmod-usb-storage kmod-usb-storage-uas \
                 kmod-fs-ext4 kmod-scsi-core block-mount e2fsprogs fdisk lsblk \
                 curl wget unzip mc losetup swap-utils \
                 luci-app-ksmbd aria2 luci-app-aria2

    if [ "$NAS_FORMAT" = "yes" ]; then
        echo -e "${YELLOW}Форматируем $NAS_DISK_BASE...${NC}"
        umount "${NAS_DISK_BASE}"* 2>/dev/null || true
        swapoff -a 2>/dev/null || true
        wipefs -a "$NAS_DISK_BASE" 2>/dev/null || dd if=/dev/zero of="$NAS_DISK_BASE" bs=1M count=10 >/dev/null 2>&1
        fdisk "$NAS_DISK_BASE" << FDISK_EOF
g
n
w
FDISK_EOF
        sleep 2
        partprobe "$NAS_DISK_BASE" 2>/dev/null || true
        sleep 1
        echo -e "${YELLOW}Создаём ext4 на $NAS_DISK_DEV...${NC}"
        mkfs.ext4 -F -L NAS "$NAS_DISK_DEV"
    else
        echo -e "${CYAN}Форматирование пропущено (используем существующую ФС).${NC}"
        if ! blkid "$NAS_DISK_DEV" 2>/dev/null | grep -q ext4; then
            echo -e "${RED}⚠️  На $NAS_DISK_DEV не обнаружена ext4-разметка. Если диск новый — перезапустите с форматированием.${NC}"
        fi
    fi

    echo -e "${YELLOW}Монтируем $NAS_DISK_DEV в $NAS_MOUNT и прописываем fstab...${NC}"
    mkdir -p "$NAS_MOUNT"
    block detect > /etc/config/fstab
    while uci -q delete fstab.@mount[0]; do :; done
    while uci -q delete fstab.@swap[0]; do :; done
    uci add fstab mount >/dev/null
    uci set fstab.@mount[-1].target="$NAS_MOUNT"
    uci set fstab.@mount[-1].device="$NAS_DISK_DEV"
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
    /etc/init.d/fstab enable
    /etc/init.d/fstab restart
    mount "$NAS_DISK_DEV" "$NAS_MOUNT" 2>/dev/null || true

    if ! df "$NAS_MOUNT" | grep -q "$NAS_DISK_DEV"; then
        echo -e "${RED}❌ Диск $NAS_DISK_DEV не смонтировался в $NAS_MOUNT! Прерываю установку NAS.${NC}"
        log_msg "FAIL nas_setup mount $NAS_DISK_DEV -> $NAS_MOUNT"
        pause; return
    fi

    echo -e "${YELLOW}Проверяем/создаём структуру папок...${NC}"
    for d in "$NAS_MOUNT/NAS/downloads" "$NAS_MOUNT/NAS/tv" "$NAS_MOUNT/NAS/movies"; do
        if [ -d "$d" ]; then
            echo -e "  ${GREEN}OK${NC}: $d"
        else
            echo -e "  ${YELLOW}создаём${NC}: $d"
            mkdir -p "$d"
        fi
    done
    chmod -R 777 "$NAS_MOUNT/NAS"

    echo -e "${YELLOW}Настраиваем swap-файл...${NC}"
    SWAP_FILE="$NAS_MOUNT/swapfile"
    NEW_SWAP="no"
    if [ "$NAS_FORMAT" = "yes" ] || [ ! -f "$SWAP_FILE" ]; then
        echo -e "  Создаём новый 2GB swap-файл..."
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048
        chmod 600 "$SWAP_FILE"
        NEW_SWAP="yes"
    else
        echo -e "  Найден существующий swap-файл, переиспользуем: $SWAP_FILE"
    fi
    losetup -f "$SWAP_FILE" 2>/dev/null || true
    LOOP_DEV="$(losetup -j "$SWAP_FILE" | cut -d: -f1)"
    if [ -n "$LOOP_DEV" ]; then
        [ "$NEW_SWAP" = "yes" ] && mkswap "$LOOP_DEV" >/dev/null 2>&1 || true
        /sbin/swapon "$LOOP_DEV" 2>/dev/null || true
        if ! grep -q "losetup -f $SWAP_FILE" /etc/rc.local 2>/dev/null; then
            SWAP_BLOCK="/tmp/oum_swap_rc.local"
            cat > "$SWAP_BLOCK" << RCEOF
losetup -f $SWAP_FILE 2>/dev/null || true
LOOP_DEV="\$(losetup -j $SWAP_FILE | cut -d: -f1)"
[ -n "\$LOOP_DEV" ] && /sbin/swapon \$LOOP_DEV 2>/dev/null || true
RCEOF
            awk -v blk="$SWAP_BLOCK" '/^exit 0/{while((getline line < blk)>0) print line} {print}' /etc/rc.local > /etc/rc.local.tmp && mv /etc/rc.local.tmp /etc/rc.local
            rm -f "$SWAP_BLOCK"
        fi
    fi

    echo -e "${YELLOW}Настраиваем aria2 + AriaNg...${NC}"
    SECT="$(uci show aria2 2>/dev/null | grep '=aria2' | head -1 | cut -d. -f2 | cut -d= -f1)"
    [ -z "$SECT" ] && SECT="main"
    uci set aria2.${SECT}=aria2
    uci set aria2.${SECT}.enabled='1'
    uci set aria2.${SECT}.dir="$NAS_MOUNT/NAS/downloads"
    uci set aria2.${SECT}.enable_rpc='true'
    uci set aria2.${SECT}.rpc_listen_all='true'
    uci set aria2.${SECT}.rpc_port='6800'
    uci set aria2.${SECT}.rpc_secret="$ARIA2_SECRET"
    uci commit aria2
    /etc/init.d/aria2 enable
    /etc/init.d/aria2 restart

    mkdir -p /www/ariang
    if [ ! -f /www/ariang/index.html ]; then
        cd /tmp
        if fetch_file "https://github.com/mayswind/AriaNg/releases/download/1.3.7/AriaNg-1.3.7-AllInOne.zip" ariang.zip && [ -s ariang.zip ]; then
            unzip -o ariang.zip -d /www/ariang/
        else
            echo -e "${RED}❌ Не удалось скачать AriaNg.${NC}"
            log_msg "FAIL nas_setup ariang download"
        fi
        rm -f ariang.zip
        cd - >/dev/null
    fi

    echo -e "${YELLOW}Настраиваем Samba (ksmbd)...${NC}"
    uci set ksmbd.@globals[0].description='OpenWrt-NAS'
    uci set ksmbd.@globals[0].workgroup='WORKGROUP'
    while uci -q delete ksmbd.@share[0]; do :; done
    uci add ksmbd share >/dev/null
    uci set ksmbd.@share[-1].name='NAS'
    uci set ksmbd.@share[-1].path="$NAS_MOUNT/NAS"
    uci set ksmbd.@share[-1].read_only='no'
    uci set ksmbd.@share[-1].guest_ok='no'
    uci set ksmbd.@share[-1].force_user='root'
    uci set ksmbd.@share[-1].create_mask='0777'
    uci set ksmbd.@share[-1].dir_mask='0777'
    uci commit ksmbd
    (echo "$SMB_PASS"; sleep 1; echo "$SMB_PASS") | ksmbd.adduser -a "$SMB_USER" 2>/dev/null || true
    /etc/init.d/ksmbd enable
    /etc/init.d/ksmbd restart

    echo -e "${YELLOW}Настраиваем firewall (aria2-RPC, SMB)...${NC}"
    _nas_add_fw_rule() {
        NAME="$1"; PORT="$2"; PROTO="$3"
        while uci -q show firewall | grep -q "\.name='$NAME'"; do
            RULE_IDX="$(uci show firewall | grep "\.name='$NAME'" | head -1 | cut -d. -f2)"
            uci -q delete "firewall.$RULE_IDX"
        done
        uci add firewall rule >/dev/null
        uci set firewall.@rule[-1].name="$NAME"
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest_port="$PORT"
        uci set firewall.@rule[-1].proto="$PROTO"
        uci set firewall.@rule[-1].target='ACCEPT'
    }
    _nas_add_fw_rule 'aria2-RPC' '6800' 'tcp'
    _nas_add_fw_rule 'ksmbd-SMB' '445' 'tcp'
    uci commit firewall
    /etc/init.d/firewall restart

    echo -e "${YELLOW}Отключаем Wi-Fi powersave (лечит отвалы Wi-Fi при активной нагрузке на USB/NAS)...${NC}"
    _wifi_powersave_fix_apply

    log_msg "OK nas_setup disk=$NAS_DISK_DEV mount=$NAS_MOUNT format=$NAS_FORMAT"
    echo ""
    echo -e "${GREEN}✅ NAS настроен!${NC}"
    echo "Точка монтирования: $NAS_MOUNT"
    echo "SMB Шара:           \\\\<IP_роутера>\\NAS"
    echo "AriaNg Web UI:       http://<IP_роутера>/ariang"
    echo "Диск форматировался: $NAS_FORMAT"
    pause
}

# ====================== Блокировка QUIC ======================
# QUIC/HTTP3 работает по UDP 80/443, а стратегии Zapret обрабатывают
# только TCP: YouTube по QUIC уходит мимо обхода и режется DPI.
# Блокировка REJECT UDP 80/443 (lan->wan) заставляет браузеры откатиться
# на TCP+TLS, который обрабатывается стратегиями Zapret.
# Имена правил (Block_UDP_80/Block_UDP_443) совместимы с Zapret-Manager.
quic_block_enabled() {
    uci show firewall 2>/dev/null | grep -q "name='Block_UDP_80'" && uci show firewall 2>/dev/null | grep -q "name='Block_UDP_443'"
}

quic_block_toggle() {
    if quic_block_enabled; then
        echo -e "${YELLOW}Отключаем блокировку QUIC...${NC}"
        for RULE in Block_UDP_80 Block_UDP_443; do
            while true; do
                IDX=$(uci show firewall 2>/dev/null | grep "name='$RULE'" | cut -d. -f2 | cut -d= -f1 | head -n1)
                [ -z "$IDX" ] && break
                uci -q delete "firewall.$IDX"
            done
        done
        uci commit firewall
        /etc/init.d/firewall restart
        echo -e "${GREEN}✅ Блокировка QUIC отключлена.${NC}"
        log_msg "quic block disabled"
    else
        echo -e "${YELLOW}Включаем блокировку QUIC (REJECT UDP 80/443, lan -> wan)...${NC}"
        uci add firewall rule >/dev/null
        uci set firewall.@rule[-1].name='Block_UDP_80'
        uci add_list firewall.@rule[-1].proto='udp'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='wan'
        uci set firewall.@rule[-1].dest_port='80'
        uci set firewall.@rule[-1].target='REJECT'
        uci add firewall rule >/dev/null
        uci set firewall.@rule[-1].name='Block_UDP_443'
        uci add_list firewall.@rule[-1].proto='udp'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='wan'
        uci set firewall.@rule[-1].dest_port='443'
        uci set firewall.@rule[-1].target='REJECT'
        uci commit firewall
        /etc/init.d/firewall restart
        echo -e "${GREEN}✅ Блокировка QUIC включена: браузеры откатятся на TCP (HTTP/2), который обрабатывается Zapret.${NC}"
        echo -e "${YELLOW}Если используете Discord (голос) или игры — при проблемах отключите и проверьте без неё.${NC}"
        log_msg "quic block enabled"
    fi
}

# ====================== Дашборд для главного меню ======================
# Строка ключевых статусов: ● работает/включено, ○ нет.
dashboard() {
    DASH="Podkop "
    if podkop_alive; then
        DASH="$DASH${GREEN}●${NC}"
    else
        DASH="$DASH${RED}○${NC}"
    fi
    DASH="$DASH  Zapret "
    if /etc/init.d/zapret status >/dev/null 2>&1 || pgrep -x nfqws >/dev/null 2>&1 || pgrep -x tpws >/dev/null 2>&1; then
        DASH="$DASH${GREEN}●${NC}"
    else
        DASH="$DASH${RED}○${NC}"
    fi
    DASH="$DASH  Watchdog "
    if crontab -l 2>/dev/null | grep -q podkop-watchdog.sh; then
        DASH="$DASH${GREEN}●${NC}"
    else
        DASH="$DASH${RED}○${NC}"
    fi
    DASH="$DASH  QUIC-block "
    if quic_block_enabled; then
        DASH="$DASH${GREEN}●${NC}"
    else
        DASH="$DASH${YELLOW}○${NC}"
    fi
    DASH="$DASH  NAS "
    if /etc/init.d/ksmbd status >/dev/null 2>&1; then
        DASH="$DASH${GREEN}●${NC}"
    else
        DASH="$DASH${RED}○${NC}"
    fi
    echo -e "$DASH"
}

# ====================== Интернет и обход блокировок ======================
menu_internet() {
    while true; do
        header
        echo -e "${CYAN}=== Интернет и обход блокировок ===${NC}"
        echo "1) Установка компонентов (база, Podkop, Zapret, AmneziaWG, всё сразу)"
        echo "2) Podkop: watchdog и каскад восстановления"
        echo "3) GearUP Booster: установка и настройка"
        if quic_block_enabled; then
            echo "4) Блокировка QUIC (UDP 80/443): ${GREEN}включена${NC} — выключить"
        else
            echo "4) Блокировка QUIC (UDP 80/443): ${YELLOW}выключена${NC} — включить"
        fi
        echo -e "   ${CYAN}(рекомендуется при использовании Zapret: YouTube уходит с QUIC на TCP)${NC}"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) menu_primary ;;
            2) menu_resilience ;;
            3) menu_gearup ;;
            4) make_backup; quic_block_toggle; pause ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== Сеть и Wi-Fi ======================
menu_network() {
    while true; do
        header
        echo -e "${CYAN}=== Сеть и Wi-Fi ===${NC}"
        echo "1) Настройка Wi-Fi (SSID/пароль, открытая сеть, PA)"
        echo "2) Отключить IPv6"
        echo "3) Отключить Wi-Fi powersave (лечит обрывы под нагрузкой)"
        if github_hosts_fix_applied; then
            echo "4) GitHub hosts-fix: ${GREEN}применён${NC} — снять"
        else
            echo "4) GitHub hosts-fix: ${YELLOW}не применён${NC} — применить (если GitHub недоступен)"
        fi
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) wifi_setup ;;
            2) make_backup; uci set network.wan6.disabled='1'; uci commit; /etc/init.d/network restart; echo -e "${GREEN}✅ IPv6 отключён.${NC}"; pause ;;
            3) wifi_powersave_fix ;;
            4)
                if github_hosts_fix_applied; then
                    echo -e "${YELLOW}Снимаем hosts-fix для GitHub...${NC}"
                    github_hosts_fix_revert
                    echo -e "${GREEN}✅ hosts-fix снят.${NC}"
                else
                    echo -e "${YELLOW}Применяем hosts-fix для GitHub (IP GitHub в /etc/hosts)...${NC}"
                    if github_hosts_fix_apply; then
                        echo -e "${GREEN}✅ hosts-fix применён.${NC}"
                        log_msg "github hosts-fix applied manually"
                    else
                        echo -e "${RED}❌ Не удалось применить hosts-fix.${NC}"
                    fi
                fi
                pause ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== Отказоустойчивость Podkop ======================
menu_resilience() {
    while true; do
        header
        echo -e "${CYAN}=== Podkop: отказоустойчивость ===${NC}"
        if crontab -l 2>/dev/null | grep -q podkop-watchdog.sh; then
            echo "Watchdog: ${GREEN}установлен${NC}"
        else
            echo "Watchdog: ${YELLOW}не установлен${NC}"
        fi
        if [ -f /tmp/podkop_watchdog/fail_count ]; then
            echo "Неудачных проверок подряд: $(cat /tmp/podkop_watchdog/fail_count)"
        fi
        if [ -f /tmp/podkop_watchdog/stopped ]; then
            echo -e "${RED}Podkop остановлен watchdog'ом — интернет без прокси.${NC}"
            echo -e "${RED}Вернуть: пункт 6 (сброс) или перезагрузка роутера.${NC}"
        fi
        echo ""
        echo "1) Watchdog: установить / обновить до v2 (по крону)"
        echo "2) Watchdog: удалить"
        echo "3) Проверить podkop сейчас (живость + внешняя сеть)"
        echo "4) ТЕСТ watchdog: уронить podkop → watchdog должен оживить (~1 мин)"
        echo "5) Каскад восстановления вручную (рестарт / обновление / пауза)"
        echo "6) Сброс: запустить podkop после остановки (сброс флагов watchdog)"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) install_podkop_watchdog ;;
            2) uninstall_podkop_watchdog ;;
            3) header; podkop_check; pause ;;
            4) watchdog_test ;;
            5) podkop_recover ;;
            6) watchdog_resume ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== NAS и медиа ======================
menu_nas_media() {
    while true; do
        header
        echo -e "${CYAN}=== NAS и медиа ===${NC}"
        if /etc/init.d/ksmbd status >/dev/null 2>&1; then
            echo "NAS (SMB): ${GREEN}активен${NC}"
        else
            echo "NAS (SMB): ${YELLOW}не настроен/выключен${NC}"
        fi
        if crontab -l 2>/dev/null | grep -q media-organizer-watch.sh; then
            echo "Медиа-сортировщик: ${GREEN}установлен${NC}"
        else
            echo "Медиа-сортировщик: ${YELLOW}не установлен${NC}"
        fi
        echo ""
        echo "1) NAS / Медиасервер (SMB + aria2 + AriaNg) — установка/перенастройка"
        echo "2) Медиа-сортировщик (TV/Movies + TMDB) — установка, ключ, запуск, лог"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) nas_setup ;;
            2) menu_media_organizer ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== Система (драйверы, темы) ======================
menu_system() {
    while true; do
        header
        echo -e "${CYAN}=== Система ===${NC}"
        echo "Роутер: $(detect_router_model)"
        echo ""
        echo "1) Драйверы и USB / файловые системы"
        echo "2) Темы LuCI"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) menu_drivers ;;
            2) menu_themes ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== Диагностика и обслуживание ======================
menu_maintenance() {
    while true; do
        header
        echo -e "${CYAN}=== Диагностика и обслуживание ===${NC}"
        echo "1) Диагностика: почему не работает"
        echo "2) Быстрый статус системы"
        echo "3) Создать бэкап конфигурации сейчас"
        echo "4) Восстановить бэкап / удалить все бэкапы (с перезагрузкой)"
        echo "5) Проверить обновления OUM"
        echo "6) Удаление компонентов"
        echo "7) Перезапустить firewall"
        echo "8) Перезагрузить роутер"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) run_diagnostics; pause ;;
            2) menu_status ;;
            3) make_backup; pause ;;
            4) menu_restore ;;
            5) oum_self_update ;;
            6) menu_uninstall ;;
            7) /etc/init.d/firewall restart; echo -e "${GREEN}✅ Firewall перезапущен.${NC}"; pause ;;
            8) echo "Перезагрузка..."; sleep 3; reboot ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== Драйверы (kmod) под конкретные роутеры ======================
# Wi-Fi-драйверы на современных сборках OpenWrt уже встроены в образ,
# поэтому набор здесь — про USB, файловые системы и кодировки.
DRV_USBFS="kmod-usb-core kmod-usb2 kmod-usb3 kmod-usb-storage kmod-usb-storage-uas kmod-scsi-core kmod-fs-ext4 kmod-fs-exfat kmod-fs-ntfs3 kmod-fs-vfat"
DRV_NLS="kmod-nls-utf8 kmod-nls-cp1251"
DRV_FULL="$DRV_USBFS $DRV_NLS kmod-tun"

detect_router_model() {
    cat /tmp/sysinfo/model 2>/dev/null || cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "неизвестно"
}

drivers_install() {
    # $1 = список пакетов
    make_backup
    pkg_update >/dev/null 2>&1
    OK=0; FAIL=0
    for p in $1; do
        if pkg_install "$p" >/dev/null 2>&1; then
            OK=$((OK + 1))
        else
            FAIL=$((FAIL + 1))
            echo -e "${YELLOW}  ⚠️  $p не установлен (может отсутствовать для этой ветки OpenWrt)${NC}"
        fi
    done
    if [ "$FAIL" -eq 0 ]; then
        echo -e "${GREEN}✅ Установлено пакетов: $OK.${NC}"
    else
        echo -e "${GREEN}✅ Установлено: $OK, не удалось: $FAIL.${NC}"
        echo -e "${YELLOW}   Для NTFS на старых ветках OpenWrt (21/22) используйте пакет ntfs-3g вместо kmod-fs-ntfs3.${NC}"
    fi
    echo -e "${YELLOW}⚠️  После перепрошивки (sysupgrade) kmod-пакеты нужно ставить заново — версия ядра меняется.${NC}"
    log_msg "OK drivers_install ok=$OK fail=$FAIL"
}

menu_drivers() {
    while true; do
        header
        MODEL=$(detect_router_model)
        echo -e "${CYAN}=== Драйверы и USB / файловые системы ===${NC}"
        echo "Роутер: $MODEL"
        case "$MODEL" in
            *AX6S*|*AX3200*)
                echo "Платформа: MediaTek MT7622 + MT7915. Wi-Fi встроен в образ."
                echo "USB-портов нет — доп. драйверы обычно не нужны (кроме kmod-tun для VPN/GearUP)." ;;
            *RAX3000*)
                echo "Платформа: MediaTek MT7981 (Filogic 820). Wi-Fi встроен в образ."
                echo "Есть USB3 — рекомендован набор «USB + файловые системы»." ;;
            *TR3000*)
                echo "Платформа: MediaTek MT7981 (Filogic 820). Wi-Fi встроен в образ."
                echo "Рекомендован набор «USB + файловые системы»." ;;
            *BPI*|*Banana*)
                echo "Платформа: MediaTek MT7986 (Filogic 700). Wi-Fi встроен в образ."
                echo "Есть USB3 — рекомендован набор «USB + файловые системы»." ;;
            *)
                echo "Платформа не распознана — доступны общие наборы (Wi-Fi уже в образе)." ;;
        esac
        echo ""
        echo "1) Всё сразу: USB + файловые системы + кодировки (NLS) + kmod-tun"
        echo "2) USB-стек + файловые системы (ext4, exFAT, NTFS, FAT)"
        echo "3) Кодировки NLS — русские имена файлов на FAT/NTFS-дисках"
        echo "4) kmod-tun отдельно (GearUP, VPN)"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) echo -e "${YELLOW}Устанавливаем полный набор...${NC}"; drivers_install "$DRV_FULL"; pause ;;
            2) echo -e "${YELLOW}Устанавливаем USB + ФС...${NC}"; drivers_install "$DRV_USBFS"; pause ;;
            3) echo -e "${YELLOW}Устанавливаем кодировки...${NC}"; drivers_install "$DRV_NLS"; pause ;;
            4) drivers_install "kmod-tun"; pause ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== Темы LuCI ======================
install_argon() {
    echo -e "${YELLOW}Определяем свежую версию Argon (GitHub API)...${NC}"
    URL=""
    if command -v curl >/dev/null 2>&1; then
        URL=$(curl -fsSL "https://api.github.com/repos/jerrykuku/luci-theme-argon/releases/latest" 2>/dev/null \
              | grep -o 'https://[^"]*luci-theme-argon[^"]*\.ipk' | head -n1)
    fi
    if [ -z "$URL" ]; then
        echo -e "${RED}❌ Не удалось получить ссылку на Argon (GitHub API недоступен?).${NC}"
        log_msg "FAIL argon: no release url"
        return 1
    fi
    echo -e "${YELLOW}Скачиваем: $URL${NC}"
    if fetch_file "$URL" /tmp/luci-theme-argon.ipk && [ -s /tmp/luci-theme-argon.ipk ]; then
        if pkg_install_local /tmp/luci-theme-argon.ipk; then
            echo -e "${GREEN}✅ Argon установлен. Сделайте его темой по умолчанию (пункт 4).${NC}"
            log_msg "OK install argon"
        else
            echo -e "${RED}❌ Не удалось установить Argon.${NC}"
            log_msg "FAIL install argon"
        fi
        rm -f /tmp/luci-theme-argon.ipk
    else
        echo -e "${RED}❌ Не удалось скачать Argon.${NC}"
        log_msg "FAIL download argon"
    fi
}

theme_set_default() {
    echo "Установленные темы:"
    ls -1 /www/luci-static 2>/dev/null
    read -p "Имя темы (например argon, material, bootstrap): " t
    if [ ! -d "/www/luci-static/$t" ]; then
        echo -e "${RED}❌ Тема $t не найдена в /www/luci-static.${NC}"
        return
    fi
    uci set luci.main.mediaurlbase="/luci-static/$t"
    uci commit luci
    echo -e "${GREEN}✅ Тема по умолчанию: $t (перезагрузите страницу LuCI).${NC}"
    log_msg "OK theme default=$t"
}

theme_remove() {
    echo "Установленные темы:"
    ls -1 /www/luci-static 2>/dev/null
    read -p "Какую тему удалить: " t
    [ -z "$t" ] && return
    if [ "$t" = "bootstrap" ]; then
        echo -e "${RED}❌ bootstrap — системная тема, удалить нельзя.${NC}"
        return
    fi
    if [ ! -d "/www/luci-static/$t" ]; then
        echo -e "${RED}❌ Тема $t не найдена.${NC}"
        return
    fi
    pkg_remove "luci-theme-$t" >/dev/null 2>&1
    rm -rf "/www/luci-static/$t"
    if [ "$(uci -q get luci.main.mediaurlbase)" = "/luci-static/$t" ]; then
        uci set luci.main.mediaurlbase='/luci-static/bootstrap'
        uci commit luci
        echo -e "${YELLOW}Тема по умолчанию сброшена на bootstrap.${NC}"
    fi
    echo -e "${GREEN}✅ Тема $t удалена.${NC}"
    log_msg "OK theme removed=$t"
}

menu_themes() {
    while true; do
        header
        echo -e "${CYAN}=== Темы LuCI ===${NC}"
        CUR=$(uci -q get luci.main.mediaurlbase)
        echo "Текущая тема: ${CUR#/luci-static/}"
        echo "Установленные: $(ls -1 /www/luci-static 2>/dev/null | tr '\n' ' ')"
        echo ""
        echo "1) Proton2025 (тёмная, современная — by ChesterGoodiny)"
        echo "2) Argon (самая популярная, тёмная/светлая, настраиваемая)"
        echo "3) Material (лёгкая, из официальных репозиториев)"
        echo "4) Сделать тему по умолчанию"
        echo "5) Удалить тему"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) make_backup
               safe_run_remote "https://raw.githubusercontent.com/ChesterGoodiny/luci-theme-proton2025/main/install.sh" "Тема Proton2025"
               pause ;;
            2) make_backup; install_argon; pause ;;
            3) make_backup
               pkg_update && pkg_install luci-theme-material
               pause ;;
            4) theme_set_default; pause ;;
            5) theme_remove; pause ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== Удаление компонентов ======================
uninstall_podkop() {
    header
    [ -f /etc/init.d/podkop ] || { echo -e "${RED}Podkop не найден.${NC}"; pause; return; }
    echo -e "${RED}Удалить Podkop? (y/N)${NC}"
    read -p "Ответ: " a
    case "$a" in y|Y) ;; *) echo -e "${YELLOW}Отменено.${NC}"; pause; return ;; esac
    make_backup
    /etc/init.d/podkop stop 2>/dev/null
    /etc/init.d/podkop disable 2>/dev/null
    rm -f /etc/init.d/podkop /usr/bin/podkop
    rm -rf /etc/podkop 2>/dev/null
    log_msg "OK podkop uninstalled"
    echo -e "${GREEN}✅ Podkop удалён (sing-box оставлен — может использоваться другим ПО).${NC}"
    echo -e "${YELLOW}Для полной очистки nftables-правил перезагрузите роутер.${NC}"
    pause
}

uninstall_zapret() {
    header
    [ -f /etc/init.d/zapret ] || { echo -e "${RED}Zapret не найден.${NC}"; pause; return; }
    echo -e "${RED}Удалить Zapret (+ Zapret-Manager)? (y/N)${NC}"
    read -p "Ответ: " a
    case "$a" in y|Y) ;; *) echo -e "${YELLOW}Отменено.${NC}"; pause; return ;; esac
    make_backup
    /etc/init.d/zapret stop 2>/dev/null
    /etc/init.d/zapret disable 2>/dev/null
    killall nfqws 2>/dev/null; killall tpws 2>/dev/null
    rm -rf /opt/zapret /etc/init.d/zapret /etc/firewall.zapret /etc/config/zapret
    rm -f /usr/bin/zms /usr/bin/zmsA
    crontab -l 2>/dev/null | grep -v -i zapret | crontab - 2>/dev/null
    /etc/init.d/cron restart 2>/dev/null
    /etc/init.d/firewall restart 2>/dev/null
    log_msg "OK zapret uninstalled"
    echo -e "${GREEN}✅ Zapret удалён.${NC}"
    echo -e "${YELLOW}Блокировка QUIC и FIX offloading (если включали) оставлены — отключаются в меню 2 и 3.${NC}"
    pause
}

uninstall_gearup() {
    header
    if ! pgrep -f guplugin >/dev/null 2>&1 && [ ! -f /etc/init.d/gearup-monitor ]; then
        echo -e "${RED}GearUP не найден.${NC}"; pause; return
    fi
    echo -e "${RED}Удалить GearUP (плагин + монитор + сервис восстановления)? (y/N)${NC}"
    read -p "Ответ: " a
    case "$a" in y|Y) ;; *) echo -e "${YELLOW}Отменено.${NC}"; pause; return ;; esac
    make_backup
    killall guplugin 2>/dev/null
    for s in gearup-monitor gearup_restore; do
        /etc/init.d/$s stop 2>/dev/null
        /etc/init.d/$s disable 2>/dev/null
        rm -f "/etc/init.d/$s"
    done
    rm -f /usr/bin/gearup-monitor.sh
    rm -rf /etc/gearup_persist /tmp/gu
    uci -q delete network.gearup_rule
    uci commit network
    # GearUP требовал forward=ACCEPT — возвращаем стоковое значение OpenWrt
    uci set firewall.@defaults[0].forward='REJECT'
    uci commit firewall
    /etc/init.d/firewall restart
    /etc/init.d/network restart
    log_msg "OK gearup uninstalled"
    echo -e "${GREEN}✅ GearUP удалён, дефолты firewall восстановлены (forward=REJECT).${NC}"
    pause
}

uninstall_awg() {
    header
    uci -q get network.AWG >/dev/null 2>&1 || { echo -e "${RED}AmneziaWG (network.AWG) не найден.${NC}"; pause; return; }
    echo -e "${RED}Удалить AmneziaWG? Удалятся интерфейс AWG, пиры и пакеты kmod-awg/luci-app-amneziawg. (y/N)${NC}"
    read -p "Ответ: " a
    case "$a" in y|Y) ;; *) echo -e "${YELLOW}Отменено.${NC}"; pause; return ;; esac
    make_backup
    ifdown AWG 2>/dev/null
    while true; do
        P=$(uci show network 2>/dev/null | grep '=wireguard_AWG$' | head -n1 | cut -d. -f2 | cut -d= -f1)
        [ -z "$P" ] && break
        uci -q delete "network.$P"
    done
    uci -q delete network.AWG
    uci commit network
    pkg_remove luci-app-amneziawg kmod-awg 2>/dev/null
    rm -rf /etc/amnezia 2>/dev/null
    /etc/init.d/network restart
    log_msg "OK awg uninstalled"
    echo -e "${GREEN}✅ AmneziaWG удалён.${NC}"
    pause
}

menu_uninstall() {
    while true; do
        header
        echo -e "${CYAN}=== Удаление компонентов ===${NC}"
        echo "1) Podkop"
        echo "2) Zapret (+ Zapret-Manager)"
        echo "3) GearUP Booster (плагин + монитор + восстановление)"
        echo "4) AmneziaWG"
        echo "5) Watchdog Podkop"
        echo "6) Медиа-сортировщик"
        echo ""
        echo -e "${YELLOW}Enter — Назад${NC}"
        choice=$(read_choice)
        case "$choice" in
            "") break ;;
            1) uninstall_podkop ;;
            2) uninstall_zapret ;;
            3) uninstall_gearup ;;
            4) uninstall_awg ;;
            5) uninstall_podkop_watchdog ;;
            6) media_organizer_uninstall ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ====================== Диагностика: «почему не работает» ======================
run_diagnostics() {
    header
    echo -e "${CYAN}=== Диагностика ===${NC}"
    echo ""
    PROB=0

    # 1. Сырой интернет (без DNS)
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Интернет (ICMP до внешних IP) есть${NC}"
    else
        echo -e "${RED}❌ Нет пинга до внешних IP — кабель/провайдер, либо весь трафик уходит в нерабочий прокси${NC}"
        PROB=$((PROB + 1))
    fi

    # 2. DNS
    if nslookup ya.ru >/dev/null 2>&1; then
        echo -e "${GREEN}✅ DNS резолвится${NC}"
    else
        echo -e "${RED}❌ DNS не резолвится (dnsmasq/прокси-резолвер?)${NC}"
        PROB=$((PROB + 1))
    fi

    # 2.5 Системное время (кривые часы = мёртвый HTTPS)
    check_time_sync || PROB=$((PROB + 1))

    # 3. WAN-интерфейс
    if ubus call network.interface.wan status 2>/dev/null | grep -q '"up": *true'; then
        echo -e "${GREEN}✅ WAN-интерфейс поднят${NC}"
    else
        echo -e "${RED}❌ WAN не поднят (pppoe/dhcp?)${NC}"
        PROB=$((PROB + 1))
    fi

    # 4. Podkop
    PODKOP_ON=0
    if podkop_alive; then
        PODKOP_ON=1
        echo -e "${GREEN}✅ Podkop активен${NC}"
    else
        echo -e "${YELLOW}— Podkop не активен${NC}"
    fi

    # 5. Zapret
    ZAPRET_INSTALLED=0; ZAPRET_ON=0
    if [ -f /etc/init.d/zapret ]; then
        ZAPRET_INSTALLED=1
        if /etc/init.d/zapret status >/dev/null 2>&1 || pgrep -x nfqws >/dev/null 2>&1; then
            ZAPRET_ON=1
            echo -e "${GREEN}✅ Zapret активен${NC}"
        else
            echo -e "${RED}❌ Zapret установлен, но не запущен${NC}"
            PROB=$((PROB + 1))
        fi
    fi

    # 6. Конфликт: оба перехватчика одновременно
    if [ "$PODKOP_ON" = "1" ] && [ "$ZAPRET_ON" = "1" ]; then
        echo -e "${RED}❌ CONFLICT: Podkop и Zapret активны одновременно — двойной перехват трафика${NC}"
        echo -e "${RED}   Оставьте один: Удаление компонентов (меню 12).${NC}"
        PROB=$((PROB + 1))
    fi

    # 7. Offloading + Zapret без FIX
    FO_ON=0
    [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = "1" ] && FO_ON=1
    [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = "1" ] && FO_ON=1
    if [ "$FO_ON" = "1" ] && [ "$ZAPRET_INSTALLED" = "1" ] && ! hw_offload_fix_applied; then
        echo -e "${RED}❌ Включён offloading + Zapret БЕЗ FIX — обход не работает. Меню 3, пункт 4.${NC}"
        PROB=$((PROB + 1))
    fi

    # 8. QUIC — информация
    if quic_block_enabled; then
        echo -e "${CYAN}ℹ️  QUIC заблокирован (нормально при использовании Zapret)${NC}"
    else
        echo -e "${CYAN}ℹ️  QUIC не заблокирован${NC}"
    fi

    # 9. GitHub доступен? (все установки OUM идут оттуда)
    if wget -q -T 8 -O /dev/null "https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh" 2>/dev/null; then
        echo -e "${GREEN}✅ GitHub доступен${NC}"
    else
        echo -e "${YELLOW}⚠️  GitHub недоступен — при необходимости примените hosts-fix (меню 2, пункт 5)${NC}"
    fi

    # 10. Место в overlay (корневая ФС)
    USE=$(df -P / 2>/dev/null | tail -n 1 | awk '{print $5}' | tr -d '%')
    if [ -n "$USE" ] && [ "$USE" -ge 90 ]; then
        echo -e "${RED}❌ Корневая ФС заполнена на ${USE}% — конфиги могут не сохраняться${NC}"
        PROB=$((PROB + 1))
    elif [ -n "$USE" ]; then
        echo -e "${GREEN}✅ Корневая ФС занята на ${USE}%${NC}"
    fi

    # 11. Свободная RAM
    MEMFREE=$(free 2>/dev/null | awk '/^Mem:/{print $4}')
    if [ -n "$MEMFREE" ] && [ "$MEMFREE" -lt 8192 ]; then
        echo -e "${YELLOW}⚠️  Мало свободной RAM: ${MEMFREE} kB${NC}"
    fi

    # 12. NAS-диск
    NASDIR=$(grep '^SOURCE_DIR=' /etc/oum/media-organizer.conf 2>/dev/null | cut -d= -f2)
    if [ -n "$NASDIR" ] && [ -d "$NASDIR" ]; then
        NASUSE=$(df -P "$NASDIR" 2>/dev/null | tail -n 1 | awk '{print $5}' | tr -d '%')
        if [ -n "$NASUSE" ]; then
            if [ "$NASUSE" -ge 95 ]; then
                echo -e "${RED}❌ NAS-диск ($NASDIR) заполнен на ${NASUSE}%${NC}"
                PROB=$((PROB + 1))
            else
                echo -e "${GREEN}✅ NAS-диск ($NASDIR) занят на ${NASUSE}%${NC}"
            fi
        fi
    fi

    echo ""
    if [ "$PROB" -eq 0 ]; then
        echo -e "${GREEN}✅ Явных проблем не найдено. Если не открывается конкретный сайт — проверьте его на другом устройстве/через прокси.${NC}"
    else
        echo -e "${RED}⚠️  Найдено проблем: $PROB — см. рекомендации выше.${NC}"
    fi
    log_msg "diagnostics run: problems=$PROB"
}

# ====================== Восстановление бэкапа ======================
menu_restore() {
    header
    if ! ls "$BACKUP_DIR"/oum_backup_*.tar.gz >/dev/null 2>&1; then
        echo -e "${YELLOW}Бэкапов пока нет: $BACKUP_DIR пуст.${NC}"
        pause
        return
    fi
    echo -e "${CYAN}=== Восстановление бэкапа ===${NC}"
    ls -1t "$BACKUP_DIR"/oum_backup_*.tar.gz | while IFS= read -r f; do
        echo "  $(basename "$f")  ($(du -h "$f" | cut -f1))"
    done
    echo ""
    echo -e "${YELLOW}ВНИМАНИЕ: конфигурация вернётся к состоянию на момент бэкапа, роутер ПЕРЕЗАГРУЗИТСЯ.${NC}"
    echo "Введите имя файла (полностью, как выше), 'd' — удалить все бэкапы, Enter — отмена:"
    read -p "Выбор: " sel
    [ -z "$sel" ] && return
    if [ "$sel" = "d" ]; then
        rm -f "$BACKUP_DIR"/oum_backup_*.tar.gz
        echo -e "${GREEN}✅ Все бэкапы удалены.${NC}"
        log_msg "all backups deleted"
        pause
        return
    fi
    FILE="$BACKUP_DIR/$sel"
    if [ ! -f "$FILE" ]; then
        echo -e "${RED}❌ Файл не найден: $FILE${NC}"
        pause
        return
    fi
    read -p "Введите YES для подтверждения: " c
    [ "$c" = "YES" ] || { echo -e "${YELLOW}Отменено.${NC}"; pause; return; }
    echo -e "${YELLOW}Восстанавливаем $FILE и перезагружаемся...${NC}"
    log_msg "restore from $sel"
    sysupgrade -r "$FILE" && sleep 3 && reboot
}

# ====================== Самообновление OUM ======================
oum_self_update() {
    header
    mkdir -p /etc/oum
    CONF="/etc/oum/oum.conf"
    if [ ! -f "$CONF" ]; then
        cat > "$CONF" << 'CONFEOF'
# Конфиг OUM.
# Для самообновления раскомментируйте и укажите URL свежей версии oum.sh:
# OUM_UPDATE_URL=https://raw.githubusercontent.com/USERNAME/REPO/main/oum.sh
CONFEOF
    fi
    OUM_UPDATE_URL=""
    . "$CONF"
    # Если URL не задан в конфиге — используем официальный репозиторий
    [ -z "$OUM_UPDATE_URL" ] && OUM_UPDATE_URL="$OUM_REPO_URL"
    if [ -z "$OUM_UPDATE_URL" ]; then
        echo -e "${YELLOW}URL обновления не задан.${NC}"
        echo "Залейте oum.sh в свой репозиторий и впишите в /etc/oum/oum.conf:"
        echo "  OUM_UPDATE_URL=https://raw.githubusercontent.com/USERNAME/REPO/main/oum.sh"
        pause
        return
    fi
    echo -e "${YELLOW}Проверяем обновления...${NC}"
    if ! fetch_file "$OUM_UPDATE_URL" /tmp/oum_new.sh || [ ! -s /tmp/oum_new.sh ]; then
        echo -e "${RED}❌ Не удалось скачать обновление.${NC}"
        pause
        return
    fi
    if head -c 200 /tmp/oum_new.sh | grep -qi "<html"; then
        echo -e "${RED}❌ По URL вернулся HTML вместо скрипта — проверьте OUM_UPDATE_URL.${NC}"
        pause
        return
    fi
    NEWV=$(grep -o 'OUM v[0-9][0-9.]*' /tmp/oum_new.sh | head -n1 | sed 's/OUM v//')
    if [ -z "$NEWV" ]; then
        echo -e "${RED}❌ Не удалось определить версию в скачанном файле — это точно oum.sh?${NC}"
        pause
        return
    fi
    echo "Текущая версия:  v$OUM_VERSION"
    echo "Доступная:       v$NEWV"
    if [ "$NEWV" = "$OUM_VERSION" ]; then
        echo -e "${GREEN}✅ У вас актуальная версия.${NC}"
        pause
        return
    fi
    read -p "Обновиться до v$NEWV? (y/N): " a
    case "$a" in
        y|Y) ;;
        *) return ;;
    esac
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if cp "$SCRIPT_PATH" "${SCRIPT_PATH}.bak" && cp /tmp/oum_new.sh "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"; then
        echo -e "${GREEN}✅ OUM обновлён до v$NEWV. Старая версия: ${SCRIPT_PATH}.bak${NC}"
        echo -e "${YELLOW}Перезапустите OUM, чтобы начать работу с новой версией.${NC}"
        log_msg "OK self-update $OUM_VERSION -> $NEWV"
    else
        echo -e "${RED}❌ Не удалось записать обновление (путь: $SCRIPT_PATH).${NC}"
        log_msg "FAIL self-update write"
    fi
    pause
}

# ====================== Статус ======================
menu_status() {
    header
    echo -e "${CYAN}Статус системы:${NC}"
    echo -e "Пакетный менеджер: ${GREEN}${PKG_MANAGER:-неизвестен}${NC}"
    echo "Uptime/Load: $(uptime 2>/dev/null)"
    TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    [ -n "$TEMP" ] && echo "Температура CPU: $((TEMP / 1000))°C"
    df -h / /tmp 2>/dev/null | tail -n +2 | while IFS= read -r line; do
        echo "Диск: $line"
    done
    NASDIR=$(grep '^SOURCE_DIR=' /etc/oum/media-organizer.conf 2>/dev/null | cut -d= -f2)
    if [ -n "$NASDIR" ] && [ -d "$NASDIR" ]; then
        df -h "$NASDIR" 2>/dev/null | tail -n 1 | awk '{print "NAS-диск: "$3" / "$2" ("$5") — "$6}'
    fi
    pgrep guplugin >/dev/null && echo "GearUP: ${GREEN}работает${NC}" || echo "GearUP: ${RED}не запущен${NC}"
    /etc/init.d/podkop status >/dev/null 2>&1 && echo "Podkop: ${GREEN}активен${NC}" || echo "Podkop: ${RED}выключен/не найден${NC}"
    /etc/init.d/ksmbd status >/dev/null 2>&1 && echo "NAS (SMB): ${GREEN}активен${NC}" || echo "NAS (SMB): ${RED}выключен/не найден${NC}"
    if crontab -l 2>/dev/null | grep -q media-organizer-watch.sh; then
        if [ -s /etc/oum/tmdb_api_key ]; then
            echo "Медиа-сортировщик: ${GREEN}установлен, TMDB-ключ задан${NC}"
        else
            echo "Медиа-сортировщик: ${YELLOW}установлен, TMDB-ключ НЕ задан${NC}"
        fi
    else
        echo "Медиа-сортировщик: ${YELLOW}не установлен${NC}"
    fi
    if crontab -l 2>/dev/null | grep -q podkop-watchdog.sh; then
        if [ -f /tmp/podkop_watchdog/stopped ]; then
            echo "Podkop watchdog: ${RED}остановил podkop — нужен сброс или перезагрузка${NC}"
        elif [ -f /tmp/podkop_watchdog/fail_count ]; then
            echo "Podkop watchdog: ${YELLOW}неудач подряд: $(cat /tmp/podkop_watchdog/fail_count)${NC}"
        else
            echo "Podkop watchdog: ${GREEN}установлен и активен${NC}"
        fi
    else
        echo "Podkop watchdog: ${YELLOW}не установлен${NC}"
    fi
    if [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = "1" ]; then
        echo "Software offloading: ${GREEN}включён${NC}"
    else
        echo "Software offloading: ${YELLOW}выключен${NC}"
    fi
    if [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = "1" ]; then
        echo "Hardware offloading: ${GREEN}включён${NC}"
    else
        echo "Hardware offloading: ${YELLOW}выключен${NC}"
    fi
    if grep -q 'ct original packets ge 30 flow offload @ft;' /usr/share/firewall4/templates/ruleset.uc 2>/dev/null; then
        echo "Flow Offloading FIX: ${GREEN}применён${NC}"
    elif [ -f /usr/share/firewall4/templates/ruleset.uc ]; then
        echo "Flow Offloading FIX: ${YELLOW}не применён${NC}"
    fi
    if quic_block_enabled; then
        echo "Блокировка QUIC: ${GREEN}включена${NC}"
    else
        echo "Блокировка QUIC: ${YELLOW}выключена${NC}"
    fi
    github_hosts_fix_applied && echo "GitHub hosts-fix: ${GREEN}применён${NC}"
    [ -x /usr/bin/zms ] && echo "Zapret Manager (zms): ${GREEN}установлен${NC}"
    echo ""
    echo "ip rule (первые 15 строк):"
    ip rule show | head -n 15
    echo ""
    if [ -f /etc/oum/oum.log ]; then
        echo "Последние 10 записей лога OUM (/etc/oum/oum.log):"
        tail -n 10 /etc/oum/oum.log
    elif [ -f /var/log/oum/oum.log ]; then
        echo "Последние 10 записей лога OUM (старый путь):"
        tail -n 10 /var/log/oum/oum.log
    fi
    pause
}

# ====================== Проверка системного времени (NTP) ======================
# Кривые часы ломают HTTPS → все GitHub-скачивания OUM умирают с ошибкой
# сертификатов. Проверяем рассинхрон с точным временем из HTTP-заголовка.
check_time_sync() {
    HN=$(date -u +%Y%m%d%H%M%S)
    # HTTP-заголовок Date с любого крупного сервера — без TLS, без зависимостей
    REMOTE=$(wget -S --spider -T 8 http://ya.ru 2>&1 | grep -i '^  Date:' | tail -n1 | sed 's/.*Date: //')
    [ -z "$REMOTE" ] && REMOTE=$(wget -S --spider -T 8 http://cloudflare.com 2>&1 | grep -i '^  Date:' | tail -n1 | sed 's/.*Date: //')
    if [ -z "$REMOTE" ]; then
        echo -e "${YELLOW}⚠️  Не удалось получить точное время (нет сети?) — проверка пропущена.${NC}"
        return 0
    fi
    # Парсим RFC-датy: "Mon, 24 Aug 2026 14:30:05 GMT" -> YYYYmmddHHMMSS
    RY=$(echo "$REMOTE" | awk '{print $4}')
    RD=$(echo "$REMOTE" | awk '{print $3}')
    RT=$(echo "$REMOTE" | awk '{print $5}' | tr -d ':')
    RMON=$(echo "$REMOTE" | awk '{print $2}' | case $(echo "$REMOTE" | awk '{print $2}') in
        Jan) echo 01;; Feb) echo 02;; Mar) echo 03;; Apr) echo 04;; May) echo 05;; Jun) echo 06;;
        Jul) echo 07;; Aug) echo 08;; Sep) echo 09;; Oct) echo 10;; Nov) echo 11;; Dec) echo 12;; *) echo 00;; esac)
    [ "$RMON" = "00" ] && { echo -e "${YELLOW}⚠️  Не распознана дата сервера ($REMOTE).${NC}"; return 0; }
    RNUM=$((RY * 10000000000 + RMON * 100000000 + RD * 1000000 + RT))
    HNUM=$(date -u +%Y%m%d%H%M%S)
    DIFF=$((HNUM - RNUM))
    [ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))
    # > 300 секунд рассинхрона — HTTPS-сертификаты могут не приниматься
    if [ "$DIFF" -gt 300 ]; then
        echo -e "${RED}❌ Время роутера рассинхронизировано на ${DIFF} сек — HTTPS/скачивания будут падать.${NC}"
        echo -e "${YELLOW}   Лечится: System -> Time Synchronization в LuCI, или:/etc/init.d/sysntpd restart${NC}"
        log_msg "WARN time drift ${DIFF}s"
        return 1
    fi
    echo -e "${GREEN}✅ Системное время синхронизировано (рассинхрон ${DIFF} сек).${NC}"
    return 0
}

# ====================== CLI-режим (без меню) ======================
# oum.sh status | diag | log [N] | version — для скриптов, cron и удалённого
# администрирования. Любой неизвестный аргумент — интерактивное меню.
cli_mode() {
    case "$1" in
        status)
            echo "OUM v$OUM_VERSION — $(detect_router_model)"
            echo "Uptime: $(uptime 2>/dev/null)"
            dashboard
            echo ""
            podkop_alive && echo "Podkop: работает" || echo "Podkop: остановлен"
            net_ok && echo "Внешняя сеть: доступна" || echo "Внешняя сеть: НЕДОСТУПНА"
            crontab -l 2>/dev/null | grep -q podkop-watchdog.sh && echo "Watchdog: установлен" || echo "Watchdog: не установлен"
            quic_block_enabled && echo "QUIC-блок: включён" || echo "QUIC-блок: выключен"
            exit 0
            ;;
        diag)
            run_diagnostics
            exit 0
            ;;
        log)
            N=${2:-30}
            case "$N" in ''|*[!0-9]*) N=30 ;; esac
            if [ -f /etc/oum/oum.log ]; then
                tail -n "$N" /etc/oum/oum.log
            elif [ -f /var/log/oum/oum.log ]; then
                tail -n "$N" /var/log/oum/oum.log
            else
                echo "Лог пуст."
            fi
            exit 0
            ;;
        version)
            echo "OUM v$OUM_VERSION"
            exit 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ====================== Установка команды oum ======================
oum_install_cmd() {
    header
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
    echo -e "${YELLOW}Текущий путь скрипта: $SCRIPT_PATH${NC}"
    if [ "$SCRIPT_PATH" != "/usr/bin/oum" ]; then
        cp "$SCRIPT_PATH" /usr/bin/oum
        chmod +x /usr/bin/oum
    fi
    # Прописываем URL самообновления на наш репозиторий
    mkdir -p /etc/oum
    if [ -f /etc/oum/oum.conf ] && grep -q "^OUM_UPDATE_URL=" /etc/oum/oum.conf; then
        sed -i "s|^OUM_UPDATE_URL=.*|OUM_UPDATE_URL=$OUM_REPO_URL|" /etc/oum/oum.conf
    else
        echo "OUM_UPDATE_URL=$OUM_REPO_URL" >> /etc/oum/oum.conf
    fi
    log_msg "OK oum installed as /usr/bin/oum"
    echo -e "${GREEN}✅ Готово. Теперь запускайте командой: oum${NC}"
    echo -e "${CYAN}CLI-режим: oum status | oum diag | oum log | oum version${NC}"
    echo -e "${CYAN}Самообновление: меню «Диагностика и обслуживание» → обновления OUM${NC}"
    pause
}

# ====================== Главное меню ======================
# CLI-режим (read-only) доступен без root; интерактивное меню — только root
if cli_mode "$@"; then
    exit 0
fi
check_root

while true; do
    header
    dashboard
    echo ""
    echo "1) Интернет и обход блокировок (Podkop, Zapret, AWG, GearUP, QUIC)"
    echo "2) Сеть и Wi-Fi"
    echo "3) Производительность (аппаратное ускорение)"
    echo "4) NAS и медиа"
    echo "5) Система (драйверы, темы LuCI)"
    echo "6) Диагностика и обслуживание (бэкапы, обновление, удаление)"
    echo "7) Быстрый статус"
    echo "8) Установить команду oum (запуск без пути + CLI)"
    echo ""
    echo -e "${YELLOW}Enter — Выход из скрипта${NC}"
    choice=$(read_choice)

    case "$choice" in
        1) menu_internet ;;
        2) menu_network ;;
        3) menu_hw_accel ;;
        4) menu_nas_media ;;
        5) menu_system ;;
        6) menu_maintenance ;;
        7) menu_status ;;
        8) oum_install_cmd ;;
        "")
            echo -e "${YELLOW}Выход из OUM? (Enter = да)${NC}"
            read -r confirm
            [ -z "$confirm" ] && { echo -e "${GREEN}До свидания!${NC}"; exit 0; }
            ;;
        *) echo -e "${RED}Неверный выбор.${NC}" ;;
    esac
done
