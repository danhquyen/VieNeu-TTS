#!/usr/bin/env bash
# Triển khai VieNeu-TTS API (chuẩn OpenAI, streaming) bằng Docker trên server Linux có GPU NVIDIA.
# Dùng profile `api-gpu` trong docker/docker-compose.yml → POST http://<server>:8600/v1/audio/speech
#
#   ./scripts/deploy.sh            # = up: kiểm tra máy, build image, chạy nền, chờ /health
#   ./scripts/deploy.sh up
#   ./scripts/deploy.sh update     # git pull + build lại + chạy lại
#   ./scripts/deploy.sh restart
#   ./scripts/deploy.sh down       # dừng và xoá container (giữ cache model)
#   ./scripts/deploy.sh logs       # xem log (Ctrl+C để thoát)
#   ./scripts/deploy.sh status     # trạng thái container + /health
#   ./scripts/deploy.sh test       # gọi thử API, lưu file wav, in độ trễ
#
# Cấu hình nằm ở docker/.env (tự tạo ở lần chạy đầu, kèm API key ngẫu nhiên):
#   VIENEU_API_KEY      key Bearer cho client (HRM backend)
#   API_PORT            port public trên server (mặc định 8600)
#   VIENEU_MAX_STREAMS  số luồng đồng thời (mặc định 16, RTX 3060 tối đa ~32)
#   VIENEU_QUEUE        số request được xếp hàng khi hết slot
#   VIENEU_WATERMARK    1 = đóng watermark âm thanh, 0 = tắt
#
# Lưu ý: KHÔNG dùng file .env ở thư mục gốc — compose đọc docker/.env.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPOSE_FILE="docker/docker-compose.yml"
PROFILE="api-gpu"
SERVICE="api-gpu"
CONTAINER="vieneu-tts-api-gpu"
ENV_FILE="docker/.env"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-1200}"   # giây; lần đầu phải tải model từ Hugging Face

C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_RESET='\033[0m'
log()  { printf "${C_CYAN}>> %s${C_RESET}\n" "$*"; }
ok()   { printf "${C_GREEN}[OK] %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}[WARN] %s${C_RESET}\n" "$*"; }
die()  { printf "${C_RED}[ERROR] %s${C_RESET}\n" "$*" >&2; exit 1; }

compose() { docker compose -f "$COMPOSE_FILE" --profile "$PROFILE" "$@"; }

env_get() {
  # Đọc một biến trong docker/.env (không source cả file).
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2-
}

api_port() { local p; p="$(env_get API_PORT)"; echo "${p:-8600}"; }

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
  if [ -f "$ENV_FILE" ]; then
    [ -n "$(env_get VIENEU_API_KEY)" ] || warn "VIENEU_API_KEY trong $ENV_FILE đang trống — API mở cho bất kỳ ai gọi tới port."
    return
  fi
  log "Tạo $ENV_FILE (lần đầu)..."
  local key
  key="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  cat > "$ENV_FILE" <<EOF
# Cấu hình VieNeu-TTS API (Docker, profile api-gpu). Không commit file này.
VIENEU_API_KEY=$key
API_PORT=8600
VIENEU_MAX_STREAMS=16
VIENEU_QUEUE=16
VIENEU_QUEUE_TIMEOUT=10
VIENEU_WATERMARK=1
EOF
  chmod 600 "$ENV_FILE"
  ok "Đã tạo $ENV_FILE với API key ngẫu nhiên."
}

wait_healthy() {
  local port url start elapsed
  port="$(api_port)"; url="http://127.0.0.1:${port}/health"; start=$(date +%s)
  log "Chờ server sẵn sàng tại $url (lần đầu tải model có thể mất vài phút)..."
  while true; do
    if curl -sf "$url" >/dev/null 2>&1; then
      ok "Server đã chạy: $(curl -s "$url")"
      return 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
      docker logs --tail 50 "$CONTAINER" 2>&1 || true
      die "Container $CONTAINER đã dừng — xem log ở trên."
    fi
    elapsed=$(( $(date +%s) - start ))
    [ "$elapsed" -lt "$HEALTH_TIMEOUT" ] || die "Quá ${HEALTH_TIMEOUT}s chưa sẵn sàng. Xem log: ./scripts/deploy.sh logs"
    sleep 5
  done
}

print_info() {
  local port
  port="$(api_port)"
  echo
  ok "VieNeu-TTS API đang chạy"
  echo "   Endpoint : http://<IP-server>:${port}/v1/audio/speech"
  echo "   Giọng    : curl -H 'Authorization: Bearer <key>' http://<IP-server>:${port}/v1/voices"
  echo "   API key  : xem trong $ROOT/$ENV_FILE (VIENEU_API_KEY)"
  echo "   Log      : ./scripts/deploy.sh logs"
  echo "   Mở port ${port} trên firewall chỉ cho IP của HRM backend."
}

cmd_up() {
  check_prereqs
  ensure_env
  log "Build image và khởi động container (lần đầu build mất ~5-10 phút)..."
  compose up -d --build "$SERVICE"
  wait_healthy
  print_info
}

cmd_update() {
  if [ -d .git ]; then
    log "Kéo code mới..."
    git pull --ff-only
  fi
  cmd_up
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
  restart) compose restart "$SERVICE"; wait_healthy ;;
  down)    compose down ;;
  logs)    compose logs -f --tail 200 "$SERVICE" ;;
  status)  compose ps; curl -s "http://127.0.0.1:$(api_port)/health" && echo || warn "/health không phản hồi" ;;
  test)    cmd_test ;;
  -h|--help|help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)       die "Lệnh không hợp lệ: $1 (up | update | restart | down | logs | status | test | help)" ;;
esac
