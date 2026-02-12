#!/bin/bash
#===============================================================================
# Akvorado Control Script
# Version: 1.0
# Author: NetFlow Setup
#
# Usage: akvorado-ctl.sh {start|stop|restart|reset|status|logs}
#
# Commands:
#   start   - Start all Akvorado services
#   stop    - Stop all Akvorado services
#   restart - Stop and start services
#   reset   - Full reset (stop, delete kafka topic/group, start)
#   status  - Show current status
#   logs    - Show recent log files
#
# Wait Times:
#   Orchestrator: 60 seconds
#   Inlet:        30 seconds
#   Outlet:       30 seconds
#   Console:      30 seconds
#   Stop:         60 seconds
#
# Service Ports:
#   8080 - Orchestrator API
#   8081 - Inlet API
#   8082 - Outlet API
#   8083 - Console (Web UI)
#   2055 - NetFlow (UDP)
#   6343 - sFlow (UDP)
#===============================================================================

set -e

KAFKA_BIN="/opt/kafka_2.13-3.9.1/bin"
BROKER="localhost:9092"
ORCH_URL="http://172.16.3.101:8080"
CONFIG="/etc/akvorado/config.yaml"
TOPIC="netplan-flows-v5"
CONSUMER_GROUP="akvorado-outlet"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

countdown() {
    local secs=$1
    while [ $secs -gt 0 ]; do
        echo -ne "\r  Waiting... ${secs}s "
        sleep 1
        : $((secs--))
    done
    echo -e "\r  Done.          "
}

case "$1" in
  start)
    log_info "Starting Akvorado services..."

    # Start orchestrator
    log_info "Starting orchestrator..."
    nohup /usr/local/bin/akvorado orchestrator $CONFIG > /var/log/akvorado-orchestrator.log 2>&1 &
    countdown 60
    if lsof -i :8080 > /dev/null 2>&1; then
        log_info "Orchestrator started (port 8080)"
    else
        log_error "Orchestrator failed to start"
        exit 1
    fi

    # Start inlet
    log_info "Starting inlet..."
    nohup /usr/local/bin/akvorado inlet $ORCH_URL > /var/log/akvorado-inlet.log 2>&1 &
    countdown 30

    # Start outlet
    log_info "Starting outlet..."
    nohup /usr/local/bin/akvorado outlet $ORCH_URL > /var/log/akvorado-outlet.log 2>&1 &
    countdown 30

    # Start console
    log_info "Starting console..."
    nohup /usr/local/bin/akvorado console $ORCH_URL > /var/log/akvorado-console.log 2>&1 &
    countdown 30

    log_info "All services started"
    $0 status
    ;;

  stop)
    log_info "Stopping Akvorado services..."
    pkill -9 -f "/usr/local/bin/akvorado" 2>/dev/null || true
    countdown 60
    if pgrep -f "/usr/local/bin/akvorado" > /dev/null; then
        log_error "Some processes still running"
        pgrep -af "/usr/local/bin/akvorado"
    else
        log_info "All services stopped"
    fi
    ;;

  restart)
    $0 stop
    $0 start
    ;;

  reset)
    log_info "=== FULL RESET ==="

    # Stop services
    log_info "Step 1: Stopping services..."
    pkill -9 -f "/usr/local/bin/akvorado" 2>/dev/null || true
    countdown 60

    # Check consumer group
    log_info "Step 2: Checking consumer group..."
    if $KAFKA_BIN/kafka-consumer-groups.sh --bootstrap-server $BROKER --list 2>/dev/null | grep -q "^${CONSUMER_GROUP}$"; then
        log_info "Consumer group '$CONSUMER_GROUP' exists, deleting..."
        $KAFKA_BIN/kafka-consumer-groups.sh --bootstrap-server $BROKER --delete --group $CONSUMER_GROUP 2>/dev/null || log_warn "Could not delete (may be active)"
    else
        log_info "Consumer group '$CONSUMER_GROUP' not found, skipping"
    fi

    # Check topic
    log_info "Step 3: Checking topic..."
    if $KAFKA_BIN/kafka-topics.sh --bootstrap-server $BROKER --list 2>/dev/null | grep -q "^${TOPIC}$"; then
        log_info "Topic '$TOPIC' exists, deleting..."
        $KAFKA_BIN/kafka-topics.sh --bootstrap-server $BROKER --delete --topic $TOPIC 2>/dev/null || log_warn "Could not delete topic"
        sleep 3
    else
        log_info "Topic '$TOPIC' not found, skipping"
    fi

    # Verify cleanup
    log_info "Step 4: Verification..."
    echo "  Topics: $($KAFKA_BIN/kafka-topics.sh --bootstrap-server $BROKER --list 2>/dev/null | tr '\n' ' ')"
    echo "  Consumer groups: $($KAFKA_BIN/kafka-consumer-groups.sh --bootstrap-server $BROKER --list 2>/dev/null | tr '\n' ' ')"

    # Start services
    log_info "Step 5: Starting services..."
    $0 start
    ;;

  status)
    echo "=== AKVORADO STATUS ==="
    echo ""
    echo "--- Processes ---"
    pgrep -af "/usr/local/bin/akvorado" || echo "  No processes running"
    echo ""
    echo "--- Ports ---"
    for port in 8080 8081 8082 8083 2055 6343; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            echo "  Port $port: OPEN"
        else
            echo "  Port $port: CLOSED"
        fi
    done
    echo ""
    echo "--- Kafka ---"
    echo "  Topics: $($KAFKA_BIN/kafka-topics.sh --bootstrap-server $BROKER --list 2>/dev/null | tr '\n' ' ')"
    echo ""
    echo "--- ClickHouse Flows ---"
    total=$(clickhouse-client --password 'netflow2026' --query "SELECT count(*) FROM akvorado.flows" 2>/dev/null || echo "N/A")
    recent=$(clickhouse-client --password 'netflow2026' --query "SELECT count(*) FROM akvorado.flows WHERE TimeReceived > now() - INTERVAL 5 MINUTE" 2>/dev/null || echo "N/A")
    echo "  Total: $total"
    echo "  Last 5 min: $recent"
    ;;

  logs)
    echo "=== RECENT LOGS ==="
    for svc in orchestrator inlet outlet console; do
        echo ""
        echo "--- $svc ---"
        tail -10 /var/log/akvorado-$svc.log 2>/dev/null || echo "  No log file"
    done
    ;;

  *)
    echo "Usage: akvorado-ctl.sh {start|stop|restart|reset|status|logs}"
    echo ""
    echo "  start   - Start all services"
    echo "  stop    - Stop all services"
    echo "  restart - Stop and start services"
    echo "  reset   - Full reset (stop, delete kafka, start)"
    echo "  status  - Show status"
    echo "  logs    - Show recent logs"
    exit 1
    ;;
esac
