# GitHub Repository Integration — Plan Document

**Status:** Proof of concept validated  
**Created:** April 1, 2026  
**Repository:** https://github.com/tnjazzgrass/xFACts

---

## Problem Statement

The current workflow for providing Claude with platform context requires uploading all documentation files to the Project Knowledge section of each Claude Project before every session. This approach has several limitations:

- **Storage limits** — Project Knowledge has finite storage; the full documentation set pushes against this limit
- **Flat structure** — all files dumped into a single directory with no folder organization
- **Manual process** — files must be cleared and re-uploaded each time content changes
- **No version awareness** — no way to tell which files changed vs which are unchanged
- **Redundancy** — stable reference files that rarely change are re-uploaded alongside active working documents

---

## What Was Validated (April 1, 2026)

### Public Repository Access
- Created public GitHub repository at `https://github.com/tnjazzgrass/xFACts`
- Claude can fetch and read file contents via `web_fetch` tool using direct file URLs
- Full folder structures are supported and navigable (e.g., `xFACts-ControlCenter/public/docs/pages/backup.html`)
- File content renders cleanly — HTML, Markdown, PowerShell all readable

### Private Repository Access
- Switching repo to private blocks Claude's access completely
- `web_fetch` cannot authenticate to private repos
- **Conclusion:** public repo is required for this workflow

### Caching Behavior
- GitHub CDN caches the repo root listing page aggressively — new files may not appear in the directory listing immediately
- Individual file URLs are NOT affected by this cache — newly committed files are accessible immediately via direct URL
- **Mitigation:** use direct file URLs rather than directory browsing; build a manifest file that lists all current files

### Current Repo State
- Full xFACts directory structure replicated manually via GitHub web interface
- All operational files (scripts, routes, APIs, JS, CSS, HTML docs) uploaded
- Documentation/reference markdown files not yet uploaded (next step)

---

## Proposed Architecture

### Repository Structure
Mirror the actual server directory layout:

```
xFACts/
├── manifest.json                          ← auto-generated file listing with timestamps
├── xFACts-PowerShell/
│   ├── scripts/
│   │   ├── collectors/                    ← Collect-*.ps1 scripts
│   │   ├── orchestrator/                  ← Orchestrator engine and functions
│   │   ├── utilities/                     ← Utility scripts
│   │   └── dmops/                         ← DmOps archive/purge scripts
│   └── modules/                           ← PowerShell modules
├── xFACts-ControlCenter/
│   ├── scripts/routes/                    ← Route files and API files
│   ├── public/
│   │   ├── js/                            ← Client-side JavaScript
│   │   ├── css/                           ← Stylesheets
│   │   └── docs/                          ← Documentation site (HTML, CSS, JS)
│   └── modules/                           ← CC helper modules
├── docs/                                  ← Working documents, reference docs, guidelines
│   ├── xFACts_Development_Guidelines.md
│   ├── xFACts_Platform_Registry.md
│   ├── xFACts_Engine_Room_Ref.md
│   ├── BDL_Import_Working_Document.md
│   ├── DmOps_Working_Document.md
│   └── ...
└── config/                                ← Configuration files (server.psd1, etc.)
```

### Manifest File
An auto-generated `manifest.json` at the repo root listing all files with metadata:

```json
{
  "generated": "2026-04-01T17:30:00Z",
  "file_count": 142,
  "files": [
    {
      "path": "docs/xFACts_Development_Guidelines.md",
      "size": 45230,
      "modified": "2026-04-01T15:00:00Z"
    },
    {
      "path": "xFACts-ControlCenter/scripts/routes/BDLImport-API.ps1",
      "size": 18400,
      "modified": "2026-04-01T16:45:00Z"
    }
  ]
}
```

This serves two purposes:
1. Claude can fetch the manifest at the start of a session to know what's available without browsing directories (bypasses CDN caching on directory listings)
2. Timestamps indicate which files have changed since the last session

### Automated Push Script
Extend the existing documentation pipeline (`Publish-ConfluenceDocumentation.ps1` or a new companion script) to push files to GitHub after generating them.

**Requirements:**
- Git client installed on FA-SQLDBB (or the server running the pipeline)
- GitHub Personal Access Token (PAT) for authentication — stored in `dbo.Credentials`
- Outbound HTTPS access to `github.com` from the pipeline server (coordinate with IT Ops)

**Push workflow:**
1. Existing pipeline generates files into the Upload directory (unchanged)
2. New step: sync Upload directory contents to local git repo clone
3. Generate `manifest.json` from file listing
4. Commit and push to GitHub
5. Files are immediately available to Claude via direct URLs

**Alternative if git client is not feasible:**
- Use GitHub's REST API directly from PowerShell (`Invoke-RestMethod`)
- No git installation required
- Push files individually via the Contents API: `PUT /repos/{owner}/{repo}/contents/{path}`
- More HTTP calls but zero local tooling dependencies

---

## Session Workflow (Future State)

### Start of Session
1. Claude fetches `manifest.json` from GitHub to see current file inventory
2. Based on the session topic, Claude fetches the relevant files on demand
3. Working documents and active scripts fetched as needed throughout the session
4. No Project Knowledge uploads required (or minimal — just the 1-2 most critical files)

### During Session
- Claude references files by fetching from GitHub as needed
- Files actively being modified are still uploaded per-chat for editing (Claude cannot write to GitHub)
- Updated files are deployed to the server by Dirk as usual

### End of Session
- Dirk runs the push script to sync current server state to GitHub
- Updated files (including any modified during the session) are pushed
- Manifest regenerated with current timestamps
- Next session starts with current content automatically

---

## Implementation Steps

### Phase 1: Manual Upload + Manifest (Immediate)
1. Upload remaining documentation files (markdown reference docs, working documents) to GitHub via web interface
2. Organize into the folder structure defined above
3. Create `manifest.json` manually (or via a quick PowerShell script run locally)
4. Test the full workflow in the next Claude session — fetch manifest, fetch files on demand
5. Evaluate whether Project Knowledge can be reduced to just the working document(s)

### Phase 2: Automated Push via GitHub API (Next Build Session)
1. Investigate outbound HTTPS access from FA-SQLDBB to github.com
2. Create GitHub PAT and store in `dbo.Credentials`
3. Build `Publish-GitHubRepository.ps1`:
   - Reads file list from Upload directory (or configured source directories)
   - Generates `manifest.json`
   - Pushes files to GitHub via REST API (`PUT /repos/tnjazzgrass/xFACts/contents/{path}`)
   - Handles create vs update (API requires the file's current SHA for updates)
4. Integrate into Admin page as a button or add to existing documentation pipeline
5. Test end-to-end: modify file → run push → verify Claude can see updated content

### Phase 3: Full Integration (Future)
- Add push step to the existing `Publish-ConfluenceDocumentation.ps1` pipeline
- Automatic push after every documentation generation cycle
- Consider GitHub Actions for automated validation (optional)
- Evaluate whether working documents should also live in GitHub as the primary copy

---

## Security Considerations

- **No PII/PHI in repository** — all content is platform architecture, code, and operational documentation
- **Public repository required** — Claude cannot access private repos. Content is internal tooling docs with no sensitive data.
- **GitHub PAT storage** — stored in `dbo.Credentials` with the same encryption as other service credentials
- **Repository discoverability** — the repo name and GitHub username do not reveal company identity or sensitive information. The repo would not appear in search results unless specifically searched for.
- **No credentials in code** — connection strings, API keys, passwords are never included in pushed files. The push script must explicitly exclude any files containing credentials.

---

## Benefits

| Current Process | Future Process |
|----------------|----------------|
| Upload 100+ files to Project Knowledge before each session | Fetch only what's needed on demand |
| Flat file dump, no organization | Full folder structure mirroring server layout |
| No version awareness | Manifest with timestamps shows what changed |
| Manual clear-and-reupload cycle | Automated push from server |
| Storage limits constrain what can be provided | No practical storage limits on GitHub |
| Files only available within Claude Projects | Files accessible from any Claude conversation |

---

## Open Questions

1. **Outbound access:** Can FA-SQLDBB (or the pipeline server) make outbound HTTPS calls to github.com? Need to coordinate with IT Ops / Shawn.
2. **Git vs API:** Should we install git on the server for a native push, or use the GitHub REST API from PowerShell? API approach has zero tooling dependencies but more complexity.
3. **Push trigger:** Should the GitHub push be part of the existing documentation pipeline, a separate Admin page button, or both?
4. **File scope:** Should we push ALL platform files (scripts, routes, CSS, JS, HTML) or just the documentation/reference files? Full mirror is more useful but larger.
5. **Exclusion list:** Which files or directories should be explicitly excluded from the push (credentials, config with sensitive values, temporary files)?
