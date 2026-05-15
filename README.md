# Dream Studio Upscaler

A focused AI upscaling interface for Forge + Ultimate SD Upscale.

One screen, no tabs. Forge runs API-only; a custom HTML UI is served from
an nginx sidecar in the same pod. Built for Blackwell (RTX 5090, sm_120)
on Kubernetes.

Forge Neo and Ultimate SD Upscale are vendored as local source trees so
the build can't be broken by upstream churn. To swap to a different
fork, replace the contents of `forge/` or `ultimate-upscale/` — nothing
else in the project references the upstream URLs.

---

## The UI

A single page, organised top to bottom on narrow screens and as a
left-rail-with-drawers on wide screens.

### Main

- **Prompt** — prompt + negative prompt, textual-inversion chips,
  applied saved styles.
- **Image drop/result surface** — one large drag-and-drop area. The
  upscaled result replaces the source in-place. A source/result A/B
  compare slider opens on the same surface.

### Tuning

CFG, denoise, steps, sampler, scheduler, seed, scale, checkpoint, LoRAs.
Saved styles live here too — apply a named prompt/negative pair from
`frontend/config.json`, or save a new one from the UI.

### ControlNet

Up to three units. Per-unit preprocessor, model, image, weight,
guidance start/end, control mode. Family-mismatch and missing-model
guards run before any request hits Forge.

### Upscaler

Upscaler picker (DAT × 4 by default when installed), tile width/height,
mask blur, padding.

### Advanced

Variants, variant jitter, Dream Assist (CLIP interrogate),
batch input directory, queue panel (with pause + clear), diagnostics,
Forge state inspector, debug log download.

**Batch mode**: type a path into Batch input (resolves under the
sidecar's `/nas/` mount), hit Upscale, the UI lists the folder via
nginx autoindex and processes every image. Combine with Variants > 1
for N runs per file.

---

## Configuration

`frontend/config.json` is the source of truth for defaults and saved
styles. Edit it, run `make ui-reload`, refresh.

```json
{
  "defaults": {
    "cfg": 5,
    "denoise": 0.5,
    "steps": 30,
    "scale": 2,
    "tile_width": 1408,
    "tile_height": 1408,
    "mask_blur": 8,
    "padding": 32,
    "upscaler_preferred": "DAT x4",
    "sampler_preferred": "Euler a"
  },
  "styles": [
    { "name": "Photoreal detail", "prompt": "...", "negative": "..." }
  ]
}
```

Saving a style in the UI persists it to `localStorage` and logs the
JSON snippet to the browser console so it can be pasted back into
`config.json` to make it portable.

---

## Build

```sh
docker build -t dream-studio-upscaler:dev .
```

The build COPYs `forge/` and `ultimate-upscale/` from this repo. No
build args. To change either, edit the folders.

`make build` builds with `:test` and `:YYYYMMDD` tags.

`make build` only puts the image in Docker's local cache — k3s/containerd
reads from its own store. To run a freshly-built image on the cluster,
either `make push` to your registry (with `imagePullPolicy: Always`,
the default in `deployment.yaml`) or import the tarball into containerd
on the node:

```sh
docker save aylopop/dream-studio-upscaler:test | sudo k3s ctr images import -
```

Typical flow: `make build && make push && make deploy`.

---

## Deploy

`deployment.yaml` describes a single pod with two containers:

- **`forgeui`** — Forge backend on `:7860`. ~11 GB image, cold start
  takes minutes; the startup probe has a long grace window on purpose.
- **`upscaler-ui`** — `nginx:1.27-alpine` sidecar on `:80`, serves
  `frontend/` from the `upscaler-ui-files` ConfigMap.

Pod is `2/2` only when both pass probes (`1/2` typically means Forge is
still loading; `0/2` means neither container is ready yet).

```sh
make deploy       # apply ConfigMap + Deployment + Service
make ui-reload    # re-project frontend/ into the sidecar (no rebuild)
make rollout      # restart the deployment (picks up a new :test image)
make logs
make logs-save    # dump last 24h of both containers to ./logs/
make shell
make status
```

To iterate on the UI only: edit `frontend/{index.html,config.json,nginx.conf}`,
run `make ui-reload`, refresh.

---

## Volume mounts

Inside the Forge container:

| Path                         | Contents                                          |
|------------------------------|---------------------------------------------------|
| `/opt/webui/models`          | Checkpoints, LoRAs, VAEs, ControlNet, upscalers   |
| `/opt/webui/embeddings`      | Textual inversion embeddings                      |
| `/opt/webui/outputs`         | Generated images                                  |
| `/opt/webui/config`          | Forge settings file (`config.json`)               |
| `/root/.cache/huggingface`   | HF hub cache                                      |
| `/dev/shm`                   | Bump to ≥4 GiB (k8s default 64 MiB SIGBUSes)      |

Forge picks model files up from subdirs under `/opt/webui/models/`:

| Model type                | Subdir under `models/`     | Extensions               |
|---------------------------|----------------------------|--------------------------|
| Checkpoint (SD/SDXL/etc.) | `Stable-diffusion/`        | `.safetensors`, `.ckpt`  |
| LoRA                      | `Lora/`                    | `.safetensors`, `.pt`    |
| VAE                       | `VAE/`                     | `.safetensors`, `.pt`    |
| ControlNet                | `ControlNet/`              | `.safetensors`, `.pth`   |
| Upscaler — ESRGAN family  | `ESRGAN/`                  | `.pth`, `.safetensors`   |
| Upscaler — DAT            | `DAT/`                     | `.pth`, `.safetensors`   |
| Upscaler — SwinIR         | `SwinIR/`                  | `.pth`                   |
| Upscaler — HAT            | `HAT/`                     | `.pth`                   |
| Upscaler — RealESRGAN     | `RealESRGAN/`              | `.pth`                   |
| Textual inversion         | `embeddings/` (top-level)  | `.safetensors`, `.pt`    |

After dropping files into any of these, click the **Refresh** icon in
the topbar (or `make rollout` if the cache is being stubborn).

The nginx sidecar exposes two read-only mounts that drive the UI:

- `/loras` — LoRA browsing for the picker.
- `/nas` — the program "home" for typeable batch paths. Bind its
  hostPath in `deployment.yaml` to whatever directory holds your
  source images.

---

## Updating Forge / Ultimate Upscale from upstream

Manual operation, done every 6–12 months or when a specific upstream
change is needed. Both vendored folders ship without `.git`, so the
first sync also initializes git history.

```sh
# First-time setup, per fork:
cd forge
git init
git remote add upstream https://github.com/Haoming02/sd-webui-forge-classic.git
git add -A && git commit -m "vendored snapshot"
git fetch upstream
git merge upstream/neo --allow-unrelated-histories
# resolve any conflicts, then:
cd ..
make build
```

Same pattern for `ultimate-upscale/` with
`https://github.com/Coyote-A/ultimate-upscale-for-automatic1111.git`
and the `master` branch.

Subsequent updates: `git fetch upstream && git merge upstream/<branch>`
in each fork folder, then `make build`.

If a fork's upstream becomes truly abandoned, swap it for a different
fork (Forge2 / reForge / ersatzForge, or another Ultimate Upscale
fork) without touching anything outside that folder.

---

## Troubleshooting

- **`numpy.dtype size changed`** — the vendored Forge requirements
  still pin numpy 1.x somewhere. Re-check the `sed` strip in the
  Dockerfile and the override in `requirements.txt`.
- **`CUDA error: no kernel image is available`** — torch wheels lack
  sm_120. Verify with
  `python -c "import torch; print(torch.cuda.get_arch_list())"`.
- **`xformers` warning at startup** — expected. `--disable-xformers`
  is correct on Blackwell; native SDPA via
  `--use-pytorch-cross-attention` is faster anyway.
- **First generation slow** — torch JIT-compiles kernels per
  architecture. Persist `/root/.cache/cuda` across pod restarts to
  keep the cache warm.
- **Old pod stuck `Terminating`, new pod `Pending`** — GPU device
  plugin not releasing on rolling update. Force-delete the wedged pod
  (`kubectl delete pod <name> --force --grace-period=0`); the durable
  fix is `strategy: { type: Recreate }` on the Deployment so the old
  pod is gone before the new one is scheduled.
