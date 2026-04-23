# Security

## Sensitive Data

Do not commit runtime artifacts, session logs, prompts, model responses, API keys, tokens, credentials, or private repository data.

The helper scripts may create local state under:

- `.runtime/`
- `.sessions/`

These paths are ignored by Git because they can contain task details, file paths, model output, or repository-specific context.

## Reporting Issues

If you find a security issue, please avoid posting secrets or private logs in a public issue. Open a minimal report that describes the behavior and the affected files without including credentials or private code.
