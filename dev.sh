#!/usr/bin/env bash
# =============================================================================
# dev.sh - Micro Grand Maison ローカル開発環境 起動・停止スクリプト
#
# 使い方:
#   ./dev.sh start   # 全サービスを起動
#   ./dev.sh stop    # 全サービスを停止
#   ./dev.sh status  # 各サービスの稼働状況を表示
#   ./dev.sh logs    # 各サービスのログを tail で表示
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/.dev-logs"
PID_FILE="$SCRIPT_DIR/.dev-pids"

MCP_DIR="$SCRIPT_DIR/micro-grand-maison-mcp"
API_DIR="$SCRIPT_DIR/micro-grand-maison-api"
WEB_DIR="$SCRIPT_DIR/micro-grand-maison-web"

# ANSIカラー
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# =============================================================================
# start
# =============================================================================
cmd_start() {
  mkdir -p "$LOG_DIR"
  > "$PID_FILE"  # PIDファイルをリセット

  echo ""
  echo "================================================================"
  echo "  Micro Grand Maison - ローカル開発環境を起動します"
  echo "================================================================"
  echo ""

  # ------------------------------------------------------------------
  # 1. PostgreSQL (Docker Compose)
  # ------------------------------------------------------------------
  log_info "PostgreSQL を起動中..."
  docker compose -f "$API_DIR/docker-compose.yml" up -d
  log_success "PostgreSQL: localhost:5432"

  # ------------------------------------------------------------------
  # 2. MCP サーバー (port 8001)
  # ------------------------------------------------------------------
  log_info "MCP サーバーを起動中..."
  (
    cd "$MCP_DIR"
    if [ ! -d ".venv" ]; then
      log_warn "  .venv が見つかりません。仮想環境を作成します..."
      /usr/bin/python3 -m venv .venv
      .venv/bin/pip install -q -r requirements.txt
    fi
    .venv/bin/python3 server.py >> "$LOG_DIR/mcp.log" 2>&1 &
    echo "MCP_PID=$!" >> "$PID_FILE"
    log_success "MCP サーバー: http://localhost:8001  (ログ: .dev-logs/mcp.log)"
  )

  # ------------------------------------------------------------------
  # 3. API サーバー (port 8000)
  # ------------------------------------------------------------------
  log_info "API サーバーを起動中..."
  (
    cd "$API_DIR"
    if [ ! -d ".venv" ]; then
      log_warn "  .venv が見つかりません。仮想環境を作成します..."
      /usr/bin/python3 -m venv .venv
      .venv/bin/pip install -q -r requirements.txt
    fi

    # DB マイグレーション（初回 or 変更があれば適用）
    log_info "  Alembic マイグレーションを実行中..."
    .venv/bin/alembic upgrade head >> "$LOG_DIR/api.log" 2>&1 || true

    .venv/bin/python3 main.py >> "$LOG_DIR/api.log" 2>&1 &
    echo "API_PID=$!" >> "$PID_FILE"
    log_success "API サーバー:  http://localhost:8000  (ログ: .dev-logs/api.log)"
  )

  # ------------------------------------------------------------------
  # 4. Web フロントエンド (port 3000)
  # ------------------------------------------------------------------
  log_info "Web フロントエンドを起動中..."
  (
    cd "$WEB_DIR"
    if [ ! -d "node_modules" ]; then
      log_warn "  node_modules が見つかりません。npm install を実行します..."
      npm install --silent
    fi
    npm run dev >> "$LOG_DIR/web.log" 2>&1 &
    echo "WEB_PID=$!" >> "$PID_FILE"
    log_success "Web フロントエンド: http://localhost:3000  (ログ: .dev-logs/web.log)"
  )

  echo ""
  echo "================================================================"
  echo "  全サービス起動完了！"
  echo ""
  echo "  ブラウザで http://localhost:3000 を開いてください。"
  echo ""
  echo "  停止: ./dev.sh stop"
  echo "  状態: ./dev.sh status"
  echo "  ログ: ./dev.sh logs"
  echo "================================================================"
  echo ""
}

# =============================================================================
# stop
# =============================================================================
cmd_stop() {
  echo ""
  echo "================================================================"
  echo "  Micro Grand Maison - ローカル開発環境を停止します"
  echo "================================================================"
  echo ""

  # PIDファイルから各プロセスを終了
  if [ -f "$PID_FILE" ]; then
    while IFS='=' read -r name pid; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null && log_success "${name%_PID}: 停止しました (PID: $pid)"
      else
        log_warn "${name%_PID}: すでに停止しています (PID: $pid)"
      fi
    done < "$PID_FILE"
    rm -f "$PID_FILE"
  else
    log_warn "PIDファイルが見つかりません。プロセスが起動していない可能性があります。"
  fi

  # PostgreSQL を停止
  log_info "PostgreSQL を停止中..."
  docker compose -f "$API_DIR/docker-compose.yml" down && log_success "PostgreSQL: 停止しました"

  echo ""
  log_success "全サービスを停止しました。"
  echo ""
}

# =============================================================================
# status
# =============================================================================
cmd_status() {
  echo ""
  echo "================================================================"
  echo "  Micro Grand Maison - サービス稼働状況"
  echo "================================================================"

  check_port() {
    local name=$1 port=$2
    if lsof -i ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
      echo -e "  ${GREEN}●${NC} $name  →  http://localhost:$port"
    else
      echo -e "  ${RED}○${NC} $name  →  停止中 (port $port)"
    fi
  }

  check_port "MCP サーバー      " 8001
  check_port "API サーバー      " 8000
  check_port "Web フロントエンド" 3000

  # Docker
  echo ""
  if docker compose -f "$API_DIR/docker-compose.yml" ps --quiet 2>/dev/null | grep -q .; then
    echo -e "  ${GREEN}●${NC} PostgreSQL        →  localhost:5432"
  else
    echo -e "  ${RED}○${NC} PostgreSQL        →  停止中 (port 5432)"
  fi
  echo ""
}

# =============================================================================
# logs
# =============================================================================
cmd_logs() {
  if [ ! -d "$LOG_DIR" ]; then
    log_error "ログディレクトリが見つかりません。先に ./dev.sh start を実行してください。"
    exit 1
  fi

  echo ""
  echo "================================================================"
  echo "  ログを表示します（Ctrl+C で終了）"
  echo "================================================================"
  echo ""

  # macOS / GNU 共通で tail -f を使って全ログを並列表示
  tail -f \
    "$LOG_DIR/mcp.log" \
    "$LOG_DIR/api.log" \
    "$LOG_DIR/web.log" 2>/dev/null
}

# =============================================================================
# エントリポイント
# =============================================================================
case "${1:-}" in
  start)  cmd_start  ;;
  stop)   cmd_stop   ;;
  status) cmd_status ;;
  logs)   cmd_logs   ;;
  *)
    echo ""
    echo "使い方: ./dev.sh [start|stop|status|logs]"
    echo ""
    echo "  start   全サービス（MCP / API / Web / PostgreSQL）を起動"
    echo "  stop    全サービスを停止"
    echo "  status  各サービスの稼働状況を確認"
    echo "  logs    各サービスのログをリアルタイム表示"
    echo ""
    exit 1
    ;;
esac
