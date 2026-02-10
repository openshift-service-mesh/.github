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

if [[ -z "${SKIP_GIT}" ]]; then
  updateGit
fi

echo "# ${REPO^} Downstream Changes" > "${OUTPUT_MARKDOWN_FILE}"
for branch in ${BRANCHES}; do
  input_yaml="${pwd}/${REPO}_${branch}.yaml"
  echo "## ${branch} branch" >> "${OUTPUT_MARKDOWN_FILE}"
  renderMarkdownTableFromYAML "${input_yaml}" >> "${OUTPUT_MARKDOWN_FILE}"
done
