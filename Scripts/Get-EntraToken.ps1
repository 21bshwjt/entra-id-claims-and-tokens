<#
.SYNOPSIS
    Signs you in with the normal Microsoft Entra sign-in page in your browser
    (Authorization Code + PKCE), checks the key claims of the token, and copies
    the token to the clipboard so you can paste it into https://jwt.ms.
    Nothing is hard-coded.

.PARAMETER TenantId
    Directory (tenant) ID. Entra ID > Overview > Tenant ID.

.PARAMETER ClientId
    Application (client) ID of the app registration.

.PARAMETER Scope
    Optional. Defaults to "openid profile api://<ClientId>/api.access".
    The scope decides who the access token is for (its "aud").

.PARAMETER TokenType
    Access (default) or Id. Which token to check and copy.

.PARAMETER Port
    Optional. Local port used to receive the sign-in response. Default 8400.
    No port is needed in the app registration: Entra ignores the port for
    localhost redirect URIs.

.PARAMETER ShowJwt
    Optional. Print the complete JWT for the access token and the ID token:
    the raw token, the decoded header, every claim in the payload, readable
    times for iat / nbf / exp, and the signature length. Alias: -ShowToken.

.EXAMPLE
    .\Get-EntraToken.ps1 -TenantId <tenant-id> -ClientId <client-id>

.EXAMPLE
    .\Get-EntraToken.ps1 -TenantId <tenant-id> -ClientId <client-id> -TokenType Id

.EXAMPLE
    .\Get-EntraToken.ps1 -TenantId <tenant-id> -ClientId <client-id> -ShowJwt

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
    [int] $Port = 8400,
    [Alias("ShowToken")] [switch] $ShowJwt
)

if (-not $Scope) { $Scope = "openid profile api://$ClientId/api.access" }
$base        = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"
$redirectUri = "http://localhost:$Port/"

# Standard Entra / OIDC claims. Anything else in a token is shown as
# "other claims" (usually your custom or optional claims).
$standardClaims = @(
    'aud','iss','iat','nbf','exp','aio','azp','azpacr','appid','appidacr','idp','idtyp',
    'name','oid','preferred_username','rh','scp','sub','tid','uti','ver','sid','nonce',
    'roles','groups','wids','hasgroups','_claim_names','_claim_sources','amr','acr','acrs',
    'acct','auth_time','ipaddr','unique_name','upn','family_name','given_name','email',
    'login_hint','c_hash','at_hash','ctry','tenant_ctry','tenant_region_scope','onprem_sid',
    'pwd_exp','pwd_url','in_corp','nickname','verified_primary_email','verified_secondary_email'
)

function ConvertTo-Base64Url([byte[]] $bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-JwtPart([string] $jwt, [int] $index) {
    # Decodes one part of a JWT (0 = header, 1 = payload). For display only.
    try {
        $part = $jwt.Split('.')[$index].Replace('-', '+').Replace('_', '/')
        switch ($part.Length % 4) { 2 { $part += '==' } 3 { $part += '=' } }
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
    } catch { $null }
}

function Format-UnixTime($value) {
    [DateTimeOffset]::FromUnixTimeSeconds([int64]$value).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz")
}

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
        if ($value) { Write-Host ("{0} ({1}) : {2}" -f $t.Label, $t.Name, (Format-UnixTime $value)) }
    }

    Write-Host "`n--- Signature ---" -ForegroundColor DarkCyan
    $sigLength = if ($parts.Count -ge 3) { $parts[2].Length } else { 0 }
    Write-Host ("{0} characters, signed with {1}. Only the API the token is for (aud) should validate it." -f $sigLength, $header.alg)
}

function Write-Check([string] $label, [string] $value, [string] $status, [string] $hint) {
    $color  = switch ($status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Gray' } }
    $marker = switch ($status) { 'OK' { '[OK]  ' } 'WARN' { '[WARN]' } default { '[INFO]' } }
    Write-Host ("{0} {1,-20}: {2}" -f $marker, $label, $value) -ForegroundColor $color
    if ($hint) { Write-Host ("       {0}" -f $hint) -ForegroundColor DarkYellow }
}

function Show-ClaimCheck([string] $kind, [string] $jwt) {
    $c = ConvertFrom-JwtPart $jwt 1
    if (-not $c) {
        Write-Host "`nCan't decode this token to check its claims." -ForegroundColor Yellow
        return
    }

    Write-Host "`n=== Claim check: $kind token ===" -ForegroundColor Green

    # aud: who the token is for
    $forThisApp = ($c.aud -eq $ClientId) -or ($c.aud -eq "api://$ClientId")
    $isGraph    = ($c.aud -eq '00000003-0000-0000-c000-000000000000') -or ($c.aud -like 'https://graph.microsoft.com*')
    if ($forThisApp) {
        Write-Check 'aud (for)' $c.aud 'OK'
    } elseif ($isGraph) {
        Write-Check 'aud (for)' "$($c.aud) (Microsoft Graph)" 'WARN' "This token is for Graph, so it has no roles or custom claims from your app. Use -Scope 'api://$ClientId/api.access'."
    } else {
        Write-Check 'aud (for)' $c.aud 'WARN' "Not your app ($ClientId). Check -Scope."
    }

    # ver / iss
    if ($c.ver) {
        if ($c.ver -eq '2.0') { Write-Check 'ver' $c.ver 'OK' }
        elseif ($kind -eq 'Access' -and $forThisApp) {
            Write-Check 'ver' $c.ver 'WARN' 'v1.0 token. Set "requestedAccessTokenVersion": 2 in the manifest "api" section.'
        } else { Write-Check 'ver' $c.ver 'INFO' }
    }
    if ($c.iss) { Write-Check 'iss (issuer)' $c.iss 'INFO' }

    # who signed in
    $user = if ($c.preferred_username) { $c.preferred_username } elseif ($c.upn) { $c.upn } else { $c.unique_name }
    if ($c.name) { Write-Check 'name' $c.name 'INFO' }
    if ($user)   { Write-Check 'user' $user 'INFO' }
    if ($c.oid)  { Write-Check 'oid (user ID)' $c.oid 'INFO' }

    # permissions
    if ($kind -eq 'Access') {
        if ($c.scp) { Write-Check 'scp (permissions)' $c.scp 'OK' }
        elseif (-not $c.roles) { Write-Check 'scp (permissions)' '(none)' 'WARN' 'No scp: the scope may not exist or was not requested.' }
        if ($c.azpacr) {
            $how = switch ($c.azpacr) { '0' { 'public client (PKCE)' } '1' { 'client secret' } '2' { 'certificate' } default { $c.azpacr } }
            Write-Check 'azpacr (client)' "$($c.azpacr) = $how" 'INFO'
        }
    }
    if ($c.roles) {
        Write-Check 'roles' (@($c.roles) -join ', ') 'OK'
    } elseif ($forThisApp) {
        Write-Check 'roles' '(none)' 'INFO' 'Assign the user to a named app role (Default Access never adds roles).'
    }
    if ($c.groups) { Write-Check 'groups' ("{0} group ID(s)" -f @($c.groups).Count) 'INFO' }
    if ($c._claim_names -and $c._claim_names.groups) {
        Write-Check 'groups' 'overage: too many groups, read them from Graph' 'WARN'
    }
    if ($c.wids) { Write-Check 'wids (admin roles)' ("{0} role template ID(s)" -f @($c.wids).Count) 'INFO' }

    # custom and other optional claims
    $other = $c.PSObject.Properties | Where-Object { $standardClaims -notcontains $_.Name -and $_.Name -notlike 'xms_*' }
    if ($other) {
        foreach ($p in $other) {
            $v = if ($p.Value -is [array]) { $p.Value -join ', ' } else { "$($p.Value)" }
            Write-Check $p.Name $v 'OK'
        }
    } elseif ($forThisApp) {
        Write-Check 'custom claims' '(none)' 'INFO' 'None found. Check Attributes & Claims, the user''s attribute values and acceptMappedClaims.'
    }

    # lifetime
    if ($c.exp) { Write-Check 'expires' (Format-UnixTime $c.exp) 'INFO' }
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
           else { "<h3>Sign-in failed: " + [System.Net.WebUtility]::HtmlEncode("$($query['error']) - $($query['error_description'])") + "</h3>" }
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
    if ($err.error_description -match 'AADSTS500011|AADSTS65001') {
        Write-Host "Hint: your API scope isn't set up or consented yet. Complete 'Expose an API' and grant consent," -ForegroundColor Yellow
        Write-Host "      or start with: -Scope ""openid profile"" -TokenType Id" -ForegroundColor Yellow
    }
    return
}

# 6. Pick the token, check its claims and copy it
$jwt = if ($TokenType -eq "Id") { $token.id_token } else { $token.access_token }
if (-not $jwt) {
    Write-Host "No $TokenType token returned. For an ID token, include 'openid' in -Scope." -ForegroundColor Red
    return
}

Write-Host "`n=== $TokenType token ===" -ForegroundColor Green
Write-Host $jwt

Show-ClaimCheck $TokenType $jwt

# Tell the user about the other token from the same sign-in
if ($TokenType -eq "Access") {
    if ($token.id_token) {
        if (-not $ShowJwt) { Write-Host "`nAn ID token was also returned. To see it: add -TokenType Id, or -ShowJwt for both tokens." -ForegroundColor Cyan }
    } else {
        Write-Host "`nNo ID token was returned: include 'openid' in -Scope to get one." -ForegroundColor Yellow
    }
}

if ($ShowJwt) {
    if ($token.access_token) { Show-Jwt "ACCESS TOKEN" $token.access_token }
    if ($token.id_token)     { Show-Jwt "ID TOKEN" $token.id_token }
}

try {
    $jwt | Set-Clipboard
    Write-Host "`n$TokenType token copied to clipboard. Paste it into https://jwt.ms" -ForegroundColor Green
} catch {
    Write-Host "`nCopy the $TokenType token above and paste it into https://jwt.ms" -ForegroundColor Yellow
}
