function GetSpotifyAccessToken() {
    # load details about the app we're running as from disk
    $clientDetails = Get-Content "app_details.secret.json" | ConvertFrom-Json
    $clientID = $clientDetails.ClientId
    $clientSecret = $clientDetails.ClientSecret
    $redirectURI = $clientDetails.RedirectUri

    # api endpoint constants
    $authBase = "https://accounts.spotify.com"
    $authAuth = "/authorize"
    $authToken = "/api/token"

    # check if we've previously run and a refresh token is available for us to pick up from first
    if (Test-Path "refresh.secret" -PathType Leaf) {
        Write-Host "Detected existing refresh token..."

        # load from disk and decrypt
        $refreshSecure = Get-Content "refresh.secret" | ConvertTo-SecureString
        $refreshCode = [System.Net.NetworkCredential]::new("", $refreshSecure).Password

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
        # encrypt the token before saving it - it's basic, but should prevent decoding it off-machine at least
        ConvertTo-SecureString -AsPlainText $tokenResponse.refresh_token | ConvertFrom-SecureString | Set-Content "refresh.secret"
    }

    Write-Host "Got access token!"

    return $tokenResponse.access_token
}
