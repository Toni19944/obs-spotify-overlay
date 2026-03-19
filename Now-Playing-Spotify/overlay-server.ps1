# overlay-server.ps1
# Handles Spotify OAuth, token refresh, and serves the overlay to OBS.
# Keep this window open while streaming.

# ═══════════════════════════════════════════════════════════════
#  CONFIGURATION
#  Fill in your Spotify app credentials before first run.
#  See README.md for instructions on getting these.
# ═══════════════════════════════════════════════════════════════
$CLIENT_ID     = "YOUR_CLIENT_ID_HERE"
$CLIENT_SECRET = "YOUR_CLIENT_SECRET_HERE"
$PORT          = 8081
$REDIRECT_URI  = "http://127.0.0.1:8082/callback"
$SCOPE         = "user-read-currently-playing user-read-playback-state"

# ── Paths ──────────────────────────────────────────────────────
$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$tokenFile = Join-Path $root "spotify-token.txt"

# ── Token state ────────────────────────────────────────────────
$script:accessToken  = $null
$script:refreshToken = $null
$script:tokenExpiry  = [DateTime]::MinValue

# ── Helpers ────────────────────────────────────────────────────
function Invoke-TokenRequest($body) {
    $auth    = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${CLIENT_ID}:${CLIENT_SECRET}"))
    $headers = @{ Authorization = "Basic $auth" }
    return Invoke-RestMethod -Uri "https://accounts.spotify.com/api/token" `
                             -Method Post -Body $body -Headers $headers `
                             -ContentType "application/x-www-form-urlencoded"
}

function Update-TokenState($response) {
    $script:accessToken = $response.access_token
    $script:tokenExpiry = [DateTime]::UtcNow.AddSeconds($response.expires_in - 60)
    if ($response.refresh_token) {
        $script:refreshToken = $response.refresh_token
        $script:refreshToken | Set-Content $tokenFile -NoNewline
    }
}

function Invoke-TokenRefresh {
    try {
        $body     = "grant_type=refresh_token&refresh_token=$($script:refreshToken)"
        $response = Invoke-TokenRequest $body
        Update-TokenState $response
        Write-Host "Token refreshed." -ForegroundColor DarkGray
    } catch {
        Write-Host "Token refresh failed: $_" -ForegroundColor Red
    }
}

function Send-Response($ctx, $statusCode, $contentType, $bytes) {
    $ctx.Response.StatusCode      = $statusCode
    $ctx.Response.ContentType     = $contentType
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.Headers.Add("Access-Control-Allow-Origin", "*")
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

function Send-Json($ctx, $json) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    Send-Response $ctx 200 "application/json" $bytes
}

function Send-File($ctx, $filePath) {
    $ext  = [IO.Path]::GetExtension($filePath).ToLower()
    $mime = switch ($ext) {
        ".html" { "text/html; charset=utf-8" }
        ".jpg"  { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        ".png"  { "image/png" }
        ".webp" { "image/webp" }
        ".avif" { "image/avif" }
        ".js"   { "application/javascript" }
        ".css"  { "text/css" }
        default { "application/octet-stream" }
    }
    $bytes = [IO.File]::ReadAllBytes($filePath)
    Send-Response $ctx 200 $mime $bytes
}

# ── Validate config ────────────────────────────────────────────
if ($CLIENT_ID -eq "YOUR_CLIENT_ID_HERE" -or $CLIENT_SECRET -eq "YOUR_CLIENT_SECRET_HERE") {
    Write-Host ""
    Write-Host "  ERROR: Spotify credentials not set." -ForegroundColor Red
    Write-Host "  Open overlay-server.ps1 and fill in CLIENT_ID and CLIENT_SECRET." -ForegroundColor Yellow
    Write-Host "  See README.md for instructions." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit
}

# ── Load saved refresh token ───────────────────────────────────
if (Test-Path $tokenFile) {
    $script:refreshToken = (Get-Content $tokenFile -Raw).Trim()
    Write-Host "Found saved Spotify token." -ForegroundColor DarkGray
}

# ── OAuth flow (first run only) ────────────────────────────────
if (-not $script:refreshToken) {
    Write-Host ""
    Write-Host "No Spotify login found. Opening browser for authorization..." -ForegroundColor Yellow
    Write-Host ""

    $authUrl = "https://accounts.spotify.com/authorize" +
               "?client_id=$CLIENT_ID" +
               "&response_type=code" +
               "&redirect_uri=$([Uri]::EscapeDataString($REDIRECT_URI))" +
               "&scope=$([Uri]::EscapeDataString($SCOPE))"

    Start-Process $authUrl

    # Listen for the OAuth callback
    $cbListener = New-Object System.Net.HttpListener
    $cbListener.Prefixes.Add("http://127.0.0.1:8082/")
    $cbListener.Start()

    Write-Host "Waiting for Spotify login in your browser..." -ForegroundColor Yellow
    $ctx  = $cbListener.GetContext()
    $code = $ctx.Request.QueryString["code"]

    # Send a friendly success page
    $successHtml = @"
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#111;color:#fff;}
.box{text-align:center;}.check{font-size:48px;margin-bottom:16px;}h2{margin:0 0 8px;font-weight:500;}p{color:rgba(255,255,255,0.5);margin:0;}</style></head>
<body><div class="box"><div class="check">✓</div><h2>All done!</h2><p>You can close this tab and go back to streaming.</p></div></body></html>
"@
    $successBytes = [Text.Encoding]::UTF8.GetBytes($successHtml)
    $ctx.Response.ContentType     = "text/html"
    $ctx.Response.ContentLength64 = $successBytes.Length
    $ctx.Response.OutputStream.Write($successBytes, 0, $successBytes.Length)
    $ctx.Response.Close()
    $cbListener.Stop()

    # Exchange code for tokens
    try {
        $body     = "grant_type=authorization_code&code=$code&redirect_uri=$([Uri]::EscapeDataString($REDIRECT_URI))"
        $response = Invoke-TokenRequest $body
        Update-TokenState $response
        Write-Host "Logged in to Spotify successfully!" -ForegroundColor Green
    } catch {
        Write-Host "Failed to exchange code for token: $_" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit
    }
}

# ── Initial token refresh ──────────────────────────────────────
Invoke-TokenRefresh

# ── Main server loop ───────────────────────────────────────────
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$PORT/")
$listener.Start()

Write-Host ""
Write-Host "Overlay server running at http://localhost:$PORT/" -ForegroundColor Green
Write-Host "Close this window to stop." -ForegroundColor DarkGray
Write-Host ""

while ($listener.IsListening) {
    $ctx  = $listener.GetContext()
    $path = $ctx.Request.Url.LocalPath.TrimStart('/')

    # Refresh access token if it's about to expire
    if ([DateTime]::UtcNow -ge $script:tokenExpiry) {
        Invoke-TokenRefresh
    }

    try {
        if ($path -eq "api/spotify/current") {
            # Fetch currently playing track from Spotify
            try {
                $spotifyRes = Invoke-WebRequest `
                    -Uri "https://api.spotify.com/v1/me/player/currently-playing" `
                    -Headers @{ Authorization = "Bearer $($script:accessToken)" } `
                    -UseBasicParsing

                if ($spotifyRes.StatusCode -eq 204) {
                    # Nothing playing
                    Send-Json $ctx '{"is_playing":false}'
                } else {
                    Send-Json $ctx $spotifyRes.Content
                }
            } catch {
                Send-Json $ctx '{"is_playing":false}'
            }

        } elseif ($path -eq "bg-list") {
            $bgDir = Join-Path $root "bg"
            $files = @()
            if (Test-Path $bgDir) {
                $exts = "*.jpg", "*.jpeg", "*.png", "*.webp", "*.avif"
                foreach ($ext in $exts) {
                    $files += Get-ChildItem -Path $bgDir -Filter $ext |
                              ForEach-Object { "bg/$($_.Name)" }
                }
            }
            $json = "[" + (($files | ForEach-Object { "`"$_`"" }) -join ",") + "]"
            Send-Json $ctx $json

        } else {
            # Serve static file
            if ($path -eq "") { $path = "nowplaying-spotify.html" }
            $file = Join-Path $root $path

            if (Test-Path $file -PathType Leaf) {
                Send-File $ctx $file
            } else {
                $notFound = [Text.Encoding]::UTF8.GetBytes("Not found")
                Send-Response $ctx 404 "text/plain" $notFound
            }
        }
    } catch {
        Write-Host "Error handling request: $_" -ForegroundColor Red
        try { $ctx.Response.StatusCode = 500; $ctx.Response.Close() } catch {}
    }
}
