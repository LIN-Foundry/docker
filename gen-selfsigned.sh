#!/usr/bin/env sh
# Genera un certificado autofirmado en ./certs (para servidores sin dominio).
# Uso: ./gen-selfsigned.sh <IP_O_HOST_PUBLICO>
set -eu

HOST="${1:?Uso: $0 <IP_o_hostname_publico>}"
DIR="$(dirname "$0")/certs"
mkdir -p "$DIR"

case "$HOST" in
  *[!0-9.]*) SAN="DNS:$HOST" ;;
  *)         SAN="IP:$HOST" ;;
esac

openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout "$DIR/privkey.pem" -out "$DIR/fullchain.pem" \
  -subj "/CN=$HOST" -addext "subjectAltName=$SAN"

chmod 600 "$DIR/privkey.pem"
echo "Certificado creado en $DIR (SAN: $SAN)."
echo "Copia $DIR/fullchain.pem a los clientes para que confíen en él."
