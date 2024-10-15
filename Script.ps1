param (
    [string]$organization = "",
    [string]$pat = "",
    [string]$projectName = "Dm.Core",
    [string]$feedNameWebApi = "Dm.WebApi", //This are samples parameters
    [string]$feedNameWinForms = "Dm.WinForms", 
    [string]$targetDir = "C:\Path\To\Folder",
    [string]$nuggetsFolder = "C:\Path\Nuggets"
)

# Log file
$logFile = "script_log.txt"
Clear-Content -Path $logFile -ErrorAction SilentlyContinue

# Logging function
function Log {
    param (
        [string]$message
    )
    Write-Output $message
}

# Function to perform authenticated requests
function Invoke-AuthenticatedRequest {
    param (
        [string]$url,
        [string]$method = "GET",
        [object]$body = $null
    )
    $encodedPat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    $headers = @{
        Authorization = "Basic $encodedPat"
        "Content-Type" = "application/json"
    }

    try {
        if ($method -eq "POST") {
            return Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 100)
        } else {
            return Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        }
    } catch {
        $exception = $_.Exception
        $response = $exception.Response
        $statusCode = if ($response) { $response.StatusCode } else { "No StatusCode" }
        $statusDescription = if ($response) { $response.StatusDescription } else { "No StatusDescription" }
        $errorMessage = if ($response -and $response.Content) { $response.Content } else { $exception.Message }
        Log "Error accessing Azure DevOps REST API: $statusCode $statusDescription $errorMessage"
        Log "URL: $url"
        throw
    }
}

# Function to get package ID by package name
function Get-PackageId {
    param (
        [string]$feedName,
        [string]$packageName
    )
    $url = "https://feeds.dev.azure.com/$organization/_apis/packaging/Feeds/$feedName/Packages"
    $response = Invoke-AuthenticatedRequest -url $url
    $package = $response.value | Where-Object { $_.name -eq $packageName }
    return $package.id
}

# Function to get package version ID by package ID and version
function Get-PackageVersionId {
    param (
        [string]$feedName,
        [string]$packageId,
        [string]$packageVersion
    )
    $url = "https://feeds.dev.azure.com/$organization/_apis/packaging/Feeds/$feedName/Packages/$packageId/versions"
    $response = Invoke-AuthenticatedRequest -url $url
    $version = $response.value | Where-Object { $_.version -eq $packageVersion }
    return $version.id
}

# Function to get provenance of a package version
function Get-PackageProvenance {
    param (
        [string]$feedName,
        [string]$packageId,
        [string]$packageVersionId
    )
    $url = "https://feeds.dev.azure.com/$organization/_apis/packaging/Feeds/$feedName/Packages/$packageId/Versions/$packageVersionId/provenance"
    Log "Fetching provenance with URL: $url"
    $response = Invoke-AuthenticatedRequest -url $url
    return $response
}

# Function to get build details by build ID
function Get-BuildDetails {
    param (
        [string]$organization,
        [string]$projectName,
        [string]$buildId
    )
    $url = "https://dev.azure.com/$organization/$projectName/_apis/build/builds/$buildId"
    Log "Fetching build details with URL: $url"
    $response = Invoke-AuthenticatedRequest -url $url
    return $response
}

# Function to get commit details by date
function Get-CommitByDate {
    param (
        [string]$organization,
        [string]$projectName,
        [string]$repoName,
        [datetime]$date
    )
    $fromDate = $date.ToString()
    $toDate = $date.AddMinutes(15).ToString()
    $url = "https://dev.azure.com/$organization/$projectName/_apis/git/repositories/$repoName/commits?searchCriteria.fromDate=${fromDate}&searchCriteria.toDate=${toDate}"
    $response = Invoke-AuthenticatedRequest -url $url
    
    if ($response.value.Count -eq 0) {
        Write-Output "No commits found in the specified time range."
        return $null
    }

    # Znajdź commit najbliższy podanej dacie
    $closestCommit = $null
    $smallestTimeDifference = [timespan]::MaxValue
    
    foreach ($commit in $response.value) {
        $commitDate = [datetime]::Parse($commit.author.date)
        $timeDifference = [System.Math]::Abs(($commitDate - $date).Ticks)
        
        if ($timeDifference -lt $smallestTimeDifference.Ticks) {
            $smallestTimeDifference = [timespan]::FromTicks($timeDifference)
            $closestCommit = $commit
        }
    }
    
    if ($closestCommit -ne $null) {
        return $closestCommit.commitId
    } else {
        return $null
    }
}

function Get-PackageVersionPublishDate {
    param (
        [string]$feedName,
        [string]$packageId,
        [string]$packageVersionId
    )
    $url = "https://feeds.dev.azure.com/$organization/_apis/packaging/Feeds/$feedName/Packages/$packageId/Versions/$packageVersionId"
    Log "Fetching package version details with URL: $url"
  
    $response = Invoke-AuthenticatedRequest -url $url
    $publishDate = $response.publishDate
	
    return  $publishDate
}

function Get-RepoList {
    param (
        [string]$organization,
        [string]$projectName
    )
    $url = "https://dev.azure.com/$organization/$projectName/_apis/git/repositories?api-version=6.0"
    $response = Invoke-AuthenticatedRequest -url $url
    return $response.value
}

function Clone-Repo {
    param (
        [string]$repoUrl,
        [string]$repoPath,
        [string]$commitId
    )
    if (Test-Path -Path $repoPath) {
        Log "Repository already exists. Pulling latest changes."
        Set-Location -Path $repoPath
        git pull | Out-File -FilePath $logFile -Append
        if ($LASTEXITCODE -ne 0) {
            Log "Failed to pull latest changes"
            exit 1
        }
    } else {
        Set-Location -Path $targetDir
        Log "Cloning repository from $repoUrl"
        git clone $repoUrl | Out-File -FilePath $logFile -Append
        if ($LASTEXITCODE -ne 0) {
            Log "Failed to clone repository"
            exit 1
        }
        Set-Location -Path $repoPath
    }

    Log "Checking out to commit $commitId"
    git checkout $commitId | Out-File -FilePath $logFile -Append
    if ($LASTEXITCODE -eq 0) {
        Log "Successfully checked out to commit $commitId"
    } else {
        Log "Failed to check out to commit $commitId"
        exit 1
    }
}

# Get list of repositories
$repositories = Get-RepoList -organization $organization -projectName $projectName

foreach ($repo in $repositories) {
    $repoName = $repo.name
    $repoUrl = $repo.remoteUrl
    $repoPath = "$targetDir\$repoName"
    
    # Get list of csproj files
    $csprojFiles = Get-ChildItem -Path $repoPath -Recurse -Filter *.csproj
    
    foreach ($csprojFile in $csprojFiles) {
        [xml]$csprojContent = Get-Content $csprojFile.FullName
        
        $packages = $csprojContent.Project.ItemGroup.PackageReference | Where-Object { $_.Include -match '^DebtManager' -or $_.Include -match '^Bakk' }
        
        foreach ($package in $packages) {
            $packageName = $package.Include
            $packageVersion = $package.Version

            Log "Processing package: $packageName, version: $packageVersion"
            
            # Process packages for both feeds
            foreach ($feedName in @($feedNameWebApi, $feedNameWinForms)) {
                # Retrieve package ID
                try {
                    $packageId = Get-PackageId -feedName $feedName -packageName $packageName
                    if ($packageId -eq $null) {
                        Log "Package not found in feed $feedName: $packageName"
                        continue
                    }
                    Log "Found packageId: $packageId for package: $packageName in feed $feedName"
                } catch {
                    Log "Error accessing Azure DevOps REST API for packages in feed $feedName: $($_)"
                    continue
                }

                # Retrieve package version ID
                try {
                    $packageVersionId = Get-PackageVersionId -feedName $feedName -packageId $packageId -packageVersion $packageVersion
                    if ($packageVersionId -eq $null) {
                        Log "Package version not found in feed $feedName: $packageVersion for package: $packageName"
                        continue
                    }
                    Log "Found packageVersionId: $packageVersionId for package version: $packageVersion in feed $feedName"
                } catch {
                    Log "Error accessing Azure DevOps REST API for package versions in feed $feedName: $($_)"
                    continue
                }

                # Retrieve package provenance
                try {
                    $provenance = Get-PackageProvenance -feedName $feedName -packageId $packageId -packageVersionId $packageVersionId
                    if ($provenance -eq $null -or $provenance.provenance -eq $null) {
                        Log "No provenance found for package version: $packageVersion in feed $feedName"
                        continue
                    }
                    $buildId = $provenance.provenance.data.'Build.BuildId'
                    $repoName = $provenance.provenance.data.'Build.Repository.Name'
                    Log "Build ID retrieved: $buildId from feed $feedName"
                    Log "Repo Name retrieved: $repoName from feed $feedName"
                } catch {
                    Log "Error accessing Azure DevOps REST API for package provenance in feed $feedName: $($_)"
                    continue
                }

                # Retrieve build details or find commit by date if build ID is not found
                try {
                    if ($buildId -eq $null) {
                        throw [Exception] "No build ID found, attempting to find commit by publish date"
                    } else {
                        Log "Fetching build details for build ID: $buildId from feed $feedName"
                        $buildDetails = Get-BuildDetails -organization $organization -projectName $projectName -buildId $buildId
                        $commitId = $buildDetails.sourceVersion
                        if ($commitId -eq $null) {
                            throw [Exception] "No commit ID found for build: $buildId from feed $feedName"
                        }
                        Log "Found commitId: $commitId for build: $buildId from feed $feedName"
                    }
                } catch {
                    Log "Error accessing build details or build not found: $($_). Attempting to find commit by publish date in feed $feedName."
                    try {
                        $publishDate = Get-PackageVersionPublishDate -feedName $feedName -packageId $packageId -packageVersionId $packageVersionId
                        $commitId = Get-CommitByDate -organization $organization -projectName $projectName -repoName $repoName -date $publishDate
                        Log "Found commitId: $commitId by publish date: $publishDate in feed $feedName"
                    } catch {
                        Log "Error accessing Azure DevOps REST API for commit by date in feed $feedName: $($_)"
                        continue
                    }
                }

                # Clone the repo and checkout to the specific commit
                Clone-Repo -repoUrl $repoUrl -repoPath $repoPath -commitId $commitId
            }
        }
    }
}

Write-Output "Script completed."
