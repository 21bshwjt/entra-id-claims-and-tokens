# Get-EntraToken

A PowerShell script that signs you in to **Microsoft Entra ID** through the normal Microsoft sign-in page and gives you a token to inspect in [jwt.ms](https://jwt.ms).

Use it to check that an app registration issues the claims you expect, such as `aud`, `scp`, `roles` and custom claims, before you hand the setup to another team (for example ServiceNow).

- Uses **Authorization Code + PKCE**, the same flow real desktop apps use
- Works with **MFA** and **Conditional Access**
- Needs **no client secret**
- Has **no hard-coded** tenant IDs, client IDs or claim names

---

## Contents

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [One-time app setup](#one-time-app-setup)
- [Usage](#usage)
- [Parameters](#parameters)
- [What to check in jwt.ms](#what-to-check-in-jwtms)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Key concepts](#key-concepts)
- [10 claim use cases with Entra setup](#10-claim-use-cases-with-entra-setup)
- [Three kinds of app: normal SPN, API app, web app](#three-kinds-of-app-normal-spn-api-app-web-app)
- [Azure portal sign-in vs your own app](#azure-portal-sign-in-vs-your-own-app)
- [Script](#script)
- [Changelog](#changelog)

---

## How it works

The sign-in uses two channels. The **front channel** goes through your browser; the **back channel** is a direct call from the script to Entra ID.

**Front channel (browser)**

1. The script creates a one-time secret (the **code verifier**) and its SHA-256 fingerprint (the **code challenge**).
2. It starts a small listener on `http://localhost:<port>/` and opens the Microsoft sign-in page with the requested `scope` and the code challenge.
3. You sign in with your own credentials (password + MFA). Entra ID checks app assignment, consent and Conditional Access.
4. Entra ID sends the browser back to `http://localhost:<port>/` with a short-lived **authorization code**.

**Back channel (direct)**

5. The script sends the code and the **code verifier** to the `/token` endpoint.
6. Entra ID checks that the verifier matches the challenge and returns the `id_token` and `access_token`.
7. The script prints the token you chose and copies it to the clipboard.

PKCE makes an intercepted code useless: the verifier never passes through the browser.

**The scope decides which token you get:**

```
openid   profile   api://<client-id>/api.access
  |         |              |
  |         |              +-- access token for your API (aud = client-id, scp = api.access)
  |         +-- profile claims (name, preferred_username, oid)
  +-- ID token
```

If you request a Microsoft Graph scope (for example `User.Read`), the access token is for Graph (`aud` = Graph) and will **not** contain your app's roles or custom claims.

---

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- A browser on the same machine
- An Entra ID app registration you can configure (Application Administrator or Cloud Application Administrator)
- A test user who is assigned to the app

---

## One-time app setup

In the **Microsoft Entra admin center** (entra.microsoft.com):

### 1. Allow the localhost redirect

**App registrations → (your app) → Authentication → Add a platform → Mobile and desktop applications**

- Custom redirect URI: `http://localhost` → **Configure**

No client secret and no "Allow public client flows" setting are needed.

### 2. If you want an access token for your own API

1. **Expose an API → Application ID URI → Add** → accept `api://<client-id>` → **Save**
2. **Add a scope** → name `api.access`, Admins only, Enabled → **Add scope**
3. **Manifest** → in the `api` section set `"requestedAccessTokenVersion": 2` → **Save**
4. **API permissions → Add a permission → APIs my organization uses → (your app) → Delegated → `api.access`** → **Grant admin consent**

### 3. Optional extras to see in the token

| To see | Configure |
| --- | --- |
| `roles` | **App roles → Create app role** (Users/Groups), then **Enterprise apps → (app) → Users and groups** → assign the user to the role |
| Custom claims (e.g. `department`, `empid`) | **Enterprise apps → (app) → Single sign-on → Attributes & Claims → Add new claim**, and set `"acceptMappedClaims": true` in the Manifest |
| `groups` / `wids` | **Token configuration → Add groups claim** |
| `upn` in a v2 access token | **Token configuration → Add optional claim → Access → upn** |

---

## Usage

```powershell
# Access token for your own API (default scope: openid profile api://<ClientId>/api.access)
.\Get-EntraToken.ps1 -TenantId <tenant-id> -ClientId <client-id>

# ID token
.\Get-EntraToken.ps1 -TenantId <tenant-id> -ClientId <client-id> -TokenType Id

# Any other scope, e.g. a Microsoft Graph token
.\Get-EntraToken.ps1 -TenantId <tenant-id> -ClientId <client-id> -Scope "User.Read"

# Use a different local port
.\Get-EntraToken.ps1 -TenantId <tenant-id> -ClientId <client-id> -Port 8500
```

If PowerShell blocks the script, allow it for the current window only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Then:

1. Your browser opens the Microsoft sign-in page. Sign in as the test user.
2. The browser shows "Signed in. You can close this tab."
3. PowerShell prints the token and copies it to the clipboard.
4. Open [jwt.ms](https://jwt.ms), paste the token and read the **Claims** tab.

---

## Parameters

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `-TenantId` | Yes | | Directory (tenant) ID: **Entra ID → Overview → Tenant ID** |
| `-ClientId` | Yes | | Application (client) ID: **App registrations → (app) → Overview** |
| `-Scope` | No | `openid profile api://<ClientId>/api.access` | Scopes to request. Decides the access token's `aud` |
| `-TokenType` | No | `Access` | `Access` or `Id`: which token to print and copy |
| `-Port` | No | `8400` | Local port that receives the sign-in response |

---

## What to check in jwt.ms

Check **`aud` first**. If it is not the app you expect, the rest of the token does not matter.

| Claim | Expected (access token for your API) | If wrong |
| --- | --- | --- |
| `aud` | Your client ID | Wrong scope requested (e.g. a Graph scope) |
| `scp` | `api.access` | Scope not created, or not requested |
| `ver` | `2.0` | Set `requestedAccessTokenVersion` to `2` |
| `iss` | `https://login.microsoftonline.com/<tenant-id>/v2.0` | Same: token is v1 |
| `azpacr` | `0` (public client, PKCE) | — |
| `oid` | The user's Object ID | Always present |
| `roles` | Your app role value | User not assigned to the role |
| Custom claims | Your configured values | Attribute empty on the user, or `acceptMappedClaims` not set |

**ID token vs access token:** if the client and the API are the same app, both tokens carry the same roles and custom claims. Only the **access token** has `scp`, and only the access token is sent to an API.

**Claims you can ignore:** `aio`, `rh`, `uti`, `sid`, `xms_*` are Entra ID internal claims. `uti` is Entra's unique token ID (there is no `jti`).

---

## Troubleshooting

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| AADSTS50011 | Redirect URI mismatch | Add `http://localhost` under **Mobile and desktop applications** (or `http://localhost:8400`) |
| AADSTS9002327 | Redirect URI is under **Single-page application** | Move it to **Mobile and desktop applications** |
| AADSTS65001 | No consent | Grant admin consent for the scope |
| AADSTS50105 | User not assigned | **Enterprise apps → (app) → Users and groups** → add the user |
| AADSTS500011 | Scope or Application ID URI missing | Complete **Expose an API** |
| AADSTS50146 | Custom claims without permission | Set `"acceptMappedClaims": true` in the Manifest |
| AADSTS700016 | App not found in tenant | Check `-TenantId` and `-ClientId` |
| "Could not listen on ..." | Port in use | Use `-Port 8500` |
| `aud` is Graph | A Graph scope was requested | Use `api://<client-id>/api.access` |
| `roles` missing | User has Default Access only | Assign the user to an app role |
| Custom claim missing | Attribute empty, or typo in claim name | Fill in the user's attribute; check spelling (case-sensitive) |

---

## Security notes

- Tokens are **bearer tokens**: anyone holding one can use it until it expires (about 60–90 minutes). Don't share, log or commit them.
- The clipboard keeps the token until you copy something else. Clear it after testing.
- Remove the `http://localhost` redirect URI from the app when you no longer need it.
- The script requests only the scopes you pass and never handles your password: you type it on Microsoft's page.
- Never commit real tenant IDs, client IDs or tokens to a public repository.

---

## Key concepts

| Term | Meaning |
| --- | --- |
| OAuth 2.0 | Protocol for permission to call APIs (access tokens) |
| OpenID Connect (OIDC) | Adds identity on top of OAuth (ID tokens); switched on by the `openid` scope |
| ID token | Who signed in; stays in the client app |
| Access token | Permission to call one API; sent as `Authorization: Bearer <token>` |
| Scope | What you ask for; decides the access token's `aud` |
| PKCE | Proof that the party exchanging the code is the one that started the sign-in |
| Front channel | Browser redirects (carries the authorization code) |
| Back channel | Direct app-to-Entra call (carries the tokens) |
| Service principal | The app's identity in your tenant; supplies the rules (assignment, roles, claims) |
| `oid` | The user's permanent Object ID; best for matching users in other systems |

---

## 10 claim use cases with Entra setup

Every use case follows the same pattern: configure Entra ID, a user (or program) signs in, Entra ID puts a claim in the token, and the app reads that claim. Test each one with this script and jwt.ms.

| # | Need | Key claim | Where you configure it |
| --- | --- | --- | --- |
| 1 | Buttons or features by role | `roles` | App roles + Users and groups |
| 2 | Entra admin-only pages | `wids` | Token configuration → groups claim (Directory roles) |
| 3 | Data by team | `groups` | Token configuration → groups claim |
| 4 | Show or route by user details | Custom (`department`, `empid`) | Attributes & Claims + `acceptMappedClaims` |
| 5 | Program with no user | `roles` (app-only) | App role for Applications + certificate |
| 6 | Show Microsoft 365 data | Graph token (`scp`) | API permissions → Microsoft Graph |
| 7 | API calls another API as the user | New token, new `aud` | Expose an API + downstream permission + certificate |
| 8 | SaaS sign-in with vendor roles | SAML NameID + role | SAML SSO + app roles with vendor values |
| 9 | MFA for sensitive actions | `acrs` / `amr` | Conditional Access authentication context |
| 10 | Guests vs employees | `acct` | Optional claim |

### Use case 1: Show buttons only to the right people (`roles`)

**Story:** In an Expense app, everyone can submit expenses, but only managers see the **Approve** button.

**Flow:**

1. A manager signs in to the Expense app.
2. Entra ID checks whether the user (or their group) is assigned the `Expense.Approver` role.
3. Entra ID adds `"roles": ["Expense.Approver"]` to the token.
4. The app shows the Approve button only when that role is present.

**Entra setup:**

1. **App registrations → Expense app → App roles → Create app role**
   - Display name: `Expense Approver` · Allowed member types: **Users/Groups** · Value: `Expense.Approver` · Enable → **Apply**
2. **Enterprise apps → Expense app → Users and groups → Add user/group** → select the **Managers** group → role **Expense Approver** → **Assign**
3. (Optional) **Enterprise apps → Expense app → Properties → Assignment required = Yes**

**Token:**

```json
"roles": ["Expense.Approver"]
```

**Watch-outs:** the app checks the role's **Value**, not its display name, and it is case-sensitive. Assigning groups needs Entra ID P1/P2, and nested groups don't count. If the app has only one role, the role picker is greyed out and auto-selected.

### Use case 2: Admin-only pages for IT staff (`wids`)

**Story:** An IT Tools portal has a "Reset user MFA" page that only Helpdesk or Global Administrators may open.

**Flow:**

1. An IT admin signs in.
2. Entra ID looks up the user's Entra admin roles.
3. Entra ID adds the role template IDs to `wids`.
4. The app shows the admin page if `wids` contains the Helpdesk or Global Administrator ID.

**Entra setup:**

1. **App registrations → IT Tools → Token configuration → Add groups claim** → tick **Directory roles** → **Add**
   (Manifest: `"groupMembershipClaims": "DirectoryRole"` or `"All"`)
2. Confirm the admins hold the role: **Entra ID → Roles & admins → Helpdesk Administrator → Assignments**

**Token:**

```json
"wids": ["729827e3-9c14-49f7-bb1b-9608f156bbb8", "b79fbf4d-3ef9-4689-8143-76b194e85509"]
```

| GUID | Meaning |
| --- | --- |
| `62e90394-69f5-4237-9190-012177145e10` | Global Administrator |
| `729827e3-9c14-49f7-bb1b-9608f156bbb8` | Helpdesk Administrator |
| `b79fbf4d-3ef9-4689-8143-76b194e85509` | Every normal member user (not an admin role) |

**Watch-outs:** these are role **template IDs**, the same in every tenant (full list: "Microsoft Entra built-in roles"). With PIM, the role appears only while active. `wids` = Entra admin roles; `roles` = roles you created for this app.

### Use case 3: Show data by team (`groups`)

**Story:** In a Reports dashboard, Finance sees finance reports and HR sees HR reports.

**Flow:**

1. A Finance employee signs in.
2. Entra ID finds the user's groups that are assigned to the app.
3. Entra ID adds their Object IDs to `groups`.
4. The app matches the Finance group ID and shows finance reports.

**Entra setup:**

1. **App registrations → Reports → Token configuration → Add groups claim** → **Groups assigned to the application** → **Add**
2. **Enterprise apps → Reports → Users and groups → Add user/group** → add the Finance and HR groups
3. Note each group's **Object ID** (**Entra ID → Groups → (group) → Overview**) and give them to the app team

**Token:**

```json
"groups": ["a1b2c3d4-0000-1111-2222-333344445555"]
```

**Watch-outs:** values are GUIDs, not names. With **All groups**, users in more than 200 groups get a link to Graph instead ("overage"). Prefer app roles (use case 1) where possible.

### Use case 4: Personalise with user details (custom claims)

**Story:** An HR portal shows "Welcome Biswajit, IT department, Employee #123" and routes tickets by department.

**Flow:**

1. The user signs in.
2. Entra ID reads Department and Employee ID from the user's profile.
3. Entra ID adds them as `department` and `empid`.
4. The app displays them and routes by `department`.

**Entra setup:**

1. **Enterprise apps → HR portal → Single sign-on → Attributes & Claims → Edit → Add new claim**
   - `department` → Source attribute `user.department` → **Save**
   - `empid` → Source attribute `user.employeeid` → **Save**
2. **App registrations → HR portal → Manifest** → `"acceptMappedClaims": true` → **Save** (single-tenant apps; multi-tenant apps need a custom signing key)
3. Fill in each user's details: **Entra ID → Users → (user) → Properties → Edit**

**Token:**

```json
"department": "IT",
"empid": "123"
```

**Watch-outs:** AADSTS50146 means `acceptMappedClaims` is missing. Empty attribute means no claim. Names are case-sensitive. Restricted names (`email`, `upn`, `oid`, `sub`, `nameid`, `preferred_username`) can't be used. Use for display and routing, not permissions.

### Use case 5: Background job with no user (client credentials)

**Story:** Every night a sync job copies new employees into ServiceNow. Nobody is signed in.

**Flow:**

1. The job sends its client ID plus certificate (or secret) to Entra ID.
2. Entra ID checks the job's app has the `ServiceNow.Integration` application permission.
3. Entra ID returns an access token with `roles` and no user.
4. The job calls ServiceNow with `Authorization: Bearer <token>`.

**Entra setup:**

1. **App registrations → ServiceNow-Integration → App roles → Create app role**
   - Display name: `ServiceNow Integration` · Allowed member types: **Applications** · Value: `ServiceNow.Integration` → **Apply**
2. **API permissions → Add a permission → APIs my organization uses → ServiceNow-Integration → Application permissions** → tick the role → **Add permissions**
3. **Grant admin consent**
4. **Certificates & secrets** → upload a certificate (preferred) or create a client secret with an expiry date

**Token request:**

```powershell
Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token" -Body @{
  grant_type    = "client_credentials"
  client_id     = "<client-id>"
  client_secret = "<secret>"   # test only; use a certificate in production
  scope         = "api://<client-id>/.default"
}
```

**Token:**

```json
"aud": "<client-id>",
"roles": ["ServiceNow.Integration"]
```

**Watch-outs:** no user means no ID token and no `name`/`upn`. The scope must end in `/.default`. Protect the certificate or secret (Key Vault, rotation). In ServiceNow use **Integration as a Service** with a Web Service Access Only account.

### Use case 6: Show the user's Microsoft 365 data (Graph)

**Story:** An intranet homepage shows the user's photo and today's meetings.

**Flow:**

1. The user signs in.
2. The app requests Graph scopes (`User.Read Calendars.Read`).
3. Entra ID returns an access token with `aud` = Microsoft Graph.
4. The app calls `https://graph.microsoft.com/v1.0/me/events` with the token.

**Entra setup:**

1. **App registrations → Intranet → API permissions → Add a permission → Microsoft Graph → Delegated** → `User.Read`, `Calendars.Read` → **Add**
2. **Grant admin consent** (or allow user consent)
3. **Authentication** → add the app's redirect URI under the right platform

**Token:**

```json
"aud": "00000003-0000-0000-c000-000000000000",
"scp": "Calendars.Read User.Read"
```

**Test with this script:** `.\Get-EntraToken.ps1 -TenantId <t> -ClientId <c> -Scope "User.Read Calendars.Read"`

**Watch-outs:** a Graph token never contains your app's roles or custom claims. Request only the permissions you need.

### Use case 7: Your API calls another API as the user (On-Behalf-Of)

**Story:** A web front end calls your Company API, which then calls ServiceNow as the same user.

**Flow:**

1. The front end gets a token for the Company API and calls it.
2. The Company API sends that token to Entra ID and asks for a ServiceNow token on behalf of the user.
3. Entra ID returns a new token: `aud` = ServiceNow-Integration, same user.
4. The Company API calls ServiceNow with the new token.

**Entra setup:**

1. **App registrations → Company API → Expose an API** → Application ID URI → scope `access`
2. **Company API → Certificates & secrets** → certificate or secret
3. **Company API → API permissions → ServiceNow-Integration → Delegated → `api.access`** → **Grant admin consent**
4. **Front-end app → API permissions → Company API → Delegated → `access`** → **Grant admin consent**

**Token exchange (Company API):**

```
grant_type          = urn:ietf:params:oauth:grant-type:jwt-bearer
requested_token_use = on_behalf_of
assertion           = <token the Company API received>
scope               = api://<servicenow-client-id>/api.access
client_id + certificate or secret = the Company API's own
```

**Watch-outs:** never forward the original token (its `aud` is the Company API). MSAL / Microsoft.Identity.Web handle the exchange (`AcquireTokenOnBehalfOf`). AADSTS65001 means consent is missing.

### Use case 8: SaaS sign-in where the vendor decides the roles (SAML)

**Story:** Staff sign in to AWS; developers get the Developer role and admins the Admin role, using AWS's role names.

**Flow:**

1. The user opens AWS (or the My Apps tile).
2. AWS sends the user to Entra ID.
3. Entra ID builds a SAML response with the NameID and the assigned role value.
4. The browser posts it to AWS, which signs the user in with that role.

**Entra setup:**

1. **Enterprise apps → New application** → pick the app from the gallery → **Create**
2. **Single sign-on → SAML → Basic SAML Configuration** → vendor's Identifier (Entity ID) and Reply URL → **Save**
3. **Attributes & Claims** → check **Unique User Identifier (Name ID)** and the role claim (`user.assignedroles`)
4. Create app roles with the **exact values the vendor requires** (for AWS, role ARNs; AWS can import them through **Provisioning**)
5. **Users and groups** → assign groups to roles
6. **SAML Certificates → Federation Metadata XML → Download** → give it to the vendor

**Watch-outs:** test with **Test single sign-on** or the SAML-tracer extension. Role values must match the vendor exactly. NameID exists only for SAML apps; OIDC apps don't have it (their user ID is `sub`, which can't be customised; use `oid` or a custom claim instead).

### Use case 9: Require MFA before a sensitive action (`acrs` / `amr`)

**Story:** In a Payroll app, viewing payslips needs a normal sign-in, but changing bank details must require MFA.

**Flow:**

1. The user signs in normally.
2. The user clicks **Change bank details**.
3. The app asks Entra ID for a token satisfying authentication context `c1`.
4. The Conditional Access policy for `c1` requires MFA; the user completes it.
5. Entra ID returns a token with `"acrs": ["c1"]`, and the app allows the change.

**Entra setup:**

1. **Entra ID → Conditional Access → Authentication contexts → New authentication context** → Name `Sensitive action`, ID `c1`, tick **Publish to apps** → **Save**
2. **Conditional Access → Policies → New policy** → Users: payroll users · Target resources: **Authentication context** → `Sensitive action` · Grant: **Require multifactor authentication** · **Report-only** first, then **On**
3. App code: request the token with claims `{"access_token":{"acrs":{"essential":true,"value":"c1"}}}` (MSAL supports this)

**Simpler alternative:** check the built-in `amr` claim contains `mfa` (rule lives in code instead of Conditional Access).

**Token:**

```json
"acrs": ["c1"],
"amr": ["pwd", "mfa"]
```

**Watch-outs:** verify menu names in your portal. Authentication context lets admins tighten rules later without code changes. Conditional Access needs Entra ID P1.

### Use case 10: Treat guests differently from employees (`acct`)

**Story:** Partner staff are guests. In a Project portal, employees see all projects; guests see only their own.

**Flow:**

1. A guest signs in.
2. Entra ID knows the user is a guest.
3. Entra ID adds `"acct": 1` (employees get `0`).
4. The app limits the view for guests.

**Entra setup:**

1. **App registrations → Project portal → Token configuration → Add optional claim** → token type **ID** (and **Access** if needed) → tick `acct` → **Add**
2. Invite partners if needed: **Entra ID → Users → New user → Invite external user**
3. (Optional) assign only the needed guests, with **Assignment required = Yes**

**Token:**

```json
"acct": 1
```

**Watch-outs:** a guest's `oid` exists only in your tenant. Guest UPNs look like `name_partner.com#EXT#@yourtenant.onmicrosoft.com`; identify guests by `oid`.

---

## Three kinds of app: normal SPN, API app, web app

| | Normal SPN | API app (`api.access`) | Web app (`localhost:3000`) |
| --- | --- | --- | --- |
| Role | Program that logs in as itself | The API that tokens are made for | The website a person uses |
| Who signs in | The program (secret or certificate) | Nobody; it receives tokens | A user (password + MFA) |
| Asks Entra for | A token for Azure or Graph | Nothing; it defines the scope | A token for `api.access` plus an ID token |
| Does with the token | Calls Azure or Graph | Checks `aud`, `scp`, `roles` | Sends it to the API as a bearer token |
| Key Entra settings | Secret/certificate; Azure RBAC or Graph permissions | Expose an API, scope, v2 tokens, app roles | Redirect URI, API permission for `api.access` |
| Example | GitHub Actions deploying to Azure | ServiceNow-Integration | React/Node site with a "Create ticket" button |

**Web app and API app together:**

1. The user opens `http://localhost:3000`.
2. The web app sends the user to Microsoft sign-in with `openid profile api://<api-app-id>/api.access`.
3. Entra ID returns an ID token (for the web app) and an access token (`aud` = API app).
4. The web app shows "Hello Biswajit" from the ID token and calls the API with the access token.
5. The API checks `aud`, `scp` and `roles`.

**Setting up the web app as its own registration:**

1. **App registrations → New registration** → `My-Web-App`, single tenant
2. **Authentication → Add a platform**: **Single-page application** (React/Angular/Vue) → `http://localhost:3000`, or **Web** (Node/.NET/Java) → callback URL + client secret or certificate
3. **API permissions → APIs my organization uses → (API app) → Delegated → `api.access`** → **Grant admin consent**
4. In code: `clientId` = My-Web-App's ID, `scopes` = `["api://<api-app-id>/api.access"]`

The access token's `aud` stays the API app; `azp` shows My-Web-App, so the API can tell which client called.

**User sign-in vs service principal credentials:** during a user sign-in, the token comes from the user's credentials. The service principal only supplies the rules (assignment, consent, roles, custom claims, Conditional Access). Its own certificate or secret is used only when no user is involved (use case 5).

---

## Azure portal sign-in vs your own app

| | Azure portal | Your app |
| --- | --- | --- |
| Sign-in page and protocol | `login.microsoftonline.com`, OIDC + OAuth | Same |
| Credentials, MFA, Conditional Access | Your own | Same |
| App registration | Microsoft's; you can't change it | Yours |
| Access token `aud` | Azure Resource Manager or Graph | Your app ID |
| Your app roles and custom claims | Not included | Included |
| Permissions decided by | Azure RBAC and Entra admin roles (`wids`) | Your app roles and the target system |

Both share one Entra session, so the second sign-in may not ask for a password, but each app still gets its own token addressed to it.

---

## Script

Save as `Get-EntraToken.ps1`.

```powershell
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
```

---

## Changelog

| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 2026-11-22 | First version: browser sign-in (Authorization Code + PKCE), `-TokenType Access/Id`, `-Scope`, `-Port`, copy to clipboard |
| 1.1 | 2026-11-22 | Added 10 claim use cases with Entra setup, the three kinds of app, and portal vs own app |

**Ideas for later versions**

- [ ] Decode the token in PowerShell and show key claims with OK/FAIL checks
- [ ] Optional `-ExpectedClaims` parameter to verify specific claims automatically
- [ ] Client credentials mode (`-ClientSecret` / `-CertificateThumbprint`) for app-only tokens
- [ ] Timeout if the browser never returns
- [ ] Clear the clipboard after a set time
