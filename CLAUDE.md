# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

MemFlow is a procedural-memory layer for AI agents. It captures step-by-step "how to" knowledge (SOPs, workflows) and exposes a `MemFlowManager` that can store, retrieve, plan, execute, and learn procedures. Python 3.10+, packaged with `uv`/`hatchling`.

## Commands

Dependency management uses `uv`:

```bash
uv sync                      # core deps only
uv sync --all-extras         # adds ollama, memmachine, openai client packages
```

Run tests (pytest is in the `dev` dependency group):

```bash
uv run --group dev pytest                      # full suite
uv run --group dev pytest tests/test_store.py  # single file
uv run --group dev pytest tests/test_store.py::TestEmulatedStore::test_add_and_search  # single test
uv run --group dev pytest -k "search"          # by keyword
```

Run an example (each example calls `MemFlowManager()` with no args and reads `.env`):

```bash
cp .env.example .env         # first time only — pick MEMFLOW_BACKEND and LLM_*
uv run ./examples/01_quickstart.py
```

Bring up the pgvector backend locally:

```bash
./scripts/pgvector.sh        # docker compose up of postgres+pgvector on :5433
```

Run the procedural-memory retrieval benchmark (requires cloning the external Proced_mem_bench repo first):

```bash
uv run benchmark/install_benchmark.py proced_mem_bench --commit-hash f7097bcaf6ca
uv pip install -e benchmark/proced_mem_bench/Proced_mem_bench
uv run benchmark/proced_mem_bench/run_proced_mem_bench.py
```

## Architecture

### Public surface

The single public entry point is `MemFlowManager` in `memflow/manager.py`. It re-exports through `memflow/__init__.py`. Five core methods, all on the manager:

- `add(messages | procedure, user_id)` — store a procedure (direct path) or run extraction (LLM path).
- `search(query, user_id, top_k)` — similarity retrieval against the configured store.
- `chat(message, ..., allow_execute=False)` — intent classifier → routes to SEARCH / ADD / EXECUTE / CONVERSATION handler(s); EXECUTE requires `allow_execute=True`.
- `plan(task, ..., multi_stage=False)` — decompose into a `TaskPlan` of `Step`s, retrieving relevant procedures as context first (Retrieve → Planner back-edge).
- `execute(plan, tools)` — run each step with the executor's tool registry.
- `run(task, ..., multi_stage=True)` — Retrieve → Plan → Execute → Learn end-to-end. With `multi_stage=True` (default), uses `_run_with_partial_replan` for adaptive replanning of failed steps; otherwise single-shot.

### The four-stage loop

The repo is structured around Retrieve → Plan → Execute → Learn with two back-edges:

- **Retrieve → Planner back-edge:** `plan()` and `run()` always call `search()` first and inject hits as `context` into the planning prompt so existing SOPs get reused.
- **Learn → Retrieve back-edge:** after a successful `run()`, `Learner.extract()` (in `memflow/learner.py`) distills the executed steps into a new `Procedure` and stores it via `self.store.add(...)`. That procedure becomes retrievable on the next call.

### Modules

- `memflow/manager.py` — orchestrator + the four `*Guard` dataclasses (see "Execution guards").
- `memflow/models.py` — `Procedure`, `SearchResult`, `Step`, `StepType`, `StepResult`, `TaskPlan`, `RunResult`. `StepType.PLAN` is reserved for hierarchical decomposition but **not yet implemented**; only `TOOL` steps execute.
- `memflow/store.py` — `BaseStore` + four backends: `EmulatedStore` (in-memory, word-overlap), `FileStore` (Markdown-with-frontmatter on disk), `MemMachineStore` (MemMachine VectorDB), `PgVectorStore` (Postgres + pgvector cosine search). All implement `add/search/get/delete/list_all`.
- `memflow/llm.py` — `BaseLLM`, `OllamaLLM`, `OpenAICompatibleLLM` (works for vLLM/LM Studio/etc.), `LLMFactory.create(provider, ...)`, and `parse_json()` which is the standard way to robustly parse model JSON output (strips ```json fences, recovers from extra prose).
- `memflow/planner.py` — `LLMPlanner.plan(...)`. Knows about `DEFAULT_TOOLS` (`llm`, `bash`, `http`) and supports multi-stage planning with reflection.
- `memflow/executor.py` — `ToolRegistry` with three built-in tools: `llm` (delegates to `BaseLLM`), `bash` (subprocess, 30s timeout), `http` (urllib). Custom tools registered with `register(name, fn)` receive `Step.args` as kwargs and must return a string.
- `memflow/learner.py` — `Learner.extract(task, steps, user_id)` filters to successful steps and asks the LLM for a reusable Procedure.
- `memflow/prompts.py` — all prompt templates (extraction, classification, planning, replan, learning, chat, intent). The classification prompt drives the bypass routing described below.

### Bypass routing for non-procedural memory

When `add(messages=...)` is called, the manager runs `_classify_memory_type` first. If the LLM classifies the content as `semantic` or `episodic` (not procedural), the manager forwards it to the optional `MemMachineBypass` instead of extracting a Procedure. Bypass is auto-constructed from `MEMMACHINE_*` env vars whenever the backend is `memmachine` or `pgvector`. For pgvector, the bypass shares the same `PgVectorStore` instance so all three memory types coexist in one DB.

### Execution guards

`run()` with `multi_stage=True` is governed by three guards (defined at the top of `manager.py`):

- `GlobalGuard` — caps total replan attempts (`max_attempts=5`) and detects cycles via `(goal, failure)` fingerprint hashing. Stored on the manager instance so cycle detection persists across recursive `run()` calls.
- `PlanGuard` — caps planner recursion depth (`max_depth=3`).
- `ToolGuard` — caps per-step retries (`max_retry=3`); `_execute_step_with_guard` uses it and respects `StepResult.retryable`.

Partial replan replaces only the failed step's subplan in `plan.steps`; previously successful steps are preserved.

### Configuration via `.env`

`MemFlowManager(use_env=True)` (default) calls `_load_env_file()` which uses `python-dotenv` with `override=False` (real env vars win over `.env`). Priority is **explicit constructor argument > env var > `.env` > fallback default**. The store backend is resolved either from the explicitly passed `store=` (its type is inferred) or from `MEMFLOW_BACKEND` (`emulated` | `file` | `memmachine` | `pgvector`). Tests must use the `clean_env` fixture in `tests/conftest.py` to wipe these vars *and* patch `_load_env_file` so a developer's local `.env` cannot leak into unit tests.

### Tests

Unit tests in `tests/` import `FakeLLM` from `tests/conftest.py` for deterministic responses (use `set_response()` to script a one-shot reply). The benchmark harness in `benchmark/proced_mem_bench/` is integration-style and depends on the externally cloned `Proced_mem_bench` repo (kept out of git via `.gitignore`).
