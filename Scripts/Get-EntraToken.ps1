<#
.SYNOPSIS
    Signs you in with the normal Microsoft Entra sign-in page in your browser
    (Authorization Code + PKCE), then copies the token to the clipboard so you
    can paste it into https://jwt.ms. Nothing is hard-coded.

.PARAMETER TenantId
    Directory (tenant) ID. Entra ID > Overview > Tenant ID.

.PARAMETER ClientId
    Application (client) ID of the app registration.

.PARAMETER Scope
    Optional. Defaults to "openid profile api://<ClientId>/api.access".
    The scope decides who the access token is for (its "aud").

.PARAMETER TokenType
    Access (default) or Id. Which token to copy.

.PARAMETER Port
    Optional. Local port used to receive the sign-in response. Default 8400.

.EXAMPLE
    .\Get-EntraToken.ps1 -TenantId <tenant-id> -ClientId <client-id>

.EXAMPLE
    .\Get-EntraToken.ps1 -TenantId <tenant-id> -ClientId <client-id> -TokenType Id

.NOTES
    One-time app setup (testing):
    App registrations > (app) > Authentication > Add a platform >
    "Mobile and desktop applications" > custom redirect URI: http://localhost
    No client secret and no "Allow public client flows" needed.
    Remove the redirect URI when you no longer need it.
#>
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ClientId,
    [string] $Scope,
    [ValidateSet("Access", "Id")] [string] $TokenType = "Access",
    [int] $Port = 8400
)

if (-not $Scope) { $Scope = "openid profile api://$ClientId/api.access" }
$base        = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"
$redirectUri = "http://localhost:$Port/"

function ConvertTo-Base64Url([byte[]] $bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# 1. PKCE values: a random secret (verifier) and its SHA-256 hash (challenge)
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$buf = New-Object byte[] 32; $rng.GetBytes($buf)
$codeVerifier  = ConvertTo-Base64Url $buf
$sha           = [System.Security.Cryptography.SHA256]::Create()
$codeChallenge = ConvertTo-Base64Url ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($codeVerifier)))
$rng.GetBytes($buf); $state = ConvertTo-Base64Url $buf

# 2. Start a small local listener to receive the sign-in response
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($redirectUri)
try { $listener.Start() } catch {
    Write-Host "Could not listen on $redirectUri. Try another -Port." -ForegroundColor Red
    return
}

# 3. Open the normal Entra sign-in page in the browser
$authUrl = "$base/authorize?" + (@(
    "client_id=$([uri]::EscapeDataString($ClientId))"
    "response_type=code"
    "redirect_uri=$([uri]::EscapeDataString($redirectUri))"
    "response_mode=query"
    "scope=$([uri]::EscapeDataString($Scope))"
    "state=$state"
    "code_challenge=$codeChallenge"
    "code_challenge_method=S256"
    "prompt=select_account"
) -join "&")

Write-Host "`nOpening the Microsoft sign-in page in your browser..." -ForegroundColor Yellow
Write-Host "If it does not open, copy this URL into a browser:`n$authUrl`n"
Start-Process $authUrl

# 4. Wait for the browser to come back with the authorization code
$context = $listener.GetContext()
$query   = $context.Request.QueryString
$html    = if ($query["code"]) { "<h3>Signed in. You can close this tab and return to PowerShell.</h3>" }
           else { "<h3>Sign-in failed: $($query['error']) - $($query['error_description'])</h3>" }
$bytes = [Text.Encoding]::UTF8.GetBytes("<html><body style='font-family:sans-serif'>$html</body></html>")
$context.Response.ContentType = "text/html"
$context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
$context.Response.Close()
$listener.Stop()

if (-not $query["code"]) {
    Write-Host "Error: $($query['error']) - $($query['error_description'])" -ForegroundColor Red
    return
}
if ($query["state"] -ne $state) {
    Write-Host "State mismatch. Sign-in response rejected." -ForegroundColor Red
    return
}

# 5. Exchange the code (plus the PKCE verifier) for tokens
try {
    $token = Invoke-RestMethod -Method Post -Uri "$base/token" -Body @{
        client_id     = $ClientId
        grant_type    = "authorization_code"
        code          = $query["code"]
        redirect_uri  = $redirectUri
        code_verifier = $codeVerifier
        scope         = $Scope
    }
} catch {
    $err = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue)
    Write-Host "Error: $($err.error) - $($err.error_description)" -ForegroundColor Red
    return
}

# 6. Pick the token and copy it
$jwt = if ($TokenType -eq "Id") { $token.id_token } else { $token.access_token }
if (-not $jwt) {
    Write-Host "No $TokenType token returned. For an ID token, include 'openid' in -Scope." -ForegroundColor Red
    return
}

Write-Host "=== $TokenType token ===" -ForegroundColor Green
Write-Host $jwt
try {
    $jwt | Set-Clipboard
    Write-Host "`nCopied to clipboard. Paste it into https://jwt.ms" -ForegroundColor Green
} catch {
    Write-Host "`nCopy the token above and paste it into https://jwt.ms" -ForegroundColor Yellow
}
