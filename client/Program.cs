using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using Docker.DotNet;
using Docker.DotNet.Handler.Abstractions;
using Docker.DotNet.Models;

// ---------------------------------------------------------------------------
// Cliente de prueba para el proxy de la Docker API (TLS + X-Api-Key).
//
//   dotnet run -- --endpoint https://IP:2376 --key CLAVE --ca fullchain.pem
//   dotnet run -- --endpoint https://IP:2376 --key CLAVE --insecure
//
// También por variables de entorno: DOCKER_PROXY_ENDPOINT, DOCKER_PROXY_KEY, DOCKER_PROXY_CA.
// ---------------------------------------------------------------------------

var opts = Options.Parse(args);
if (opts is null)
{
    Console.WriteLine("Uso: --endpoint https://IP:2376 --key CLAVE (--ca fullchain.pem | --insecure) [--exec CONTENEDOR]");
    return 2;
}

var validator = CertValidator.Create(opts.CaPath, opts.Insecure);
var results = new List<(string Name, bool Ok, string Detail)>();

async Task Check(string name, Func<Task<string>> test)
{
    Console.Write($"  {name,-45} ");
    try
    {
        var detail = await test();
        results.Add((name, true, detail));
        Console.ForegroundColor = ConsoleColor.Green;
        Console.WriteLine($"OK   {detail}");
    }
    catch (Exception ex)
    {
        var msg = ex.InnerException is null ? ex.Message : $"{ex.Message} -> {ex.InnerException.Message}";
        results.Add((name, false, msg));
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine($"FAIL {msg}");
    }
    Console.ResetColor();
}

Console.WriteLine($"Endpoint: {opts.Endpoint}");
Console.WriteLine($"TLS:      {(opts.Insecure ? "sin validar (--insecure)" : opts.CaPath is null ? "confianza del sistema" : $"CA {opts.CaPath}")}\n");

// --- 1. HTTP crudo: la autenticación del proxy -----------------------------
using var http = new HttpClient(new SocketsHttpHandler
{
    SslOptions = new SslClientAuthenticationOptions { RemoteCertificateValidationCallback = validator }
})
{ BaseAddress = opts.Endpoint, Timeout = TimeSpan.FromSeconds(15) };

async Task<HttpStatusCode> Get(string path, string? key)
{
    using var req = new HttpRequestMessage(HttpMethod.Get, path);
    if (key is not null) req.Headers.Add("X-Api-Key", key);
    using var res = await http.SendAsync(req);
    return res.StatusCode;
}

static string Expect(HttpStatusCode got, HttpStatusCode expected) =>
    got == expected ? $"{(int)got}" : throw new Exception($"esperado {(int)expected}, recibido {(int)got}");

Console.WriteLine("[HTTP] Autenticación del proxy");
await Check("Sin clave -> 401", async () => Expect(await Get("/_ping", null), HttpStatusCode.Unauthorized));
await Check("Clave incorrecta -> 401", async () => Expect(await Get("/_ping", "clave-incorrecta"), HttpStatusCode.Unauthorized));
await Check("Clave correcta -> 200", async () => Expect(await Get("/_ping", opts.Key), HttpStatusCode.OK));

// --- 2. Docker.DotNet a través del proxy -----------------------------------
Console.WriteLine("\n[Docker.DotNet] API de Docker vía proxy");

using var docker = new DockerClientBuilder()
    .WithEndpoint(opts.Endpoint)
    .WithAuthProvider(new ApiKeyTlsAuthProvider(validator))
    .WithHeader("X-Api-Key", opts.Key)
    .WithTimeout(TimeSpan.FromSeconds(30))
    .Build();

await Check("GET /version", async () =>
{
    var v = await docker.System.GetVersionAsync();
    return $"Docker {v.Version}, API {v.APIVersion}, {v.Os}/{v.Arch}";
});

IList<ContainerListResponse> containers = [];
await Check("Listar contenedores", async () =>
{
    containers = await docker.Containers.ListContainersAsync(new ContainersListParameters { All = true });
    return $"{containers.Count} contenedor(es)";
});

// exec usa conexión hijacked (Upgrade: tcp): valida que el proxy la deja pasar
var execTarget = opts.ExecContainer
    ?? containers.FirstOrDefault(c => (c.Names ?? []).Any(n => n.TrimStart('/') == "docker-api-proxy") && c.State == "running")?.ID
    ?? containers.FirstOrDefault(c => c.State == "running")?.ID;

if (execTarget is null)
{
    Console.WriteLine("  (sin contenedores corriendo: se omite la prueba de exec)");
}
else
{
    await Check("Exec (stream hijacked) 'echo'", async () =>
    {
        var exec = await docker.Exec.CreateContainerExecAsync(execTarget, new ContainerExecCreateParameters
        {
            Cmd = ["echo", "proxy-exec-ok"],
            AttachStdout = true,
            AttachStderr = true,
        });
        using var stream = await docker.Exec.StartContainerExecAsync(exec.ID, new ContainerExecStartParameters(), CancellationToken.None);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        var (stdout, stderr) = await stream.ReadOutputToEndAsync(cts.Token);
        return stdout.Trim() == "proxy-exec-ok"
            ? $"salida '{stdout.Trim()}'"
            : throw new Exception($"salida inesperada: '{stdout.Trim()}' {stderr}");
    });
}

// --- Resumen ---------------------------------------------------------------
var failed = results.Count(r => !r.Ok);
Console.WriteLine();
Console.ForegroundColor = failed == 0 ? ConsoleColor.Green : ConsoleColor.Red;
Console.WriteLine(failed == 0 ? $"Todas las pruebas OK ({results.Count})." : $"{failed} de {results.Count} pruebas fallaron.");
Console.ResetColor();
return failed == 0 ? 0 : 1;

// ===========================================================================

/// <summary>
/// Activa HTTPS en Docker.DotNet sin certificado de cliente y aplica la validación
/// del certificado del servidor (CA propia / autofirmado).
/// </summary>
sealed class ApiKeyTlsAuthProvider(RemoteCertificateValidationCallback validator) : IAuthProvider
{
    public bool TlsEnabled => true;

    public HttpMessageHandler ConfigureHandler(HttpMessageHandler handler)
    {
        switch (handler)
        {
            case SocketsHttpHandler sockets:
                sockets.SslOptions.RemoteCertificateValidationCallback = validator;
                break;
            case HttpClientHandler client:
                client.ServerCertificateCustomValidationCallback = (_, cert, chain, errors) => validator(this, cert, chain, errors);
                break;
            default:
                // Transporte legacy (ManagedHandler): expone ServerCertificateValidationCallback
                var prop = handler.GetType().GetProperty("ServerCertificateValidationCallback");
                if (prop?.PropertyType == typeof(RemoteCertificateValidationCallback))
                    prop.SetValue(handler, validator);
                break;
        }
        return handler;
    }
}

static class CertValidator
{
    public static RemoteCertificateValidationCallback Create(string? caPath, bool insecure)
    {
        if (insecure) return (_, _, _, _) => true;
        if (caPath is null) return (_, _, _, errors) => errors == SslPolicyErrors.None;

        var trusted = X509CertificateLoader.LoadCertificateFromFile(caPath);
        return (_, cert, _, errors) =>
        {
            if (cert is null) return false;
            // El nombre/IP del certificado debe coincidir con el endpoint
            if (errors.HasFlag(SslPolicyErrors.RemoteCertificateNameMismatch)) return false;

            using var chain = new X509Chain();
            chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
            chain.ChainPolicy.CustomTrustStore.Add(trusted);
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            return chain.Build(new X509Certificate2(cert));
        };
    }
}

sealed record Options(Uri Endpoint, string Key, string? CaPath, bool Insecure, string? ExecContainer)
{
    public static Options? Parse(string[] args)
    {
        string? Arg(string name) => args.SkipWhile(a => a != name).Skip(1).FirstOrDefault();

        var endpoint = Arg("--endpoint") ?? Environment.GetEnvironmentVariable("DOCKER_PROXY_ENDPOINT");
        var key = Arg("--key") ?? Environment.GetEnvironmentVariable("DOCKER_PROXY_KEY");
        var ca = Arg("--ca") ?? Environment.GetEnvironmentVariable("DOCKER_PROXY_CA");
        var insecure = args.Contains("--insecure");

        if (string.IsNullOrWhiteSpace(endpoint) || string.IsNullOrWhiteSpace(key)) return null;
        return new Options(new Uri(endpoint), key, ca, insecure, Arg("--exec"));
    }
}
