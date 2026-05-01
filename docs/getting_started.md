# Getting Started with MemFlow

The first thing to know: **`docker compose` is only needed for the pgvector backend.** If you pick `emulated` or `file`, you skip Docker entirely. Choose your backend first, then wire up the LLM, then (only if needed) bring up Docker.

## 1. What MemFlow needs, regardless of backend

Every path needs an **LLM provider**. The classifier, planner, executor, and learner all call it. Two options, set in `.env`:

| Provider | What you run | `.env` lines |
|---|---|---|
| **Ollama** (easiest local) | `ollama serve` + `ollama pull llama3.2` | `LLM_PROVIDER=ollama`<br>`LLM_MODEL=llama3.2`<br>`LLM_API_BASE=http://localhost:11434` |
| **OpenAI-compatible** (vLLM / LM Studio / hosted) | A server speaking the OpenAI chat-completions API | `LLM_PROVIDER=openai-compatible`<br>`LLM_MODEL=<your-model>`<br>`LLM_API_BASE=http://localhost:8000/v1`<br>`LLM_API_KEY=<key or EMPTY>` |

Setup is the same regardless:

```bash
cp .env.example .env       # then edit it
uv sync --all-extras       # installs ollama + openai + memmachine clients
```

## 2. Pick a backend — three on-ramps

### A. Easiest — `emulated` (in-memory; no Docker, no persistence)

```ini
# .env
MEMFLOW_BACKEND=emulated
```

Run an example. That's it.

### B. `file` (persists to local Markdown files; no Docker)

```ini
# .env
MEMFLOW_BACKEND=file
MEMFLOW_FILE_DIR=./file_data
```

Procedures are written one-per-file as Markdown with frontmatter. Survives process restarts. No external services.

### C. `pgvector` (real semantic search; this is when you need `docker compose`)

This backend needs **two** external services — Postgres and a separate embedding server. The docker-compose file only provides the first.

```ini
# .env  (lines that matter for pgvector)
MEMFLOW_BACKEND=pgvector
PGVECTOR_BASE_URL=postgresql://pgvector:pgvector_password@localhost:5433/pgvector

# Embedding server — NOT bundled in docker-compose, you stand this up yourself
PGVECTOR_EMBEDDING_API_BASE=http://localhost:8001/v1   # required
PGVECTOR_EMBEDDING_MODEL=Qwen/Qwen3-Embedding-4B
PGVECTOR_EMBEDDING_API_KEY=EMPTY
PGVECTOR_EMBEDDING_DIMENSIONS=2560
```

**Before** `docker compose`:
1. Edit `.env` (above).
2. Stand up an OpenAI-compatible embedding endpoint at `PGVECTOR_EMBEDDING_API_BASE`. Typical choice: `vllm serve Qwen/Qwen3-Embedding-4B --port 8001`. Any OpenAI-compatible `/v1/embeddings` server works — match `PGVECTOR_EMBEDDING_DIMENSIONS` to the model.
3. Make sure your **LLM provider** from §1 is also up.

**Bring up Postgres+pgvector:**

```bash
./scripts/pgvector.sh      # docker compose up of pgvector/pgvector:pg16 on :5433
```

That script is just a wrapper around `docker compose -f scripts/docker-compose.pgvector.yml up -d`. Data persists in `./postgres_data/`. Defaults (DB/user/password/port) are overridable via env vars in the compose file.

## 3. After it's up — how to interact

There's no server, no CLI, no REST endpoint — MemFlow is a **Python library**. "Interaction" means importing `MemFlowManager` and calling its five methods. Two equivalent ways:

### Run a bundled example

```bash
uv run ./examples/01_quickstart.py    # store one procedure, ask about it
uv run ./examples/06_file_persistence.py
uv run ./examples/10_run.py           # full plan/execute/learn loop
```

Examples 01–14 walk through every method; each is self-contained and reads your `.env`.

### Write your own script

```python
from memflow import MemFlowManager, Procedure

m = MemFlowManager()                         # reads .env automatically

m.add(procedure=Procedure(
    title="Deploy service",
    content="1. Run tests\n2. Build image\n3. kubectl apply",
))

hits = m.search("how do I ship a service")   # similarity retrieval
reply = m.chat("walk me through deployment") # intent-routed answer
plan = m.plan("Deploy the staging service")  # decompose into Steps
result = m.run("Deploy the staging service") # plan + execute + learn
```

The full surface is `add` / `search` / `chat` / `plan` / `execute` / `run`, all on `MemFlowManager`.

## TL;DR decision tree

```
Need persistence?
├─ No  → emulated      (no Docker, no extra services)
├─ Yes, simple → file  (no Docker, just a directory)
└─ Yes, semantic search → pgvector
                          requires:  docker compose (Postgres+pgvector)
                                  +  separate embedding server (e.g. vLLM)
                                  +  LLM provider
```

Then `cp .env.example .env`, edit, `uv sync --all-extras`, and `uv run ./examples/01_quickstart.py`.
