---
name: code-review-develop
description: High-effort code review for develop branch - functional, stability, security analysis
whenToUse: Full repository review of develop branch with comprehensive findings
---

# Workflow: Code Review – Develop Branch

## Overview
This script performs a high-effort, read-only code review of the `develop` branch in `F:\llama\llm-manager`. It fans out functional issues, stability, and security analysis agents, then synthesizes findings into a Markdown report.

## Parameters
- **scriptPath**: Path to this workflow script (e.g. `.claude/workflows/code-review-develop.md`)
- **args**: Not used
- **resumeFromRunId**: Not used

## Output
A Markdown report containing:
- Repository overview
- Functional issues with brief descriptions
- Stability concerns
- Security findings
- Summary with total count

## Execution Steps
1. **Graphify the repository** — use the `graphify` skill on the entire repo to generate an HTML+JSON audit and a concise summary of modules, files, and notable patterns. This establishes structural understanding.
2. **Fan out analysis agents**:
   - *Functional issues*: Examine logic, edge cases, error handling, and correctness across the codebase. Focus on the `llm-core`, `main`, and `script` directories.
   - *Stability*: Assess robustness, retry logic, resource cleanup, and failure modes.
   - *Security*: Identify auth flaws, data leaks, injection risks, and unsafe operations.
3. **Synthesize findings** — compile the outputs from the three agents into a single Markdown document with clear headings and bullet points.
4. **Return report** — the final result is the Markdown string.

## Notes
- All agents run in high effort; no code is modified.
- Use the `graphify` skill via the Skill tool before calling any agents.
- The graphify output contains a `summary` field that can be used to seed context for agents if needed.

---

# Workflow: Code Review – Develop Branch

## Overview
This script performs a high-effort, read-only code review of the develop branch in F:\llama\llm-manager. It fans out functional issues, stability, and security analysis agents, then synthesizes findings into a Markdown report.

## Parameters
- **scriptPath**: Path to this workflow script (e.g. .claude/workflows/code-review-develop.md)
- **args**: Not used
- **resumeFromRunId**: Not used

## Output
A Markdown report containing:
- Repository overview
- Functional issues with brief descriptions
- Stability concerns
- Security findings
- Summary with total count

## Execution Steps
1. **Graphify the repository** — use the graphify skill on the entire repo to generate an HTML+JSON audit and a concise summary of modules, files, and notable patterns. This establishes structural understanding.
2. **Fan out analysis agents**:
   - *Functional issues*: Examine logic, edge cases, error handling, and correctness across the codebase. Focus on the llm-core, main, and script directories.
   - *Stability*: Assess robustness, retry logic, resource cleanup, and failure modes.
   - *Security*: Identify auth flaws, data leaks, injection risks, and unsafe operations.
3. **Synthesize findings** — compile the outputs from the three agents into a single Markdown document with clear headings and bullet points.
4. **Return report** — the final result is the Markdown string.

## Notes
- All agents run in high effort; no code is modified.
- Use the graphify skill via the Skill tool before calling any agents.
- The graphify output contains a summary field that can be used to seed context for agents if needed.

---

# Workflow: Code Review – Develop Branch

## Overview
This script performs a high-effort, read-only code review of the develop branch in F:\llama\llm-manager. It fans out functional issues, stability, and security analysis agents, then synthesizes findings into a Markdown report.

## Parameters
- **scriptPath**: Path to this workflow script (e.g. .claude/workflows/code-review-develop.md)
- **args**: Not used
- **resumeFromRunId**: Not used

## Output
A Markdown report containing:
- Repository overview
- Functional issues with brief descriptions
- Stability concerns
- Security findings
- Summary with total count

## Execution Steps
1. **Graphify the repository** — use the graphify skill on the entire repo to generate an HTML+JSON audit and a concise summary of modules, files, and notable patterns. This establishes structural understanding.
2. **Fan out analysis agents**:
   - *Functional issues*: Examine logic, edge cases, error handling, and correctness across the codebase. Focus on the llm-core, main, and script directories.
   - *Stability*: Assess robustness, retry logic, resource cleanup, and failure modes.
   - *Security*: Identify auth flaws, data leaks, injection risks, and unsafe operations.
3. **Synthesize findings** — compile the outputs from the three agents into a single Markdown document with clear headings and bullet points.
4. **Return report** — the final result is the Markdown string.

## Notes
- All agents run in high effort; no code is modified.
- Use the graphify skill via the Skill tool before calling any agents.
- The graphify output contains a summary field that can be used to seed context for agents if needed.

---

# Workflow: Code Review – Develop Branch

## Overview
This script performs a high-effort, read-only code review of the develop branch in F:\llama\llm-manager. It fans out functional issues, stability, and security analysis agents, then synthesizes findings into a Markdown report.

## Parameters
- **scriptPath**: Path to this workflow script (e.g. .claude/workflows/code-review-develop.md)
- **args**: Not used
- **resumeFromRunId**: Not used

## Output
A Markdown report containing:
- Repository overview
- Functional issues with brief descriptions
- Stability concerns
- Security findings
- Summary with total count

## Execution Steps
1. **Graphify the repository** — use the graphify skill on the entire repo to generate an HTML+JSON audit and a concise summary of modules, files, and notable patterns. This establishes structural understanding.
2. **Fan out analysis agents**:
   - *Functional issues*: Examine logic, edge cases, error handling, and correctness across the codebase. Focus on the llm-core, main, and script directories.
   - *Stability*: Assess robustness, retry logic, resource cleanup, and failure modes.
   - *Security*: Identify auth flaws, data leaks, injection risks, and unsafe operations.
3. **Synthesize findings** — compile the outputs from the three agents into a single Markdown document with clear headings and bullet points.
4. **Return report** — the final result is the Markdown string.

## Notes
- All agents run in high effort; no code is modified.
- Use the graphify skill via the Skill tool before calling any agents.
- The graphify output contains a summary field that can be used to seed context for agents if needed.

---

# Workflow: Code Review – Develop Branch

## Overview
This script performs a high-effort, read-only code review of the develop branch in F:\llama\llm-manager. It fans out functional issues, stability, and security analysis agents, then synthesizes findings into a Markdown report.

## Parameters
- **scriptPath**: Path to this workflow script (e.g. .claude/workflows/code-review-develop.md)
- **args**: Not used
- **resumeFromRunId**: Not used

## Output
A Markdown report containing:
- Repository overview
- Functional issues with brief descriptions
- Stability concerns
- Security findings
- Summary with total count

## Execution Steps
1. **Graphify the repository** — use the graphify skill on the entire repo to generate an HTML+JSON audit and a concise summary of modules, files, and notable patterns. This establishes structural understanding.
2. **Fan out analysis agents**:
   - *Functional issues*: Examine logic, edge cases, error handling, and correctness across the codebase. Focus on the llm-core, main, and script directories.
   - *Stability*: Assess robustness, retry logic, resource cleanup, and failure modes.
   - *Security*: Identify auth flaws, data leaks, injection risks, and unsafe operations.
3. **Synthesize findings** — compile the outputs from the three agents into a single Markdown document with clear headings and bullet points.
4. **Return report** — the final result is the Markdown string.

## Notes
- All agents run in high effort; no code is modified.
- Use the graphify skill via the Skill tool before calling any agents.
- The graphify output contains a summary field that can be used to seed context for agents if needed.
