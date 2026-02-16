var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => "Hello from APP_NAME");
app.MapGet("/healthz", () => Results.Ok("ok"));
app.MapGet("/readyz", () => Results.Ok("ok"));

app.Run();
