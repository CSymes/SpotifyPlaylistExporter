param(
    [ValidateSet("Oauth", "WebPlayer", "Cookie")] $authMethod = "Cookie",
    [Switch] $getLyrics = $false,
    [Switch] $fetchAllPlaylists = $false
)

$ErrorActionPreference = "Stop"

# general API endpoint consts
$apiBase = "https://api.spotify.com/v1"
$apiGetMe = "/me"
$apiGetPlaylist = "/playlists/{id}"
$apiGetPlaylistItems = "/playlists/{id}/tracks"
$privateApiGetLyrics = "https://spclient.wg.spotify.com/color-lyrics/v2/track/{id}?format=json&vocalRemoval=false";



function DetermineCallingUser() {
    $meResponse = Invoke-RestMethod -Uri "$apiBase$apiGetMe" -Method GET -Headers $headers

    Write-Host "Running as $($meResponse.display_name) ($($meResponse.id))"

    return $meResponse.id
}

function ProcessFolder($item, $indentation) {
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
    }
    elseif ($item.type -eq "playlist") {
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

    if (($plDetails.owner.id -eq $me) -or $fetchAllPlaylists) {
        Write-Host "$name"
    }
    else {
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
            # create a new folder for each playlist to hold all lyric files in
            New-Item $nameDir -ItemType Directory -ea 0 | Out-Null
            Push-Location $nameDir
            
            try {
                foreach ($track in $pl.items) {
                    $id = $track.track.id
                    $url = $privateApiGetLyrics -replace "{id}", $id

                    $songNameSanitised = "$($track.track.name) - $($track.track.artists[0].name)".Split([IO.Path]::GetInvalidFileNameChars()) -join '_'
                    $songFileName = "$songNameSanitised.txt"

                    # skip lyrics we've already fetched - unlike playlist contents, we don't expect them to vary over time
                    if (Test-Path $songFileName -PathType Leaf) {
                        continue
                    }

                    try {
                        $lyrics = Invoke-RestMethod -Uri "$url" -Method GET -Headers $privateApiHeaders

                        $lyrics.lyrics.lines | ForEach-Object { $_.words } | Set-Content $songFileName
                        Write-Verbose "Got lyrics for $($track.track.name)"
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
        }
        else {
            break
        }
    }

    $tracks | ConvertTo-Json -Depth 10 | Set-Content "$nameSanitised.json"
}

function GetPlaylistFolderStructure() {
    if (!(Test-Path "spotifyfolders.py" -PathType Leaf)) {
        Write-Host "Spotify folder scraper not found, downloading..."
    
        Invoke-WebRequest "https://git.io/folders" -OutFile "spotifyfolders.py"
    }
    $all = python ./spotifyfolders.py | ConvertFrom-Json

    return $all
}



# load helpers for authenticating against spotify
. ./SpotifyAuth.ps1

# request an actual auth access token
switch ($authMethod) {
    "Oauth" {
        if ($getLyrics) { throw "Cannot fetch lyrics using OAuth authentication!" }

        $token = GetSpotifyAccessToken
    }
    "WebPlayer" {
        $token = GetWebPlayerAccessToken
    }
    "Cookie" {
        $token = GetSpDcAccessToken
    }
}

# and create header block from it
$headers = @{
    "Authorization" = "Bearer " + $token
    "Content-Type"  = "application/json"
}

$privateApiHeaders = @{
    "Authorization" = "Bearer " + $token
    "App-Platform"  = "WebPlayer"
}

$me = DetermineCallingUser
$all = GetPlaylistFolderStructure
ProcessFolder $all 0
