"""
Vendored CLIP+BLIP image interrogator for Forge Neo, which dropped
/sdapi/v1/interrogate from upstream. Wraps the `clip-interrogator` PyPI
package (BLIP for caption candidates, CLIP for scoring) so the UI's
"Auto-prompt" feature can prepend a description of the source image to
the user's prompt before each upscale.

Models are downloaded on first use (~2-3 GB for the default config) and
cached at /root/.cache/clip-interrogator. The Interrogator instance is
cached in-process keyed by CLIP model name so subsequent calls reuse it.
"""
import base64
import threading
from io import BytesIO

from PIL import Image

_lock = threading.Lock()
_cache = {}  # clip_model_name -> Interrogator

DEFAULT_CLIP_MODEL = "ViT-L-14/openai"   # matches SD 1.5's text encoder family


def _get_interrogator(clip_model_name: str):
    if clip_model_name in _cache:
        return _cache[clip_model_name]
    with _lock:
        if clip_model_name in _cache:
            return _cache[clip_model_name]
        # Lazy import — clip-interrogator pulls in BLIP/openclip on import,
        # we don't want that on Forge startup, only on first interrogate.
        from clip_interrogator import Config, Interrogator
        cfg = Config(
            clip_model_name=clip_model_name,
            cache_path="/root/.cache/clip-interrogator",
            device="cuda",
        )
        _cache[clip_model_name] = Interrogator(cfg)
        return _cache[clip_model_name]


def interrogate(image_b64: str, clip_model_name: str = DEFAULT_CLIP_MODEL,
                mode: str = "fast") -> str:
    """Return a caption for the image. `mode` is "fast" (single-pass,
    ~3s) or "best" (iterative refinement, ~30s) or "classic" (a1111-
    style, ~10s). Default fast — auto-prompt should not block runs."""
    raw = base64.b64decode(image_b64)
    img = Image.open(BytesIO(raw)).convert("RGB")
    ci = _get_interrogator(clip_model_name)
    if mode == "best":
        return ci.interrogate(img)
    if mode == "classic":
        return ci.interrogate_classic(img)
    return ci.interrogate_fast(img)
