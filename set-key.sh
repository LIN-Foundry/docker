#!/usr/bin/env sh
# Cambia la API key del proxy de la Docker API y reinicia el contenedor.
#
#   sudo sh set-key.sh                 # genera una clave aleatoria (64 hex)
#   sudo sh set-key.sh MI_CLAVE        # usa esa clave
#   sudo API_KEY=MI_CLAVE sh set-key.sh   # igual, sin que quede en la lista de procesos
#
# Remoto:
#   curl -fsSL https://raw.githubusercontent.com/LIN-Foundry/docker/main/set-key.sh | sudo sh
#   curl -fsSL https://raw.githubusercontent.com/LIN-Foundry/docker/main/set-key.sh | sudo sh -s -- MI_CLAVE
#
# Reglas: solo A-Z a-z 0-9 - _ ; mínimo 32 caracteres.
# Variable opcional: INSTALL_DIR (default /opt/docker-api-proxy).
set -eu

main() {
DIR="${INSTALL_DIR:-/opt/docker-api-proxy}"
NEW_KEY="${1:-${API_KEY:-}}"
MIN_LEN=32

say()  { printf '\033[1;32m>>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$DIR/docker-compose.yml" ] || die "No encuentro el proxy en $DIR. Instálalo primero (install.sh)."
[ -w "$DIR" ] || die "Sin permisos sobre $DIR. Ejecuta con sudo."

if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null; then DC="docker-compose"
else die "Falta Docker Compose."; fi

# 1. Clave: la indicada o una aleatoria
if [ -z "$NEW_KEY" ]; then
  command -v openssl >/dev/null || die "Falta openssl para generar la clave."
  NEW_KEY="$(openssl rand -hex 32)"
  say "Clave aleatoria generada"
fi

# 2. Validación (la clave se inserta tal cual en la config de nginx)
case "$NEW_KEY" in
  *[!A-Za-z0-9_-]*) die "La clave solo puede tener letras, números, '-' y '_'." ;;
esac
[ "${#NEW_KEY}" -ge "$MIN_LEN" ] || die "La clave debe tener al menos $MIN_LEN caracteres (tiene ${#NEW_KEY})."

# 3. Guardar en .env (con respaldo de la anterior)
cd "$DIR"
PORT="2376"
if [ -f .env ]; then
  cp .env .env.bak
  chmod 600 .env.bak
  PORT="$(grep '^PROXY_PORT=' .env | cut -d= -f2 || true)"
  [ -n "$PORT" ] || PORT="2376"
fi
umask 077
printf 'API_KEY=%s\nPROXY_PORT=%s\n' "$NEW_KEY" "$PORT" > .env.tmp
mv .env.tmp .env
chmod 600 .env
say "Clave guardada en $DIR/.env"

# 4. Reiniciar el proxy con la nueva clave
$DC up -d --force-recreate >/dev/null 2>&1 || die "Falló docker compose up. Revisa: docker logs docker-api-proxy"

# 5. Verificar (espera a que nginx arranque)
code_new=""; code_none=""
i=0
while [ $i -lt 15 ]; do
  code_new=$(curl -sk -o /dev/null -w '%{http_code}' -H "X-Api-Key: $NEW_KEY" "https://127.0.0.1:$PORT/_ping" || true)
  [ "$code_new" = "200" ] && break
  i=$((i + 1)); sleep 1
done
code_none=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/_ping" || true)

if [ "$code_new" = "200" ] && [ "$code_none" = "401" ]; then
  say "Prueba OK (con clave nueva: 200, sin clave: 401)"
else
  printf '\033[1;31mERROR:\033[0m Prueba fallida (con clave: %s, sin clave: %s). Restaurando la clave anterior…\n' "$code_new" "$code_none" >&2
  if [ -f .env.bak ]; then
    mv .env.bak .env
    $DC up -d --force-recreate >/dev/null 2>&1 || true
  fi
  die "Revisa: docker logs docker-api-proxy"
fi

rm -f .env.bak
printf '\n  API key: %s\n\n' "$NEW_KEY"
}

main "$@"
