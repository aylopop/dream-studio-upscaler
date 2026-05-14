# Giga Upscaler

A single-purpose upscaling app. Forge (vendored Neo fork) runs API-only;
a custom Apple-style HTML UI is served from an nginx sidecar in the same pod.
Built for Blackwell (RTX 5090, sm_120) on Kubernetes.

This is **my fork**. Forge Neo and Ultimate SD Upscale are vendored as local
source trees, not cloned at build time, because both upstreams are
unmaintained / drift-prone. The build is **mostly** reproducible from this
repo — the base image tag and a handful of optional preprocessor deps
(`fvcore`, `mediapipe`, `onnxruntime`, `svglib`, `handrefinerportable`,
`depth-anything`, `bitsandbytes>=0.49.1`) are not digest- or version-pinned.
For fully reproducible builds, pin the `FROM` line to a digest and tighten
those lines in the Dockerfile.

## What it is

- **One screen**, no tabs, no clutter.
- **Auto1111 / Forge img2img** under the hood — the same upscaling workflow
  that works reliably — but with everything that isn't upscaling stripped out.
- **Ultimate SD Upscale** script is the only generation path. Tile-based
  refinement with optional ControlNet × 3.

## Folder structure

```
.
├── Dockerfile               # Forge backend image (Blackwell-tuned, API-only)
├── Makefile                 # build / push / deploy / ui-reload / logs / shell
├── requirements.txt         # thin pip overrides on top of Forge's pins
├── .dockerignore            # tight build context filter
├── README.md
│
├── forge/                   # ← vendored Forge Neo fork (the engine)
├── ultimate-upscale/        # ← vendored Ultimate SD Upscale extension fork
│
└── frontend/                # the UI (projected into the nginx sidecar)
    ├── index.html
    ├── nginx.conf
    └── config.json          # editable defaults + saved styles
```

## Features

- Upscaler picker at the top (defaults to DAT x4 if installed).
- Prompt + negative prompt + textual-inversion chips.
- **Saved styles** — apply named prompt/negative pairs from `frontend/config.json`,
  save new ones from the UI.
- CFG (default 5), Denoise (default 0.5), Sampler picker (defaults to Euler a).
- Checkpoint + LoRA in one combined picker.
- Single large drag-and-drop image surface. The result replaces the source
  in-place — no separate preview pane.
- **ControlNet × 3** with per-unit preprocessor, model, image, weight,
  guidance start/end, pixel-perfect toggle.
- Scale slider (default ×2).
- **Advanced disclosure** (hidden): passes (a.k.a. diffusion steps), tile
  width/height, mask blur, padding, **batch input directory**.
- **Batch mode** — when Batch input is set, the UI lists the folder via the
  sidecar's `/nas/` autoindex and processes every image in sequence.
- **Editable config** — `frontend/config.json` is the source of truth for
  defaults and styles. Edit it, run `make ui-reload`, refresh.

## Build

```sh
docker build -t giga-upscaler:dev .
```

The build COPYs in `forge/` and `ultimate-upscale/` from this repo. There are
no build args. To change Forge or Ultimate Upscale, edit those folders.

`make build` builds with `:test` and `:YYYYMMDD` tags.

**`make build` puts the image in Docker's local cache**, which is not what
k3s/containerd reads from. To run a freshly-built image on the cluster you
need to either `make push` to your registry (with `imagePullPolicy: Always`,
which is the default in `deployment.yaml`) or import the tarball into
containerd on the node:

```sh
docker save aylopop/giga-upscaler:test | sudo k3s ctr images import -
```

The usual flow is `make build && make push && make deploy`.

## Deploy

The Makefile expects a `deployment.yaml` in this directory that:
1. Runs the Forge container with the image you built.
2. Runs an `nginx:1.27-alpine` sidecar consuming the `upscaler-ui-files`
   ConfigMap as `/usr/share/nginx/html` and `/etc/nginx/nginx.conf`.
3. Mounts your LoRA hostPath into the sidecar at `/loras` (read-only).
4. Mounts a "browse root" hostPath at `/nas` (read-only) — the program "home"
   for typeable batch paths.

`deployment.yaml` is where you bind all the env-specific hostPaths. Nothing
else in the project references your filesystem layout.

```sh
make deploy       # apply ConfigMap + Deployment + Service
make ui-reload    # re-project frontend/ into the sidecar (no rebuild)
make rollout      # restart the deployment (picks up a new :test image)
make logs
make shell
make status
```

To iterate on the UI: edit `frontend/{index.html,config.json,nginx.conf}`,
run `make ui-reload`, refresh.

## Volume mounts inside the Forge container

| Path                         | Contents                                          |
|------------------------------|---------------------------------------------------|
| `/opt/webui/models`          | Checkpoints, LoRAs, VAEs, ControlNet, upscalers   |
| `/opt/webui/embeddings`      | Textual inversion embeddings                      |
| `/opt/webui/outputs`         | Generated images                                  |
| `/opt/webui/config`          | Forge settings file (`config.json`)               |
| `/root/.cache/huggingface`   | HF hub cache                                      |
| `/dev/shm`                   | Bump to ≥4 GiB (k8s default 64 MiB SIGBUSes)      |

### Where each model type lives on disk

Forge picks models up from subdirs under `/opt/webui/models/`. On the host
that's `/mnt/Diffusion/Models/<subdir>/`:

| Model type                | Subdir under `models/`     | File extensions          |
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

After dropping files into any of these directories, click the **Refresh**
icon in the topbar (or run `make rollout` if the cache is being stubborn) to
re-scan disk. The refresh button calls `refresh-checkpoints`/`-loras`/`-vae`
and re-fetches the upscaler and ControlNet lists.

### Reading logs

`make logs` tails Forge live. For sharing or debugging an HTTP 500, run
`make logs-save` — it writes the last 24 hours of both containers' logs to
`./logs/giga-upscaler-<timestamp>.log`. The UI also prints the full Forge
response body to the browser DevTools console on any non-2xx response, with
the short reason mirrored into the status line.

## Editing defaults and styles

`frontend/config.json` is loaded on every page open:

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

Hitting **Save** in the UI stores the style in `localStorage` and logs the
JSON snippet to the browser console so you can paste it into `config.json` to
make it portable.

## Batch mode

The nginx sidecar exposes a `/nas/` location whose hostPath is set in
`deployment.yaml`. The **Batch input** field in the UI's Advanced section
accepts paths relative to that mount.

1. In `deployment.yaml`, bind the `nas` volume's hostPath to whatever host
   directory contains your source images.
2. In the UI, open **Advanced** and type a path into **Batch input** —
   e.g. `images/run-2024` resolves to `/nas/images/run-2024/`. Absolute paths
   (starting with `/`) pass through unchanged.
3. Hit **Upscale**. The UI lists the folder via autoindex, sends each file
   through `/sdapi/v1/img2img` with the Ultimate SD Upscale script, and Forge
   saves results to `/opt/webui/outputs` (whose hostPath you also set in
   `deployment.yaml`).

## Updating Forge / Ultimate Upscale from upstream

This is a manual operation I do every 6-12 months, or sooner if I want a
specific upstream change. Both vendored folders ship without `.git`, so the
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
`https://github.com/Coyote-A/ultimate-upscale-for-automatic1111.git` and the
`master` branch.

**Subsequent updates** are just `git fetch upstream && git merge upstream/<branch>`
in each fork folder, followed by `make build`.

If a fork's upstream becomes truly abandoned, I can swap it for a different
fork (Forge2/reForge/ersatzForge, or another Ultimate Upscale fork) without
touching anything outside that folder — the rest of the project never references
the upstream URL.

## Why these choices

- **Vendored forks, not GitHub clones.** Both upstreams have stalled in the
  past; vendoring eliminates the "build broke because someone force-pushed"
  failure mode.
- **`--nowebui --api`.** Forge's Gradio UI is dead weight when the custom
  frontend is the only consumer.

## Troubleshooting

- **`numpy.dtype size changed`** — the vendored Forge requirements still pin
  numpy 1.x somewhere. Re-check the `sed` strip in the Dockerfile and the
  override in `requirements.txt`.
- **`CUDA error: no kernel image is available`** — torch wheels lack sm_120.
  Verify with `python -c "import torch; print(torch.cuda.get_arch_list())"`.
- **`xformers` warning at startup** — expected. `--disable-xformers` is
  correct on Blackwell; native SDPA via `--use-pytorch-cross-attention` is
  faster anyway.
- **First generation slow** — torch JIT-compiles kernels per architecture.
  Persist `/root/.cache/cuda` across pod restarts to keep the cache warm.
