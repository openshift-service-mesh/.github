#/bin/bash
set -eux -o pipefail

UPSTREAM_CLONE_URL=${UPSTREAM_CLONE_URL:-https://github.com/istio/istio.git}
DOWNSTREAM_CLONE_URL=${DOWNSTREAM_CLONE_URL:-https://github.com/openshift-service-mesh/istio.git}
REPO=$(basename "${UPSTREAM_CLONE_URL}" .git)
BRANCHES=${BRANCHES:-master release-1.30 release-1.28 release-1.27 release-1.26 release-1.24}

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
LABEL_PENDING_UPSTREAM=${LABEL_PENDING_UPSTREAM:-"pending-upstream-sync"}
GRAPHQL_LABELS_LIMIT=${GRAPHQL_LABELS_LIMIT:-20}

# Patterns for commits to hide from rendered output (extended regex, matched against title)
HIDE_PATTERNS=${HIDE_PATTERNS:-"Automator: |^dependabot"}

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

  echo "| Commit SHA | Title | Upstream PR | Pending Sync | Permanent | Comment | Date | Author |"
  echo "| --- | --- | --- | --- | --- | --- | --- |--- |"
  commit_data=$(yq e '.commits[] | select(.hide != true) | [.sha, .title, (.upstreamPR // "null"), (.isPendingUpstreamSync // "null"), (.isPermanent // "false"), (.comment // "null"), .date, .author] | @tsv' ${yaml_file})
  while IFS=$'\t' read -r sha title upstreamPR isPendingUpstreamSync isPermanent comment date author _; do
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
    echo "| [${sha:0:8}](${COMMIT_BASE_URL}${sha}) | `renderTitle "${title}"` | ${upstreamPR} | ${isPendingUpstreamSync} | ${isPermanent} | `renderComment "${comment}"` | ${date} | ${author} |"
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
  local batch_size=50

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
    # Use || true because gh exits non-zero when the response contains partial errors
    # (e.g. NOT_FOUND for upstream PR numbers), even though valid data is returned
    local response
    response=$(gh api graphql -f query="$query" 2>/dev/null) || true

    if [[ -n "${response}" ]] && echo "${response}" | jq -e '.data.repository' >/dev/null 2>&1; then
      for pr_num in "${batch[@]}"; do
        local labels
        labels=$(echo "$response" | jq -r ".data.repository.pr${pr_num}.labels.nodes[]?.name" 2>/dev/null | tr '\n' ' ' || echo "")
        result_map["$pr_num"]="$labels"
        total_fetched=$((total_fetched + 1))
      done
    else
      echo "  Warning: GraphQL batch failed at index ${batch_start}, trying individual PR fallback"
      for pr_num in "${batch[@]}"; do
        if labels=$(gh pr view "$pr_num" --repo "${GRAPHQL_REPO_OWNER}/${GRAPHQL_REPO_NAME}" --json labels --jq '.labels[].name' 2>/dev/null | tr '\n' ' '); then
          result_map["$pr_num"]="$labels"
          total_fetched=$((total_fetched + 1))
        else
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

  # Phase 1: collect unlabeled commits and unique PRs across ALL branches
  declare -A global_unique_prs
  local global_pr_list=()

  # Per-branch data: branch -> array of "sha|pr_number" for unlabeled commits
  declare -A branch_unlabeled

  for branch in ${BRANCHES}; do
    yaml_file="${pwd}/${REPO}_${branch}.yaml"

    if [[ ! -f "${yaml_file}" ]]; then
      continue
    fi

    echo "Scanning branch: ${branch}"

    local unlabeled_entries=()

    readarray -t commits < <(yq e -o=j -I=0 '.commits[] | [.sha, .title] | @tsv' "${yaml_file}")

    for commit_line in "${commits[@]}"; do
      if [[ -z "${commit_line}" ]]; then
        continue
      fi

      clean_line=$(echo "${commit_line}" | sed 's/^"//; s/"$//' | sed 's/\\t/\t/g')
      sha=$(echo "${clean_line}" | awk -F'\t' '{print $1}')
      title=$(echo "${clean_line}" | awk -F'\t' '{print $2}')

      pr_number=$(extractPRNumber "${title}")
      if [[ -n "${pr_number}" ]]; then
        unlabeled_entries+=("${sha}|${pr_number}")

        if [[ -z "${global_unique_prs[${pr_number}]:-}" ]]; then
          global_unique_prs["${pr_number}"]="1"
          global_pr_list+=("${pr_number}")
        fi
      fi
    done

    branch_unlabeled["${branch}"]=$(printf '%s\n' "${unlabeled_entries[@]}")
    echo "  Found ${#unlabeled_entries[@]} unlabeled commits to process"
  done

  if [[ ${#global_pr_list[@]} -eq 0 ]]; then
    echo "No unlabeled PRs to fetch across any branch"
    return
  fi

  # Phase 2: single batch fetch for all unique PRs
  declare -A global_pr_labels
  echo ""
  echo "Fetching labels for ${#global_pr_list[@]} unique PRs across all branches..."
  batchFetchPRLabels global_pr_labels "${global_pr_list[@]}"

  # Phase 3: apply labels to each branch file
  for branch in ${BRANCHES}; do
    yaml_file="${pwd}/${REPO}_${branch}.yaml"

    if [[ ! -f "${yaml_file}" ]]; then
      continue
    fi

    local entries="${branch_unlabeled[${branch}]:-}"
    if [[ -z "${entries}" ]]; then
      continue
    fi

    echo ""
    echo "Applying labels for branch: ${branch}"

    local updates=()

    while IFS='|' read -r sha pr_number; do
      if [[ -z "${sha}" ]]; then
        continue
      fi

      labels="${global_pr_labels[$pr_number]:-}"
      if [[ -n "${labels}" ]]; then
        if echo "${labels}" | grep -q "${LABEL_NON_PERMANENT}"; then
          updates+=("(.commits[] | select(.sha == \"${sha}\") | .isPermanent) = false")
          echo "  Setting isPermanent=false for commit ${sha:0:8} (PR #${pr_number}) - found '${LABEL_NON_PERMANENT}' label"
        elif echo "${labels}" | grep -q "${LABEL_PERMANENT}"; then
          updates+=("(.commits[] | select(.sha == \"${sha}\") | .isPermanent) = true")
          echo "  Setting isPermanent=true for commit ${sha:0:8} (PR #${pr_number}) - found '${LABEL_PERMANENT}' label"
        elif echo "${labels}" | grep -q "${LABEL_PENDING_UPSTREAM}"; then
          updates+=("(.commits[] | select(.sha == \"${sha}\") | .isPendingUpstreamSync) = true")
          echo "  Setting isPendingUpstreamSync=true for commit ${sha:0:8} (PR #${pr_number}) - found '${LABEL_PENDING_UPSTREAM}' label"
        else
          echo "  No relevant labels found for commit ${sha:0:8} (PR #${pr_number}) - expected one of: '${LABEL_PERMANENT}', '${LABEL_NON_PERMANENT}', or '${LABEL_PENDING_UPSTREAM}'"
        fi
      fi
    done <<< "${entries}"

    if [[ ${#updates[@]} -gt 0 ]]; then
      local yq_expr=""
      for update in "${updates[@]}"; do
        [[ -n "${yq_expr}" ]] && yq_expr+=" | "
        yq_expr+="${update}"
      done

      yq -i e "${yq_expr}" "${yaml_file}"
      echo "  Applied ${#updates[@]} updates to ${yaml_file##*/}"
    fi
  done

  unset global_unique_prs global_pr_labels branch_unlabeled
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

function markHiddenCommits() {
  echo "Marking hidden commits..."
  for branch in ${BRANCHES}; do
    yaml_file="${pwd}/${REPO}_${branch}.yaml"
    [[ ! -f "${yaml_file}" ]] && continue

    local count
    count=$(yq e "[.commits[] | select(.hide != true and (.title | test(\"${HIDE_PATTERNS}\")))] | length" "${yaml_file}")
    if [[ "${count}" -gt 0 ]]; then
      yq -i e "(.commits[] | select(.hide != true and (.title | test(\"${HIDE_PATTERNS}\"))) | .hide) = true" "${yaml_file}"
      echo "  ${branch}: marked ${count} commits as hidden"
    fi
  done
}

markHiddenCommits

function renderOverviewMatrix() {
  # Collect all unique commit titles across branches with their latest date, then sort newest-first
  declare -A title_date

  for branch in ${BRANCHES}; do
    yaml_file="${pwd}/${REPO}_${branch}.yaml"
    [[ ! -f "${yaml_file}" ]] && continue
    while IFS= read -r line; do
      local date="${line%%|||*}"
      local title="${line#*|||}"
      [[ -z "${title}" ]] && continue
      if [[ -z "${title_date["${title}"]:-}" || "${date}" > "${title_date["${title}"]}" ]]; then
        title_date["${title}"]="${date}"
      fi
    done < <(yq e '.commits[] | select(.hide != true) | .date + "|||" + .title' "${yaml_file}")
  done

  local ordered_titles=()
  while IFS= read -r line; do
    ordered_titles+=("${line#*|||}")
  done < <(for title in "${!title_date[@]}"; do printf '%s|||%s\n' "${title_date["${title}"]}" "${title}"; done | sort -r)

  if [[ ${#ordered_titles[@]} -eq 0 ]]; then
    return
  fi

  # Build set of titles present per branch and track permanent status
  declare -A branch_has    # key: "branch|title" -> 1
  declare -A title_permanent  # key: "title" -> 1 if any branch marks it permanent

  for branch in ${BRANCHES}; do
    yaml_file="${pwd}/${REPO}_${branch}.yaml"
    [[ ! -f "${yaml_file}" ]] && continue
    while IFS= read -r line; do
      local perm="${line%%|||*}"
      local title="${line#*|||}"
      [[ -z "${title}" ]] && continue
      branch_has["${branch}|${title}"]=1
      if [[ "${perm}" == "true" ]]; then
        title_permanent["${title}"]=1
      fi
    done < <(yq e '.commits[] | select(.hide != true) | (.isPermanent // "false") + "|||" + .title' "${yaml_file}")
  done

  # Render header row: Title | branch1 | branch2 | ...
  local header="| Title |"
  local separator="| --- |"
  for branch in ${BRANCHES}; do
    header+=" ${branch} |"
    separator+=" :---: |"
  done

  echo "${header}"
  echo "${separator}"

  # Render one row per commit title, skipping master-only commits
  for title in "${ordered_titles[@]}"; do
    local on_release=false
    for branch in ${BRANCHES}; do
      if [[ "${branch}" != "master" && -n "${branch_has["${branch}|${title}"]:-}" ]]; then
        on_release=true
        break
      fi
    done
    [[ "${on_release}" == "false" ]] && continue

    local is_permanent="${title_permanent["${title}"]:-}"
    # Find the oldest branch (rightmost in BRANCHES) where this commit appears
    local oldest_idx=-1
    local branches_arr=(${BRANCHES})
    for (( i=${#branches_arr[@]}-1; i>=0; i-- )); do
      if [[ -n "${branch_has["${branches_arr[$i]}|${title}"]:-}" ]]; then
        oldest_idx=$i
        break
      fi
    done
    local row="| `renderTitle \"${title}\"` |"
    for (( i=0; i<${#branches_arr[@]}; i++ )); do
      if [[ -n "${branch_has["${branches_arr[$i]}|${title}"]:-}" ]]; then
        row+=" :white_check_mark: |"
      elif [[ "${is_permanent}" == "1" && $i -lt $oldest_idx && "${branches_arr[$i]}" != "master" ]]; then
        row+=" :warning: |"
      else
        row+=" :x: |"
      fi
    done
    echo "${row}"
  done
}

echo "# ${REPO^} Downstream Changes" > "${OUTPUT_MARKDOWN_FILE}"

echo "## Overview" >> "${OUTPUT_MARKDOWN_FILE}"
renderOverviewMatrix >> "${OUTPUT_MARKDOWN_FILE}"

for branch in ${BRANCHES}; do
  input_yaml="${pwd}/${REPO}_${branch}.yaml"
  echo "## ${branch} branch" >> "${OUTPUT_MARKDOWN_FILE}"
  renderMarkdownTableFromYAML "${input_yaml}" >> "${OUTPUT_MARKDOWN_FILE}"
done
