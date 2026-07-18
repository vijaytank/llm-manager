# Contributing to LLM Manager

Thank you for your interest in contributing to LLM Manager! To maintain code quality, security, and portability, please follow the guidelines outlined below.

---

## 1. Commit Message Convention
We enforce the **Conventional Commits** specification. Commit messages must be structured as follows:

```
<type>(<scope>): <description>

[optional body]
```

### Approved Types
* **`feat`**: A new feature or configuration setting (e.g. `feat(router): add custom parameter support`)
* **`fix`**: A bug fix (e.g. `fix(setup): strip quotes from pasted paths`)
* **`docs`**: Changes to documentation (e.g. `docs(guide): update client instructions`)
* **`refactor`**: Code restructuring without changing behavior (e.g. `refactor(path): resolve paths relative to PSScriptRoot`)
* **`test`**: Adding or correcting tests (e.g. `test(health): add ast parser syntax tests`)
* **`chore`**: Maintenance tasks, dependencies, or git ignores (e.g. `chore(git): ignore system logs`)

---

## 2. Pull Request & Merging Rules
* **No Hardcoded Absolute Paths**: All file paths must be dynamically resolved relative to `$PSScriptRoot` or loaded configurations. Never hardcode absolute drives like `C:\` or `F:\`.
* **Privacy & Credentials**: Ensure no personal system profiles (`docs\SYSTEM_COMMANDS.md`), credentials, private API keys, or active presets (`llo-config.json`, `models-preset.ini`) are added to the pull request.
* **Mandatory Testing**: Before submitting a PR, you must run the health verification script:
  ```powershell
  powershell -File script\test-health.ps1
  ```
  Pull requests with failing syntax, broken JSON configurations, or invalid hardware profilers will be automatically blocked.
* **Target Branch**: Submit all pull requests to the `master` branch (or `main` depending on your repository's primary branch).

---

## 3. Getting Help
* If you have setup questions, please refer to [USER_GUIDE.md](USER_GUIDE.md).
* If you want to check internal optimizations, check [ARCHITECTURE.md](ARCHITECTURE.md).
* For support, suggestions, or ideas, please visit the **GitHub Discussions** tab.
