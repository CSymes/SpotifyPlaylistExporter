$ErrorActionPreference = "Stop"

$apiBase = "https://api.spotify.com/v1"
$apiGetMe = "/me"
$apiGetPlaylist = "/playlists/{id}"
$apiGetPlaylistItems = "/playlists/{id}/tracks"
$privateApiGetLyrics = "https://spclient.wg.spotify.com/color-lyrics/v2/track/{id}?format=json&vocalRemoval=false";

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


if (!(Test-Path "spotifyfolders.py" -PathType Leaf)) {
    Write-Host "Spotify folder scraper not found, downloading..."

    Invoke-WebRequest "https://git.io/folders" -OutFile "spotifyfolders.py"
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




$headers = @{
    "Authorization" = "Bearer " + $tokenResponse.access_token
    "Content-Type" = "application/json"
}

$getLyrics = $false
$privateApiHeaders = @{
    "Authorization" = "Bearer " + $tokenResponse.access_token
    "App-Platform" = "WebPlayer"
}

$meResponse = Invoke-RestMethod -Uri "$apiBase$apiGetMe" -Method GET -Headers $headers
$me = $meResponse.id



# $nextPlaylistsPageUrl = "$apiBase$apiGetUsersPlaylists";
# while($true) {
#     $playlistsPage = Invoke-RestMethod -Uri "$nextPlaylistsPageUrl" -Method GET -Headers $headers

#     Write-Host "Got page at: $($playlistsPage.offset) + ~$($playlistsPage.limit) / $($playlistsPage.total)"

#     foreach ($pl in $playlistsPage.items) {
#         Write-Host "`t$($pl.name)"
#     }

#     if ($playlistsPage.next -ne $null) {
#         $nextPlaylistsPageUrl = $playlistsPage.next
#     } else {
#         Write-Host "No more pages, breaking"
#         break
#     }
# }


function ProcessFolder($item, $indentation) {
    # Write-Host $indentation
    # return

    if ($item.type -eq "folder") {
        $name = $item.name ?? "Playlists"

        Write-Host "$("`t" * $indentation)Folder '$name'"

        New-Item $name -ItemType Directory -ea 0 | Out-Null
        Push-Location $name

        try {
            $item.children | ForEach-Object { ProcessFolder $_ ($indentation + 1) }
        }
        finally {
            Pop-Location
        }
    } elseif ($item.type -eq "playlist") {
        $id = $item.uri -replace "spotify:\w+:", ""
        Write-Host "$("`t" * $indentation)$id`t" -NoNewLine

        ProcessPlaylist $id
    }
}

function ProcessPlaylist($id) {
    $plUrl = "$apiBase$apiGetPlaylist" -replace "{id}", $id
    $plFields = "name,owner(id,display_name),public,collaborative"
    $plUrl = "$plUrl`?fields=$plFields"
    $plDetails = Invoke-RestMethod -Uri "$plUrl" -Method GET -Headers $headers
    $name = $plDetails.name
    $nameSanitised = $name.Split([IO.Path]::GetInvalidFileNameChars()) -join '_'
    $nameDir = "${nameSanitised} (Lyrics)"
    # $plDetails | ConvertTo-Json | Set-Content "$id.json"

    if ($plDetails.owner.id -eq $me) {
        Write-Host "$name"
    } else {
        Write-Host "$name - owned by $($plDetails.owner.display_name), skipping"
        return
    }

    $fields = "next,items(track(id,name,album.name,artists(name)))"
    $url = "$apiBase$apiGetPlaylistItems" -replace "{id}", $id
    $url = "$url`?fields=$fields"

    $tracks = @()

    while ($true) {
        $pl = Invoke-RestMethod -Uri "$url" -Method GET -Headers $headers

        # add a simplified track object for each track to a playlist-scoped list
        $tracks += $pl.items | ForEach-Object { @{
            Artist = $_.track.artists[0].name
            Title  = $_.track.name
            Album  = $_.track.album.name
        } }

        # fetch lyrics for all songs
        if ($getLyrics) {
            New-Item $nameDir -ItemType Directory -ea 0 | Out-Null
            Push-Location $nameDir
            try {
                foreach ($track in $pl.items) {
                    $id = $track.track.id
                    $url = $privateApiGetLyrics -replace "{id}", $id

                    try {
                        # Write-Information "Got lyrics for $($track.track.name)"
                        $songNameSanitised = "$($track.track.name) - $($track.track.artists[0].name)".Split([IO.Path]::GetInvalidFileNameChars()) -join '_'
                        $songFileName = "$songNameSanitised.txt"

                        $lyrics = Invoke-RestMethod -Uri "$url" -Method GET -Headers $privateApiHeaders
                        $lyrics.lyrics.lines | ForEach-Object { $_.words } | Set-Content $songFileName
                    }
                    catch {
                        Write-Warning "No lyrics found for $($track.track.name) ($id)"
                    }
                }
            }
            finally {
                Pop-Location
            }
        }

        # continue to next page of songs, if any
        if ($null -ne $pl.next) {
            $url = $pl.next
        } else {
            break
        }
    }

    $tracks | ConvertTo-Json -Depth 10 | Set-Content "$nameSanitised.json"
}

$all = python ./spotifyfolders.py | ConvertFrom-Json
ProcessFolder $all 0
