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

# Обновление системы и установка зависимостей
show "Обновление системы и установка зависимостей..."
sudo apt update && sudo apt upgrade -y

for package in git curl; do
  if ! [ -x "$(command -v $package)" ]; then
    show "Устанавливаю $package..."
    sudo apt install -y $package
  else
    show "$package уже установлен."
  fi
done

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
IP=$(curl -s ifconfig.me)
if [ -z "$IP" ]; then
  error "Не удалось получить внешний IP адрес."
  exit 1
fi

# Запрашиваем имя контейнера
read -p "Введите имя контейнера: " container_name

# Создание уникальной конфигурационной папки
config_dir="$HOME/chromium/config_$container_name"
mkdir -p "$config_dir"

# Выбор порта
default_port=10000
read -p "Оставить порт по умолчанию (${default_port})? [y/n]: " port_choice
if [[ "$port_choice" =~ ^[nN]$ ]]; then
  read -p "Введите порт для браузера: " port
else
  port=$default_port
fi

# Настройка прокси
read -p "Использовать прокси? [y/n]: " proxy_choice
proxy_flag=""
if [[ "$proxy_choice" =~ ^[yY]$ ]]; then
  read -p "Выберите тип прокси (http/socks5): " proxy_type
  case "$proxy_type" in
    http)
      read -p "Введите HTTP-прокси (в формате USER:PASS@IP:PORT): " proxy
      proxy_flag="--proxy-server=http://$proxy"
      ;;
    socks5)
      read -p "Введите SOCKS5-прокси (в формате USER:PASS@IP:PORT): " proxy
      proxy_flag="--proxy-server=socks5://$proxy"
      ;;
    *)
      error "Неверный тип прокси. Выберите 'http' или 'socks5'."
      exit 1
      ;;
  esac
fi

# Проверка и загрузка образа Docker с Chromium
show "Загрузка последнего образа Docker с Chromium..."
if ! docker pull linuxserver/chromium:latest; then
  error "Не удалось загрузить образ Docker с Chromium."
  exit 1
else
  show "Образ Docker с Chromium успешно загружен."
fi

# Запуск контейнера
show "Запуск контейнера с Chromium..."
docker run -d --name "$container_name" \
  --privileged \
  -e TITLE="Chromium Browser" \
  -e DISPLAY=:1 \
  -e PUID=1000 \
  -e PGID=1000 \
  -e LANGUAGE=en_US.UTF-8 \
  -e CHROMIUM_FLAGS="$proxy_flag" \
  -v "$config_dir:/config" \
  -p "$port:3000" \
  --shm-size="2gb" \
  --restart unless-stopped \
  lscr.io/linuxserver/chromium:latest

if [ $? -eq 0 ]; then
  show "Контейнер с Chromium успешно запущен."
  show "Откройте этот адрес: http://$IP:$port/"
else
  error "Не удалось запустить контейнер с Chromium."
fi
