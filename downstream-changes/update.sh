#/bin/bash
set -eux -o pipefail

UPSTREAM_CLONE_URL=${UPSTREAM_CLONE_URL:-https://github.com/istio/istio.git}
DOWNSTREAM_CLONE_URL=${DOWNSTREAM_CLONE_URL:-https://github.com/openshift-service-mesh/istio.git}
REPO=$(basename "${UPSTREAM_CLONE_URL}" .git)
BRANCHES=${BRANCHES:-master release-1.24 release-1.26 release-1.27 release-1.28}

# base URLs for markdown rendering
COMMIT_BASE_URL=https://github.com/openshift-service-mesh/istio/commit/
JIRA_BASE_URL=https://issues.redhat.com/browse/
GH_ISSUES_BASE_URL=https://github.com/openshift-service-mesh/istio/issues/

pwd=`pwd`

OUTPUT_MARKDOWN_FILE="${pwd}/${REPO}.md"
SKIP_GIT=${SKIP_GIT:-}
SKIP_PR_LABELS=${SKIP_PR_LABELS:-}
SKIP_PR_DISCOVERY=${SKIP_PR_DISCOVERY:-}
FORCE_LABEL_UPDATE=${FORCE_LABEL_UPDATE:-}

# GraphQL and label configuration
GRAPHQL_REPO_OWNER=${GRAPHQL_REPO_OWNER:-"openshift-service-mesh"}
GRAPHQL_REPO_NAME=${GRAPHQL_REPO_NAME:-"istio"}
LABEL_PERMANENT=${LABEL_PERMANENT:-"permanent-change"}
LABEL_NON_PERMANENT=${LABEL_NON_PERMANENT:-"no-permanent-change"}
LABEL_PENDING_UPSTREAM=${LABEL_PENDING_UPSTREAM:-"pending-upstream-sync"}
GRAPHQL_LABELS_LIMIT=${GRAPHQL_LABELS_LIMIT:-20}

function updateGit() {
  # Initialize file to track new commits discovered in this run
  > "${pwd}/.new_commits_list"

  cd `mktemp -d`

  git clone -o downstream ${DOWNSTREAM_CLONE_URL} .
  git remote add upstream ${UPSTREAM_CLONE_URL}


  for branch in ${BRANCHES}; do
    output_yaml="${pwd}/${REPO}_${branch}.yaml"
    touch "${output_yaml}"

    git fetch upstream ${branch}
    git fetch downstream ${branch}
    while IFS="|" read -r sha title date author
    do
      if [[ $(yq e ".commits[] | select(.sha == \"${sha}\")" ${output_yaml}) != "" ]]; then
        # Existing commit - update metadata only
        yq -i e "(.commits[] | select(.sha == \"${sha}\") | .title) = \"${title//\"/\\\"}\" |
                (.commits[] | select(.sha == \"${sha}\") | .author) = \"${author}\" |
                (.commits[] | select(.sha == \"${sha}\") | .date) = \"${date}\"" ${output_yaml}
      else
        # NEW commit - add to YAML and track in new commits list
        yq -i e ".commits += [{\"sha\":\"${sha}\",\"title\":\"${title//\"/\\\"}\",\"author\":\"${author}\",\"date\":\"${date}\",\"found\": true}]" ${output_yaml}
        echo "${sha}" >> "${pwd}/.new_commits_list"
      fi
    done < <(git log --pretty="tformat:%H|%s|%ai|%an" --no-decorate --no-merges upstream/${branch}..downstream/${branch})
  done
}

function renderTitle() {
    echo $1 | sed "s|\(OSSM-[0-9]*\)|[\1](${JIRA_BASE_URL}\1)|g" | sed "s|\#\([0-9]*\)|[#\1](${GH_ISSUES_BASE_URL}\1)|g"
}

function renderComment() {
    echo $1 | sed "s|\(OSSM-[0-9]*\)|[\1](${JIRA_BASE_URL}\1)|g"
}

function renderMarkdownTableFromYAML() {
  yaml_file="${1}"

  readarray commits < <(yq e -o=j -I=0 '.commits | to_entries' ${yaml_file} )

  echo "| Commit SHA | Title | PR | Upstream PR | Pending Sync | Permanent | Comment | Date | Author |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- |--- |"
  commit_data=$(yq e '.commits[] | [.sha, .title, (.prNumber // "null"), (.upstreamPR // "null"), (.isPendingUpstreamSync // "null"), (.isPermanent // "false"), (.comment // "null"), .date, .author] | @tsv' ${yaml_file})
  while IFS=$'\t' read -r sha title prNumber upstreamPR isPendingUpstreamSync isPermanent comment date author _; do
    # Format PR number as a link if available
    local pr_display=""
    if [[ -n "${prNumber}" && "${prNumber}" != "null" ]]; then
      pr_display="[#${prNumber}](https://github.com/${GRAPHQL_REPO_OWNER}/${GRAPHQL_REPO_NAME}/pull/${prNumber})"
    else
      # Fallback: extract from title for backwards compatibility
      local extracted_pr=$(extractPRNumber "${title}")
      if [[ -n "${extracted_pr}" ]]; then
        pr_display="[#${extracted_pr}](https://github.com/${GRAPHQL_REPO_OWNER}/${GRAPHQL_REPO_NAME}/pull/${extracted_pr})"
      fi
    fi

    if [[ "${isPermanent}" == "true" ]]; then
      isPermanent=":white_check_mark:"
    else
      isPermanent=":x:"
    fi
    if [[ "${isPendingUpstreamSync}" == "true" ]]; then
      isPendingUpstreamSync=":hourglass_flowing_sand:"
    else
      isPendingUpstreamSync=""
    fi
    if [[ "${comment}" == "null" ]]; then
      comment=""
    fi
    if [[ "${upstreamPR}" == "null" ]]; then
      upstreamPR=""
    fi
    echo "| [${sha:0:8}](${COMMIT_BASE_URL}${sha}) | `renderTitle "${title}"` | ${pr_display} | ${upstreamPR} | ${isPendingUpstreamSync} | ${isPermanent} | `renderComment "${comment}"` | ${date} | ${author} |"
  done < <(echo "${commit_data}")
}

function extractPRNumber() {
  local title="$1"
  local pr_number=""

  # Extract all PR numbers in format (#123) and take the last one (for downstream PRs)
  if pr_number=$(echo "$title" | grep -oE '\(#[0-9]+\)' | tail -1 | grep -oE '[0-9]+'); then
    echo "$pr_number"
    return
  fi

  # If no simple (#123) pattern found, try repo/name#123 pattern
  if pr_number=$(echo "$title" | grep -oE '\([^/]+/[^#]+#[0-9]+\)' | tail -1 | grep -oE '[0-9]+'); then
    echo "$pr_number"
    return
  fi

  echo ""
}

function batchFetchPRLabels() {
  local -n result_map="$1"
  local pr_numbers=("${@:2}")
  local batch_size=10

  if [[ ${#pr_numbers[@]} -eq 0 ]]; then
    return 0
  fi

  echo "  Batch fetching labels for ${#pr_numbers[@]} PRs via GraphQL..."

  local total_fetched=0
  local batch_start=0

  while [[ ${batch_start} -lt ${#pr_numbers[@]} ]]; do
    local batch_end=$((batch_start + batch_size))
    if [[ ${batch_end} -gt ${#pr_numbers[@]} ]]; then
      batch_end=${#pr_numbers[@]}
    fi

    # Extract current batch
    local batch=("${pr_numbers[@]:${batch_start}:${batch_size}}")

    # Build dynamic GraphQL query using configurable values
    local query="query { repository(owner: \"${GRAPHQL_REPO_OWNER}\", name: \"${GRAPHQL_REPO_NAME}\") {"
    for pr_num in "${batch[@]}"; do
      query+=" pr${pr_num}: pullRequest(number: ${pr_num}) { labels(first: ${GRAPHQL_LABELS_LIMIT}) { nodes { name } } }"
    done
    query+=' } }'

    # GraphQL API call for this batch
    local response
    if response=$(gh api graphql -f query="$query" 2>/dev/null); then
      # Parse response and populate result map
      for pr_num in "${batch[@]}"; do
        local labels
        labels=$(echo "$response" | jq -r ".data.repository.pr${pr_num}.labels.nodes[]?.name" 2>/dev/null | tr '\n' ' ' || echo "")
        result_map["$pr_num"]="$labels"
        total_fetched=$((total_fetched + 1))
      done
    else
      # GraphQL query failed, try individual PR processing as fallback for this batch
      echo "  Warning: GraphQL batch failed at index ${batch_start}, trying individual PR fallback"
      for pr_num in "${batch[@]}"; do
        # Single PR fallback using gh pr view (only for failed batches)
        if labels=$(gh pr view "$pr_num" --repo "${GRAPHQL_REPO_OWNER}/${GRAPHQL_REPO_NAME}" --json labels --jq '.labels[].name' 2>/dev/null | tr '\n' ' '); then
          result_map["$pr_num"]="$labels"
          total_fetched=$((total_fetched + 1))
        else
          # PR doesn't exist, mark as empty
          result_map["$pr_num"]=""
        fi
      done
    fi

    batch_start=${batch_end}
  done

  if [[ ${total_fetched} -gt 0 ]]; then
    echo "  Successfully fetched labels for ${total_fetched} PRs"
  fi
}

function findPRForCommit() {
  local sha="$1"
  local branch="${2:-}"  # Optional: branch name to filter PRs
  local pr_number=""

  # Primary method: GitHub commits API
  # Works for: Regular commits (non-cherry-picked)
  # Fails for: Cherry-picked commits (GitHub doesn't maintain commit→PR mapping for cherry-picks)
  if pr_number=$(gh api -X GET "repos/${GRAPHQL_REPO_OWNER}/${GRAPHQL_REPO_NAME}/commits/${sha}/pulls" --jq '.[0].number' 2>/dev/null); then
    if [[ -n "$pr_number" && "$pr_number" != "null" ]]; then
      echo "$pr_number"
      return 0
    fi
  fi

  # Fallback 1: GitHub Search API
  # Why keep this: May catch edge cases where search indexing differs from commits endpoint
  # Known limitation: Also fails for cherry-picked commits (same underlying data as primary)
  if pr_number=$(gh api -X GET "search/issues" -f q="repo:${GRAPHQL_REPO_OWNER}/${GRAPHQL_REPO_NAME} ${sha} type:pr" --jq '.items[0].number' 2>/dev/null); then
    if [[ -n "$pr_number" && "$pr_number" != "null" ]]; then
      echo "$pr_number"
      return 0
    fi
  fi

  # Fallback 2: GraphQL - Check recent merged PRs
  # Why needed: Solves the cherry-pick problem by reversing the query direction
  # Instead of "which PR has this commit?" (broken for cherry-picks)
  # We ask "does this recent PR contain this commit?" (works!)
  # This works because PR→commits mapping is maintained even for cherry-picks
  echo "  Searching recent PRs for commit..." >&2

  local limit=50

  # Get recent PR numbers merged to the branch
  local pr_numbers
  pr_numbers=$(gh pr list --repo "${GRAPHQL_REPO_OWNER}/${GRAPHQL_REPO_NAME}" \
    --state merged --limit ${limit} ${branch:+--base "$branch"} --json number --jq '.[].number' 2>/dev/null)

  if [[ -z "$pr_numbers" ]]; then
    echo ""
    return 1
  fi

  # Check each PR's commits via GraphQL in batches of 10
  local batch_size=10
  local pr_array=($pr_numbers)

  for ((i=0; i<${#pr_array[@]}; i+=batch_size)); do
    local batch=("${pr_array[@]:i:batch_size}")

    # Build GraphQL query to check if commit exists in these PRs
    local query="query { repository(owner: \"${GRAPHQL_REPO_OWNER}\", name: \"${GRAPHQL_REPO_NAME}\") {"
    for pr_num in "${batch[@]}"; do
      # Query first 100 commits in each PR (adjust if PRs have more commits)
      query+=" pr${pr_num}: pullRequest(number: ${pr_num}) { number commits(first: 100) { nodes { commit { oid } } } }"
    done
    query+=' } }'

    # Execute GraphQL query
    local response
    if response=$(gh api graphql -f query="$query" 2>/dev/null); then
      # Check each PR in the response
      for pr_num in "${batch[@]}"; do
        # Check if our commit SHA is in this PR's commits
        if echo "$response" | jq -r ".data.repository.pr${pr_num}.commits.nodes[]?.commit.oid" 2>/dev/null | grep -q "^${sha}$"; then
          echo "$pr_num"
          return 0
        fi
      done
    else
      # If GraphQL batch fails, try individual PR checks using REST API
      for pr_num in "${batch[@]}"; do
        if gh api "repos/${GRAPHQL_REPO_OWNER}/${GRAPHQL_REPO_NAME}/pulls/${pr_num}/commits" \
           --jq '.[].sha' 2>/dev/null | grep -q "^${sha}$"; then
          echo "$pr_num"
          return 0
        fi
      done
    fi
  done

  echo ""
  return 1
}

function loadNewCommitsSet() {
  local -n result_set="$1"  # nameref to associative array

  if [[ -f "${pwd}/.new_commits_list" ]]; then
    while read -r sha; do
      [[ -n "${sha}" ]] && result_set["${sha}"]=1
    done < "${pwd}/.new_commits_list"
  fi

  # Temporarily disable 'set -u' to safely get count
  set +u
  local count=${#result_set[@]}
  set -u

  echo "$count"
}

function shouldProcessCommit() {
  local sha="$1"
  local -n commits_set="$2"  # nameref to new_commits_set

  # In FORCE mode, process everything
  if [[ -n "${FORCE_LABEL_UPDATE}" ]]; then
    return 0
  fi

  # In DEFAULT mode, only process new commits
  if [[ -n "${commits_set[$sha]:-}" ]]; then
    return 0
  fi

  return 1
}

function discoverMissingPRNumbers() {
  echo "Discovering PR numbers for commits without them..."

  if ! command -v gh >/dev/null 2>&1; then
    echo "  Warning: gh CLI not available, skipping PR discovery"
    return
  fi

  # Load list of new commits discovered in this run
  declare -A new_commits_set
  local new_commits_count=$(loadNewCommitsSet new_commits_set)

  if [[ -n "${FORCE_LABEL_UPDATE}" ]]; then
    echo "  FORCE mode: discovering PR numbers for ALL commits without them"
  else
    echo "  Default mode: discovering PR numbers for only NEW commits (${new_commits_count} commits)"
  fi

  for branch in ${BRANCHES}; do
    yaml_file="${pwd}/${REPO}_${branch}.yaml"

    if [[ ! -f "${yaml_file}" ]]; then
      continue
    fi

    echo "Processing branch: ${branch}"

    # Find commits without PR numbers in title
    readarray -t commits_data < <(yq e '.commits[] | select(.title | test("#[0-9]") | not) | [.sha, .title] | @tsv' "${yaml_file}")

    local updates_made=0
    for commit_line in "${commits_data[@]}"; do
      if [[ -z "${commit_line}" ]]; then
        continue
      fi

      # Parse sha and title from TSV
      clean_line=$(echo "${commit_line}" | sed 's/^"//; s/"$//' | sed 's/\\t/\t/g')
      sha=$(echo "${clean_line}" | awk -F'\t' '{print $1}')
      title=$(echo "${clean_line}" | awk -F'\t' '{print $2}')

      if [[ -z "$sha" ]]; then continue; fi

      # Check if this commit should be processed based on mode
      if ! shouldProcessCommit "$sha" new_commits_set; then
        continue
      fi

      echo "  Finding PR for commit ${sha:0:8}: ${title:0:50}..."
      pr_number=$(findPRForCommit "$sha" "$branch" || true)

      if [[ -n "$pr_number" ]]; then
        # Set prNumber field (separate from title)
        yq -i e "(.commits[] | select(.sha == \"${sha}\") | .prNumber) = ${pr_number}" "${yaml_file}"
        echo "    ✅ Set prNumber=${pr_number}"
        updates_made=$((updates_made + 1))
      else
        echo "    ❌ No PR found (likely direct commit or API limit reached)"
      fi
    done

    if [[ $updates_made -gt 0 ]]; then
      echo "  Updated ${updates_made} commit titles in ${yaml_file##*/}"
    else
      echo "  No updates needed for ${branch}"
    fi
    echo ""
  done
}

function processPRData() {
  echo "Processing commits to set isPermanent fields based on PR labels..."

  if ! command -v gh >/dev/null 2>&1; then
    echo "  Warning: gh CLI not available, skipping label processing"
    return
  fi

  # Load list of new commits discovered in this run
  # Always declare the array, even if file doesn't exist (e.g., when SKIP_GIT=1)
  declare -A new_commits_set
  local new_commits_count=$(loadNewCommitsSet new_commits_set)

  if [[ -n "${FORCE_LABEL_UPDATE}" ]]; then
    echo "  FORCE_LABEL_UPDATE enabled: processing ALL commits (sets fields based on current PR labels)"
  else
    echo "  Default mode: processing only NEW commits discovered in this run (${new_commits_count} commits)"
  fi

  # Process all branches and all commits in each YAML file
  for branch in ${BRANCHES}; do
    yaml_file="${pwd}/${REPO}_${branch}.yaml"

    if [[ ! -f "${yaml_file}" ]]; then
      continue
    fi

    echo "Processing branch: ${branch}"

    declare -A commit_pr_map  # sha -> pr_number mapping
    declare -A unique_prs     # track unique PRs to avoid duplicates
    local pr_list=()          # array of unique PR numbers

    # Get ALL commits from YAML file with prNumber field
    readarray -t commits < <(yq e -o=j -I=0 '.commits[] | [.sha, .title, (.prNumber // "null")] | @tsv' "${yaml_file}")

    for commit_line in "${commits[@]}"; do
      if [[ -z "${commit_line}" ]]; then
        continue
      fi

      # Remove quotes and convert escaped tab to real tab, then split
      clean_line=$(echo "${commit_line}" | sed 's/^"//; s/"$//' | sed 's/\\t/\t/g')
      sha=$(echo "${clean_line}" | awk -F'\t' '{print $1}')
      title=$(echo "${clean_line}" | awk -F'\t' '{print $2}')
      pr_from_field=$(echo "${clean_line}" | awk -F'\t' '{print $3}')

      # Check if this commit should be processed based on mode
      if ! shouldProcessCommit "$sha" new_commits_set; then
        continue
      fi

      # Get PR number: check prNumber field first, then fallback to extracting from title
      if [[ -n "${pr_from_field}" && "${pr_from_field}" != "null" ]]; then
        pr_number="${pr_from_field}"
      else
        pr_number=$(extractPRNumber "${title}")
      fi
      if [[ -n "${pr_number}" ]]; then
        commit_pr_map["${sha}"]="${pr_number}"

        # Add to unique PR list if not already present
        if [[ -z "${unique_prs[${pr_number}]:-}" ]]; then
          unique_prs["${pr_number}"]="1"
          pr_list+=("${pr_number}")
        fi
      fi
    done

    if [[ ${#pr_list[@]} -eq 0 ]]; then
      echo "  No PRs found in commit titles for ${branch}"
      continue
    fi

    # Batch fetch all PR labels via GraphQL
    declare -A pr_labels  # pr_number -> labels mapping
    batchFetchPRLabels pr_labels "${pr_list[@]}"

    # Build batch updates for YAML
    local updates=()

    for sha in "${!commit_pr_map[@]}"; do
      pr_number="${commit_pr_map[$sha]}"

      # Process labels if available
      labels="${pr_labels[$pr_number]:-}"

      # Check for permanent change labels
      if echo "${labels}" | grep -q "${LABEL_PERMANENT}"; then
        updates+=("(.commits[] | select(.sha == \"${sha}\") | .isPermanent) = true")
        echo "  Setting isPermanent=true for commit ${sha:0:8} (PR #${pr_number}) - found '${LABEL_PERMANENT}' label"
      elif echo "${labels}" | grep -q "${LABEL_NON_PERMANENT}"; then
        updates+=("(.commits[] | select(.sha == \"${sha}\") | .isPermanent) = false")
        echo "  Setting isPermanent=false for commit ${sha:0:8} (PR #${pr_number}) - found '${LABEL_NON_PERMANENT}' label"
      fi

      # Check for pending upstream sync label
      if echo "${labels}" | grep -q "${LABEL_PENDING_UPSTREAM}"; then
        updates+=("(.commits[] | select(.sha == \"${sha}\") | .isPendingUpstreamSync) = true")
        echo "  Setting isPendingUpstreamSync=true for commit ${sha:0:8} (PR #${pr_number}) - found '${LABEL_PENDING_UPSTREAM}' label"
      fi

      # Log if no labels found (informational)
      if [[ -z "${labels}" ]] || [[ ! "${labels}" =~ (${LABEL_PERMANENT}|${LABEL_NON_PERMANENT}|${LABEL_PENDING_UPSTREAM}) ]]; then
        echo "  No relevant labels found for commit ${sha:0:8} (PR #${pr_number})"
      fi
    done

    # Apply all updates in a single yq call
    if [[ ${#updates[@]} -gt 0 ]]; then
      local yq_expr=""
      for update in "${updates[@]}"; do
        [[ -n "${yq_expr}" ]] && yq_expr+=" | "
        yq_expr+="${update}"
      done

      yq -i e "${yq_expr}" "${yaml_file}"
      echo "  Applied ${#updates[@]} updates to ${yaml_file##*/}"
    fi

    unset commit_pr_map unique_prs pr_labels
  done
}

# Clear the new commits list before starting
# If updateGit() runs, it will create a fresh list
# If SKIP_GIT=1, the empty/missing file indicates no new commits
rm -f "${pwd}/.new_commits_list"

if [[ -z "${SKIP_GIT}" ]]; then
  updateGit
fi

# PR discovery and label processing in separate passes
if [[ -z "${SKIP_PR_DISCOVERY}" ]]; then
  discoverMissingPRNumbers
fi

if [[ -z "${SKIP_PR_LABELS}" ]]; then
  processPRData
fi

echo "# ${REPO^} Downstream Changes" > "${OUTPUT_MARKDOWN_FILE}"
for branch in ${BRANCHES}; do
  input_yaml="${pwd}/${REPO}_${branch}.yaml"
  echo "## ${branch} branch" >> "${OUTPUT_MARKDOWN_FILE}"
  renderMarkdownTableFromYAML "${input_yaml}" >> "${OUTPUT_MARKDOWN_FILE}"
done

# Clean up temporary file
rm -f "${pwd}/.new_commits_list"
