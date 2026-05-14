# Forge / USDU patches owned by this project

The `forge/` and `ultimate-upscale/` trees are vendored forks. We own a
handful of patches on top of upstream — list them here so a future Forge
Neo or USDU upgrade can re-apply them cleanly.

## 1. DAT upscaler scanner (new file)

**Why**: Forge Neo's `UpscalerESRGAN` only walks `models/ESRGAN/`. DAT
weights in `models/DAT/` (e.g. `DAT_x4.pth`) never register, even though
Spandrel loads DAT correctly when given the file.

**Files**:
- `forge/modules/dat_model.py` (new) — `UpscalerDAT` class subclassing
  `UpscalerESRGAN`, scoped to its own dir, drops the ESRGAN URL fallback.
- `forge/modules/cmd_args.py` — added `--dat-models-path` flag (default
  `models/DAT/`).
- `forge/modules/modelloader.py:load_upscalers` — instantiates
  `UpscalerDAT`, merges its scalers into `shared.sd_upscalers`
  alphabetically with ESRGAN's.

## 2. USDU outer-loop interrupt early-exit (7 sites)

**Why**: Upstream USDU only `break`s the inner tile loop on
`state.interrupted`. The outer loop kept iterating (re-checking on each
row), so interrupt latency was O(rows) instead of O(1). Frontend cancel
button felt sluggish.

**File**: `ultimate-upscale/scripts/ultimate-upscale.py`

**Sites patched** (add `if state.interrupted: break` at top of outer loop):
- `linear_process` (~L173)
- `chess_process` color calc (~L195)
- `chess_process` first pass (~L206)
- `chess_process` second pass (~L222)
- `half_tile_process` row pass (~L277)
- `half_tile_process` col pass (~L294)
- `half_tile_process_corners` (~L329)

## 3. `set_config` refresh=True for `sd_model_checkpoint`

**Why**: `override_settings.sd_model_checkpoint` was silently failing to
actually load the new model. `sysinfo.set_config` called
`main_entry.checkpoint_change(refresh=False)`, which updates `opts.data`
but skips `refresh_model_loading_parameters`. The next
`manage_model_and_prompt_cache` reads stale `forge_loading_parameters`
and keeps the old model in VRAM, even though `opts.data` reads the new
checkpoint name. Classic "GUI says A, Forge has B" bug at the deepest
layer.

**File**: `forge/modules/sysinfo.py:225` — flipped `refresh=False` to
`refresh=True`.

## 4. Vendored `/sdapi/v1/interrogate` endpoint

**Why**: Forge Neo dropped upstream's CLIP/BLIP interrogator. We need it
for the frontend Auto-prompt feature.

**Files**:
- `forge/modules/interrogate_neo.py` (new) — thin wrapper around the
  `clip-interrogator` pip package (BLIP for caption candidates, CLIP for
  scoring). Lazy-imported so Forge startup doesn't pay the cost unless
  the endpoint actually fires.
- `forge/modules/api/api.py`:
  - Route registration after `/sdapi/v1/extensions`.
  - `interrogateapi(req: dict)` method that delegates to
    `interrogate_neo.interrogate(...)` and returns
    `{"caption": "...", "error": "..."}`.

**Dockerfile dep**: `RUN uv pip install --system "clip-interrogator==0.6.0"`.

(Aside) **sageattention is pinned to git tag `v2.2.0`** in the Dockerfile.
PyPI only carries the 1.0.x series (no Blackwell support); the 2.x branch
lives on GitHub only. v2.2.0 (Oct 2025) is the first release that compiles
sm_120 cleanly for SageAttention2++ kernels.

Build flags worth knowing:
- `--no-build-isolation` — sage's setup.py imports torch at build time to
  read CUDA version + arch list. Without this flag uv would build in an
  isolated env with a different torch and clobber our 2.7.0+cu128 pin.
- Fallback `xformers` is installed with `--no-deps`. Its wheel pulls in
  torch 2.12 + the cu13 stack, which would destroy our cu128/sm_120
  pinning. `--no-deps` keeps only the xformers package itself.
- Sentinel file lives at `/opt/.sage_fallback_xformers` (NOT `/opt/webui/`
  — that path doesn't exist at the sage-build stage). CMD reads it to
  decide between `--sage` and `--xformers`.

If a future sage release breaks our build, bump the git tag only after
confirming the new tag compiles for sm_120 (the fallback catches failure
but a silent downgrade to xformers loses ~2× attention perf).

**Cache layout**:
- BLIP weights → HF cache (`/root/.cache/huggingface/`, NAS-backed via
  `hf-cache` mount).
- CLIP weights → torch hub cache (`/root/.cache/torch/`, NAS-backed via
  `torch-cache` mount).
- clip-interrogator prompt embeddings → `/root/.cache/clip-interrogator/`
  (NAS-backed via `ci-cache` mount).

## Upgrade procedure

When pulling a fresh upstream Forge Neo:

1. Diff the new vendored tree against the patch points above.
2. For each conflict:
   - **DAT loader**: check `forge/modules/modelloader.py:load_upscalers`
     still has the same shape. Re-apply the `UpscalerDAT` registration.
   - **USDU interrupt**: re-grep upstream `ultimate-upscale.py` for the
     7 `if state.interrupted: break` sites, re-add the outer-loop
     checks if they're still missing.
   - **sysinfo.set_config**: confirm the `refresh=False` argument is
     still at the same call site; flip to `refresh=True`.
   - **interrogate route**: confirm the api.py method registration still
     works; the import + endpoint shape are independent of Forge
     internals.
3. Rebuild: `make build && make deploy`.
4. Verify: `make logs-attention` shows the picked attention backend;
   first run with auto-prompt on succeeds; checkpoint switch via
   `override_settings.sd_model_checkpoint` actually changes the loaded
   model (visible in the resulting PNG metadata `Model: ...` field).
