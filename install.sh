#!/bin/bash

# Цвета для вывода
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

show() {
  echo -e "${GREEN}$1${RESET}"
}

error() {
  echo -e "${RED}$1${RESET}"
}

# Проверка на запуск от имени root
if [ "$EUID" -ne 0 ]; then
  error "Пожалуйста, запустите скрипт с правами root."
  exit 1
fi

# Установка зависимостей
show "Установка зависимостей..."
sudo apt update && sudo apt upgrade -y

for package in git curl python3 python3-pip; do
  if ! [ -x "$(command -v $package)" ]; then
    show "Устанавливаю $package..."
    sudo apt install -y $package
  else
    show "$package уже установлен."
  fi
done

pip3 install --user user-agents

# Проверка и установка Docker
if ! [ -x "$(command -v docker)" ]; then
  show "Установка Docker..."
  curl -fsSL https://get.docker.com | sh
  if ! [ -x "$(command -v docker)" ]; then
    error "Не удалось установить Docker."
    exit 1
  else
    show "Docker успешно установлен."
  fi
else
  show "Docker уже установлен."
fi

# Получение внешнего IP-адреса
IP=$(curl -4 -s ifconfig.me)
if [ -z "$IP" ]; then
  error "Не удалось получить внешний IP адрес."
  exit 1
fi

# Запрашиваем количество контейнеров
read -p "Сколько контейнеров хотите создать? " container_count

# Запрашиваем базовое имя контейнера
read -p "Введите базовое имя контейнера: " container_name

# Запрашиваем стартовый порт
default_port=10000
read -p "С какого порта начать? (По умолчанию $default_port): " start_port
start_port=${start_port:-$default_port}

# Проверка уникальности порта
function check_port() {
  port_in_use=$(lsof -i -P -n | grep -w "$1")
  if [ -n "$port_in_use" ]; then
    echo "Порт $1 уже занят. Выберите другой порт."
    return 1
  else
    return 0
  fi
}

# Путь к файлу с прокси
PROXY_FILE="$HOME/proxies.txt"

# Проверка наличия файла с прокси
if [ ! -f "$PROXY_FILE" ]; then
  error "Файл с прокси не найден. Пожалуйста, создайте файл $PROXY_FILE и введите список прокси."
  exit 1
fi

# Чтение прокси из файла
mapfile -t PROXIES < "$PROXY_FILE"

# Удаление файла после того, как прокси были считаны
rm -f "$PROXY_FILE"

# Проверка, что количество прокси не меньше количества контейнеров
if [ ${#PROXIES[@]} -lt "$container_count" ]; then
  error "Количество прокси меньше, чем количество контейнеров. Скрипт завершает работу."
  exit 1
fi

# Функция генерации случайного User-Agent с помощью Python
generate_user_agent() {
  python3 - <<END
from user_agents import generate_user_agent
print(generate_user_agent(device_type="desktop"))
END
}

# Генерация случайных параметров контейнера
generate_random_config() {
  width=$(( RANDOM % 400 + 1366 ))                     # Случайное разрешение (ширина)
  height=$(( RANDOM % 200 + 768 ))                    # Случайное разрешение (высота)
  scale=$(awk -v min=1.0 -v max=1.5 'BEGIN{srand(); print min+(max-min)*rand()}') # Масштаб
  timezone=$(shuf -n 1 /usr/share/zoneinfo/zone.tab | awk '{print $3}' | head -1) # Таймзона
  language=$(shuf -e en_US fr_FR de_DE es_ES ru_RU -n 1)                         # Язык
  user_agent=$(generate_user_agent)                                             # User-Agent
  echo "$width,$height,$scale,$timezone,$language,$user_agent"
}

# Создание контейнеров
for ((i=0; i<container_count; i++)); do
  # Используем прокси из файла для каждого контейнера
  proxy="${PROXIES[$i]}"

  # Разделяем строку на учетные данные (user:pass) и детали прокси (ip:port)
  IFS='@' read -r credentials proxy_details <<< "$proxy"
  IFS=':' read -r user pass <<< "$credentials"
  IFS=':' read -r ip port <<< "$proxy_details"

  # Прокси HTTP
  proxy_http="-e HTTP_PROXY=http://$user:$pass@$ip:$port"
  proxy_https="-e HTTPS_PROXY=http://$user:$pass@$ip:$port"
  chromium_proxy_args="--proxy-server=http://$user:$pass@$ip:$port"

  # Генерация случайных параметров
  config=$(generate_random_config)
  width=$(echo "$config" | cut -d, -f1)
  height=$(echo "$config" | cut -d, -f2)
  scale=$(echo "$config" | cut -d, -f3)
  timezone=$(echo "$config" | cut -d, -f4)
  language=$(echo "$config" | cut -d, -f5)
  user_agent=$(echo "$config" | cut -d, -f6)

  current_port=$((start_port + i * 10))  # Каждый следующий контейнер на 10 портов дальше

  # Проверка, что порт свободен
  if ! check_port "$current_port"; then
    error "Невозможно запустить контейнер на порту $current_port, так как он занят."
    continue
  fi

  # Генерация уникального имени контейнера
  container_name_unique="${container_name}$i"

  # Создание уникальной конфигурационной папки
  config_dir="$HOME/chromium/config_$container_name_unique"
  mkdir -p "$config_dir"

  # Запуск контейнера
  show "Запуск контейнера $container_name_unique с портом $current_port..."
  docker run -d --name "$container_name_unique" \
    --privileged \
    -e LANGUAGE="$language" \
    -e TZ="$timezone" \
    -e USER_AGENT="$user_agent" \
    --shm-size="2gb" \
    -v "$config_dir:/config" \
    -p "$current_port:3000" \
    --restart unless-stopped \
    lscr.io/linuxserver/chromium:latest \
    --window-size="${width}x${height}" \
    --force-device-scale-factor="$scale" \
    --user-agent="$user_agent"

  if [ $? -eq 0 ]; then
    show "Контейнер $container_name_unique успешно запущен."
    show "Откройте этот адрес: http://$IP:$current_port/"
    show "Параметры контейнера:"
    show "  ➤ User-Agent: $user_agent"
    show "  ➤ Разрешение экрана: ${width}x${height}, масштаб: $scale"
    show "  ➤ Язык: $language, Таймзона: $timezone"
  else
    error "Не удалось запустить контейнер $container_name_unique."
  fi
done

