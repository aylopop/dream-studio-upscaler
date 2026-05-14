# syntax=docker/dockerfile:1.7
#
# Dream Studio Upscaler — Forge Neo backend for Blackwell (RTX 5090 / sm_120).
# Pair with the nginx sidecar that serves frontend/ and proxies the REST API.
#
# Forge Neo and Ultimate SD Upscale are vendored under ./forge/ and
# ./ultimate-upscale/. Upstreams are unmaintained / drift-prone; we own the
# source. See README for how to pull fresh upstream snapshots manually.

FROM pytorch/pytorch:2.7.0-cuda12.8-cudnn9-devel

# Pin to a digest in prod: `docker inspect --format='{{index .RepoDigests 0}}' ...`

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    TORCH_CUDA_KERNEL_CACHE=/root/.cache/torch/kernels \
    CUDA_CACHE_PATH=/root/.cache/cuda \
    CUDA_CACHE_MAXSIZE=2147483648 \
    CUDA_CACHE_DISABLE=0 \
    HF_HOME=/root/.cache/huggingface \
    HUGGINGFACE_HUB_CACHE=/root/.cache/huggingface/hub \
    TRANSFORMERS_CACHE=/root/.cache/huggingface/transformers \
    TORCH_HOME=/root/.cache/torch \
    # Compute capability for the target hardware. RTX 5090 = Blackwell
    # consumer = sm_120 → "12.0" in PyTorch's TORCH_CUDA_ARCH_LIST format.
    # sageattention's setup.py reads this when no GPU is present at build
    # time (Docker build containers don't see the host GPU); without it
    # sage errors "No target compute capabilities". Doesn't affect runtime
    # — torch picks the actual arch at first use.
    TORCH_CUDA_ARCH_LIST=12.0

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ffmpeg libglib2.0-0 libsm6 libxext6 libxrender-dev \
        libcairo2 libcairo2-dev pkg-config \
        python3-dev gcc build-essential \
        curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --upgrade \
        pip==25.1.1 setuptools==75.1.0 wheel==0.45.1 uv==0.5.18

# Conda libsqlite >= 3.49 has an ABI change diskcache trips over on py3.11.
RUN conda install -y -n base "sqlite<3.49" "libsqlite<3.49" && conda clean -afy

# cu128 wheels carry sm_120 kernels for Blackwell.
RUN uv pip install --system \
        torch==2.7.0+cu128 torchvision==0.22.0+cu128 torchaudio==2.7.0+cu128 \
        --index-url https://download.pytorch.org/whl/cu128

# bitsandbytes 0.49.1 = first release with Blackwell sm_120 kernels.
RUN uv pip install --system \
        torchdiffeq==0.2.5 torchsde==0.2.6 joblib==1.5.3 "bitsandbytes>=0.49.1"

# sageattention — fastest attention backend Forge supports (~2× pytorch
# SDPA). Compiles native CUDA kernels for sm_120 (Blackwell).
#
# Version pinning notes:
#   - PyPI only carries 1.0.x (Nov 2024, no Blackwell support).
#   - 2.x lives on GitHub only — install from a tag for reproducibility.
#   - v2.2.0 (Oct 2025) is the first release that compiles sm_120 cleanly
#     for SageAttention2++ kernels. See PATCHES.md for upgrade procedure.
#
# `--no-build-isolation` is required: sage's setup.py imports torch to
# read CUDA version + arch list, and an isolated build environment would
# reinstall a different torch and clobber our 2.7.0+cu128 pin.
#
# Fallback flags (xformers) are intentionally restrictive:
#   - `--no-deps`: xformers's wheel pulls a different torch (2.12 + cu13
#     stack) which destroys the cu128/sm_120 build. We already have a
#     compatible torch installed; just take xformers itself.
#   - sentinel lands in /opt (writeable, exists, NOT wiped by the /tmp
#     cleanup near the end of the Dockerfile) so the CMD layer can
#     detect the fallback. /opt/webui doesn't exist yet at this build
#     stage — the forge tree is COPY'd in later.
RUN uv pip install --system --no-build-isolation \
        "sageattention @ git+https://github.com/thu-ml/SageAttention.git@v2.2.0" \
 || (echo "sage build failed — falling back to xformers (slower)" \
     && uv pip install --system --no-deps xformers \
     && touch /opt/.sage_fallback_xformers)

# clip-interrogator — Forge Neo dropped upstream's /sdapi/v1/interrogate
# endpoint. We restore it via a vendored route (modules/interrogate_neo.py)
# wrapping this package. Pinned because the package's interrogate_fast/
# interrogate_classic API surface needs to stay stable with our code.
# BLIP weights download via HF (NAS-backed hf-cache); CLIP via torch
# (NAS-backed torch-cache); prompt-embedding cache to /root/.cache/
# clip-interrogator (NAS-backed ci-cache, mounted in deployment.yaml).
RUN uv pip install --system "clip-interrogator==0.6.0"

# Purge conda-preinstalled libs whose .so files would otherwise link against a
# different numpy ABI than what we pin below ("Expected 96 from C header, got 88").
RUN python -m pip uninstall -y \
        numpy scipy scikit-image scikit-learn \
        opencv-python opencv-python-headless \
        pydantic pydantic-core fastapi gradio \
        || true

# Vendored Forge Neo fork — copy in the source tree at /opt/webui.
COPY forge/ /opt/webui/
WORKDIR /opt/webui

# Strip torch family + xformers + bitsandbytes from Forge's requirements so its
# resolver can't fight our pinned stack.
RUN sed -i \
        -e '/^torch$/d' \
        -e '/^torch[<=>[:space:]]/d' \
        -e '/^torchvision/d' \
        -e '/^torchaudio/d' \
        -e '/^xformers/d' \
        -e '/^bitsandbytes/d' \
        requirements.txt

COPY requirements.txt /tmp/overrides.txt
RUN uv pip install --system -r /tmp/overrides.txt -r /opt/webui/requirements.txt

# Bake runtime preprocessor deps — Forge installs these per cold start otherwise.
RUN uv pip install --system \
        fvcore mediapipe onnxruntime svglib handrefinerportable depth-anything \
    || echo "optional preprocessor deps unavailable — non-fatal"

# insightface builds from source on some platforms; Forge degrades gracefully.
RUN uv pip install --system insightface \
    || echo "insightface unavailable — face preprocessors will be limited"

# Vendored Ultimate SD Upscale extension fork.
COPY ultimate-upscale/ /opt/webui/extensions/ultimate-upscale-for-automatic1111/

RUN mkdir -p \
        /opt/webui/models /opt/webui/outputs /opt/webui/embeddings /opt/webui/config \
        /root/.cache/huggingface /root/.cache/torch \
 && chmod -R 0777 /opt/webui/models /opt/webui/outputs \
        /opt/webui/embeddings /opt/webui/config /root/.cache

# Pre-warm prepare_environment() so cold starts skip the asset-clone dance.
# Allow `timeout` to fire (exit 124) since a long prewarm isn't a build failure,
# but propagate any other non-zero exit so a broken dep fails the build instead
# of getting deferred to pod runtime.
SHELL ["/bin/bash", "-c"]
RUN set -o pipefail; \
    timeout 600 python launch.py --skip-torch-cuda-test --exit 2>&1 \
        | tee /opt/webui/.prewarm.log; \
    rc=${PIPESTATUS[0]}; \
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then \
        echo "pre-warm failed with exit $rc" >&2; exit "$rc"; \
    fi

RUN python -m pip cache purge || true \
 && rm -rf /root/.cache/uv /tmp/* /var/tmp/*

EXPOSE 7860

# API-only: --nowebui kills Gradio. The custom UI lives in the nginx sidecar.
HEALTHCHECK --interval=30s --timeout=10s --start-period=240s --retries=3 \
    CMD curl -fsS http://127.0.0.1:7860/docs >/dev/null || exit 1

# Bash CMD so we can branch on the sage-fallback sentinel written above.
# If sage built, run with --sage. Otherwise we installed xformers as a
# fallback; pass --xformers instead. The rest of the args are identical.
CMD bash -lc 'ATTN_FLAG="--sage"; \
    [ -f /opt/.sage_fallback_xformers ] && ATTN_FLAG="--xformers"; \
    exec python launch.py \
        --nowebui --api --api-log \
        --api-server-stop \
        --listen --port 7860 \
        --skip-torch-cuda-test \
        --highvram \
        $ATTN_FLAG \
        --ui-settings-file /opt/webui/config/config.json'
