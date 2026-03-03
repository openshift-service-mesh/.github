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
  # Look for patterns like (#123) or (openshift-service-mesh/istio#123)
  if [[ ${title} =~ \(#([0-9]+)\) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ ${title} =~ \([^/]+/[^#]+#([0-9]+)\) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

function batchFetchPRLabels() {
  local -n result_map="$1"
  local pr_numbers=("${@:2}")

  if [[ ${#pr_numbers[@]} -eq 0 ]]; then
    return 0
  fi

  echo "  Batch fetching labels for ${#pr_numbers[@]} PRs via GraphQL..."

  # Build dynamic GraphQL query using configurable values
  local query="query { repository(owner: \"${GRAPHQL_REPO_OWNER}\", name: \"${GRAPHQL_REPO_NAME}\") {"
  for pr_num in "${pr_numbers[@]}"; do
    query+=" pr${pr_num}: pullRequest(number: ${pr_num}) { labels(first: ${GRAPHQL_LABELS_LIMIT}) { nodes { name } } }"
  done
  query+=' } }'

  # Single GraphQL API call
  local response
  if response=$(gh api graphql -f query="$query" 2>/dev/null); then
    # Parse response and populate result map
    for pr_num in "${pr_numbers[@]}"; do
      local labels
      labels=$(echo "$response" | jq -r ".data.repository.pr${pr_num}.labels.nodes[]?.name" 2>/dev/null | tr '\n' ' ' || echo "")
      result_map["$pr_num"]="$labels"
    done
    echo "  Successfully fetched labels for ${#pr_numbers[@]} PRs"
  else
    echo "  Warning: GraphQL query failed, skipping label processing"
  fi
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

if [[ -z "${SKIP_PR_LABELS}" ]]; then
  processPRData
fi

echo "# ${REPO^} Downstream Changes" > "${OUTPUT_MARKDOWN_FILE}"
for branch in ${BRANCHES}; do
  input_yaml="${pwd}/${REPO}_${branch}.yaml"
  echo "## ${branch} branch" >> "${OUTPUT_MARKDOWN_FILE}"
  renderMarkdownTableFromYAML "${input_yaml}" >> "${OUTPUT_MARKDOWN_FILE}"
done
