<#
.SYNOPSIS
    Signs you in with the normal Microsoft Entra sign-in page in your browser
    (Authorization Code + PKCE), gets a Microsoft Graph access token, and calls
    one or more Microsoft Graph endpoints with it. Nothing is hard-coded.

.PARAMETER TenantId
    Directory (tenant) ID. Entra ID > Overview > Tenant ID.

.PARAMETER ClientId
    Application (client) ID of the app registration.

.PARAMETER Scope
    Optional. Microsoft Graph delegated permissions to ask for.
    Default: "openid profile User.Read".
    Use only Graph permissions here; scopes for another API in the same
    request fail with AADSTS700022.

.PARAMETER Endpoint
    Optional. One or more Graph paths to call. Default: "/me".
    Use single quotes for OData options, e.g. '/me/messages?$top=5',
    so PowerShell doesn't treat $top as a variable.

.PARAMETER ApiVersion
    Optional. "v1.0" (default) or "beta".

.PARAMETER Port
    Optional. Local port used to receive the sign-in response. Default 8400.

.PARAMETER ShowJwt
    Optional. Print the complete JWT for the access token and the ID token:
    the raw token, the decoded header, every claim in the payload, readable
    times for iat / nbf / exp, and the signature length. The access token is
    copied to the clipboard. Alias: -ShowToken.

.EXAMPLE
    .\Test-GraphApi.ps1 -TenantId <tenant-id> -ClientId <client-id>

.EXAMPLE
    .\Test-GraphApi.ps1 -TenantId <tenant-id> -ClientId <client-id> `
        -Scope "openid profile User.Read Calendars.ReadBasic" `
        -Endpoint '/me', '/me/events?$top=5&$select=subject,start,end'

.EXAMPLE
    .\Test-GraphApi.ps1 -TenantId <tenant-id> -ClientId <client-id> -ShowJwt

.NOTES
    One-time app setup (testing):
    1. App registrations > (app) > Authentication > Add a platform >
       "Mobile and desktop applications" > custom redirect URI: http://localhost
    2. App registrations > (app) > API permissions > Add a permission >
       Microsoft Graph > Delegated permissions > the permissions you need
       (User.Read is added by default). Grant admin consent if your tenant
       doesn't allow users to consent.
    No client secret and no "Allow public client flows" needed.
#>
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ClientId,
    [string]   $Scope = "openid profile User.Read",
    [string[]] $Endpoint = @("/me"),
    [ValidateSet("v1.0", "beta")] [string] $ApiVersion = "v1.0",
    [int]      $Port = 8400,
    [Alias("ShowToken")] [switch] $ShowJwt
)

$base        = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"
$redirectUri = "http://localhost:$Port/"
$graphRoot   = "https://graph.microsoft.com"

function ConvertTo-Base64Url([byte[]] $bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-JwtPart([string] $jwt, [int] $index) {
    # Decodes one part of a JWT (0 = header, 1 = payload). For display only:
    # Microsoft says not to depend on the format of tokens for APIs you don't
    # own (like Graph), so failures here are ignored.
    try {
        $part = $jwt.Split('.')[$index].Replace('-', '+').Replace('_', '/')
        switch ($part.Length % 4) { 2 { $part += '==' } 3 { $part += '=' } }
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
    } catch { $null }
}

function ConvertFrom-JwtPayload([string] $jwt) { ConvertFrom-JwtPart $jwt 1 }

function Show-Jwt([string] $title, [string] $jwt) {
    $parts = $jwt.Split('.')
    Write-Host "`n################ $title ################" -ForegroundColor Magenta

    Write-Host "`n--- Raw token (header.payload.signature) ---" -ForegroundColor DarkCyan
    Write-Host $jwt

    $header = ConvertFrom-JwtPart $jwt 0
    $claims = ConvertFrom-JwtPart $jwt 1
    if (-not $header -or -not $claims) {
        Write-Host "`nThis token can't be decoded as a JWT (it may be encrypted or use a special format)." -ForegroundColor Yellow
        return
    }

    Write-Host "`n--- Header: how the token is signed ---" -ForegroundColor DarkCyan
    $header | ConvertTo-Json -Depth 10

    Write-Host "`n--- Payload: all claims ---" -ForegroundColor DarkCyan
    $claims | ConvertTo-Json -Depth 10

    Write-Host "`n--- Times (your local time) ---" -ForegroundColor DarkCyan
    foreach ($t in @(
        @{ Name = "iat"; Label = "Issued at  " },
        @{ Name = "nbf"; Label = "Not before " },
        @{ Name = "exp"; Label = "Expires at " })) {
        $value = $claims.($t.Name)
        if ($value) {
            $local = [DateTimeOffset]::FromUnixTimeSeconds([int64]$value).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz")
            Write-Host ("{0} ({1}) : {2}" -f $t.Label, $t.Name, $local)
        }
    }

    Write-Host "`n--- Signature ---" -ForegroundColor DarkCyan
    $sigLength = if ($parts.Count -ge 3) { $parts[2].Length } else { 0 }
    Write-Host ("{0} characters, signed with {1}. Only the API the token is for (aud) should validate it." -f $sigLength, $header.alg)
}

function Get-GraphErrorText($errorRecord) {
    $msg = $errorRecord.ErrorDetails.Message
    if ($msg) {
        $json = $msg | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($json.error) { return "$($json.error.code): $($json.error.message)" }
        return $msg
    }
    return $errorRecord.Exception.Message
}

# 1. PKCE values: a random secret (verifier) and its SHA-256 fingerprint (challenge)
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
    if ($err.error_description -match 'AADSTS7000218') {
        Write-Host "Hint: http://localhost is registered under the 'Web' platform, so Entra expects a client secret." -ForegroundColor Yellow
        Write-Host "      Authentication > remove it from 'Web' > Add a platform > 'Mobile and desktop applications' > http://localhost" -ForegroundColor Yellow
    }
    if ($err.error_description -match 'AADSTS50146') {
        Write-Host "Hint: the app has custom claims (Enterprise apps > Single sign-on > Attributes & Claims)." -ForegroundColor Yellow
        Write-Host "      Single-tenant app: Manifest > ""api"" section > ""acceptMappedClaims"": true > Save." -ForegroundColor Yellow
        Write-Host "      Or remove the custom claims, or test with a separate app registration." -ForegroundColor Yellow
    }
    return
}

if (-not $token.access_token) {
    Write-Host "No access token returned. Include at least one Graph permission (e.g. User.Read) in -Scope." -ForegroundColor Red
    return
}

# 6. Show what the token allows
$claims = ConvertFrom-JwtPayload $token.access_token
Write-Host "`n=== Microsoft Graph access token ===" -ForegroundColor Green
Write-Host ("Granted permissions : {0}" -f $token.scope)
Write-Host ("Expires in          : {0} minutes" -f [math]::Round($token.expires_in / 60))
if ($claims) {
    Write-Host ("Audience (aud)      : {0}" -f $claims.aud)
    Write-Host ("Signed-in user      : {0}" -f $(if ($claims.upn) { $claims.upn } else { $claims.unique_name }))
}

if ($ShowJwt) {
    Show-Jwt "ACCESS TOKEN (for Microsoft Graph)" $token.access_token
    if ($token.id_token) {
        Show-Jwt "ID TOKEN (for your app)" $token.id_token
    }
    Write-Host "`nNote: Graph access tokens are made for Graph. jwt.ms may say their signature is invalid; that's expected." -ForegroundColor DarkYellow
    Write-Host "Note: your app's roles and custom claims (e.g. department) are never in the Graph access token." -ForegroundColor DarkYellow
    Write-Host "      Look in the ID TOKEN section above, or get an access token for your own API with Get-EntraToken.ps1." -ForegroundColor DarkYellow
    if (-not $token.id_token) {
        Write-Host "      No ID token was returned: include 'openid' in -Scope to get one." -ForegroundColor DarkYellow
    }
    try {
        $token.access_token | Set-Clipboard
        Write-Host "Access token copied to clipboard. Paste it into https://jwt.ms" -ForegroundColor Green
    } catch {
        Write-Host "Copy the access token above and paste it into https://jwt.ms" -ForegroundColor Yellow
    }
}

# 7. Call each Graph endpoint with the token
$headers = @{ Authorization = "Bearer $($token.access_token)" }

foreach ($path in $Endpoint) {
    $uri = if ($path -match '^https://') { $path }
           else { "$graphRoot/$ApiVersion/" + $path.TrimStart('/') }

    Write-Host "`n=== GET $uri ===" -ForegroundColor Cyan
    try {
        $result = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        if ($null -ne $result.value) {
            Write-Host ("{0} item(s) returned" -f @($result.value).Count) -ForegroundColor Green
        }
        $result | ConvertTo-Json -Depth 10
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Host ("Failed (HTTP {0}) {1}" -f $status, (Get-GraphErrorText $_)) -ForegroundColor Red
        switch ($status) {
            401 { Write-Host "Hint: the token was rejected. Sign in again." -ForegroundColor Yellow }
            403 { Write-Host "Hint: add the Graph permission this endpoint needs to -Scope and to API permissions, then grant consent." -ForegroundColor Yellow }
            404 { Write-Host "Hint: check the path. Some data (e.g. a photo or mailbox) may not exist for this user." -ForegroundColor Yellow }
        }
    }
}
