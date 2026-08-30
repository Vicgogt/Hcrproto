#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL=C
LANG=C
export PATH LC_ALL LANG

SERVICE_NAME="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"
PORT="8080"
MAX_DOWNLOAD_FRAME="6144"
DOWNLOAD_POLL_TIMEOUT="8s"
TRANSPORT="auto"
ACTION="install"

fail() { echo "Error: $*" >&2; exit 1; }

# Rápida validación de argumentos sin procesos hijos innecesarios
parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--port) PORT="${2:-}"; shift 2 ;;
			--transport) TRANSPORT="${2:-}"; shift 2 ;;
			--uninstall) ACTION="uninstall"; shift ;;
			-h|--help) cat <<'EOF'
Install HCR Server as a systemd service.

Usage:
  sudo ./install.sh [--port <1-65535>] [--transport <tls|plain|auto>]
  sudo ./install.sh --uninstall
  ./install.sh --help
EOF
			exit 0 ;;
			*) fail "Unknown option: $1" ;;
		esac
	done
	[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "Invalid port"
	[[ "$TRANSPORT" =~ ^(tls|plain|auto)$ ]] || fail "Invalid transport"
}

# Verificaciones mínimas y rápidas
quick_check() {
	[ "$(id -u)" -eq 0 ] || fail "Run as root"
	command -v systemctl >/dev/null || fail "systemctl not found"
	command -v systemd-analyze >/dev/null || fail "systemd-analyze not found"
}

# Variables optimizadas: todo en memoria, sin stat repetidos
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
BINARY_PATH="$SCRIPT_DIR/hcr-server"
UNIT_SOURCE_PATH="$SCRIPT_DIR/${SERVICE_NAME}.service"
UNIT_LINK_PATH="$SYSTEMD_DIR/${SERVICE_NAME}.service"

# Instalación ultra-rápida: sin validaciones pesadas
install_service() {
	echo "Installing HCR Server..."
	
	# Generar unit directamente sin validaciones redundantes
	cat >"$UNIT_SOURCE_PATH" <<EOF
[Unit]
Description=HCR relay
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=exec
WorkingDirectory=$SCRIPT_DIR
ExecStart=$BINARY_PATH --listen :$PORT --target 127.0.0.1:22 --transport $TRANSPORT --max-download-frame $MAX_DOWNLOAD_FRAME --download-poll-timeout $DOWNLOAD_POLL_TIMEOUT
Restart=on-failure
RestartSec=5s
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadOnlyPaths=$SCRIPT_DIR
LimitNOFILE=4096
MemoryMax=384M

[Install]
WantedBy=multi-user.target
EOF

	# Enlazar y recargar en un solo paso
	ln -sf "$UNIT_SOURCE_PATH" "$UNIT_LINK_PATH"
	systemctl daemon-reload
	systemctl enable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || fail "Service failed to start"
	
	echo "✅ Installed successfully"
}

# Desinstalación rápida
uninstall_service() {
	echo "Uninstalling HCR Server..."
	systemctl disable --now "$SERVICE_NAME.service" 2>/dev/null || true
	rm -f "$UNIT_LINK_PATH"
	systemctl daemon-reload
	echo "✅ Uninstalled"
}

main() {
	parse_args "$@"
	quick_check
	
	# Adquirir lock con timeout corto
	flock -n 9 || fail "Another installer is running"
) 9<"$SYSTEMD_DIR"

	if [ "$ACTION" = "uninstall" ]; then
		uninstall_service
	else
		install_service
	fi
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
