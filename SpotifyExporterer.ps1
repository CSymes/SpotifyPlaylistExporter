param(
    [ValidateSet("Oauth", "WebPlayer", "Cookie")] $authMethod = "Cookie",
    [Switch] $getLyrics = $false,
    [Switch] $fetchAllPlaylists = $false,
    [Switch] $recheckMissingLyrics = $false,
    [string] $playlist = $null
)

$ErrorActionPreference = "Stop"
$maxAuthRetries = 3

# general API endpoint consts
$apiBase = "https://api.spotify.com/v1"
$apiGetMe = "/me"
$apiGetPlaylist = "/playlists/{id}"
$apiGetPlaylistItems = "/playlists/{id}/tracks"
$privateApiGetLyrics = "https://spclient.wg.spotify.com/color-lyrics/v2/track/{id}?format=json&vocalRemoval=false";



function DetermineCallingUser() {
    $meResponse = CallApiEndpoint "$apiBase$apiGetMe" $headers

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

        # skip if the id string was malformed
        if ([string]::IsNullOrEmpty($id)) {
            return
        }

        # abort if a specific playlist ID has been targetted and this isn't it
        if (!([string]::IsNullOrEmpty($playlist)) -and ($id -ne $playlist)) {
            return
        }

        Write-Host "$("`t" * $indentation)$id`t" -NoNewLine

        ProcessPlaylist $id

        # no point continuing, if we were targetting a specific playlist and this was it
        if ($id -eq $playlist) {
            exit
        }
    }
}

function ProcessPlaylist($id) {
    $plUrl = "$apiBase$apiGetPlaylist" -replace "{id}", $id
    $plFields = "name,owner(id,display_name),public,collaborative"
    $plUrl = "$plUrl`?fields=$plFields"

    try {
        $plDetails = CallApiEndpoint $plUrl $headers
    }
    catch {
        $err = ($_ | ConvertFrom-Json)?.error
        $msg = ($null -eq $err) ? "unknown - $_" : "$($err.status) - $($err.message)"
        Write-Host "error $msg"
        return
    }
    
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
        # SPEEDUP: use the getPlaylist api request to get the first page
        $pl = CallApiEndpoint $url $headers

        # ensure there are some tracks to bother with
        if (($null -eq $pl.items) -or ($pl.items.Count -eq 0)) {
            break
        }
        # filter out any items with a null track property (not quite clear why this happens sometimes, there isn't a (visibly) missing track)
        $validItems = $pl.items | Where-Object { $null -ne ${_}?.track }

        # add a simplified track object for each track to a playlist-scoped list
        $tracks += $validItems | ForEach-Object { @{
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
                $trackIndex = 0
                foreach ($track in $validItems) {
                    ++$trackIndex

                    $id = $track.track.id
                    $trackName = $track.track.name
                    $trackArtist = $track.track.artists[0].name

                    $fqName = "$trackIndex. $trackName - $trackArtist"
                    $fqNameSanitised = $fqName.Split([IO.Path]::GetInvalidFileNameChars()) -join '_'
                    $lyricsFileName = "$fqNameSanitised.txt"
                    $lyricsFileNameNoLyrics = "${fqNameSanitised}_NoKnownLyrics.txt"
                
                    # skip lyrics we've already fetched - unlike playlist contents, we don't expect them to vary over time
                    if (Test-Path $lyricsFileName -PathType Leaf) {
                        continue
                    }
                    # skip tracks we've previously checked and couldn't find lyrics for, unless we explicitly want to re-check them
                    elseif ((Test-Path $lyricsFileNameNoLyrics -PathType Leaf) -and ($recheckMissingLyrics -eq $false)) {
                        continue
                    }
                    # attempt to find lyrics for this track
                    else {
                        $lyrics = GetTrackLyrics $id

                        if ($null -ne $lyrics) {
                            Write-Verbose "Got lyrics for $fqName"
                            $lyrics | Set-Content -LiteralPath $lyricsFileName
                        }
                        else {
                            Write-Warning "No lyrics found for $fqName ($id)"
                            $null | Set-Content -LiteralPath $lyricsFileNameNoLyrics
                        }
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

    ConvertTo-Json -Depth 10 $tracks | Set-Content -LiteralPath "$nameSanitised.json"
}

function GetTrackLyrics($id) {
    # there isn't a reasonably accessible API with much song coverage that I was able to glean,
    # so we are a bit cheeky and use Spotify's own internal lyrics API to do this.
    # obviously we're not meant to use this undocumented API, and it's not usable with a standard
    # app OAuth token... however we can access it by impersonating a user directly and using theirs.

    # (aside - lyrics.ovh seems reasonable, but I had issues getting it to work, so not sure of its track stock)

    $url = $privateApiGetLyrics -replace "{id}", $id

    try {
        $lyrics = CallApiEndpoint $url $privateApiHeaders

        return $lyrics.lyrics.lines | ForEach-Object { $_.words }
    }
    catch {
        return $null
    }
}

function GetPlaylistFolderStructure() {
    # because there's no official folder API, and spotify don't seem to have any interest in adding one,
    # https://github.com/spotify/web-api/issues/38
    # we use mikez's spotifyfolders script to rip the structure out of the local cache.
    # it logically follows then that this will only work on a machine where you are logged in as the
    # user and that structure is cached locally.

    if (!(Test-Path "spotifyfolders.py" -PathType Leaf)) {
        Write-Host "Spotify folder scraper not found, downloading..."
    
        Invoke-WebRequest "https://git.io/folders" -OutFile "spotifyfolders.py"
    }
    $all = python ./spotifyfolders.py | ConvertFrom-Json

    return $all
}

function CallApiEndpoint($url, $headers) {
    foreach ($retry in (0..$maxAuthRetries)) {
        try {
            $result = Invoke-RestMethod -Uri "$url" -Method GET -Headers $headers

            # the initial request failed, and this is a successful retry
            if ($retry -gt 0) {
                Write-Host "Following request succeeded!"
            }

            return $result
        }
        catch {
            $err = ($_ | ConvertFrom-Json)?.error

            # Unauthorised - token probably expired
            if (${err}?.status -eq 401) {

                Write-Host "Experienced $($err.status) while calling API ($($err.message)) (try $retry), " -NoNewline

                $wait = $([Math]::Pow(2, $retry) - 1)
                if ($retry -eq $maxAuthRetries) {
                    Write-Host "could not re-authenticate!" 
                    exit
                }
                else { 
                    Write-Host "retrying..." 
                    Start-Sleep -Seconds $wait
                    AuthAndSetTokens
                    continue
                }
            }
            else {
                throw
            }
        }
    }
}

function AuthAndSetTokens() {
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
    
    # and create header blocks from it
    $script:headers = @{
        "Authorization" = "Bearer " + $token
        "Content-Type"  = "application/json"
    }
    
    $script:privateApiHeaders = @{
        "Authorization" = "Bearer " + $token
        "App-Platform"  = "WebPlayer"
    }
}



# load helpers for authenticating against spotify
. ./SpotifyAuth.ps1

# request an actual auth access token
AuthAndSetTokens

$me = DetermineCallingUser
$all = GetPlaylistFolderStructure
ProcessFolder $all 0
