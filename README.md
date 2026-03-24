# Downstream Changes Tracking

This repository contains tools for tracking and documenting differences between the upstream [istio/istio](https://github.com/istio/istio) repository and the midstream [openshift-service-mesh/istio](https://github.com/openshift-service-mesh/istio) repository.

## Purpose

The `downstream-changes/update.sh` script automatically:

1. **Identifies midstream-only commits** - Finds commits that exist in the midstream repository but not in the upstream repository across multiple release branches
2. **Discovers PR associations** - Links commits to their corresponding Pull Requests using GitHub APIs
3. **Classifies changes as permanent or temporary** - Uses PR labels to determine if changes should be permanently maintained or eventually upstreamed
4. **Generates documentation** - Creates a comprehensive markdown report showing all midstream changes with their metadata

This helps the OpenShift Service Mesh team track which changes are intentionally divergent from upstream and which are temporary patches awaiting upstream contribution.

## Workflow

The script follows these main steps:

### 1. Find Midstream-Only Commits
Compares upstream and midstream repositories to identify commits that exist only in the midstream branches.

### 2. Link Commits to Pull Requests
Automatically discovers which Pull Request each commit came from using GitHub's API.

### 3. Classify Changes by Labels
Reads PR labels to classify changes into three mutually exclusive categories:
- **permanent-change**: Downstream-only commits that should be cherry-picked to all new release branches
- **no-permanent-change**: Downstream-only commits that should NOT be cherry-picked to new release branches
- **pending-upstream-sync**: Commits that were merged to upstream and backported, but not yet synced downstream. These are manually cherry-picked to existing branches. For new release branches, the cherry-pick automation checks if the commit already exists (synced from upstream) and excludes it if found.

**Note**: The `update.sh` script only tracks these labels in the YAML files. The actual upstream checking and label removal happens in separate cherry-pick automation.

### 4. Generate Documentation
Creates a markdown report with tables showing all midstream changes, their status, and relevant metadata.

## Configuration

The script supports extensive configuration through environment variables:

### Flow Control
```bash
SKIP_GIT=1                    # Skip git operations (use existing YAML files)
SKIP_PR_DISCOVERY=1           # Skip automatic PR number discovery
SKIP_PR_LABELS=1              # Skip PR label processing
```

### Repository Configuration
```bash
UPSTREAM_CLONE_URL="https://github.com/istio/istio.git"                    # Upstream repository URL
MIDSTREAM_CLONE_URL="https://github.com/openshift-service-mesh/istio.git"  # midstream repository URL
BRANCHES="master release-1.24 release-1.26 release-1.27 release-1.28"      # Branches to analyze
```

### Label Configuration
```bash
LABEL_PERMANENT="permanent-change"              # Label for commits that should be cherry-picked to all new releases
LABEL_NON_PERMANENT="no-permanent-change"       # Label for commits that should NOT be cherry-picked
LABEL_PENDING_UPSTREAM="pending-upstream-sync"  # Label for commits awaiting upstream synchronization
```

## Usage

### Local Execution
```bash
# Full update (git clone + PR discovery + label processing + markdown generation)
make update

# Generate markdown from existing YAML files (skip git operations)
make gen

# Check if files need updating (useful in CI)
make gen-check
```

### Custom Configuration
```bash
# Analyze different branches
BRANCHES="master release-1.25" make update

# Skip PR discovery for faster execution
SKIP_PR_DISCOVERY=1 make gen
```

## Output

The script generates several files:

- `istio.md` - Main markdown report with tables for each branch
- `istio_master.yaml` - YAML data for master branch commits
- `istio_release-X.XX.yaml` - YAML data for each release branch

### YAML Structure
```yaml
commits:
  - sha: "abc123..."
    title: "Fix bug in component (#123)"
    author: "Developer Name"
    date: "2024-03-08 10:30:00 +0000"
    found: true
    isPermanent: true                # Set when PR has "permanent-change" label
    isPendingUpstreamSync: true      # Set when PR has "pending-upstream-sync" label
    upstreamPR: "456"
    comment: "This change is specific to OpenShift"
```

**Note**: Each commit should have only ONE classification field set (`isPermanent` or `isPendingUpstreamSync`). These correspond to mutually exclusive PR labels.
