function GetSpotifyAccessToken() {
    $clientDetails = Get-Content "app_details.secret.json" | ConvertFrom-Json
    $clientID = $clientDetails.ClientId
    $clientSecret = $clientDetails.ClientSecret

    $authBase = "https://accounts.spotify.com"
    $authAuth = "/authorize"
    $authToken = "/api/token"
    $redirectURI = "https://localhost/callback"

    if (!(Test-Path "refresh.secret" -PathType Leaf)) {
        Write-Host "Performing initial auth code flow..."

        $scopes = "playlist-read-private playlist-read-collaborative"
        $state = -join ((97..122) | Get-Random -Count 16 | ForEach-Object {[char]$_})
        # Redirect the user to the authorization endpoint to obtain an authorization code
        $authURL = "$authBase$authAuth`?client_id=$clientID&redirect_uri=$redirectURI&response_type=code&scope=$scopes&state=$state"

        Write-Host "Auth URL: $authURL"
        Start-Process $authURL

        # After the user has authorized your application, obtain the authorization code from the callback URL
        $callbackURL = [Uri](Read-Host "Enter the callback URL:")
        $authResult = [System.Web.HttpUtility]::ParseQueryString($callbackURL.Query)
        $authCode = $authResult["code"]

        if ($authResult["state"] -ne $state) {
            Write-Error "XSRF err - state mismatch (expected $state, was $($authResult["state"]))"
            exit 1
        } elseif ($null -ne $authResult["error"]) {
            Write-Error "Got error '$($authResult["error"])'!"
            exit 1
        }

        # Exchange the authorization code for an access token
        $tokenBody = @{
            grant_type    = "authorization_code"
            code          = $authCode
            redirect_uri  = $redirectURI
        }
    } else {
        Write-Host "Detected existing refresh token..."

        $refreshSecure = Get-Content "refresh.secret" | ConvertTo-SecureString
        $refreshCode = [System.Net.NetworkCredential]::new("", $refreshSecure).Password

        # Exchange the authorization code for an access token
        $tokenBody = @{
            grant_type    = "refresh_token"
            refresh_token = $refreshCode
        }
    }



    $token_headers = @{
        "Authorization" = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${clientID}:${clientSecret}"))
        "Content-Type" = "application/x-www-form-urlencoded"
    }

    $tokenResponse = Invoke-RestMethod -Uri "$authBase$authToken" -Method POST -Body $tokenBody -Headers $token_headers

    if ($null -ne $tokenResponse.refresh_token) {
        Write-Host "Got new access token, so saving it."
        ConvertTo-SecureString -AsPlainText $tokenResponse.refresh_token | ConvertFrom-SecureString | Set-Content "refresh.secret"
    }

    Write-Host "Got token!"

    return $tokenResponse.access_token
}
