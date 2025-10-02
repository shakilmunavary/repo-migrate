# Load credentials from credentials.txt
$creds = @{}
Get-Content "credentials.txt" | ForEach-Object {
    $parts = $_ -split "="
    if ($parts.Length -eq 2) {
        $creds[$parts[0].Trim()] = $parts[1].Trim()
    }
}
$azurePAT = $creds["AZURE_PAT"]
$gitlabPAT = $creds["GITLAB_PAT"]

# GitLab target group path
$gitlabGroup = "shakil-ai-poc"

# Azure DevOps org and project
$azureOrg = "23932140510"
$azureProject = "AI-POC"

# Read repo list
$repos = Get-Content "repo_list.txt"

foreach ($repoUrl in $repos) {
    $repoName = ($repoUrl -split "/")[-1]
    Write-Host ""
    Write-Host "Starting migration for $repoName..."

    # Step 1: Get GitLab group ID
    try {
        $groupInfo = Invoke-RestMethod -Uri "https://gitlab.com/api/v4/groups?search=$gitlabGroup" -Headers @{ "PRIVATE-TOKEN" = $gitlabPAT }
        $groupId = ($groupInfo | Where-Object { $_.full_path -eq $gitlabGroup }).id
        if (-not $groupId) {
            Write-Host "GitLab group '$gitlabGroup' not found."
            continue
        }
    } catch {
        Write-Host "Failed to retrieve GitLab group info."
        continue
    }

    # Step 2: Create GitLab project with import_url
    try {
        $createProjectUrl = "https://gitlab.com/api/v4/projects"
        $importUrl = $repoUrl -replace "https://", "https://anything:$azurePAT@"
        $createBody = @{
            name = $repoName
            namespace_id = $groupId
            import_url = $importUrl
        }
        $project = Invoke-RestMethod -Uri $createProjectUrl -Method Post -Headers @{ "PRIVATE-TOKEN" = $gitlabPAT } -Body $createBody
        Write-Host "Project created for $repoName."
    } catch {
        Write-Host "Failed to create project for $repoName."
        continue
    }

    # Step 3: Configure mirror (push-only via API)
    try {
        $mirrorBody = @{
            url = $importUrl
            enabled = $true
            mirror_trigger_builds = $false
            keep_divergent_refs = $true
        }
        $mirrorApi = "https://gitlab.com/api/v4/projects/$($project.id)/remote_mirrors"
        Invoke-RestMethod -Uri $mirrorApi -Method Post -Headers @{ "PRIVATE-TOKEN" = $gitlabPAT } -Body $mirrorBody
        Write-Host "Mirror configured for $repoName."
    } catch {
        Write-Host "Mirror already exists or failed to configure for $repoName."
    }

    # Step 4: Wait for GitLab to finish import
    $maxRetries = 20
    $retryDelay = 30
    $importComplete = $false
    $gitlabBranches = @()

    for ($i = 0; $i -lt $maxRetries; $i++) {
        Start-Sleep -Seconds $retryDelay
        try {
            $gitlabBranches = Invoke-RestMethod -Uri "https://gitlab.com/api/v4/projects/$($project.id)/repository/branches" -Headers @{ "PRIVATE-TOKEN" = $gitlabPAT }
            if ($gitlabBranches.Count -gt 0) {
                $importComplete = $true
                break
            }
        } catch {
            Write-Host "Waiting for GitLab to finish import..."
        }
    }

    if (-not $importComplete) {
        Write-Host "Import incomplete. Skipping validation for $repoName."
        continue
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $gitlabProjectPath = "$gitlabGroup/$repoName"
    $gitlabProjectEncoded = $gitlabProjectPath -replace "/", "%2F"
    $gitlabProjectInfo = Invoke-RestMethod -Uri "https://gitlab.com/api/v4/projects/$gitlabProjectEncoded" -Headers @{ "PRIVATE-TOKEN" = $gitlabPAT }
    $gitlabProjectId = $gitlabProjectInfo.id

    # GitLab branches
    $gitlabBranchNames = @()
    $page = 1
    $perPage = 100
    do {
        $gitlabBranchesPage = Invoke-RestMethod -Uri "https://gitlab.com/api/v4/projects/$gitlabProjectId/repository/branches?per_page=$perPage&page=$page" -Headers @{ "PRIVATE-TOKEN" = $gitlabPAT }
        $gitlabBranchNames += $gitlabBranchesPage.name
        $page++
    } while ($gitlabBranchesPage.Count -eq $perPage)

    # Azure branches
    $azureBranchNames = @()
    $continuationToken = $null
    do {
        $headers = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$azurePAT")) }
        if ($continuationToken) {
            $headers["x-ms-continuationtoken"] = $continuationToken
        }

        $azureApi = "https://dev.azure.com/$azureOrg/$azureProject/_apis/git/repositories/$repoName/refs?filter=heads/&api-version=6.0"
        $response = Invoke-RestMethod -Uri $azureApi -Headers $headers

        $azureBranchNames += $response.value.name | ForEach-Object { $_ -replace "refs/heads/", "" }
        $continuationToken = $response.ContinuationToken
    } while ($continuationToken)
    # Step 5: Trigger GitLab mirror resync before tag validation
    try {
        $mirrorApi = "https://gitlab.com/api/v4/projects/$gitlabProjectId/remote_mirrors"
        $mirrors = Invoke-RestMethod -Uri $mirrorApi -Headers @{ "PRIVATE-TOKEN" = $gitlabPAT }
        if ($mirrors.Count -gt 0) {
            $mirrorId = $mirrors[0].id
            Invoke-RestMethod -Uri "$mirrorApi/$mirrorId/trigger" -Method POST -Headers @{ "PRIVATE-TOKEN" = $gitlabPAT }
            Write-Host "Triggered GitLab mirror resync for $repoName."
            Start-Sleep -Seconds 20
        }
    } catch {
        Write-Host "Failed to trigger GitLab mirror resync for $repoName."
    }

    # Step 6: Validation
    $validationStatus = "Failed"
    $tagCountMatch = $false
    $latestTagMatch = $false
    $commitCountMatch = $false
    $latestTagAzure = ""
    $latestTagGitLab = ""
    $failureReason = ""

    try {
        # Azure tags
        $azureTagsApi = "https://dev.azure.com/$azureOrg/$azureProject/_apis/git/repositories/$repoName/refs?filter=tags/&api-version=6.0"
        $azureHeaders = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$azurePAT")) }
        $azureTagsResponse = Invoke-RestMethod -Uri $azureTagsApi -Headers $azureHeaders
        $azureTags = $azureTagsResponse.value.name | ForEach-Object { $_ -replace "refs/tags/", "" } | Sort-Object
        $azureTagCount = $azureTags.Count
        $latestTagAzure = ($azureTags | Sort-Object)[-1]

        # GitLab tags
        $gitlabTagsApi = "https://gitlab.com/api/v4/projects/$gitlabProjectId/repository/tags"
        $gitlabTagsResponse = Invoke-RestMethod -Uri $gitlabTagsApi -Headers @{ "PRIVATE-TOKEN" = $gitlabPAT }
        $gitlabTags = $gitlabTagsResponse.name | Sort-Object
        $gitlabTagCount = $gitlabTags.Count
        $latestTagGitLab = ($gitlabTags | Sort-Object)[-1]

        # Azure commits
        $azureCommitsApi = "https://dev.azure.com/$azureOrg/$azureProject/_apis/git/repositories/$repoName/commits?searchCriteria.itemVersion.version=master&api-version=6.0"
        $azureCommitsResponse = Invoke-RestMethod -Uri $azureCommitsApi -Headers $azureHeaders
        $azureCommitCount = $azureCommitsResponse.count

        # GitLab commits
        $gitlabCommitsApi = "https://gitlab.com/api/v4/projects/$gitlabProjectId/repository/commits"
        $gitlabCommitsResponse = Invoke-RestMethod -Uri $gitlabCommitsApi -Headers @{ "PRIVATE-TOKEN" = $gitlabPAT }
        $gitlabCommitCount = $gitlabCommitsResponse.Count

        # Compare
        $tagCountMatch = ($azureTagCount -eq $gitlabTagCount)
        $latestTagMatch = ($latestTagAzure -eq $latestTagGitLab)
        $commitCountMatch = ($azureCommitCount -eq $gitlabCommitCount)

        if ($azureBranchNames.Count -eq $gitlabBranchNames.Count -and $tagCountMatch -and $latestTagMatch -and $commitCountMatch) {
            $validationStatus = "Successful"
        } else {
            if (-not $tagCountMatch) {
                $failureReason += "Tag count mismatch: Azure=$azureTagCount, GitLab=$gitlabTagCount. "
            }
            if (-not $latestTagMatch) {
                $failureReason += "Latest tag mismatch: Azure='$latestTagAzure', GitLab='$latestTagGitLab'. "
            }
            if (-not $commitCountMatch) {
                $failureReason += "Commit count mismatch: Azure=$azureCommitCount, GitLab=$gitlabCommitCount. "
            }
        }
    } catch {
        $failureReason = "Error during metadata comparison."
    }

    # Display summary
    Write-Host "`n--- Validation Summary ---"
    Write-Host "Branch Count Match     : Azure=$($azureBranchNames.Count), GitLab=$($gitlabBranchNames.Count)"
    Write-Host "Tag Count Match        : $tagCountMatch"
    Write-Host "Latest Tag Match       : $latestTagMatch"
    Write-Host "Commit Count Match     : $commitCountMatch"
    Write-Host "Validation             : $validationStatus"
    if ($failureReason) {
        Write-Host "Reason for Failure     : $failureReason"
    }

    # Write log file
    $logContent = @"
Source Repo URL      : $repoUrl
Destination Repo URL : https://gitlab.com/$gitlabGroup/$repoName
Time of Migration    : $timestamp

Branch Count Match   : Azure=$($azureBranchNames.Count), GitLab=$($gitlabBranchNames.Count)
Tag Count Match      : $tagCountMatch
Latest Tag Match     : $latestTagMatch
Commit Count Match   : $commitCountMatch
Validation Status    : $validationStatus
Reason for Failure   : $failureReason
"@

    $logFile = "$repoName`_status.log"
    try {
        Set-Content -Path $logFile -Value $logContent
        Write-Host "Validation log written to $logFile"
    } catch {
        Write-Host "Failed to write validation log for $repoName"
    }
}
