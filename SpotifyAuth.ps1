# Do everything by the books, using OAuth with an app registration etc.
function GetSpotifyAccessToken() {
    # load details about the app we"re running as from disk
    $clientDetails = Get-Content "app_details.secret.json" | ConvertFrom-Json
    $clientID = $clientDetails.ClientId
    $clientSecret = $clientDetails.ClientSecret
    $redirectURI = $clientDetails.RedirectUri

    # api endpoint constants
    $authBase = "https://accounts.spotify.com"
    $authAuth = "/authorize"
    $authToken = "/api/token"

    $refreshTokenFilename = "refresh.secret"

    # check if we"ve previously run and a refresh token is available for us to pick up from first
    if (Test-Path $refreshTokenFilename -PathType Leaf) {
        Write-Host "Detected existing refresh token..."

        # load from disk and decrypt
        $refreshCode = DecodeEncryptedFile $refreshTokenFilename

        # Exchange the authorization code for an access token
        $tokenBody = @{
            grant_type    = "refresh_token"
            refresh_token = $refreshCode
        }
    }
    # otherwise, perform the full OAuth flow
    else {
        Write-Host "Performing initial auth code flow..."

        $scopes = "playlist-read-private playlist-read-collaborative"
        $state = -join ((97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
        # Redirect the user to the authorization endpoint to obtain an authorization code
        $authURL = "$authBase$authAuth`?client_id=$clientID&redirect_uri=$redirectURI&response_type=code&scope=$scopes&state=$state"

        Write-Host "Auth URL: $authURL"
        Start-Process $authURL

        # After the user has authorized the application, parse the authorization code from the callback URL
        # because we're not kicking up a webserver to capture the callback, we have to get the user to manually pase the URL in
        $callbackURL = [Uri](Read-Host "Enter the callback URL:")
        $authResult = [System.Web.HttpUtility]::ParseQueryString($callbackURL.Query)
        $authCode = $authResult["code"]

        if ($authResult["state"] -ne $state) {
            Write-Error "XSRF err - state mismatch (expected $state, was $($authResult["state"]))"
            exit 1
        }
        elseif ($null -ne $authResult["error"]) {
            Write-Error "Got error '$($authResult["error"])'!"
            exit 1
        }

        # Exchange the authorization code for an access token
        $tokenBody = @{
            grant_type   = "authorization_code"
            code         = $authCode
            redirect_uri = $redirectURI
        }
    }



    $token_headers = @{
        "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${clientID}:${clientSecret}"))
        "Content-Type"  = "application/x-www-form-urlencoded"
    }

    # exchange our auth token for an access token
    $tokenResponse = Invoke-RestMethod -Uri "$authBase$authToken" -Method POST -Body $tokenBody -Headers $token_headers

    # if it's the first time, or they feel like reissuing our refresh token, store it for later
    if ($null -ne $tokenResponse.refresh_token) {
        Write-Host "Got new access token, so saving it."
        # encrypt the token before saving it - it"s basic, but should prevent decoding it off-machine at least
        EncryptTextToFile $refreshTokenFilename $tokenResponse.refresh_token
    }

    $expiry = $tokenResponse.expires_in / 60
    Write-Host "Got access token via OAuth - expires in ${expiry}min"

    return $tokenResponse.access_token
}

# Cheeky user impersonation to get a more powerful user access token
function GetWebPlayerAccessToken() {
    # the web player's access token generation URL
    $tokenGenerator = "https://open.spotify.com/get_access_token"

    # open in the user's browser, and (provided they're logged in), get their own personal token (:O!)
    Start-Process $tokenGenerator
    $tokenResponse = (Read-Host "Enter the provided JSON token response:") | ConvertFrom-Json

    # log out the time until the token expires - usually somewhere in the range of an hour, but I"m not sure when they reissue
    $expiry = GetExpiryMinutes $tokenResponse.accessTokenExpirationTimestampMs
    Write-Host "Got webplayer access token, expires in ${expiry}min"

    return $tokenResponse.accessToken
}

# Even cheekier user impersonation by using the root auth cookie instead of just the access token
function GetSpDcAccessToken() {
    # api details
    $baseUrl = "https://open.spotify.com"
    $tokenGenEndpoint = "/get_access_token"

    # encryption store
    $spdcFilename = "sp_dc.secret"
    $shouldWrite = $false

    # check if we've previously saved an sp_dc cookie, or if we need to request it from the user
    if (Test-Path $spdcFilename -PathType Leaf) {
        $sp_dc = DecodeEncryptedFile $spdcFilename
    }
    else {
        Start-Process $baseUrl
        $sp_dc = (Read-Host "Enter the value of the sp_dc cookie:")

        $shouldWrite = $true
    }

    # verbosely create a session to allow sending a cookie in our rest invocation
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $cookie = [System.Net.Cookie]::new("sp_dc", $sp_dc)
    $session.Cookies.Add($baseUrl, $cookie)
    $session.Headers.Add("App-Platform", "WebPlayer")
    
    $tokenResponse = Invoke-RestMethod -Method GET -Uri "$baseUrl$tokenGenEndpoint" -WebSession $session

    # save sp_dc now it's confirmed to be valid
    if ($shouldWrite) {
        EncryptTextToFile $spdcFilename $sp_dc
    }

    $expiry = GetExpiryMinutes $tokenResponse.accessTokenExpirationTimestampMs
    Write-Host "Got access token via cookie, expires in ${expiry}min"

    return $tokenResponse.accessToken
}

function DecodeEncryptedFile($path) {
    $textSecure = Get-Content $path | ConvertTo-SecureString
    return [System.Net.NetworkCredential]::new("", $textSecure).Password
}

function EncryptTextToFile($path, $text) {
    ConvertTo-SecureString -AsPlainText $text | ConvertFrom-SecureString | Set-Content $path
}

function GetExpiryMinutes($unixTime) {
    $expiryDeltaSeconds = $unixTime / 1000 - (Get-Date -UFormat %s)
    $expiryDeltaMinutes = [math]::Round($expiryDeltaSeconds / 60)
    return $expiryDeltaMinutes
}
