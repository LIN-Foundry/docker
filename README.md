# Docker API Proxy con API Key

nginx con TLS delante del socket de Docker. El puerto queda abierto a internet; solo entra
quien envíe la cabecera `X-Api-Key` correcta. Intentos fallidos limitados a 10/min por IP (luego 429).

```
Internet ──HTTPS :2376 + X-Api-Key──► nginx ──► /var/run/docker.sock
```

## Instalación (en el servidor)

```bash
curl -fsSL https://raw.githubusercontent.com/LIN-Foundry/docker/main/install.sh | sudo sh
```

Si la IP pública no se detecta bien, pásala:

```bash
curl -fsSL https://raw.githubusercontent.com/LIN-Foundry/docker/main/install.sh | sudo sh -s -- 203.0.113.10
```

El script instala en `/opt/docker-api-proxy`, genera la API key y un certificado autofirmado,
levanta nginx, prueba que responda 401 sin clave y 200 con clave, y muestra la clave al final.
Requiere Docker, Docker Compose, openssl, curl y tar.

Volver a ejecutarlo **actualiza** los archivos y **conserva** la API key (`.env`) y `certs/`.

## Después de instalar

### 1. Cerrar el acceso directo al daemon (IMPRESCINDIBLE)

El daemon NO debe escuchar en TCP; si no, el proxy se puede saltar.

```bash
cat /etc/docker/daemon.json              # quitar "tcp://..." de "hosts"
systemctl cat docker | grep ExecStart    # quitar "-H tcp://..." (sudo systemctl edit docker)
sudo systemctl daemon-reload && sudo systemctl restart docker
sudo ss -ltnp | grep 2375                # no debe aparecer nada
```

### 2. Firewall

Abre `2376/tcp` en el firewall del proveedor y elimina la regla del `2375`.
Ojo: los puertos publicados por Docker se saltan ufw/firewalld.

### 3. Probar desde fuera

```bash
curl -k https://SERVIDOR:2376/version                           # 401
curl -k -H "X-Api-Key: TU_CLAVE" https://SERVIDOR:2376/version  # 200
```

(`-k` porque el certificado es autofirmado; o usa `--cacert fullchain.pem`.)

## Clientes

- **Docker CLI**: en `~/.docker/config.json` → `"HttpHeaders": { "X-Api-Key": "TU_CLAVE" }`.
- **.NET (Docker.DotNet)**: `defaultHttpRequestHeaders` en `DockerClientConfiguration`.
- **HTTP directo**: cabecera `X-Api-Key` en cada petición.

## Operación

| Tarea | Comando |
|---|---|
| Ver la clave | `sudo grep API_KEY /opt/docker-api-proxy/.env` |
| Rotar la clave (aleatoria) | `curl -fsSL https://raw.githubusercontent.com/LIN-Foundry/docker/main/set-key.sh \| sudo sh` |
| Poner una clave manual | `curl -fsSL https://raw.githubusercontent.com/LIN-Foundry/docker/main/set-key.sh \| sudo sh -s -- MI_CLAVE` (A-Z a-z 0-9 - _, mín. 32) |
| Varias claves | agregar `"clave" 1;` en el `map` de `templates/default.conf.template` |
| Logs / intentos fallidos | `docker logs docker-api-proxy \| grep ' 401 '` |
| Desinstalar | `cd /opt/docker-api-proxy && sudo docker compose down && sudo rm -rf /opt/docker-api-proxy` |

## Seguridad

- Quien tenga la clave tiene control total del host (equivale a root). Trátala como una contraseña de root.
- Nunca subas `.env` ni `certs/` a git (están en `.gitignore`).

## Cliente de prueba (.NET)

`client/` es una consola .NET 10 que valida un proxy instalado: 401 sin clave / clave incorrecta,
200 con clave, y con Docker.DotNet (`Docker.DotNet.Enhanced`) `version`, listar contenedores y un
`exec` (stream hijacked).

```bash
cd client
dotnet run -- --endpoint https://IP:2376 --key CLAVE --ca fullchain.pem   # valida el certificado
dotnet run -- --endpoint https://IP:2376 --key CLAVE --insecure           # sin validar (solo pruebas)
```

Cómo conectarse con Docker.DotNet (v4) desde tu código:

```csharp
using var docker = new DockerClientBuilder()
    .WithEndpoint(new Uri("https://IP:2376"))
    .WithAuthProvider(new ApiKeyTlsAuthProvider(validator))   // activa HTTPS + valida el cert (ver Program.cs)
    .WithHeader("X-Api-Key", apiKey)
    .Build();
```
