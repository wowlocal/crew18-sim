# Crew 18 infrastructure

[Architecture, local setup and API contracts](../docs/infrastructure.md).

- `control-plane/`: FastAPI, SQLite queue, artifact validation, CLI, tests and OpenAPI.
- `deploy/`: Linux VPS Docker Compose, HTTPS gateway and encrypted tunnel templates.
- `examples/`: technical pilot case, participant answer and workflow caller template.

The participant saves an idea and explicitly commands the agent to run.
Generation workers, GitHub dispatch and the participant UI are integrations to connect next.
