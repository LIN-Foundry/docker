#!/usr/bin/env sh
# Instala (o actualiza) el proxy de la Docker API con API key + TLS autofirmado.
#
#   curl -fsSL https://raw.githubusercontent.com/LIN-Foundry/docker/main/install.sh | sudo sh
#   curl -fsSL https://raw.githubusercontent.com/LIN-Foundry/docker/main/install.sh | sudo sh -s -- <IP_PUBLICA>
#
# Variables opcionales: INSTALL_DIR (default /opt/docker-api-proxy), BRANCH (default main)
# Volver a ejecutarlo actualiza los archivos y conserva .env (API key) y certs/.
set -eu

# Todo va en main() para que el shell lea el script completo antes de ejecutarlo
# (descarga truncada o auto-actualización no ejecutan código a medias).
main() {
REPO="LIN-Foundry/docker"
BRANCH="${BRANCH:-main}"
DIR="${INSTALL_DIR:-/opt/docker-api-proxy}"
IP="${1:-}"

say()  { printf '\033[1;32m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ejecuta como root (sudo)."

# 1. Requisitos
for c in docker openssl curl tar; do
  command -v "$c" >/dev/null || die "Falta '$c'. Instálalo y vuelve a intentar."
done
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null; then DC="docker-compose"
else die "Falta Docker Compose (p. ej. apt install docker-compose-plugin)."; fi
docker info >/dev/null 2>&1 || die "El daemon de Docker no responde."

# 2. Descargar / actualizar archivos del repo
say "Descargando $REPO@$BRANCH en $DIR"
mkdir -p "$DIR"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar -xz --strip-components=1 -C "$DIR"
cd "$DIR"
chmod +x gen-selfsigned.sh install.sh

# 3. IP pública
if [ -z "$IP" ]; then
  IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [ -n "$IP" ] || IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$IP" ] || die "No pude detectar la IP. Pásala como argumento: ... | sudo sh -s -- <IP>"
  say "IP detectada: $IP"
fi

# 4. API key (solo la primera vez)
if [ ! -f .env ]; then
  printf 'API_KEY=%s\nPROXY_PORT=2376\n' "$(openssl rand -hex 32)" > .env
  say "API key nueva generada"
else
  say "Conservando .env existente"
fi
chmod 600 .env

# 5. Certificado (solo si no existe)
if [ ! -f certs/fullchain.pem ]; then
  ./gen-selfsigned.sh "$IP"
else
  say "Conservando certificado existente"
fi

# 6. Arrancar
$DC up -d --force-recreate
sleep 3

# 7. Verificación
KEY=$(grep '^API_KEY=' .env | cut -d= -f2)
NOKEY=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:2376/version || true)
WITHKEY=$(curl -sk -o /dev/null -w '%{http_code}' -H "X-Api-Key: $KEY" https://127.0.0.1:2376/version || true)
if [ "$NOKEY" = "401" ] && [ "$WITHKEY" = "200" ]; then
  say "Prueba OK (sin clave: 401, con clave: 200)"
else
  warn "Prueba inesperada: sin clave=$NOKEY (esperado 401), con clave=$WITHKEY (esperado 200)"
  warn "Revisa: docker logs docker-api-proxy"
fi

# 8. ¿El daemon sigue expuesto por TCP?
if ss -ltn 2>/dev/null | grep -qE ':2375([^0-9]|$)'; then
  echo ""
  warn "Algo sigue escuchando en el puerto 2375 (daemon SIN protección)."
  warn "Quita 'tcp://...' de /etc/docker/daemon.json o '-H tcp://...' del servicio systemd,"
  warn "reinicia Docker y cierra el 2375 en el firewall. Si no, la API key no protege nada."
fi

cat <<EOF

  Endpoint:    https://$IP:2376
  API key:     $KEY
  Certificado: $DIR/certs/fullchain.pem   (cópialo a los clientes)

  Abre el puerto 2376/tcp en el firewall del proveedor.
EOF
}

main "$@"
