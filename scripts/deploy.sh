#!/usr/bin/env bash
# Triển khai VieNeu-TTS bằng Docker trên server Linux có GPU NVIDIA. Chạy 2 container:
#   api-gpu : API chuẩn OpenAI, streaming → http://<server>:8600/v1/audio/speech
#   web-gpu : Web UI (Gradio) + hướng dẫn sử dụng API → http://<server>:8601
#
#   ./scripts/deploy.sh            # = up: kiểm tra máy, build image, chạy nền, chờ sẵn sàng
#   ./scripts/deploy.sh up
#   ./scripts/deploy.sh update     # git pull + build lại + chạy lại
#   ./scripts/deploy.sh restart
#   ./scripts/deploy.sh down       # dừng và xoá container (giữ cache model)
#   ./scripts/deploy.sh logs [api|web]   # xem log (Ctrl+C để thoát)
#   ./scripts/deploy.sh status     # trạng thái container + /health
#   ./scripts/deploy.sh test       # gọi thử API, lưu file wav, in độ trễ
#
# Cấu hình nằm ở docker/.env (tự tạo / bổ sung khi chạy, kèm API key và mật khẩu ngẫu nhiên):
#   VIENEU_API_KEY         key Bearer cho client (HRM backend)
#   API_PORT               port API trên server (mặc định 8600)
#   WEB_PORT               port Web UI trên server (mặc định 8601)
#   VIENEU_WEB_AUTH        đăng nhập Web UI, dạng user:password
#   VIENEU_API_PUBLIC_URL  địa chỉ API hiển thị trong trang hướng dẫn (vd. http://10.0.0.5:8600)
#   VIENEU_MAX_STREAMS     số luồng API đồng thời (mặc định 16, RTX 3060 tối đa ~32)
#   VIENEU_QUEUE           số request được xếp hàng khi hết slot
#   VIENEU_WATERMARK       1 = đóng watermark âm thanh, 0 = tắt
#
# Lưu ý: KHÔNG dùng file .env ở thư mục gốc — compose đọc docker/.env.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPOSE_FILE="docker/docker-compose.yml"
API_SERVICE="api-gpu"; API_CONTAINER="vieneu-tts-api-gpu"
WEB_SERVICE="web-gpu"; WEB_CONTAINER="vieneu-tts-web-gpu"
ENV_FILE="docker/.env"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-1200}"   # giây; lần đầu phải tải model từ Hugging Face

C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}>> %s${C_RESET}\n" "$*"; }
ok()   { printf "${C_GREEN}[OK] %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}[WARN] %s${C_RESET}\n" "$*"; }
die()  { printf "${C_RED}[ERROR] %s${C_RESET}\n" "$*" >&2; exit 1; }

compose() { docker compose -f "$COMPOSE_FILE" --profile "$API_SERVICE" --profile "$WEB_SERVICE" "$@"; }

env_get() {
  # Đọc một biến trong docker/.env (không source cả file).
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2-
}

env_default() {
  # Thêm KEY=VALUE vào docker/.env nếu chưa có (giữ nguyên giá trị người dùng đã sửa).
  if ! grep -qE "^$1=" "$ENV_FILE" 2>/dev/null; then
    echo "$1=$2" >> "$ENV_FILE"
    ok "Thêm $1 vào $ENV_FILE"
  fi
}

api_port() { local p; p="$(env_get API_PORT)"; echo "${p:-8600}"; }
web_port() { local p; p="$(env_get WEB_PORT)"; echo "${p:-8601}"; }
random_secret() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
server_ip() { local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"; echo "${ip:-<IP-server>}"; }

check_prereqs() {
  log "Kiểm tra môi trường..."
  command -v docker >/dev/null 2>&1 || die "Chưa cài Docker: https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 || die "Thiếu Docker Compose v2 (lệnh 'docker compose')."
  docker info >/dev/null 2>&1 || die "Không gọi được Docker daemon (thêm user vào group docker hoặc chạy bằng sudo)."
  ok "Docker $(docker version --format '{{.Server.Version}}'), $(docker compose version --short)"

  if command -v nvidia-smi >/dev/null 2>&1; then
    ok "GPU: $(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | head -n1)"
  else
    die "Không thấy nvidia-smi — server chưa cài driver NVIDIA."
  fi

  if docker info 2>/dev/null | grep -qi nvidia || command -v nvidia-ctk >/dev/null 2>&1; then
    ok "NVIDIA Container Toolkit"
  else
    die "Chưa cài NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
       Sau khi cài: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
  fi
}

ensure_env() {
  if [ ! -f "$ENV_FILE" ]; then
    log "Tạo $ENV_FILE (lần đầu)..."
    echo "# Cấu hình VieNeu-TTS (Docker, profile api-gpu + web-gpu). Không commit file này." > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi
  # Bổ sung các biến còn thiếu — file tạo từ bản script cũ chưa có phần Web UI.
  env_default VIENEU_API_KEY "$(random_secret 24)"
  env_default API_PORT 8600
  env_default WEB_PORT 8601
  env_default VIENEU_WEB_AUTH "admin:$(random_secret 8)"
  env_default VIENEU_API_PUBLIC_URL "http://$(server_ip):$(api_port)"
  env_default VIENEU_MAX_STREAMS 16
  env_default VIENEU_QUEUE 16
  env_default VIENEU_QUEUE_TIMEOUT 10
  env_default VIENEU_WATERMARK 1
  [ -n "$(env_get VIENEU_API_KEY)" ] || warn "VIENEU_API_KEY đang trống — API mở cho bất kỳ ai gọi tới port."
  [ -n "$(env_get VIENEU_WEB_AUTH)" ] || warn "VIENEU_WEB_AUTH đang trống — Web UI không cần đăng nhập."
}

wait_ready() {
  # wait_ready <container> <url> <tên hiển thị>
  local container="$1" url="$2" name="$3" start elapsed restarts line last=""
  start=$(date +%s)
  log "Chờ $name sẵn sàng tại $url (lần đầu tải model có thể mất vài phút)..."
  while true; do
    if curl -sf -o /dev/null "$url" 2>/dev/null; then
      ok "$name đã chạy."
      return 0
    fi
    # restart: unless-stopped che mất crash — container vẫn "chạy" nhưng khởi động lại liên tục.
    restarts="$(docker inspect -f '{{.RestartCount}}' "$container" 2>/dev/null || echo 0)"
    if [ "${restarts:-0}" -gt 0 ] || ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
      docker logs --tail 60 "$container" 2>&1 || true
      die "Container $container bị crash (restart ${restarts} lần) — xem log ở trên."
    fi
    elapsed=$(( $(date +%s) - start ))
    [ "$elapsed" -lt "$HEALTH_TIMEOUT" ] || die "Quá ${HEALTH_TIMEOUT}s $name chưa sẵn sàng. Xem log: ./scripts/deploy.sh logs"
    # In dòng log mới nhất (tiến độ tải model, load GPU...) để không phải chờ mù.
    line="$(docker logs --tail 1 "$container" 2>&1 | tr '\r' '\n' | tail -n1 | cut -c1-150)"
    if [ -n "$line" ] && [ "$line" != "$last" ]; then
      printf '   [%4ss] %s\n' "$elapsed" "$line"; last="$line"
    fi
    sleep 5
  done
}

wait_all() {
  wait_ready "$API_CONTAINER" "http://127.0.0.1:$(api_port)/health" "API"
  wait_ready "$WEB_CONTAINER" "http://127.0.0.1:$(web_port)/" "Web UI"
}

print_info() {
  local ip
  ip="$(server_ip)"
  echo
  ok "VieNeu-TTS đang chạy"
  echo "   Web UI      : http://${ip}:$(web_port)   (đăng nhập: VIENEU_WEB_AUTH trong $ENV_FILE)"
  echo "   Hướng dẫn   : Web UI → mục \"📘 Hướng dẫn sử dụng API\" (cuối trang)"
  echo "   API         : http://${ip}:$(api_port)/v1/audio/speech   (Swagger: /docs)"
  echo "   API key     : VIENEU_API_KEY trong $ROOT/$ENV_FILE"
  echo "   Log         : ./scripts/deploy.sh logs [api|web]"
  echo "   Firewall    : port $(api_port) chỉ mở cho HRM backend; port $(web_port) cho người dùng nội bộ."
  echo "   Web UI chỉ nạp model lên GPU khi bấm \"Tải Model\" — tốn thêm VRAM bên cạnh API."
}

cmd_up() {
  check_prereqs
  ensure_env
  log "Build image (lần đầu mất ~5-10 phút)..."
  compose build "$API_SERVICE" "$WEB_SERVICE"
  # Volume cache model có thể đã được tạo với owner root (image cũ chưa có sẵn thư mục này),
  # trong khi container chạy bằng user app (UID 1000) → không tải được model. Chown lại cho chắc.
  log "Cấp quyền thư mục cache model cho user app..."
  compose run --rm --no-deps --user root --entrypoint chown "$API_SERVICE" -R 1000:1000 /home/app/.cache/huggingface
  log "Khởi động container..."
  compose up -d "$API_SERVICE" "$WEB_SERVICE"
  wait_all
  print_info
}

cmd_update() {
  if [ -d .git ]; then
    log "Kéo code mới..."
    git pull --ff-only
  fi
  cmd_up
}

cmd_logs() {
  case "${1:-}" in
    api) compose logs -f --tail 200 "$API_SERVICE" ;;
    web) compose logs -f --tail 200 "$WEB_SERVICE" ;;
    "")  compose logs -f --tail 200 "$API_SERVICE" "$WEB_SERVICE" ;;
    *)   die "Dùng: ./scripts/deploy.sh logs [api|web]" ;;
  esac
}

cmd_test() {
  local port key out
  port="$(api_port)"; key="$(env_get VIENEU_API_KEY)"; out="${TMPDIR:-/tmp}/vieneu-test.wav"
  log "Gọi thử POST /v1/audio/speech..."
  curl -sfN -o "$out" \
    -w "   TTFB=%{time_starttransfer}s  total=%{time_total}s  bytes=%{size_download}\n" \
    "http://127.0.0.1:${port}/v1/audio/speech" \
    -H "Content-Type: application/json" \
    ${key:+-H "Authorization: Bearer $key"} \
    -d '{"input":"Chào bạn, cảm ơn bạn đã tham gia buổi phỏng vấn hôm nay.","response_format":"wav"}' \
    || die "Gọi API thất bại — kiểm tra ./scripts/deploy.sh status"
  ok "Đã lưu $out"
}

case "${1:-up}" in
  up)      cmd_up ;;
  update)  cmd_update ;;
  restart) compose restart "$API_SERVICE" "$WEB_SERVICE"; wait_all ;;
  down)    compose down ;;
  logs)    cmd_logs "${2:-}" ;;
  status)  compose ps; curl -s "http://127.0.0.1:$(api_port)/health" && echo || warn "/health không phản hồi" ;;
  test)    cmd_test ;;
  -h|--help|help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)       die "Lệnh không hợp lệ: $1 (up | update | restart | down | logs | status | test | help)" ;;
esac
