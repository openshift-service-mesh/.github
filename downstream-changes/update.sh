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

# GraphQL and label configuration
GRAPHQL_REPO_OWNER=${GRAPHQL_REPO_OWNER:-"openshift-service-mesh"}
GRAPHQL_REPO_NAME=${GRAPHQL_REPO_NAME:-"istio"}
LABEL_PERMANENT=${LABEL_PERMANENT:-"permanent-change"}
LABEL_NON_PERMANENT=${LABEL_NON_PERMANENT:-"no-permanent-change"}
GRAPHQL_LABELS_LIMIT=${GRAPHQL_LABELS_LIMIT:-20}

function updateGit() {
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
        yq -i e "(.commits[] | select(.sha == \"${sha}\") | .title) = \"${title//\"/\\\"}\" |
                (.commits[] | select(.sha == \"${sha}\") | .author) = \"${author}\" |
                (.commits[] | select(.sha == \"${sha}\") | .date) = \"${date}\"" ${output_yaml}
      else
        yq -i e ".commits += [{\"sha\":\"${sha}\",\"title\":\"${title//\"/\\\"}\",\"author\":\"${author}\",\"date\":\"${date}\",\"found\": true}]" ${output_yaml}
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

  echo "| Commit SHA | Title | Upstream PR | Permanent | Comment | Date | Author |"
  echo "| --- | --- | --- | --- | --- | --- |--- |"
  commit_data=$(yq e '.commits[] | [.sha, .title, (.upstreamPR // "null"), (.isPermanent // "false"), (.comment // "null"), .date, .author] | @tsv' ${yaml_file})
  while IFS=$'\t' read -r sha title upstreamPR isPermanent comment date author _; do
    if [[ "${isPermanent}" == "true" ]]; then
      isPermanent=":white_check_mark:"
    else 
      isPermanent=":x:"
    fi
    if [[ "${comment}" == "null" ]]; then
      comment=""
    fi
    if [[ "${upstreamPR}" == "null" ]]; then
      upstreamPR=""
    fi
    echo "| [${sha:0:8}](${COMMIT_BASE_URL}${sha}) | `renderTitle "${title}"` | ${upstreamPR} | ${isPermanent} | `renderComment "${comment}"` | ${date} | ${author} |"
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
  local pr_number=""

  # Try GitHub commits API (primary method)
  if pr_number=$(gh api -X GET "repos/${GRAPHQL_REPO_OWNER}/${GRAPHQL_REPO_NAME}/commits/${sha}/pulls" --jq '.[0].number' 2>/dev/null); then
    if [[ -n "$pr_number" && "$pr_number" != "null" ]]; then
      echo "$pr_number"
      return 0
    fi
  fi

  # Fallback: GitHub search API
  if pr_number=$(gh api -X GET "search/issues" -f q="repo:${GRAPHQL_REPO_OWNER}/${GRAPHQL_REPO_NAME} ${sha} type:pr" --jq '.items[0].number' 2>/dev/null); then
    if [[ -n "$pr_number" && "$pr_number" != "null" ]]; then
      echo "$pr_number"
      return 0
    fi
  fi

  echo ""
}

function discoverMissingPRNumbers() {
  echo "Discovering PR numbers for commits without them..."

  if ! command -v gh >/dev/null 2>&1; then
    echo "  Warning: gh CLI not available, skipping PR discovery"
    return
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

      echo "  Finding PR for commit ${sha:0:8}: ${title:0:50}..."
      pr_number=$(findPRForCommit "$sha")

      if [[ -n "$pr_number" ]]; then
        # Update commit title to include PR number
        new_title="${title} (#${pr_number})"
        yq -i e "(.commits[] | select(.sha == \"${sha}\") | .title) = \"${new_title//\"/\\\"}\"" "${yaml_file}"
        echo "    ✅ Added PR #${pr_number} to title"
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

    # Get ALL commits from YAML file
    readarray -t commits < <(yq e -o=j -I=0 '.commits[] | [.sha, .title] | @tsv' "${yaml_file}")

    for commit_line in "${commits[@]}"; do
      if [[ -z "${commit_line}" ]]; then
        continue
      fi

      # Remove quotes and convert escaped tab to real tab, then split
      clean_line=$(echo "${commit_line}" | sed 's/^"//; s/"$//' | sed 's/\\t/\t/g')
      sha=$(echo "${clean_line}" | awk -F'\t' '{print $1}')
      title=$(echo "${clean_line}" | awk -F'\t' '{print $2}')

      # Extract PR number from title
      pr_number=$(extractPRNumber "${title}")
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
      if [[ -n "${labels}" ]]; then
        if echo "${labels}" | grep -q "${LABEL_PERMANENT}"; then
          updates+=("(.commits[] | select(.sha == \"${sha}\") | .isPermanent) = true")
          echo "  Setting isPermanent=true for commit ${sha:0:8} (PR #${pr_number}) - found '${LABEL_PERMANENT}' label"
        elif echo "${labels}" | grep -q "${LABEL_NON_PERMANENT}"; then
          updates+=("(.commits[] | select(.sha == \"${sha}\") | .isPermanent) = false")
          echo "  Setting isPermanent=false for commit ${sha:0:8} (PR #${pr_number}) - found '${LABEL_NON_PERMANENT}' label"
        else
          echo "  No relevant labels found for commit ${sha:0:8} (PR #${pr_number}) - expected '${LABEL_PERMANENT}' or '${LABEL_NON_PERMANENT}'"
        fi
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
